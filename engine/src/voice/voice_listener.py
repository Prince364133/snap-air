"""Offline voice capture + transcription (sounddevice + faster-whisper).

- Energy-based endpointing with an *adaptive* noise floor (works in quiet rooms
  and next to a fan) and a user sensitivity setting.
- "Listen once" windows: armed by the push-to-talk hotkey, a palm-hold gesture,
  or saying just the wake word. The next utterance is treated as a command
  without needing the wake word.
- A single transcription worker so commands run in order, never concurrently.
"""
import os
import queue
import sys
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
        self.suppress_fn = None       # legacy: returns True to mute the mic completely
        # Barge-in (full duplex): the mic stays open while Snap talks.
        self.talking_fn = None        # True while Snap is speaking
        self.echo_level_fn = None     # current playback RMS (what the speakers are putting out)
        self.headphones_fn = None     # True = no speaker echo, use the normal threshold
        self.on_barge_in = None       # called the moment the user starts talking over Snap
        self.coupling = 0.3           # learned ratio mic-RMS / playback-RMS (speaker echo)
        self.last_lang = "en"
        self.mic_blocked = False
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
            # More threads is NOT faster for tiny models (8 was 2.5x slower in testing)
            threads = max(2, min(4, (os.cpu_count() or 4) // 4))
            # the installer ships tiny.en so voice works offline on first launch
            bundled = os.path.join(os.path.dirname(sys.executable) if getattr(sys, "frozen", False)
                                   else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                                   "models", f"faster-whisper-{name}")
            m = WhisperModel(bundled if os.path.isdir(bundled) else name, device="cpu", compute_type="int8",
                             cpu_threads=threads)
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

    def _input_candidates(self):
        """Default device first, then the same microphone through other Windows audio
        APIs (some drivers refuse MME at 16 kHz), then any other input device."""
        cands = [(None, None)]
        try:
            default = sd.query_devices(kind="input")
            base = default["name"].split("(")[0].strip().lower()
            apis = {i: h["name"] for i, h in enumerate(sd.query_hostapis())}
            order = {"Windows WASAPI": 0, "Windows DirectSound": 1, "MME": 2, "Windows WDM-KS": 3}
            devs = [(i, d) for i, d in enumerate(sd.query_devices()) if d["max_input_channels"] > 0]
            devs.sort(key=lambda x: (0 if x[1]["name"].lower().startswith(base) else 1,
                                     order.get(apis.get(x[1]["hostapi"], ""), 9)))
            for i, d in devs:
                extra = None
                if apis.get(d["hostapi"]) == "Windows WASAPI":
                    try:
                        extra = sd.WasapiSettings(auto_convert=True)
                    except TypeError:
                        extra = None
                cands.append((i, extra))
        except Exception:
            pass
        return cands

    def _listen_loop(self):
        if sd is None:
            self._status("No audio library: " + str(_SD_ERR))
            return
        while self.is_running:
            opened = False
            last_err = None
            for device, extra in self._input_candidates():
                try:
                    with sd.InputStream(device=device, samplerate=self.sample_rate, channels=1, dtype="float32",
                                        blocksize=int(self.sample_rate * self.CHUNK_S), extra_settings=extra,
                                        callback=self._audio_callback):
                        name = sd.query_devices(device if device is not None else sd.default.device[0])["name"]
                        print("[Voice] Microphone open:", name)
                        opened = True
                        self._capture()
                    break
                except Exception as e:
                    last_err = e
                    if not opened and not getattr(self, "_logged_candidates", False):
                        print(f"[Voice]   device {device}: {e}")
                    if opened:
                        break        # it was working and then failed: restart from the default device
            if not opened:
                self._logged_candidates = True
                print("[Voice] Microphone error (retrying in 3s):", last_err)
                # Every API failing with these errors = Windows privacy has denied this app the mic
                blocked = any(k in str(last_err) for k in ("MME error 1", "DirectSound error", "Invalid device"))
                self.mic_blocked = blocked
                self._status("Microphone blocked by Windows privacy settings" if blocked else "Microphone unavailable")
                # Re-initialise PortAudio: other native libraries loading at startup can leave
                # its device list stale ("Invalid device" / MME host errors).
                try:
                    sd._terminate()
                    sd._initialize()
                except Exception as e:
                    print("[Voice] PortAudio reset failed:", e)
            time.sleep(3 if not opened else 0.5)

    def _capture(self):
        pre_roll = []           # audio just before speech started (catches first syllable)
        recording = []
        speaking = False
        barged = False
        loud_chunks = 0
        quiet_chunks = 0
        while self.is_running:
            try:
                chunk = self.audio_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            talking = bool(self.talking_fn and self.talking_fn())
            if (self.suppress_fn and self.suppress_fn()) or (not self.enabled and not self.armed and not talking):
                pre_roll, recording, speaking, loud_chunks = [], [], False, 0
                continue

            rms = float(np.sqrt(np.mean(chunk ** 2)))
            self.level = rms
            threshold = max(self.min_threshold, self.noise_floor * 3.0)
            need = 2
            echo_guard = talking and not (self.headphones_fn and self.headphones_fn())
            if echo_guard:
                # Echo guard: our own voice leaks from the speakers into the mic, so the bar
                # to count as "the user is talking" rises with what we're playing right now.
                echo = self.echo_level_fn() if self.echo_level_fn else 0.0
                threshold = max(threshold * 2.5, echo * self.coupling * 2.5)
                need = 3                                       # 300 ms of clear speech
                if not speaking and echo > 0.01:
                    self.coupling = 0.97 * self.coupling + 0.03 * min(2.0, rms / echo)

            if not speaking:
                pre_roll = (pre_roll + [chunk])[-3:]
                if rms > threshold:
                    loud_chunks += 1
                    if loud_chunks >= need:
                        speaking = True
                        recording = list(pre_roll)
                        quiet_chunks = 0
                        barged = talking
                        if talking and self.on_barge_in:
                            self.on_barge_in()                 # stop playback immediately
                        self._status("Hearing you…")
                else:
                    loud_chunks = 0
                    if not talking:
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
                    # talking over Snap counts as addressing Snap (no wake word needed)
                    self.jobs.put((audio, self.armed or barged))
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
