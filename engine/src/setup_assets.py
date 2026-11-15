"""First-run setup: download everything that isn't inside the (small) installer,
with real byte-level progress for the "Setting up Snapy" screen.

Components, in order:
  speech  — speech recognition model (Whisper tiny.en, ~75 MB)       needed to hear you
  voice   — Snapy's natural voice (Kokoro int8, ~115 MB)              Windows voice is used meanwhile
  runtime — local AI engine (Ollama, ~1 GB installer)                 skipped if installed / cloud-only
  brain   — the AI model sized for this PC (e.g. Qwen3 1.7B, ~1.4 GB) skipped if installed / cloud-only

Downloads resume after a dropped connection (HTTP Range) and retry a few times.
"""
import os
import sys
import threading
import time

import requests

from src import storage, appdata

# download sources come from src/data/app.json
WHISPER_REPO = appdata.get("speech_models.repo_url")
WHISPER_FILES = appdata.get("speech_models.files")
KOKORO_URL = appdata.get("voice_model.url")
KOKORO_FILES = appdata.get("voice_model.files")


def models_root():
    return os.path.join(storage.data_dir(), "models")


def _bundled(*parts):
    if getattr(sys, "frozen", False):
        p = os.path.join(os.path.dirname(sys.executable), "models", *parts)
        return p if os.path.exists(p) else None
    return None


def whisper_dir(name="tiny.en"):
    """Where the speech model lives: bundled (full installer) or downloaded."""
    b = _bundled(f"faster-whisper-{name}")
    if b and os.path.exists(os.path.join(b, "model.bin")):
        return b
    return os.path.join(models_root(), f"faster-whisper-{name}")


def whisper_ready(name="tiny.en"):
    d = whisper_dir(name)
    return all(os.path.exists(os.path.join(d, f)) for f in WHISPER_FILES)


def kokoro_ready():
    from src.voice.tts import model_dir
    d = model_dir()
    return all(os.path.exists(os.path.join(d, f)) for f in KOKORO_FILES)


class Setup:
    """Runs the first-run downloads one by one and reports progress."""

    def __init__(self, on_change=None):
        self.on_change = on_change
        self.items = []
        self.running = False
        self._cancelled = False
        self._last_emit = 0.0
        self._lock = threading.Lock()

    def cancel(self):
        self._cancelled = True
        self.running = False
        for it in self.items:
            if it.get("state") == "downloading":
                it["state"] = "cancelled"
        self._emit(force=True)

    # ------------------------------------------------------------- state
    def _item(self, id_, label, desc, size_hint):
        return {"id": id_, "label": label, "desc": desc, "state": "waiting", "done": 0, "total": size_hint,
                "speed": 0, "error": None}

    def plan(self, need_speech, need_voice, need_runtime, need_brain, brain_name=""):
        self._cancelled = False
        items = []
        est = appdata.get("setup_size_estimates", {})          # replaced by real sizes once known
        if need_speech:
            items.append(self._item("speech", "Speech recognition", "So Snapy can understand what you say", est.get("speech", 0)))
        if need_voice:
            items.append(self._item("voice", "Snapy’s voice", "A natural voice for spoken replies", est.get("voice", 0)))
        if need_runtime:
            items.append(self._item("runtime", "Local AI engine", "Runs AI privately on this PC (Ollama)", est.get("runtime", 0)))
        if need_brain:
            items.append(self._item("brain", "AI model", f"{brain_name} — chosen for this PC’s hardware", est.get("brain", 0)))
        self.items = items
        self._emit(force=True)

    def state(self):
        total = sum(i["total"] or 0 for i in self.items)
        done = sum(min(i["done"], i["total"] or i["done"]) if i["state"] != "done" else (i["total"] or 0) for i in self.items)
        return {"type": "setup", "running": self.running, "items": self.items,
                "done": done, "total": total, "complete": bool(self.items) and all(i["state"] in ("done", "skipped") for i in self.items)}

    def _emit(self, force=False):
        now = time.time()
        if not force and now - self._last_emit < 0.25:
            return
        self._last_emit = now
        if self.on_change:
            try:
                self.on_change(self.state())
            except Exception:
                pass

    def get(self, id_):
        return next((i for i in self.items if i["id"] == id_), None)

    def update(self, id_, **kw):
        it = self.get(id_)
        if it:
            it.update(kw)
            self._emit(force=kw.get("state") is not None)

    # --------------------------------------------------------- downloads
    def fetch(self, id_, urls_dests):
        """Download several files as one progress item, resuming partial files."""
        if self._cancelled:
            return
        it = self.get(id_)
        sizes = []
        for url, _ in urls_dests:
            try:
                h = requests.head(url, allow_redirects=True, timeout=15)
                sizes.append(int(h.headers.get("content-length") or 0))
            except requests.RequestException:
                sizes.append(0)
        if all(sizes):
            it["total"] = sum(sizes)
        self.update(id_, state="downloading", error=None)
        base = 0
        t0, b0 = time.time(), 0
        for (url, dest), size in zip(urls_dests, sizes):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.exists(dest) and (not size or os.path.getsize(dest) == size):
                base += os.path.getsize(dest)
                it["done"] = base
                continue
            part = dest + ".part"
            for attempt in range(4):
                have = os.path.getsize(part) if os.path.exists(part) else 0
                headers = {"Range": f"bytes={have}-"} if have else {}
                try:
                    with requests.get(url, stream=True, timeout=(10, 60), headers=headers) as r:
                        if have and r.status_code != 206:          # server ignored Range: start over
                            have = 0
                        r.raise_for_status()
                        with open(part, "ab" if have else "wb") as f:
                            for chunk in r.iter_content(1 << 18):
                                f.write(chunk)
                                have += len(chunk)
                                it["done"] = base + have
                                el = time.time() - t0
                                if el > 1:
                                    it["speed"] = int((it["done"] - b0) / el)
                                    if el > 4:
                                        t0, b0 = time.time(), it["done"]
                                self._emit()
                    os.replace(part, dest)
                    break
                except requests.RequestException as e:
                    if attempt == 3:
                        raise RuntimeError(f"network error: {e}") from e
                    self.update(id_, error="Connection dropped — retrying…")
                    time.sleep(2 * (attempt + 1))
            base += os.path.getsize(dest)
            it["done"] = base
        self.update(id_, state="done", done=it["total"], speed=0, error=None)
