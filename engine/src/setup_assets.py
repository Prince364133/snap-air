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
from src import diag  # noqa: E402

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


class SetupCancelled(Exception):
    """The user pressed Cancel; the current download stops and the rest are skipped."""


class IncompleteDownload(Exception):
    """The server closed the connection before the whole file arrived (retried, resumed)."""


def _expected_length(r):
    """Bytes the body should have, or 0 when unknown (no header, or a compressed transfer
    whose header counts compressed bytes while iter_content yields decoded ones)."""
    if r.headers.get("Content-Encoding"):
        return 0
    try:
        return int(r.headers.get("Content-Length") or 0)
    except ValueError:
        return 0


def download_file(url, dest, timeout=(10, 120), chunk=1 << 20):
    """Download one file to dest via dest.part, renamed only once it is complete: a dropped
    connection never leaves a truncated model that later looks "installed"."""
    part = dest + ".part"
    with requests.get(url, stream=True, timeout=timeout) as r:
        r.raise_for_status()
        expected, got = _expected_length(r), 0
        with open(part, "wb") as f:
            for c in r.iter_content(chunk):
                f.write(c)
                got += len(c)
    if expected and got != expected:
        try:
            os.remove(part)
        except OSError as e:
            diag.record("setup.remove_partial", e, quiet=True)
        raise IncompleteDownload(f"{os.path.basename(dest)}: got {got} of {expected} bytes")
    os.replace(part, dest)
    return dest


# ------------------------------------------------------------ installer checks
def authenticode(path):
    """(status, signer subject) of a file's Authenticode signature, via PowerShell.
    The path goes through an environment variable, never into the command text."""
    import subprocess
    script = ("$s = Get-AuthenticodeSignature -LiteralPath $env:SNAPY_VERIFY_FILE; "
              "Write-Output ($s.Status.ToString() + '|' + [string]$s.SignerCertificate.Subject)")
    out = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                         env={**os.environ, "SNAPY_VERIFY_FILE": path}, capture_output=True, text=True,
                         timeout=60, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    status, _, subject = (out.stdout or "").strip().partition("|")
    return status or "UnknownError", subject


def verify_installer(path, expected_size=0, signature_fn=None):
    """Raise RuntimeError unless a downloaded installer is complete and, on Windows, validly
    signed by the publisher in app.json ("ollama.installer_signer"). Runs before the file
    is ever executed: a truncated, corrupted or swapped installer is refused."""
    got = os.path.getsize(path)
    if expected_size and got != expected_size:
        raise RuntimeError(f"the download is incomplete ({got} of {expected_size} bytes)")
    if not appdata.get("ollama.require_signature", True):
        return
    if signature_fn is None:
        if sys.platform != "win32":
            return
        signature_fn = authenticode
    status, subject = signature_fn(path)
    if status != "Valid":
        raise RuntimeError(f"the installer's digital signature is not valid ({status})")
    want = (appdata.get("ollama.installer_signer") or "").lower()
    if want and want not in (subject or "").lower():
        raise RuntimeError("the installer is signed by an unexpected publisher")


class Setup:
    """Runs the first-run downloads one by one and reports progress."""

    def __init__(self, on_change=None):
        self.on_change = on_change
        self.items = []
        self.running = False
        self._cancel = threading.Event()
        self._last_emit = 0.0
        self._lock = threading.Lock()

    # ------------------------------------------------------------ lifecycle
    def try_start(self):
        """Atomically claim the setup run; False if one is already in progress."""
        with self._lock:
            if self.running:
                return False
            self.running = True
            self._cancel.clear()
            return True

    def finish(self):
        with self._lock:
            self.running = False
        self._emit(force=True)

    @property
    def cancelled(self):
        return self._cancel.is_set()

    def check_cancel(self):
        if self._cancel.is_set():
            raise SetupCancelled()

    def cancel(self):
        """Stop the running download and skip what's left. `running` stays True until the
        worker thread actually exits, so a retry can't start a second run alongside it."""
        self._cancel.set()
        for it in self.items:
            if it.get("state") in ("waiting", "downloading"):
                it.update(state="cancelled", speed=0)
        self._emit(force=True)

    # ------------------------------------------------------------- state
    def _item(self, id_, label, desc, size_hint):
        return {"id": id_, "label": label, "desc": desc, "state": "waiting", "done": 0, "total": size_hint,
                "speed": 0, "error": None}

    def plan(self, need_speech, need_voice, need_runtime, need_brain, brain_name=""):
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
        return {"type": "setup", "running": self.running, "items": self.items, "done": done, "total": total,
                "cancelled": any(i["state"] == "cancelled" for i in self.items),
                "complete": bool(self.items) and all(i["state"] in ("done", "skipped") for i in self.items)}

    def _emit(self, force=False):
        now = time.time()
        if not force and now - self._last_emit < 0.25:
            return
        self._last_emit = now
        if self.on_change:
            try:
                self.on_change(self.state())
            except Exception as e:
                diag.record("setup.emit", e, quiet=True)

    def get(self, id_):
        return next((i for i in self.items if i["id"] == id_), None)

    def update(self, id_, **kw):
        it = self.get(id_)
        if it:
            it.update(kw)
            self._emit(force=kw.get("state") is not None)

    # --------------------------------------------------------- downloads
    def fetch(self, id_, urls_dests):
        """Download several files as one progress item, resuming partial files.
        Raises SetupCancelled when the user cancels (the .part file is kept for resuming)."""
        self.check_cancel()
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
                if size and have > size:                           # a stale/corrupt partial: start over
                    os.remove(part)
                    have = 0
                if size and have == size:                          # finished before (e.g. crash before rename)
                    os.replace(part, dest)
                    break
                headers = {"Range": f"bytes={have}-"} if have else {}
                try:
                    with requests.get(url, stream=True, timeout=(10, 60), headers=headers) as r:
                        if have and r.status_code != 206:          # server ignored Range: start over
                            have = 0
                        r.raise_for_status()
                        compressed = bool(r.headers.get("Content-Encoding"))   # decoded bytes != Content-Length
                        with open(part, "ab" if have else "wb") as f:
                            for chunk in r.iter_content(1 << 18):
                                self.check_cancel()
                                f.write(chunk)
                                have += len(chunk)
                                it["done"] = base + have
                                el = time.time() - t0
                                if el > 1:
                                    it["speed"] = int((it["done"] - b0) / el)
                                    if el > 4:
                                        t0, b0 = time.time(), it["done"]
                                self._emit()
                    # a connection that closes cleanly mid-file ends iter_content without an
                    # error: never install a truncated model, resume it instead
                    if size and not compressed and have != size:
                        raise IncompleteDownload(f"got {have} of {size} bytes")
                    os.replace(part, dest)
                    break
                except (requests.RequestException, IncompleteDownload) as e:
                    if attempt == 3:
                        raise RuntimeError(f"network error: {e}") from e
                    self.update(id_, error="Connection dropped — retrying…")
                    if self._cancel.wait(2 * (attempt + 1)):     # wake immediately on Cancel
                        raise SetupCancelled()
            base += os.path.getsize(dest)
            it["done"] = base
        self.update(id_, state="done", done=it["total"], speed=0, error=None)
