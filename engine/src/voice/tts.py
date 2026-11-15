"""Text-to-speech: Kokoro-82M int8 (Apache-2.0, 8 languages) with a Windows
SAPI fallback. Two threads: one synthesizes the next sentence while the other
plays the current one, so long replies start speaking almost immediately."""
import os
import queue
import re
import subprocess
import sys
import threading
import time

import numpy as np

try:
    import sounddevice as sd
except Exception:  # pragma: no cover
    sd = None

from src import storage

# whisper language code -> (kokoro voice, kokoro lang)
VOICES = {
    "en": ("af_heart", "en-us"), "hi": ("hf_alpha", "hi"), "es": ("ef_dora", "es"), "fr": ("ff_siwis", "fr-fr"),
    "it": ("if_sara", "it"), "ja": ("jf_alpha", "ja"), "pt": ("pf_dora", "pt-br"), "zh": ("zf_xiaobei", "cmn"),
}
ENGLISH_VOICES = [("af_heart", "Heart (warm, female)"), ("af_bella", "Bella (bright, female)"),
                  ("af_nicole", "Nicole (soft, female)"), ("am_michael", "Michael (calm, male)"),
                  ("am_fenrir", "Fenrir (deep, male)"), ("bf_emma", "Emma (British, female)"),
                  ("bm_george", "George (British, male)")]
KOKORO_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"
DEVANAGARI = re.compile(r"[ऀ-ॿ]")


def model_dir():
    return os.path.join(storage.data_dir(), "models", "kokoro")


class SentenceChunker:
    """Turns a token stream into speakable chunks. The first chunk may break at a
    comma so the voice starts sooner."""

    END = re.compile(r"(.+?[.!?।]+[\"')\]]*)(\s+|$)", re.S)

    def __init__(self):
        self.buf = ""
        self.first = True

    def feed(self, text):
        self.buf += text
        out = []
        while True:
            m = self.END.match(self.buf)
            if self.first and (m is None or m.end() > 60) and len(self.buf) > 30:
                # long first sentence: start speaking at the first comma
                cm = re.match(r"(.{12,}?[,;:])\s+", self.buf)
                if cm and (m is None or cm.end() < m.end()):
                    out.append(cm.group(1).strip())
                    self.buf = self.buf[cm.end():]
                    self.first = False
                    continue
            if m and (m.group(2) or len(self.buf) > m.end()):
                out.append(m.group(1).strip())
                self.buf = self.buf[m.end():]
                self.first = False
                continue
            if self.first and len(self.buf) > 40:
                cm = re.match(r"(.{20,}?[,;:])\s+", self.buf)
                if cm:
                    out.append(cm.group(1).strip())
                    self.buf = self.buf[cm.end():]
                    self.first = False
                    continue
            break
        return [s for s in out if re.search(r"\w", s)]

    def flush(self):
        rest, self.buf = self.buf.strip(), ""
        return [rest] if re.search(r"\w", rest) else []


def clean_for_speech(text):
    t = re.sub(r"`{1,3}[^`]*`{1,3}", "", text)          # code
    t = re.sub(r"https?://\S+", "a link", t)
    t = re.sub(r"[*_#>|]+", "", t)
    t = re.sub(r"\s+", " ", t)
    return t.strip()


