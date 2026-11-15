"""Offline voice capture + transcription (sounddevice + faster-whisper).

- Energy-based endpointing with an *adaptive* noise floor (works in quiet rooms
  and next to a fan) and a user sensitivity setting.
- "Listen once" windows: armed by the push-to-talk hotkey, a palm-hold gesture,
  or saying just the wake word. The next utterance is treated as a command
  without needing the wake word.
- A single transcription worker so commands run in order, never concurrently.
"""
import queue
import threading
import time

import numpy as np

try:
    import sounddevice as sd
except Exception as e:  # pragma: no cover - missing PortAudio etc.
    sd = None
    _SD_ERR = e

# Vocabulary hint for Whisper. It must NOT contain the wake word: with "Snap, ..."
# in the prompt Whisper hallucinated "Snap, open YouTube" on 11/12 clips of plain
# room noise (measured); without it, 0/12.
COMMAND_PROMPT = ("Scroll down. Switch to Chrome. Next tab. Open YouTube. Take note. "
                  "Remind me at 5 pm. Volume up. Pause.")


def looks_hallucinated(text):
    """Whisper loops on noise ("open YouTube. open YouTube. open YouTube...")."""
    parts = [p.strip().lower() for p in text.replace("!", ".").replace("?", ".").split(".") if p.strip()]
    return len(parts) >= 3 and len(set(parts)) <= len(parts) / 2


