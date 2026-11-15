"""Product data (download sources, model names, timings, limits) from src/data/app.json.

Nothing product-specific is hardcoded in the engine: code asks for a value by its
dotted path, e.g. get("ollama.installer_url"). An override file next to the user's
data (%APPDATA%\\SnapAir\\app.json) can change any value without rebuilding.
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


def load(reload=False):
    global _cache
    if _cache is not None and not reload:
        return _cache
    with open(_base_file(), encoding="utf-8") as f:
        data = json.load(f)
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
