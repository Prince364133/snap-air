"""Diagnostics: errors that used to be swallowed silently are recorded here instead.

record("ws.send", exc) logs one line, counts it per code, keeps the last few in
memory and persists the counts to diagnostics.json in the data folder, so the
trust centre can show "what went wrong, how often" without a log file. It never
raises: a failing diagnostic must not turn a handled error into a crash.
Only exception type + a short message are kept (no stack frames, no payloads),
so nothing personal ends up in the file beyond what the message itself says.
"""
import collections
import json
import os
import threading
import time

_lock = threading.Lock()
_counts = {}
_recent = collections.deque(maxlen=50)
_loaded = False
_last_save = 0.0
SAVE_EVERY_S = 5.0                             # throttle disk writes (app.json: diagnostics.save_every_s)


def _file():
    from src import storage                    # late import: storage imports this module
    return os.path.join(storage.data_dir(), "diagnostics.json")


def _load():
    global _loaded, _recent, SAVE_EVERY_S
    if _loaded:
        return
    _loaded = True
    # read limits lazily: storage imports this module, and appdata imports storage
    try:
        from src import appdata
        _recent = collections.deque(_recent, maxlen=int(appdata.get("diagnostics.keep_recent", 50) or 50))
        SAVE_EVERY_S = float(appdata.get("diagnostics.save_every_s", 5) or 5)
    except Exception:                          # noqa: BLE001 - defaults are fine
        pass
    try:
        with open(_file(), encoding="utf-8") as f:
            saved = json.load(f)
        for k, v in (saved.get("counts") or {}).items():
            _counts[k] = _counts.get(k, 0) + int(v)
    except (OSError, ValueError, TypeError, AttributeError):
        pass                                   # first run or unreadable: start counting from zero


def _save(force=False):
    global _last_save
    now = time.time()
    if not force and now - _last_save < SAVE_EVERY_S:
        return
    _last_save = now
    try:
        p = _file()
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"counts": _counts, "updated": int(now)}, f, indent=2)
        os.replace(tmp, p)
    except OSError as e:
        print(f"[Diag] couldn't save diagnostics: {e}")


def record(code, exc=None, quiet=False, **ctx):
    """Note a handled error under a stable code (e.g. "ws.send", "setup.cleanup")."""
    try:
        msg = f"{type(exc).__name__}: {exc}"[:200] if exc is not None else ""
        with _lock:
            _load()
            _counts[code] = _counts.get(code, 0) + 1
            _recent.append({"code": code, "error": msg, "t": int(time.time()),
                            **{k: str(v)[:80] for k, v in ctx.items()}})
            _save()
        if not quiet:
            extra = " ".join(f"{k}={str(v)[:80]}" for k, v in ctx.items())
            print(f"[Diag] {code} {msg} {extra}".rstrip())
    except Exception:                          # noqa: BLE001 - diagnostics must never raise
        pass


def summary():
    """Counts per code (all time) and the most recent errors (this run)."""
    with _lock:
        _load()
        return {"counts": dict(sorted(_counts.items(), key=lambda kv: -kv[1])),
                "recent": list(_recent)[::-1], "total": sum(_counts.values())}


def flush():
    with _lock:
        _save(force=True)


def reset():
    """Forget everything (tests, and "clear diagnostics" in the trust centre)."""
    global _loaded
    with _lock:
        _counts.clear()
        _recent.clear()
        _loaded = True
        _save(force=True)
