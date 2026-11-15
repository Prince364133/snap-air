"""Hermetic test environment, applied once for the whole suite (imported by tests/__init__.py,
so it runs before any test module and before anything from src/ is imported).

1. Data and settings live in a throw-away folder, never in the user's %APPDATA%\\SnapAir.
   Modules that need their own folder use `setUpModule, tearDownModule = module_data_dir()`
   (or `isolated_data(self)` in a test); both restore the previous value afterwards, so the
   result never depends on which module ran first.
2. No test talks to a real model or the internet: outgoing connections are refused except to
   loopback, and the local Ollama port is refused too (a running Ollama used to make the
   meeting / reminder tests wait for real generations and time out). Code under test sees
   the same errors as on an offline PC with Ollama stopped. Ollama is never spawned.

Tests that need a fake server bind their own loopback port, which stays allowed.
"""
import atexit
import os
import shutil
import socket
import tempfile

ROOT = tempfile.mkdtemp(prefix="snapy_tests_")
atexit.register(shutil.rmtree, ROOT, True)

os.environ["SNAP_AIR_DATA"] = os.path.join(ROOT, "data")
os.environ["SNAP_AIR_SETTINGS"] = os.path.join(ROOT, "settings.json")
os.environ.pop("SNAPY_WS_TOKEN", None)
os.makedirs(os.environ["SNAP_AIR_DATA"], exist_ok=True)


# ------------------------------------------------------------------ data folders
def new_data_dir(prefix="data_"):
    return tempfile.mkdtemp(prefix=prefix, dir=ROOT)


def isolated_data(tc):
    """Point SNAP_AIR_DATA at a fresh folder for one test (restored by addCleanup)."""
    prev = os.environ.get("SNAP_AIR_DATA")
    d = new_data_dir()
    os.environ["SNAP_AIR_DATA"] = d
    tc.addCleanup(_restore, prev)
    return d


def _restore(prev):
    if prev is None:
        os.environ.pop("SNAP_AIR_DATA", None)
    else:
        os.environ["SNAP_AIR_DATA"] = prev


def module_data_dir():
    """(setUpModule, tearDownModule) giving one module its own data folder while it runs."""
    saved = {}

    def setup():
        saved["prev"] = os.environ.get("SNAP_AIR_DATA")
        os.environ["SNAP_AIR_DATA"] = new_data_dir("mod_")

    def teardown():
        _restore(saved.get("prev"))
    return setup, teardown


# ------------------------------------------------------------------ no network, no models
_LOOPBACK_NAMES = {"localhost", "127.0.0.1", "::1", "0.0.0.0", ""}


def _blocked_ports():
    try:
        from urllib.parse import urlsplit
        from src import appdata
        port = urlsplit(appdata.get("ollama.host") or "").port
        return {port} if port else set()
    except Exception:                       # noqa: BLE001 - fall back to Ollama's well-known port
        return {11434}


BLOCKED_LOOPBACK_PORTS = _blocked_ports() | {11434}
_real_getaddrinfo = socket.getaddrinfo
_real_connect = socket.socket.connect
_real_connect_ex = socket.socket.connect_ex


def _is_loopback(host):
    host = (host.decode() if isinstance(host, bytes) else str(host or "")).strip("[]").lower()
    return host in _LOOPBACK_NAMES or host.startswith("127.")


def _guard_getaddrinfo(host, *a, **k):
    if not _is_loopback(host):
        raise socket.gaierror(socket.EAI_NONAME, f"network disabled in tests ({host})")
    return _real_getaddrinfo(host, *a, **k)


def _check(address):
    if isinstance(address, tuple) and len(address) >= 2:
        host, port = address[0], address[1]
        if not _is_loopback(host) or int(port) in BLOCKED_LOOPBACK_PORTS:
            raise ConnectionRefusedError(f"network disabled in tests ({host}:{port})")


def _guard_connect(self, address):
    _check(address)
    return _real_connect(self, address)


def _guard_connect_ex(self, address):
    _check(address)
    return _real_connect_ex(self, address)


socket.getaddrinfo = _guard_getaddrinfo
socket.socket.connect = _guard_connect
socket.socket.connect_ex = _guard_connect_ex

# Never start a real Ollama ("ollama serve") from a test
from src.brain import llm as _llm  # noqa: E402

_llm._ollama_exe = lambda: None
