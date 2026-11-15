"""Local LLM client (Ollama). Structured JSON output instead of native tool
calling (smaller prompts on CPU + avoids Qwen3.5 think/tool-format bugs, see
docs/RESEARCH.md §3). Models are swappable from Settings."""
import json
import os
import re
import shutil
import subprocess
import threading
import time

import requests

# Measured on a Ryzen 7 7730U laptop (docs/RESEARCH.md §3): qwen3 reuses the
# prompt cache between turns (~0.7 s prompt), qwen3.5 does not (~18-27 s/turn).
DEFAULT_MODEL = "qwen3:1.7b"
EMBED_MODEL = "embeddinggemma"
RECOMMENDED = [
    {"name": "qwen3:1.7b", "label": "Fast — Qwen3 1.7B (recommended for laptops)", "size": "1.4 GB",
     "ram": "2 GB free", "note": "First words in ~3-4 s on a laptop CPU. Multilingual, good with your memory and tasks."},
    {"name": "qwen3:4b", "label": "Smarter — Qwen3 4B", "size": "2.5 GB", "ram": "5 GB free",
     "note": "Better reasoning and fewer mistakes; about twice as slow on CPU."},
    {"name": "qwen3.5:4b", "label": "Best quality — Qwen3.5 4B", "size": "3.4 GB", "ram": "6 GB free + GPU",
     "note": "Most capable, but slow on CPU-only laptops (no prompt caching). Use with a GPU."},
]


def _ollama_exe():
    cands = [os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Ollama", "ollama.exe"),
             r"C:\Program Files\Ollama\ollama.exe", shutil.which("ollama") or ""]
    return next((c for c in cands if c and os.path.exists(c)), None)


