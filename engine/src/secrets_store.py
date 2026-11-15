"""API keys encrypted with Windows DPAPI (bound to this Windows user account).
Keys are never written in plain text and never sent back to the HUD."""
import base64
import ctypes
import sys

from src import storage

try:
    from ctypes import wintypes
except (ImportError, ValueError):            # not Windows
    wintypes = None

# Other platforms plug in their own cipher, e.g. Android Keystore AES-GCM (set_cipher)
_cipher = None


def set_cipher(protect, unprotect):
    """protect/unprotect: bytes -> bytes (used instead of DPAPI on Android)."""
    global _cipher
    _cipher = (protect, unprotect)


if wintypes is not None:
    class _Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _protect(data: bytes) -> bytes:
    if _cipher:
        return bytes(_cipher[0](data))
    if sys.platform != "win32":
        return data
    inp = _Blob(len(data), ctypes.cast(ctypes.create_string_buffer(data, len(data)), ctypes.POINTER(ctypes.c_char)))
    out = _Blob()
    if not ctypes.windll.crypt32.CryptProtectData(ctypes.byref(inp), "SnapyKey", None, None, None, 0x1, ctypes.byref(out)):
        raise OSError("DPAPI encryption failed")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)


def _unprotect(data: bytes) -> bytes:
    if _cipher:
        return bytes(_cipher[1](data))
    if sys.platform != "win32":
        return data
    inp = _Blob(len(data), ctypes.cast(ctypes.create_string_buffer(data, len(data)), ctypes.POINTER(ctypes.c_char)))
    out = _Blob()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(inp), None, None, None, None, 0x1, ctypes.byref(out)):
        raise OSError("DPAPI decryption failed")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)


def _file():
    return storage.path("secrets.json")


def set_key(name, value):
    data = storage.read_json(_file(), {}) or {}
    if value:
        data[name] = base64.b64encode(_protect(value.strip().encode("utf-8"))).decode("ascii")
    else:
        data.pop(name, None)
    storage.write_json(_file(), data)


def get_key(name):
    data = storage.read_json(_file(), {}) or {}
    if name not in data:
        return ""
    try:
        return _unprotect(base64.b64decode(data[name])).decode("utf-8")
    except Exception:
        return ""


def masked(name):
    k = get_key(name)
    return ("•••• " + k[-4:]) if len(k) >= 8 else ("set" if k else "")
