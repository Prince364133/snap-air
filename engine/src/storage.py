"""Local data store: everything Snap Air knows lives in plain JSON under one
folder the user can open, read and delete (%APPDATA%\\SnapAir by default)."""
import datetime as dt
import json
import os
import re
import threading

from src import diag

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
            except OSError as e2:
                diag.record("storage.keep_corrupt", e2, file=os.path.basename(p))
            print(f"[Storage] {os.path.basename(p)} unreadable ({e}); starting fresh")
            return default


def write_json(p, data):
    with _lock(p):
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp, p)
    _stamp(p)


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
            except OSError as e:
                diag.record("storage.prune", e, quiet=True, file=name)
    return n


# ---------------------------------------------------------- schema versions
# Every file written with write_json gets its format version recorded in
# <data dir>/schema_versions.json ({"tasks.json": 1, "activity/{date}.json": 1, ...}).
# The version lives in this sidecar rather than inside the files because many are
# plain lists (tasks.json, notes.json) or dicts whose keys are read as data
# (profile.json, secrets.json): a "schema_version" key in them would break readers.
# Files never stamped are version 1 (everything written before versions existed).
# To change a format: bump it with register_migration(key, from_version, fn), and
# migrate() (run once at startup) rewrites old files before anything reads them.
SCHEMA_FILE = "schema_versions.json"
CURRENT = {}            # key -> version this build writes; unlisted keys are version 1
MIGRATIONS = {}         # key -> {from_version: fn(data) -> data}
_DATED = re.compile(r"\d{4}-\d{2}-\d{2}")
_schema_lock = threading.RLock()
_schema_cache = {}      # data dir -> {key: version}


def register_migration(key, from_version, fn):
    MIGRATIONS.setdefault(key, {})[int(from_version)] = fn
    CURRENT[key] = max(CURRENT.get(key, 1), int(from_version) + 1)


def schema_key(p):
    """'tasks.json', 'memory/profile.json', 'activity/{date}.json'; None outside the data dir."""
    base = os.path.abspath(data_dir())
    full = os.path.abspath(p)
    if os.path.commonpath([base, full]) != base:
        return None
    rel = os.path.relpath(full, base).replace(os.sep, "/")
    if rel == SCHEMA_FILE:
        return None
    head, _, name = rel.rpartition("/")
    name = _DATED.sub("{date}", name, count=1) if _DATED.match(name) else name
    return f"{head}/{name}" if head else name


def schema_versions():
    base = data_dir()
    with _schema_lock:
        if base not in _schema_cache:
            try:
                with open(os.path.join(base, SCHEMA_FILE), encoding="utf-8") as f:
                    v = json.load(f)
                _schema_cache[base] = v if isinstance(v, dict) else {}
            except FileNotFoundError:
                _schema_cache[base] = {}
            except (OSError, ValueError) as e:
                diag.record("storage.schema_read", e)
                _schema_cache[base] = {}
        return _schema_cache[base]


def schema_version(p):
    key = schema_key(p)
    return int(schema_versions().get(key, 1)) if key else 1


def _set_versions(updates):
    base = data_dir()
    with _schema_lock:
        v = dict(schema_versions())
        v.update(updates)
        tmp = os.path.join(base, SCHEMA_FILE + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(v, f, indent=2, sort_keys=True)
        os.replace(tmp, os.path.join(base, SCHEMA_FILE))
        _schema_cache[base] = v


def _stamp(p):
    """Record that p is now in this build's format (writes the sidecar only on change)."""
    try:
        key = schema_key(p)
        if key is None:
            return
        want = CURRENT.get(key, 1)
        if schema_versions().get(key) != want:
            _set_versions({key: want})
    except (OSError, ValueError) as e:
        diag.record("storage.schema_stamp", e, file=os.path.basename(p))


def migrate():
    """Bring every file with a registered migration up to the current version.
    Returns the list of files rewritten. A failing migration leaves that file as it
    was (and is recorded), so the app still starts."""
    done = []
    base = data_dir()
    for key, steps in MIGRATIONS.items():
        target = CURRENT.get(key, 1)
        head, _, pattern = key.rpartition("/")
        folder = os.path.join(base, *head.split("/")) if head else base
        if not os.path.isdir(folder):
            continue
        rx = re.compile(re.escape(pattern).replace(re.escape("{date}"), r"\d{4}-\d{2}-\d{2}") + "$")
        for name in sorted(os.listdir(folder)):
            if not rx.match(name):
                continue
            p = os.path.join(folder, name)
            v = schema_version(p)
            if v >= target:
                continue
            try:
                data = read_json(p, None)
                while v < target:
                    data = steps[v](data)        # KeyError = a missing step: a bug, recorded below
                    v += 1
                with _lock(p):
                    tmp = p + ".tmp"
                    with open(tmp, "w", encoding="utf-8") as f:
                        json.dump(data, f, indent=2, ensure_ascii=False)
                    os.replace(tmp, p)
                done.append(p)
            except Exception as e:               # noqa: BLE001 - keep the old file, keep starting
                diag.record("storage.migrate", e, file=name, from_version=v)
        # one version per key: dated files share it, so only stamp when every file made it
        if all(schema_version(os.path.join(folder, n)) >= target or os.path.join(folder, n) in done
               for n in os.listdir(folder) if rx.match(n)):
            _set_versions({key: target})
    return done