class LLM:
    def __init__(self, settings=None, host="http://127.0.0.1:11434"):
        self.settings = settings
        self.host = host
        self.busy = threading.Event()        # set while a user-facing turn runs
        self.fg_lock = threading.Lock()
        self._embed_ok = None
        self._embed_checked = 0.0
        self.pulling = None                  # {"name", "pct", "status"}
        self.last_error = None

    # ------------------------------------------------------------ config
    @property
    def model(self):
        return (self.settings.get("llm_model") if self.settings else None) or DEFAULT_MODEL

    @property
    def keep_alive(self):
        return (self.settings.get("llm_keep_alive") if self.settings else None) or "5m"

    # ------------------------------------------------------------ server
    def available(self, timeout=1.5):
        try:
            return requests.get(self.host + "/api/version", timeout=timeout).ok
        except requests.RequestException:
            return False

    def ensure_server(self):
        if self.available():
            return True
        exe = _ollama_exe()
        if not exe:
            self.last_error = "Ollama is not installed"
            return False
        try:
            subprocess.Popen([exe, "serve"], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.last_error = str(e)
            return False
        for _ in range(20):
            time.sleep(0.5)
            if self.available():
                return True
        self.last_error = "Ollama did not start"
        return False

    def installed_models(self):
        try:
            r = requests.get(self.host + "/api/tags", timeout=3)
            return [m["name"] for m in r.json().get("models", [])]
        except (requests.RequestException, ValueError):
            return []

    def has_model(self, name=None):
        name = name or self.model
        models = self.installed_models()
        return any(m == name or m == name + ":latest" or m.split(":")[0] == name for m in models)

    def ready(self):
        # cached briefly: called on every conversation turn
        now = time.time()
        if now - getattr(self, "_ready_t", 0) < 30 and getattr(self, "_ready", False):
            return True
        self._ready = self.available() and self.has_model()
        self._ready_t = now
        return self._ready

    def status(self):
        up = self.available()
        installed = self.installed_models() if up else []
        return {"server": up, "installed": installed, "current": self.model,
                "ready": up and any(m.startswith(self.model) for m in installed),
                "pulling": self.pulling, "recommended": RECOMMENDED, "error": self.last_error,
                "ollama_installed": bool(_ollama_exe())}

    def pull(self, name, on_progress=None):
        """Download a model with progress callbacks (pct 0..100)."""
        self.pulling = {"name": name, "pct": 0, "status": "starting"}
        try:
            with requests.post(self.host + "/api/pull", json={"name": name, "stream": True},
                               stream=True, timeout=(5, 600)) as r:
                for line in r.iter_lines():
                    if not line:
                        continue
                    d = json.loads(line)
                    if d.get("error"):
                        raise RuntimeError(d["error"])
                    total, done = d.get("total"), d.get("completed")
                    pct = round(done * 100 / total, 1) if total and done else self.pulling["pct"]
                    self.pulling = {"name": name, "pct": pct, "status": d.get("status", "")}
                    if on_progress:
                        on_progress(self.pulling)
            self.pulling = None
            return True
        except Exception as e:
            self.last_error = f"Download failed: {e}"
            self.pulling = {"name": name, "pct": 0, "status": "error", "error": str(e)}
            if on_progress:
                on_progress(self.pulling)
            return False

    # -------------------------------------------------------------- chat
    def _payload(self, messages, schema=None, max_tokens=256, temperature=0.4, stream=False):
        p = {"model": self.model, "messages": messages, "stream": stream, "think": False,
             "keep_alive": self.keep_alive,
             "options": {"temperature": temperature, "num_predict": max_tokens, "num_ctx": 4096}}
        if schema:
            p["format"] = schema
        return p

    @staticmethod
    def _clean(text):
        return re.sub(r"<think>.*?</think>", "", text or "", flags=re.S).strip()

    def chat_json(self, messages, schema, max_tokens=256, temperature=0.2, background=True):
        """Blocking structured call. Background callers wait for user-facing turns."""
        if background:
            while self.busy.is_set():
                time.sleep(0.3)
        r = requests.post(self.host + "/api/chat", json=self._payload(messages, schema, max_tokens, temperature),
                          timeout=180)
        r.raise_for_status()
        text = self._clean(r.json()["message"]["content"])
        try:
            return json.loads(text)
        except ValueError:
            m = re.search(r"\{.*\}", text, re.S)
            return json.loads(m.group()) if m else {}

    def chat_text(self, messages, max_tokens=300, temperature=0.4, background=True):
        if background:
            while self.busy.is_set():
                time.sleep(0.3)
        r = requests.post(self.host + "/api/chat", json=self._payload(messages, None, max_tokens, temperature),
                          timeout=300)
        r.raise_for_status()
        return self._clean(r.json()["message"]["content"])

    def stream(self, messages, schema=None, max_tokens=300, temperature=0.4, cancel=None):
        """Yield content chunks as they are generated (user-facing: takes priority)."""
        with self.fg_lock:
            self.busy.set()
            try:
                with requests.post(self.host + "/api/chat", stream=True, timeout=(5, 300),
                                   json=self._payload(messages, schema, max_tokens, temperature, stream=True)) as r:
                    r.raise_for_status()
                    for line in r.iter_lines():
                        if cancel is not None and cancel.is_set():
                            break
                        if not line:
                            continue
                        d = json.loads(line)
                        chunk = d.get("message", {}).get("content", "")
                        if chunk:
                            yield chunk
                        if d.get("done"):
                            self.last_stats = {k: d.get(k) for k in ("prompt_eval_count", "prompt_eval_duration",
                                                                     "eval_count", "eval_duration", "load_duration")}
                            break
            finally:
                self.busy.clear()

    # ------------------------------------------------------------ embeds
    def embed(self, texts):
        if not texts:
            return []
        now = time.time()
        if self._embed_ok is False and now - self._embed_checked < 300:
            return None
        try:
            r = requests.post(self.host + "/api/embed", json={"model": EMBED_MODEL, "input": texts,
                                                              "keep_alive": "10m"}, timeout=60)
            if not r.ok:
                raise RuntimeError(r.text[:200])
            self._embed_ok = True
            return r.json().get("embeddings")
        except Exception:
            self._embed_ok, self._embed_checked = False, now
            return None


class JsonFieldStreamer:
    """Incrementally extracts the value of one string field (e.g. "say") from a
    JSON object as it streams, so speech can start before the JSON is complete."""

    def __init__(self, field="say"):
        self.buf = ""
        self.field = field
        self.pos = None
        self.done = False
        self.emitted = 0

    def feed(self, chunk):
        self.buf += chunk
        if self.done:
            return ""
        if self.pos is None:
            m = re.search(r'"' + self.field + r'"\s*:\s*"', self.buf)
            if not m:
                return ""
            self.pos = m.end()
        out, i, s = [], self.pos, self.buf
        while i < len(s):
            c = s[i]
            if c == "\\":
                if i + 1 >= len(s):
                    break
                nxt = s[i + 1]
                if nxt == "u":
                    if i + 6 > len(s):
                        break
                    try:
                        out.append(chr(int(s[i + 2:i + 6], 16)))
                    except ValueError:
                        pass
                    i += 6
                    continue
                out.append({"n": "\n", "t": " ", '"': '"', "\\": "\\", "/": "/"}.get(nxt, nxt))
                i += 2
                continue
            if c == '"':
                self.done = True
                i += 1
                break
            out.append(c)
            i += 1
        self.pos = i
        return "".join(out)