class VoiceListener:
    CHUNK_S = 0.1

    def __init__(self, sample_rate=16000, model_name="tiny.en", sensitivity=5, language="en"):
        self.sample_rate = sample_rate
        self.model_name = model_name
        self.language = None if language in (None, "", "auto") else language
        self.suppress_fn = None       # returns True while Snap itself is talking
        self.last_lang = "en"
        self.set_sensitivity(sensitivity)
        self.audio_queue = queue.Queue()
        self.jobs = queue.Queue()
        self.is_running = False
        self.enabled = True
        self.model = None
        self.model_error = None
        self.noise_floor = 0.004
        self.level = 0.0
        self.listen_until = 0.0
        self.on_transcript_callback = None
        self.on_status_callback = None
        self.status = "Loading speech model…"
        threading.Thread(target=self._init_model, daemon=True).start()
        threading.Thread(target=self._transcribe_worker, daemon=True).start()

    # ------------------------------------------------------------- config
    def set_sensitivity(self, level):
        level = max(1, min(10, int(level)))
        self.min_threshold = 0.03 * (0.72 ** (level - 1))   # 5 -> ~0.008

    def set_model(self, name):
        if name and name != self.model_name:
            self.model_name = name
            self.model = None
            threading.Thread(target=self._init_model, daemon=True).start()

    def set_language(self, language):
        """'auto' = detect each utterance (multilingual model), or a code like 'en'/'hi'."""
        self.language = None if language in (None, "", "auto") else language

    def set_callbacks(self, on_transcript=None, on_status=None):
        self.on_transcript_callback = on_transcript
        self.on_status_callback = on_status

    def _status(self, s):
        self.status = s
        if self.on_status_callback:
            self.on_status_callback(s)

    def _init_model(self):
        name = self.model_name
        try:
            from faster_whisper import WhisperModel
            print(f"[Voice] Loading faster-whisper ({name})…")
            import os
            # More threads is NOT faster for tiny models (8 was 2.5x slower in testing)
            threads = max(2, min(4, (os.cpu_count() or 4) // 4))
            m = WhisperModel(name, device="cpu", compute_type="int8", cpu_threads=threads)
            # warm-up so the first real command isn't slow
            m.transcribe(np.zeros(self.sample_rate, dtype=np.float32), language="en", without_timestamps=True)
            if name == self.model_name:
                self.model = m
                self.model_error = None
                print("[Voice] Speech model ready")
                self._status("Ready")
        except Exception as e:
            self.model_error = str(e)
            print("[Voice] Failed to load faster-whisper:", e)
            self._status("Speech model failed to load")

    # ------------------------------------------------------------ control
    def arm(self, seconds=6.0):
        """Treat the next utterance (within `seconds`) as a command."""
        self.listen_until = time.time() + seconds
        self._status("Listening for a command…")

    def disarm(self):
        self.listen_until = 0.0

    @property
    def armed(self):
        return time.time() < self.listen_until

    def start(self):
        if self.is_running:
            return
        self.is_running = True
        threading.Thread(target=self._listen_loop, daemon=True).start()

    def stop(self):
        self.is_running = False

    # ---------------------------------------------------------- capture
    def _audio_callback(self, indata, frames, time_info, status):
        self.audio_queue.put(indata[:, 0].copy())

    def _listen_loop(self):
        if sd is None:
            self._status("No audio library: " + str(_SD_ERR))
            return
        while self.is_running:
            try:
                with sd.InputStream(samplerate=self.sample_rate, channels=1, dtype="float32",
                                    blocksize=int(self.sample_rate * self.CHUNK_S),
                                    callback=self._audio_callback):
                    print("[Voice] Microphone open:", sd.query_devices(kind="input")["name"])
                    self._capture()
            except Exception as e:
                print("[Voice] Microphone error (retrying in 3s):", e)
                self._status("Microphone unavailable")
                time.sleep(3)

    def _capture(self):
        pre_roll = []           # audio just before speech started (catches first syllable)
        recording = []
        speaking = False
        loud_chunks = 0
        quiet_chunks = 0
        while self.is_running:
            try:
                chunk = self.audio_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            if (not self.enabled and not self.armed) or (self.suppress_fn and self.suppress_fn()):
                # muted, or Snap is talking: don't transcribe our own voice
                pre_roll, recording, speaking, loud_chunks = [], [], False, 0
                continue

            rms = float(np.sqrt(np.mean(chunk ** 2)))
            self.level = rms
            threshold = max(self.min_threshold, self.noise_floor * 3.0)

            if not speaking:
                pre_roll = (pre_roll + [chunk])[-3:]
                if rms > threshold:
                    loud_chunks += 1
                    if loud_chunks >= 2:
                        speaking = True
                        recording = list(pre_roll)
                        quiet_chunks = 0
                        self._status("Hearing you…")
                else:
                    loud_chunks = 0
                    # Track background noise only while nobody is talking
                    self.noise_floor = 0.95 * self.noise_floor + 0.05 * rms
                continue

            recording.append(chunk)
            quiet_chunks = quiet_chunks + 1 if rms < threshold * 0.8 else 0
            too_long = len(recording) * self.CHUNK_S > 10
            if quiet_chunks >= 6 or too_long:           # 0.6 s of quiet ends the phrase
                audio = np.concatenate(recording)
                speaking, recording, loud_chunks, pre_roll = False, [], 0, []
                if len(audio) >= self.sample_rate * 0.45:
                    self.jobs.put((audio, self.armed))
                else:
                    self._status("Ready")

    # ------------------------------------------------------- transcribe
    def transcribe(self, audio):
        lang = self.language if not self.model_name.endswith(".en") else "en"
        segments, info = self.model.transcribe(
            audio, language=lang, beam_size=1, temperature=0.0, without_timestamps=True,
            condition_on_previous_text=False, initial_prompt=COMMAND_PROMPT if (lang or "en") == "en" else None)
        self.last_lang = getattr(info, "language", None) or lang or "en"
        parts = []
        for seg in segments:
            if seg.no_speech_prob > 0.6 and seg.avg_logprob < -0.8:
                continue   # almost certainly noise
            parts.append(seg.text.strip())
        text = " ".join(parts).strip()
        return "" if looks_hallucinated(text) else text

    def _transcribe_worker(self):
        while True:
            audio, was_armed = self.jobs.get()
            if self.model is None:
                self._status("Speech model still loading…")
                continue
            self._status("Transcribing…")
            t = time.time()
            try:
                text = self.transcribe(audio)
            except Exception as e:
                print("[Voice] Transcription error:", e)
                self._status("Ready")
                continue
            print(f"[Voice] \"{text}\" ({time.time() - t:.2f}s)")
            if text and self.on_transcript_callback:
                self.on_transcript_callback(text, was_armed or self.armed, self.last_lang)
            elif not text:
                self._status("Ready")