class Speaker:
    def __init__(self, settings=None, on_level=None, on_state=None):
        self.settings = settings
        self.on_level = on_level or (lambda lvl: None)
        self.on_state = on_state or (lambda speaking: None)
        self.kokoro = None
        self.engine = "none"
        self.text_q = queue.Queue()
        self.audio_q = queue.Queue(maxsize=4)
        self.gen = 0
        self.speaking = False
        self.last_spoke = 0.0
        self._pending = 0
        self._lock = threading.Lock()
        self._sapi = None
        threading.Thread(target=self._load, daemon=True).start()
        threading.Thread(target=self._synth_loop, daemon=True).start()
        threading.Thread(target=self._play_loop, daemon=True).start()

    def _s(self, k, d):
        v = self.settings.get(k) if self.settings else None
        return d if v is None else v

    @property
    def enabled(self):
        return bool(self._s("tts_enabled", True))

    def _download(self, d, files):
        """First run: fetch the natural voice (~120 MB). The Windows voice is used meanwhile."""
        import requests
        os.makedirs(d, exist_ok=True)
        for name in files:
            dest = os.path.join(d, name)
            if os.path.exists(dest):
                continue
            print(f"[TTS] Downloading {name}…")
            with requests.get(KOKORO_URL + name, stream=True, timeout=(10, 120)) as r:
                r.raise_for_status()
                with open(dest + ".part", "wb") as f:
                    for chunk in r.iter_content(1 << 20):
                        f.write(chunk)
            os.replace(dest + ".part", dest)

    def _load(self):
        d = model_dir()
        onnx, voices = os.path.join(d, "kokoro-v1.0.int8.onnx"), os.path.join(d, "voices-v1.0.bin")
        if not (os.path.exists(onnx) and os.path.exists(voices)):
            self.engine = "sapi" if sys.platform == "win32" else "none"
            try:
                self._download(d, ["voices-v1.0.bin", "kokoro-v1.0.int8.onnx"])
            except Exception as e:
                print("[TTS] Couldn't download the natural voice (offline?):", e)
        if os.path.exists(onnx) and os.path.exists(voices):
            try:
                from kokoro_onnx import Kokoro
                self.kokoro = Kokoro(onnx, voices)
                self.kokoro.create("Ready.", voice="af_heart", lang="en-us")   # warm-up
                self.engine = "kokoro"
                print("[TTS] Kokoro ready")
                return
            except Exception as e:
                print("[TTS] Kokoro failed, using Windows voice:", e)
        self.engine = "sapi" if sys.platform == "win32" else "none"

    # ------------------------------------------------------------ API
    def say(self, text, lang="en"):
        """Queue one chunk of speech (call repeatedly while streaming)."""
        text = clean_for_speech(text)
        if not text or not self.enabled:
            return
        with self._lock:
            self._pending += 1
        self.text_q.put((self.gen, text, lang))

    def interrupt(self):
        with self._lock:
            self.gen += 1
            self._pending = 0
        for q in (self.text_q, self.audio_q):
            while True:
                try:
                    q.get_nowait()
                except queue.Empty:
                    break
        if self._sapi:
            try:
                self._sapi.kill()
            except Exception:
                pass
            self._sapi = None
        self._set_speaking(False)

    @property
    def busy(self):
        return self.speaking or self._pending > 0

    def wait_done(self, timeout=60):
        end = time.time() + timeout
        while self.busy and time.time() < end:
            time.sleep(0.05)

    def _set_speaking(self, on):
        if on != self.speaking:
            self.speaking = on
            if not on:
                self.last_spoke = time.time()
                self.on_level(0.0)
            self.on_state(on)

    # --------------------------------------------------------- workers
    def _voice_for(self, text, lang):
        if DEVANAGARI.search(text):
            lang = "hi"
        voice, klang = VOICES.get((lang or "en")[:2], VOICES["en"])
        if klang == "en-us":
            voice = self._s("tts_voice", "af_heart") or "af_heart"
            if voice.startswith("b"):
                klang = "en-gb"
        return voice, klang

    def _synth_loop(self):
        while True:
            gen, text, lang = self.text_q.get()
            if gen != self.gen:
                continue
            for _ in range(100):           # wait for the model to finish loading
                if self.engine != "none" or self.kokoro:
                    break
                time.sleep(0.1)
            try:
                if self.kokoro:
                    voice, klang = self._voice_for(text, lang)
                    samples, sr = self.kokoro.create(text, voice=voice, lang=klang,
                                                     speed=float(self._s("tts_speed", 1.0)))
                    if gen == self.gen:
                        self.audio_q.put((gen, samples.astype(np.float32), sr))
                elif self.engine == "sapi":
                    if gen == self.gen:
                        self.audio_q.put((gen, text, None))
            except Exception as e:
                print("[TTS] synth error:", e)
                with self._lock:
                    self._pending = max(0, self._pending - 1)

    def _play_loop(self):
        while True:
            try:
                gen, audio, sr = self.audio_q.get(timeout=0.25)
            except queue.Empty:
                if self.speaking and self._pending <= 0:
                    self._set_speaking(False)
                continue
            if gen != self.gen:
                continue
            self._set_speaking(True)
            try:
                if sr is None:
                    self._speak_sapi(audio, gen)
                else:
                    self._play(audio, sr, gen)
            except Exception as e:
                print("[TTS] playback error:", e)
            with self._lock:
                self._pending = max(0, self._pending - 1)
            if self._pending <= 0 and self.audio_q.empty():
                self._set_speaking(False)

    def _play(self, audio, sr, gen):
        if sd is None:
            return
        block = int(sr * 0.04)
        vol = float(self._s("tts_volume", 1.0))
        with sd.OutputStream(samplerate=sr, channels=1, dtype="float32", blocksize=block) as out:
            for i in range(0, len(audio), block):
                if gen != self.gen:
                    break
                chunk = audio[i:i + block] * vol
                self.on_level(float(np.sqrt(np.mean(chunk ** 2))) if len(chunk) else 0.0)
                out.write(chunk.reshape(-1, 1))

    def _speak_sapi(self, text, gen):
        script = ("Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
                  "$s.Speak([Console]::In.ReadToEnd())")
        self._sapi = subprocess.Popen(["powershell", "-NoProfile", "-Command", script], stdin=subprocess.PIPE,
                                      creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self._sapi.stdin.write(text.encode("utf-8"))
        self._sapi.stdin.close()
        t = 0.0
        while self._sapi and self._sapi.poll() is None and gen == self.gen:
            t += 0.08
            self.on_level(0.04 + 0.03 * abs(np.sin(t * 7)))   # gentle orb motion
            time.sleep(0.08)
        self._sapi = None
