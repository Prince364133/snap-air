"""On-device activity & routine learning.

Samples the foreground app every few seconds and keeps per-day totals in
activity/YYYY-MM-DD.json. Stored by default: app name + seconds, project names
parsed from IDE titles, and time on well-known sites (YouTube, GitHub...).
Never stored: keystrokes, screen content, URLs, private/incognito windows,
excluded apps. Full titles only when the user opts in (privacy = "all").
"""
import ctypes
import datetime as dt
import os
import re
import statistics
import sys
import threading
import time

from src import storage
from src import diag  # noqa: E402

IDLE_AWAY_S = 120          # no input for 2 min = away (not counted)
NEW_SESSION_IDLE_S = 4 * 3600
PRIVATE_MARKERS = ("inprivate", "incognito", "private browsing", "- private")
DEFAULT_EXCLUDE = {"keepass", "keepassxc", "1password", "bitwarden", "lastpass", "dashlane"}

FRIENDLY = {
    "chrome": "Chrome", "msedge": "Edge", "brave": "Brave", "firefox": "Firefox", "opera": "Opera",
    "code": "VS Code", "antigravity": "Antigravity", "antigravity ide": "Antigravity IDE", "cursor": "Cursor",
    "windsurf": "Windsurf", "pycharm64": "PyCharm", "idea64": "IntelliJ IDEA", "webstorm64": "WebStorm",
    "devenv": "Visual Studio", "sublime_text": "Sublime Text", "zed": "Zed", "notepad++": "Notepad++",
    "windowsterminal": "Terminal", "powershell": "PowerShell", "cmd": "Command Prompt", "wt": "Terminal",
    "explorer": "File Explorer", "slack": "Slack", "ms-teams": "Teams", "teams": "Teams", "zoom": "Zoom",
    "discord": "Discord", "spotify": "Spotify", "winword": "Word", "excel": "Excel", "powerpnt": "PowerPoint",
    "outlook": "Outlook", "olk": "Outlook", "notion": "Notion", "obsidian": "Obsidian", "figma": "Figma",
    "whatsapp": "WhatsApp", "telegram": "Telegram", "postman": "Postman", "docker desktop": "Docker Desktop",
    "applicationframehost": "Windows app", "systemsettings": "Settings", "acrobat": "Acrobat",
}
IDE_EXES = {"code", "antigravity", "antigravity ide", "cursor", "windsurf", "pycharm64", "idea64", "webstorm64",
            "devenv", "sublime_text", "zed", "rider64", "goland64", "clion64", "android studio", "studio64"}
BROWSERS = {"chrome", "msedge", "brave", "firefox", "opera", "vivaldi", "arc"}
SITES = ["YouTube", "GitHub", "Gmail", "Stack Overflow", "Jira", "Confluence", "Google Meet", "Meet",
         "ChatGPT", "Claude", "Netflix", "Instagram", "Reddit", "X", "LinkedIn", "WhatsApp", "Notion",
         "Google Docs", "Google Sheets", "Figma", "Slack", "Facebook", "Amazon", "Prime Video", "Hotstar",
         "Spotify", "Coursera", "Udemy", "Wikipedia", "Gemini", "Perplexity"]
WORK_HINT = IDE_EXES | {"windowsterminal", "powershell", "cmd", "wt", "postman", "docker desktop", "devenv"}


def friendly(exe):
    return FRIENDLY.get(exe, exe.replace("_", " ").title() if exe else "Unknown")


def extract_project(exe, title):
    if exe not in IDE_EXES or not title:
        return None
    parts = [p.strip() for p in re.split(r"\s[-–—]\s", title) if p.strip()]
    app_words = {"visual studio code", "antigravity ide", "antigravity", "cursor", "windsurf", "zed",
                 "sublime text", "pycharm", "intellij idea", "webstorm", "visual studio"}
    for i, p in enumerate(parts):
        pl = p.lower()
        if any(pl.startswith(a) for a in app_words):
            if i >= 1:
                cand = parts[i - 1]
                return None if cand.lower().startswith(("diff:", "settings", "welcome", "untitled")) else cand[:60]
            return None
    # JetBrains style "project – file"
    return parts[0][:60] if exe.endswith("64") and parts else None


def extract_site(exe, title):
    if exe not in BROWSERS or not title:
        return None
    parts = [p.strip() for p in re.split(r"\s[-–—|]\s", title)]
    # browser name is last; site is usually the part right before it
    for p in reversed(parts[:-1] or parts):
        for s in SITES:
            if p.lower() == s.lower() or p.lower().endswith(" " + s.lower()):
                return "Google Meet" if s == "Meet" else s
    tl = title.lower()
    for s in ("YouTube", "Gmail", "GitHub", "Stack Overflow", "ChatGPT", "Google Meet"):
        if s.lower() in tl:
            return s
    return None


