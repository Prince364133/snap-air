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
# Every local model we offer, 1B -> 14B. "params" drives device compatibility.
CATALOG = [
    {"name": "llama3.2:1b", "label": "Llama 3.2 1B", "params": 1.2, "size": "1.3 GB", "note": "Tiny and very fast; basic chat only."},
    {"name": "gemma3:1b", "label": "Gemma 3 1B", "params": 1.0, "size": "0.8 GB", "note": "Smallest download; simple answers."},
    {"name": "qwen2.5:1.5b", "label": "Qwen2.5 1.5B", "params": 1.5, "size": "1.0 GB", "note": "Fast, multilingual, good at short commands."},
    {"name": "qwen3:1.7b", "label": "Qwen3 1.7B", "params": 1.7, "size": "1.4 GB", "note": "Best small all-rounder: multilingual (Hinglish), uses your memory and tasks well."},
    {"name": "smollm2:1.7b", "label": "SmolLM2 1.7B", "params": 1.7, "size": "1.8 GB", "note": "Fast English-only assistant."},
    {"name": "llama3.2:3b", "label": "Llama 3.2 3B", "params": 3.2, "size": "2.0 GB", "note": "Good general chat, English-first."},
    {"name": "qwen2.5:3b", "label": "Qwen2.5 3B", "params": 3.1, "size": "1.9 GB", "note": "Solid multilingual 3B."},
    {"name": "phi4-mini", "label": "Phi-4 mini 3.8B", "params": 3.8, "size": "2.5 GB", "note": "Strong reasoning and tool use for its size."},
    {"name": "qwen3:4b", "label": "Qwen3 4B", "params": 4.0, "size": "2.5 GB", "note": "Smarter than 1.7B, about twice as slow on CPU."},
    {"name": "gemma3:4b", "label": "Gemma 3 4B", "params": 4.3, "size": "3.3 GB", "note": "Natural writing, multilingual."},
    {"name": "qwen2.5:7b", "label": "Qwen2.5 7B", "params": 7.6, "size": "4.7 GB", "note": "High quality; needs a GPU or a lot of RAM."},
    {"name": "llama3.1:8b", "label": "Llama 3.1 8B", "params": 8.0, "size": "4.9 GB", "note": "High quality; needs a GPU or a lot of RAM."},
    {"name": "qwen3:8b", "label": "Qwen3 8B", "params": 8.2, "size": "5.2 GB", "note": "Very capable; needs a GPU or 24 GB+ RAM."},
    {"name": "gemma3:12b", "label": "Gemma 3 12B", "params": 12.0, "size": "8.1 GB", "note": "Excellent writing; GPU recommended."},
    {"name": "qwen3:14b", "label": "Qwen3 14B", "params": 14.8, "size": "9.3 GB", "note": "Best local quality; needs a strong GPU or 32 GB+ RAM."},
]
RECOMMENDED = CATALOG      # backwards compatibility


