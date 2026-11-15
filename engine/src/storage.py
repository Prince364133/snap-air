"""Local data store: everything Snap Air knows lives in plain JSON under one
folder the user can open, read and delete (%APPDATA%\\SnapAir by default)."""
import datetime as dt
import json
import os
import threading

_locks = {}
_locks_guard = threading.Lock()


def data_dir():
    override = os.environ.get("SNAP_AIR_DATA")
    if override:
        base = override
    elif os.environ.get("APPDATA"):
        base = os.path.join(os.environ["APPDATA"], "SnapAir")
    else:
        base = os.path.join(os.path.expanduser("~"), ".snap-air")
    os.makedirs(base, exist_ok=True)
    return base


def path(*parts):
    p = os.path.join(data_dir(), *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def _lock(p):
    with _locks_guard:
        return _locks.setdefault(os.path.abspath(p), threading.RLock())


def read_json(p, default=None):
    with _lock(p):
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            return default
        except (ValueError, OSError) as e:
            # Keep a copy of a corrupted file rather than silently losing it
            try:
                os.replace(p, p + ".corrupt")
            except OSError:
                pass
            print(f"[Storage] {os.path.basename(p)} unreadable ({e}); starting fresh")
            return default


def write_json(p, data):
    with _lock(p):
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp, p)


def append_jsonl(p, record):
    with _lock(p):
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")


def read_jsonl(p, limit=None):
    try:
        with open(p, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return []
    if limit:
        lines = lines[-limit:]
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def today(now=None):
    return (now or dt.datetime.now()).strftime("%Y-%m-%d")


def day_key(offset_days=0, now=None):
    return ((now or dt.datetime.now()) + dt.timedelta(days=offset_days)).strftime("%Y-%m-%d")


def prune_dated_files(folder, keep_days, suffixes=(".json", ".jsonl")):
    """Delete YYYY-MM-DD.* files older than keep_days (retention policy)."""
    if not os.path.isdir(folder):
        return 0
    cutoff = (dt.datetime.now() - dt.timedelta(days=keep_days)).strftime("%Y-%m-%d")
    n = 0
    for name in os.listdir(folder):
        stem, ext = os.path.splitext(name)
        if ext in suffixes and len(stem) == 10 and stem < cutoff:
            try:
                os.remove(os.path.join(folder, name))
                n += 1
            except OSError:
                pass
    return n