def fmt_duration(seconds):
    seconds = int(seconds)
    h, m = divmod(seconds // 60, 60)
    if h:
        return f"{h}h {m:02d}m"
    return f"{m}m" if m else f"{seconds}s"


# --------------------------------------------------------------------- win32
def _idle_seconds():
    if sys.platform != "win32":
        return 0.0

    class LASTINPUTINFO(ctypes.Structure):
        _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]

    lii = LASTINPUTINFO()
    lii.cbSize = ctypes.sizeof(lii)
    if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(lii)):
        return 0.0
    return max(0, (ctypes.windll.kernel32.GetTickCount() - lii.dwTime) / 1000.0)


def _foreground():
    _, exe, title = _foreground_full()
    return exe, title


def _foreground_full():
    """(hwnd, exe, title) of the foreground window; (None, "", "") for none or Snapy's own."""
    if sys.platform != "win32":
        return None, "", ""
    from src.os_control import windows as win
    hwnd = win.user32.GetForegroundWindow()
    if not hwnd or win.is_own(hwnd):
        return None, "", ""
    return hwnd, win._exe(hwnd), win._title(hwnd)


def apps_using_microphone(exclude_exes=("python", "pythonw")):
    """Apps holding the microphone right now, from the Windows privacy store."""
    if sys.platform != "win32":
        return []
    import winreg
    out = []
    base = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"

    def scan(key_path, packaged):
        try:
            k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path)
        except OSError:
            return
        i = 0
        while True:
            try:
                name = winreg.EnumKey(k, i)
            except OSError:
                break
            i += 1
            if name == "NonPackaged":
                continue
            try:
                sk = winreg.OpenKey(k, name)
                start, _ = winreg.QueryValueEx(sk, "LastUsedTimeStart")
                stop, _ = winreg.QueryValueEx(sk, "LastUsedTimeStop")
            except OSError:
                continue
            if start and stop == 0:
                exe = os.path.splitext(name.split("#")[-1])[0].lower() if not packaged else name.split("_")[0].lower()
                if not any(x in exe for x in exclude_exes):
                    out.append(exe)

    scan(base, True)
    scan(base + r"\NonPackaged", False)
    return out


CALL_APPS = ("teams", "zoom", "slack", "discord", "webex", "skype", "whatsapp", "chrome", "msedge", "brave", "firefox")
CALL_TITLES = ("meet -", "meet.google.com", "zoom meeting", "| microsoft teams", "huddle", "webex")


CALL_WINDOW = re.compile(r"^Meet - |meet\.google\.com|\bZoom Meeting\b|^Zoom Workplace - Meeting|"
                         r"\bMeeting( with [^|]+)? \| Microsoft Teams|\bCall with .+ \| Microsoft Teams|"
                         r"\bWebex\b.*\bmeeting\b|\bHuddle\b.*\bSlack\b", re.I)


def call_from_titles(titles):
    """Call apps announce live calls in their window titles."""
    for t in titles:
        if CALL_WINDOW.search(t or ""):
            tl = t.lower()
            return ("Zoom" if "zoom" in tl else "Teams" if "teams" in tl else "Slack" if "slack" in tl else
                    "Webex" if "webex" in tl else "Google Meet")
    return None


def detect_call():
    """Best-effort: the app name if a call seems live (call window title, or a
    call-capable app currently holding the microphone)."""
    try:
        from src.os_control import windows as win
        hit = call_from_titles(t for _, t, _ in win.list_windows())
        if hit:
            return hit
    except Exception as e:
        diag.record("activity.call_titles", e, quiet=True)
    try:
        users = apps_using_microphone()
    except Exception:
        users = []
    for u in users:
        if any(c in u for c in CALL_APPS):
            return friendly(u.split("\\")[-1])
    return None


