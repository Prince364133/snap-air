"""Product data by dotted path, e.g. get("ollama.installer_url") or get("android.social_apps").

One tree, three layers (later wins):
  1. src/data/app.json      Windows-engine data (installers, model names, timings, camera…)
  2. core/rules/*.json      data shared with the Android app (social apps, phone rules, nudges,
                            limits, ordinals, cloud providers…), see core/README.md
  3. %APPDATA%\\SnapAir\\app.json   optional user override, changes any value without rebuilding

Every fact lives in exactly one of 1 or 2 (load() warns if both define a path). Nothing
product-specific is hardcoded in the engine: code asks for a value by its path.
"""
import json
import os
import sys

_cache = None


def _base_file():
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "app.json")
    if os.path.exists(here):
        return here
    meipass = getattr(sys, "_MEIPASS", None)                 # PyInstaller bundle
    return os.path.join(meipass, "src", "data", "app.json") if meipass else here


def _merge(base, extra):
    for k, v in extra.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _merge(base[k], v)
        else:
            base[k] = v
    return base


def _overlaps(a, b, where=""):
    """Leaf paths defined in both trees (a fact must have one source)."""
    out = []
    for k, v in b.items():
        if k in ("_comment", "_meta") or k not in a:
            continue
        p = f"{where}.{k}" if where else k
        if isinstance(v, dict) and isinstance(a[k], dict):
            out += _overlaps(a[k], v, p)
        else:
            out.append(p)
    return out


def load(reload=False):
    global _cache
    if _cache is not None and not reload:
        return _cache
    with open(_base_file(), encoding="utf-8") as f:
        data = json.load(f)
    try:
        from src import core_loader
        if reload:
            core_loader.reload()
        shared = json.loads(json.dumps(core_loader.config_tree()))
        dup = _overlaps(data, shared)
        if dup:
            print("[AppData] defined in both app.json and core/ (core wins):", ", ".join(dup))
        _merge(data, shared)
    except Exception as e:                                   # never stop Snapy, but say why
        print("[AppData] couldn't load core/:", e)
    try:
        from src import storage
        override = os.path.join(storage.data_dir(), "app.json")
        if os.path.exists(override):
            with open(override, encoding="utf-8") as f:
                _merge(data, json.load(f))
    except Exception as e:                                   # a broken override must not stop Snapy
        print("[AppData] ignoring override:", e)
    _cache = data
    return data


def get(path, default=None):
    node = load()
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node
