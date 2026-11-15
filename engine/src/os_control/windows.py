"""Win32 window helpers (ctypes, no extra dependencies)."""
import ctypes
import re
import os
import sys
import time

try:                                     # not available on Android/Linux
    from ctypes import wintypes
except (ImportError, ValueError):
    wintypes = None

IS_WIN = sys.platform == "win32"

# Windows that belong to Snap Air itself and must never receive shortcuts
OWN_TITLES = ("snapy hud", "snapy - camera", "snap air hud", "snap air - camera", "snap-air engine",
              "snap-air app", "snapy engine")

if IS_WIN:
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
    user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsIconic.argtypes = [wintypes.HWND]
    user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
    user32.GetWindow.restype = wintypes.HWND
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]

SW_MAXIMIZE, SW_MINIMIZE, SW_RESTORE = 3, 6, 9
GW_HWNDNEXT, GW_OWNER = 2, 4
GWL_EXSTYLE = -20
WS_EX_TOOLWINDOW = 0x80


def _title(hwnd):
    n = user32.GetWindowTextLengthW(hwnd)
    if n <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


def _exe(hwnd):
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    h = kernel32.OpenProcess(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(520)
        size = wintypes.DWORD(520)
        if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return os.path.splitext(os.path.basename(buf.value))[0].lower()
    finally:
        kernel32.CloseHandle(h)
    return ""


def is_own(hwnd):
    t = _title(hwnd).lower()
    return any(t.startswith(o) for o in OWN_TITLES)


def _is_app_window(hwnd):
    if not user32.IsWindowVisible(hwnd) or user32.GetWindow(hwnd, GW_OWNER):
        return False
    if user32.GetWindowLongW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW:
        return False
    # Suspended UWP apps report "visible" but are cloaked (not on screen)
    cloaked = ctypes.c_int(0)
    try:
        ctypes.windll.dwmapi.DwmGetWindowAttribute(hwnd, 14, ctypes.byref(cloaked), ctypes.sizeof(cloaked))
    except Exception:
        pass
    if cloaked.value:
        return False
    t = _title(hwnd)
    return bool(t) and t not in ("Program Manager", "Windows Input Experience",
                                 "Microsoft Text Input Application")


def list_windows():
    """Top-level app windows in z-order (front first): [(hwnd, title, exe)]."""
    if not IS_WIN:
        return []
    out = []

    def cb(hwnd, _):
        if _is_app_window(hwnd) and not is_own(hwnd):
            out.append((hwnd, _title(hwnd), _exe(hwnd)))
        return True

    user32.EnumWindows(EnumWindowsProc(cb), 0)
    return out


def focus(hwnd):
    if not IS_WIN or not hwnd:
        return False
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, SW_RESTORE)
    # Windows only lets the foreground process change focus; a synthetic Alt
    # keypress satisfies that rule.
    user32.keybd_event(0x12, 0, 0, 0)
    user32.keybd_event(0x12, 0, 2, 0)
    ok = bool(user32.SetForegroundWindow(hwnd))
    time.sleep(0.05)
    return ok


def ensure_target_focus():
    """If a Snap Air window (HUD/preview/console) is focused, hand focus back to
    the app the user was working in so shortcuts land in the right place."""
    if not IS_WIN:
        return None
    fg = user32.GetForegroundWindow()
    if fg and not is_own(fg) and _title(fg):
        return fg
    wins = list_windows()
    if wins:
        focus(wins[0][0])
        time.sleep(0.08)
        return wins[0][0]
    return None


def find_window(query):
    """Best window matching a spoken name (title words or process name)."""
    import difflib
    from src import appdata
    q = query.lower().strip()
    if not q:
        return None
    exe_hint = (appdata.get("window_aliases", {}) or {}).get(q)
    qs = q.replace(" ", "")                     # "anti gravity" == "antigravity"
    best, best_score = None, 0
    for hwnd, title, exe in list_windows():
        tl = title.lower()
        tls = tl.replace(" ", "")
        score = 0
        if exe_hint and exe == exe_hint:
            score = 100
        elif exe == q.replace(" ", ""):
            score = 90
        elif q in tl:
            score = 70 + (10 if tl.endswith(q) else 0)
        elif q.replace(" ", "") in exe:
            score = 60
        elif all(w in tl for w in q.split()):
            score = 50
        elif len(qs) >= 4 and (qs in tls or qs in exe.replace(" ", "")):
            score = 45
        else:
            # misheard names: compare with each word of the title and the app name
            words = re.findall(r"[a-z0-9]+", tl) + [exe.replace(" ", "")]
            r = max((difflib.SequenceMatcher(None, qs, w).ratio() for w in words if len(w) >= 3), default=0)
            if r >= 0.8:
                score = int(30 + 10 * r)
        if score > best_score:
            best, best_score = (hwnd, title), score
    return best


def foreground_title():
    if not IS_WIN:
        return ""
    return _title(user32.GetForegroundWindow())


def show_window(cmd):
    hwnd = ensure_target_focus()
    if hwnd:
        user32.ShowWindow(hwnd, cmd)
        return True
    return False