# ------------------------------------------------------------------ tracker
class ActivityTracker:
    def __init__(self, settings=None, folder=None, interval=3.0,
                 on_session_start=None, on_break_due=None, on_call_change=None):
        self.settings = settings
        self.folder = folder or os.path.join(storage.data_dir(), "activity")
        os.makedirs(self.folder, exist_ok=True)
        self.interval = interval
        self.on_session_start = on_session_start
        self.on_break_due = on_break_due
        self.on_call_change = on_call_change
        self.day = None
        self.data = None
        self.last_t = None
        self.last_active_t = None
        self.active_streak_start = None
        self.break_fired = False
        self.current = ("", "")
        self.in_call = None
        self._dirty_since = None
        self.running = False
        self.lock = threading.RLock()
        # extra consumers of each foreground poll: fn(hwnd, exe, title, idle_s, t) (e.g. attention)
        self.observers = []
        # optional fn() -> seconds or None: poll faster for a while (e.g. a video feed is in front)
        self.interval_fn = None

    # ---------------------------------------------------------- settings
    def _s(self, k, d):
        if self.settings is None:
            return d
        v = self.settings.get(k)
        return d if v is None else v

    @property
    def enabled(self):
        return self._s("activity_tracking", True)

    # ------------------------------------------------------------- data
    def _file(self, day):
        return os.path.join(self.folder, f"{day}.json")

    def load_day(self, day):
        return storage.read_json(self._file(day), None) or {
            "apps": {}, "projects": {}, "sites": {}, "timeline": [], "first_active": None, "last_active": None}

    def _ensure_day(self, now):
        day = now.strftime("%Y-%m-%d")
        if day != self.day:
            if self.data is not None:
                self.flush()
            self.day, self.data = day, self.load_day(day)

    def flush(self):
        with self.lock:
            if self.data is not None and self.day:
                storage.write_json(self._file(self.day), self.data)
                self._dirty_since = None

    # ----------------------------------------------------------- sample
    def sample(self, exe, title, idle_s, t=None):
        """Feed one observation (exposed for tests). t = epoch seconds."""
        t = t or time.time()
        now = dt.datetime.fromtimestamp(t)
        with self.lock:
            self._ensure_day(now)
            prev_t, self.last_t = self.last_t, t
            gap = (t - prev_t) if prev_t else 0
            exe = (exe or "").lower()
            tl = (title or "").lower()

            away = idle_s >= IDLE_AWAY_S
            # New work session: first activity today, or back after a long break/sleep
            if not away:
                since_active = (t - self.last_active_t) if self.last_active_t else None
                if since_active is None or since_active >= NEW_SESSION_IDLE_S or \
                        (self.last_active_t and dt.datetime.fromtimestamp(self.last_active_t).date() != now.date()):
                    if self.on_session_start:
                        self.on_session_start(now, since_active)
                self.last_active_t = t
                if self.data["first_active"] is None:
                    self.data["first_active"] = t
                self.data["last_active"] = t

            # break nudges: continuous activity without a 5-minute pause
            if idle_s >= 300 or (prev_t and gap > 300):
                self.active_streak_start = None
                self.break_fired = False
            elif not away:
                if self.active_streak_start is None:
                    self.active_streak_start = t
                mins = int(self._s("break_reminder_minutes", 0) or 0)
                if mins and not self.break_fired and t - self.active_streak_start >= mins * 60:
                    self.break_fired = True
                    if self.on_break_due:
                        self.on_break_due(int((t - self.active_streak_start) / 60))

            if not self.enabled or away or not exe or not prev_t or gap > self.interval * 4:
                return
            if any(m in tl for m in PRIVATE_MARKERS):
                return
            exclude = set(self._s("activity_exclude", list(DEFAULT_EXCLUDE)) or [])
            if exe in exclude:
                return

            secs = min(gap, self.interval * 2)
            a = self.data["apps"].setdefault(exe, {"seconds": 0, "name": friendly(exe)})
            a["seconds"] = round(a["seconds"] + secs, 1)
            project = extract_project(exe, title)
            if project:
                self.data["projects"][project] = round(self.data["projects"].get(project, 0) + secs, 1)
            site = extract_site(exe, title)
            if site:
                self.data["sites"][site] = round(self.data["sites"].get(site, 0) + secs, 1)
            if self._s("activity_privacy", "standard") == "all" and title:
                titles = a.setdefault("titles", [])
                if title not in titles:
                    titles.append(title[:120])
                    del titles[:-20]

            tlz = self.data["timeline"]
            label = project or site
            if tlz and tlz[-1][2] == exe and tlz[-1][3] == label and t - tlz[-1][1] <= self.interval * 3:
                tlz[-1][1] = t
            else:
                tlz.append([prev_t, t, exe, label])
            self.current = (exe, label)
            if self._dirty_since is None:
                self._dirty_since = t
            if t - self._dirty_since > 30:
                self.flush()

    # ------------------------------------------------------------- loop
    def start(self):
        if self.running:
            return
        self.running = True
        threading.Thread(target=self._loop, daemon=True).start()

    def stop(self):
        self.running = False
        self.flush()

    def _loop(self):
        last_call_check = 0
        while self.running:
            wait = self.interval
            try:
                hwnd, exe, title = _foreground_full()
                idle = _idle_seconds()
                self.sample(exe, title, idle)
                now = time.time()
                for obs in list(self.observers):
                    try:
                        obs(hwnd, exe, title, idle, now)
                    except Exception as e:      # one failing consumer must not stop the others (or spam the log)
                        diag.record("activity.observer", e, quiet=True, observer=getattr(obs, "__name__", "?"))
                if self.interval_fn:
                    fast = self.interval_fn()
                    if fast:
                        wait = min(wait, float(fast))
                if time.time() - last_call_check > 6:
                    last_call_check = time.time()
                    call = detect_call()
                    if call != self.in_call:
                        self.in_call = call
                        if self.on_call_change:
                            self.on_call_change(call)
            except Exception as e:
                print("[Activity] sample error:", e)
            time.sleep(wait)

    # ---------------------------------------------------------- queries
    def summary(self, day=None):
        day = day or storage.today()
        with self.lock:
            data = self.data if day == self.day and self.data else self.load_day(day)
            apps = sorted(((v.get("name") or friendly(k), v["seconds"], k) for k, v in data["apps"].items()),
                          key=lambda x: -x[1])
            total = sum(s for _, s, _ in apps)
            focus = 0
            for start, end, exe, _ in data["timeline"]:
                if exe in WORK_HINT and end - start >= 25 * 60:
                    focus += end - start
            return {
                "day": day,
                "total_active": round(total),
                "first_active": data["first_active"],
                "last_active": data["last_active"],
                "top_apps": [{"name": n, "exe": e, "seconds": round(s)} for n, s, e in apps[:8]],
                "projects": sorted(({"name": k, "seconds": round(v)} for k, v in data["projects"].items()),
                                   key=lambda x: -x["seconds"])[:6],
                "sites": sorted(({"name": k, "seconds": round(v)} for k, v in data["sites"].items()),
                                key=lambda x: -x["seconds"])[:6],
                "focus_seconds": round(focus),
                "switches": len(data["timeline"]),
                "timeline": [[round(a), round(b), friendly(e), l] for a, b, e, l in data["timeline"][-400:]],
            }

    def time_on(self, name, day=None):
        """Seconds spent on an app or site matching `name` (e.g. 'youtube', 'chrome')."""
        s = self.summary(day)
        n = name.lower().strip()
        total = 0
        for group in ("sites", "top_apps", "projects"):
            for item in s[group]:
                if n in item["name"].lower() or n in item.get("exe", ""):
                    total += item["seconds"]
            if total:
                return total, group
        return 0, None

    def routine(self, days=14, today=None):
        today = today or dt.date.today()
        starts, first_apps, project_totals, last_project = [], {}, {}, None
        counted = 0
        for i in range(1, days + 1):
            d = (today - dt.timedelta(days=i)).strftime("%Y-%m-%d")
            data = storage.read_json(self._file(d), None)
            if not data or not data.get("first_active"):
                continue
            counted += 1
            fa = dt.datetime.fromtimestamp(data["first_active"])
            starts.append(fa.hour * 60 + fa.minute)
            seen = []
            for start, end, exe, label in data["timeline"]:
                if start - data["first_active"] > 45 * 60:
                    break
                if exe not in seen and exe not in ("explorer", "applicationframehost", "searchhost", "shellexperiencehost"):
                    seen.append(exe)
            for e in seen[:5]:
                first_apps[e] = first_apps.get(e, 0) + 1
            if i <= 7:
                for p, s in data.get("projects", {}).items():
                    project_totals[p] = project_totals.get(p, 0) + s
            if last_project is None and data.get("projects"):
                last_project = max(data["projects"].items(), key=lambda x: x[1])[0]
        typical = None
        if starts:
            m = int(statistics.median(starts))
            typical = f"{m // 60:02d}:{m % 60:02d}"
        usual = [e for e, c in sorted(first_apps.items(), key=lambda x: -x[1]) if counted and c / counted >= 0.5]
        return {
            "days_observed": counted,
            "typical_start": typical,
            "usual_first_apps": [{"exe": e, "name": friendly(e)} for e in usual[:4]],
            "top_projects": [p for p, _ in sorted(project_totals.items(), key=lambda x: -x[1])[:3]],
            "last_project": last_project,
        }

    def prune(self, keep_days=90):
        return storage.prune_dated_files(self.folder, keep_days)
