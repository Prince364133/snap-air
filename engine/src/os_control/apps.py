"""Finds installed applications by spoken name.

Indexes Start Menu shortcuts plus `Get-StartApps` (which also covers Store
apps), so "open spotify", "open discord", "open word" etc. work for whatever
is installed on this PC, instead of a hard-coded list.
"""
import difflib
import glob
import os
import re
import subprocess
import threading

ALIASES = {
    "vs code": "visual studio code", "vscode": "visual studio code", "code": "visual studio code",
    "chrome": "google chrome", "edge": "microsoft edge", "browser": "__browser__",
    "file explorer": "__explorer__", "explorer": "__explorer__", "files": "__explorer__",
    "my files": "__explorer__", "downloads": "__downloads__", "my downloads": "__downloads__",
    "documents": "__documents__", "terminal": "__terminal__", "powershell": "windows powershell",
    "command prompt": "__cmd__", "cmd": "__cmd__",
    "calculator": "calculator", "calc": "calculator", "notepad": "notepad",
    "windows settings": "__ms-settings__", "system settings": "__ms-settings__",
    "pc settings": "__ms-settings__", "control panel": "control panel",
    "task manager": "__taskmgr__", "paint": "paint", "camera": "camera", "photos": "photos",
    "word": "word", "excel": "excel", "powerpoint": "powerpoint", "outlook": "outlook",
}

BUILTIN = {
    "__explorer__": ["explorer.exe"],
    "__downloads__": ["explorer.exe", os.path.join(os.path.expanduser("~"), "Downloads")],
    "__documents__": ["explorer.exe", os.path.join(os.path.expanduser("~"), "Documents")],
    "__cmd__": ["cmd.exe", "/c", "start", "cmd.exe"],
    "__taskmgr__": ["taskmgr.exe"],
    "__ms-settings__": ["explorer.exe", "ms-settings:"],
    "__browser__": ["explorer.exe", "https://www.google.com"],
}


def _clean(name):
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9+#. ]", " ", name.lower())).strip()


class AppIndex:
    def __init__(self, autoload=True):
        self.apps = {}          # clean name -> ("lnk", path) | ("appid", id)
        self.ready = threading.Event()
        if autoload:
            threading.Thread(target=self.refresh, daemon=True).start()

    def refresh(self):
        apps = {}
        roots = [os.environ.get("ProgramData", r"C:\ProgramData"), os.environ.get("APPDATA", "")]
        for root in roots:
            pattern = os.path.join(root, "Microsoft", "Windows", "Start Menu", "Programs", "**", "*.lnk")
            for lnk in glob.glob(pattern, recursive=True):
                name = _clean(os.path.splitext(os.path.basename(lnk))[0])
                if name and "uninstall" not in name and name not in apps:
                    apps[name] = ("lnk", lnk)
        try:
            out = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 "Get-StartApps | ForEach-Object { $_.Name + '|' + $_.AppID }"],
                capture_output=True, text=True, timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            for line in out.stdout.splitlines():
                if "|" in line:
                    name, appid = line.rsplit("|", 1)
                    name = _clean(name)
                    if name and "uninstall" not in name and name not in apps:
                        apps[name] = ("appid", appid.strip())
        except Exception as e:
            print("[Apps] Get-StartApps failed:", e)
        self.apps = apps
        self.ready.set()
        print(f"[Apps] Indexed {len(apps)} installed apps")

    def find(self, spoken):
        """Return (display_name, target) or None."""
        q = _clean(spoken)
        q = re.sub(r"^(the|my)\s+", "", q)
        q = re.sub(r"\s+(app|application|program)$", "", q)
        if not q:
            return None
        alias = ALIASES.get(q)
        if alias and alias in BUILTIN:
            return q, ("cmd", BUILTIN[alias])
        if alias:
            q = alias
        self.ready.wait(timeout=8)
        apps = self.apps
        if q in apps:
            return q, apps[q]
        # Prefer the shortest name that starts with / contains every spoken word
        starts = sorted((n for n in apps if n.startswith(q + " ") or n.startswith(q)), key=len)
        if starts:
            return starts[0], apps[starts[0]]
        words = q.split()
        contains = sorted((n for n in apps if all(w in n.split() for w in words)), key=len)
        if contains:
            return contains[0], apps[contains[0]]
        close = difflib.get_close_matches(q, list(apps), n=1, cutoff=0.8)
        if close:
            return close[0], apps[close[0]]
        return None

    @staticmethod
    def launch(target):
        kind, value = target
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        if kind == "lnk":
            os.startfile(value)
        elif kind == "appid":
            subprocess.Popen(["explorer.exe", "shell:AppsFolder\\" + value], creationflags=flags)
        elif kind == "cmd":
            subprocess.Popen(value, creationflags=flags)
        else:
            raise ValueError(kind)