def hardware():
    """RAM, CPU cores and dedicated GPU memory (NVIDIA via nvidia-smi)."""
    total, free = system_ram_gb()
    cores = os.cpu_count() or 4
    vram = 0.0
    smi = shutil.which("nvidia-smi")
    if smi:
        try:
            out = subprocess.run([smi, "--query-gpu=memory.total", "--format=csv,noheader,nounits"], capture_output=True,
                                 text=True, timeout=5, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
            vram = max((float(x) for x in out.split() if x.strip().replace(".", "").isdigit()), default=0) / 1024
        except Exception:
            vram = 0.0
    return {"ram_total": round(total, 1), "ram_free": round(free, 1), "cores": cores, "gpu_vram": round(vram, 1)}


def max_params(hw):
    """Largest model (billions of parameters) that runs smoothly on this machine."""
    if hw["gpu_vram"] >= 10:
        return 14.8
    if hw["gpu_vram"] >= 6:
        return 8.2
    # CPU only: token speed is memory-bandwidth bound, so size is capped hard
    t = hw["ram_total"]
    if t < 6:
        return 1.2
    if t <= 9:
        return 1.7
    if t <= 13:
        return 3.2
    if t <= 20:
        return 4.3
    if t <= 40:
        return 8.2
    return 14.8


def compatibility(hw=None):
    hw = hw or hardware()
    cap = max_params(hw)
    rec = recommend_model(hw["ram_total"], hw["ram_free"]) if hw["gpu_vram"] < 6 else (
        "qwen3:14b" if hw["gpu_vram"] >= 10 else "qwen3:8b")
    out = []
    for m in CATALOG:
        ok = m["params"] <= cap
        reason = "" if ok else (
            f"Not compatible with this PC: a {m['params']:.0f}B model needs "
            + ("a GPU with 6 GB+ memory" if m["params"] <= 8.2 else "a GPU with 10 GB+ memory")
            + f" or {'24' if m['params'] <= 8.2 else '48'} GB+ RAM to run smoothly (you have {hw['ram_total']:.0f} GB"
            + (", no dedicated GPU" if not hw["gpu_vram"] else f", {hw['gpu_vram']:.0f} GB GPU") + ").")
        out.append({**m, "compatible": ok, "recommended": m["name"] == rec, "reason": reason})
    return {"hardware": hw, "max_params": cap, "recommended": rec, "models": out}


def is_compatible(name, hw=None):
    c = compatibility(hw)
    for m in c["models"]:
        if m["name"] == name:
            return m["compatible"], m["reason"]
    return True, ""   # unknown/custom tag: allow


def _ollama_exe():
    cands = [os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Ollama", "ollama.exe"),
             r"C:\Program Files\Ollama\ollama.exe", shutil.which("ollama") or ""]
    return next((c for c in cands if c and os.path.exists(c)), None)


class LLM:
    def __init__(self, settings=None, host=None):
        self.settings = settings
        if host is None:
            from src import appdata
            host = appdata.get("ollama.host")
        self.host = host
        self.busy = threading.Event()        # set while a user-facing turn runs
        self.fg_lock = threading.Lock()
        self._embed_ok = None
        self._embed_checked = 0.0
        self.pulling = None                  # {"name", "pct", "status"}
        self._cancel_pull = threading.Event()
        self._active_pull_resp = None
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
            # below-normal priority: the model never starves the HUD, camera or your IDE
            subprocess.Popen([exe, "serve"], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0) | 0x00004000,
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
        total, free = system_ram_gb()
        return {"server": up, "installed": installed, "current": self.model,
                "ram_total": round(total, 1), "ram_free": round(free, 1),
                "recommended_model": recommend_model(total, free),
                "ready": up and any(m.startswith(self.model) for m in installed),
                "pulling": self.pulling, "recommended": RECOMMENDED, "error": self.last_error,
                "catalog": compatibility(),
                "ollama_installed": bool(_ollama_exe())}

    def pull(self, name, on_progress=None):
        """Download a model with progress callbacks (pct 0..100)."""
        self._cancel_pull.clear()
        self.pulling = {"name": name, "pct": 0, "status": "starting"}
        try:
            with requests.post(self.host + "/api/pull", json={"name": name, "stream": True},
                               stream=True, timeout=(5, 600)) as r:
                self._active_pull_resp = r
                for line in r.iter_lines():
                    if self._cancel_pull.is_set():
                        self.pulling = None
                        return False
                    if not line:
                        continue
                    d = json.loads(line)
                    if d.get("error"):
                        raise RuntimeError(d["error"])
                    total, done = d.get("total"), d.get("completed")
                    pct = round(done * 100 / total, 1) if total and done else self.pulling["pct"]
                    self.pulling = {"name": name, "pct": pct, "status": d.get("status", ""),
                                    "done": done or 0, "total": total or 0}
                    if on_progress:
                        on_progress(self.pulling)
            self.pulling = None
            return True
        except Exception as e:
            if self._cancel_pull.is_set():
                self.pulling = None
                return False
            self.last_error = f"Download failed: {e}"
            self.pulling = {"name": name, "pct": 0, "status": "error", "error": str(e)}
            if on_progress:
                on_progress(self.pulling)
            return False
        finally:
            self._active_pull_resp = None

    def cancel_pull(self):
        """Immediately abort active model download."""
        self._cancel_pull.set()
        r = getattr(self, "_active_pull_resp", None)
        if r:
            try:
                r.close()
            except Exception:
                pass
        self.pulling = None

    # -------------------------------------------------------------- chat
    def _payload(self, messages, schema=None, max_tokens=256, temperature=0.4, stream=False):
        p = {"model": self.model, "messages": messages, "stream": stream, "think": False,
             "keep_alive": self.keep_alive,
             "options": {"temperature": temperature, "num_predict": max_tokens, "num_ctx": 4096,
                         "num_thread": max(2, (os.cpu_count() or 4) // 2 - 1)}}
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
        """Yield content chunks as they are generated (user-facing: takes priority).
        <think> blocks are hidden even when split across chunks; if streaming fails
        before anything arrived, falls back to one non-streaming request."""
        with self.fg_lock:
            self.busy.set()
            think = ThinkFilter()
            got_any = False
            try:
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
                            chunk = think.feed(d.get("message", {}).get("content", ""))
                            if chunk:
                                got_any = True
                                yield chunk
                            if d.get("done"):
                                self.last_stats = {k: d.get(k) for k in ("prompt_eval_count", "prompt_eval_duration",
                                                                         "eval_count", "eval_duration", "load_duration")}
                                break
                except (requests.RequestException, ValueError):
                    if got_any:
                        raise
                    # non-streaming fallback (some streaming paths drop or garble output)
                    r = requests.post(self.host + "/api/chat", timeout=300,
                                      json=self._payload(messages, schema, max_tokens, temperature, stream=False))
                    r.raise_for_status()
                    text = self._clean(r.json()["message"]["content"])
                    if text:
                        yield text
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


class ThinkFilter:
    """Removes <think>...</think> from a token stream, even when the tags are split
    across chunks ("<thi" + "nk>")."""

    def __init__(self):
        self.buf = ""
        self.inside = False

    def feed(self, chunk):
        self.buf += chunk or ""
        out = []
        while self.buf:
            if self.inside:
                end = self.buf.find("</think>")
                if end < 0:
                    self.buf = self.buf[-7:]       # keep a possible partial closing tag
                    return "".join(out)
                self.buf = self.buf[end + 8:]
                self.inside = False
            else:
                start = self.buf.find("<think>")
                if start < 0:
                    # hold back a possible partial "<think" at the end
                    keep = 0
                    for n in range(min(6, len(self.buf)), 0, -1):
                        if "<think>".startswith(self.buf[-n:]):
                            keep = n
                            break
                    out.append(self.buf[:len(self.buf) - keep])
                    self.buf = self.buf[len(self.buf) - keep:]
                    return "".join(out)
                out.append(self.buf[:start])
                self.buf = self.buf[start + 7:]
                self.inside = True
        return "".join(out)


def system_ram_gb():
    """(total, free) GB of RAM."""
    try:
        import ctypes

        class MS(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                        ("a", ctypes.c_ulonglong), ("b", ctypes.c_ulonglong), ("c", ctypes.c_ulonglong),
                        ("d", ctypes.c_ulonglong), ("e", ctypes.c_ulonglong)]
        ms = MS()
        ms.dwLength = ctypes.sizeof(MS)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
        return ms.ullTotalPhys / 2 ** 30, ms.ullAvailPhys / 2 ** 30
    except Exception:
        return 8.0, 4.0


def recommend_model(total_gb=None, free_gb=None):
    """RAM tiers from the research (<=8 GB -> 1.7B, 8-14 -> 4B, 16 -> 8B, more -> 14B),
    capped by free RAM: measured on a 16 GB laptop with an emulator + IDE running
    (0.8-1.7 GB free), anything above 1.7B was too slow to feel conversational."""
    if total_gb is None:
        total_gb, free_gb = system_ram_gb()
    if total_gb <= 9:
        tier = "qwen3:1.7b"
    elif total_gb < 15:
        tier = "qwen3:4b"
    elif total_gb < 24:
        tier = "qwen3:8b"
    else:
        tier = "qwen3:14b"
    need = {"qwen3:1.7b": 0, "qwen3:4b": 4, "qwen3:8b": 7, "qwen3:14b": 11}
    if free_gb is not None:
        for name in ("qwen3:14b", "qwen3:8b", "qwen3:4b"):
            if tier == name and free_gb < need[name]:
                tier = {"qwen3:14b": "qwen3:8b", "qwen3:8b": "qwen3:4b", "qwen3:4b": "qwen3:1.7b"}[name]
    return tier


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
