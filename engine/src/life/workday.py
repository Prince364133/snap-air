"""Workday helpers: stand-up draft, focus mode, park/resume a work context."""
import datetime as dt
import os
import re
import subprocess
import threading
import time
import uuid

from src import storage

NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def git(args, cwd, timeout=8):
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=timeout,
                           creationflags=NO_WINDOW, encoding="utf-8", errors="replace")
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


# ---------------------------------------------------------------- stand-up
def standup_draft(project_dir, tasks, now=None):
    """Yesterday / Today / Blockers from git log + finished and open tasks."""
    now = now or dt.datetime.now()
    since = "yesterday.00:00" if now.weekday() != 0 else "last.friday.00:00"
    yesterday = []
    if project_dir and os.path.isdir(project_dir):
        author = git(["config", "user.name"], project_dir)
        args = ["log", f"--since={since}", "--no-merges", "--pretty=format:%s"]
        if author:
            args.insert(1, f"--author={author}")
        yesterday += [l.strip() for l in git(args, project_dir).splitlines() if l.strip()][:8]
    yday = (now - dt.timedelta(days=3 if now.weekday() == 0 else 1)).strftime("%Y-%m-%d")
    for d in sorted({yday, (now - dt.timedelta(days=1)).strftime("%Y-%m-%d")}):
        yesterday += [t["title"] for t in tasks.done_on(d)]
    today = [t["title"] for t in tasks.open_tasks()[:5]]
    blockers = [t["title"] for t in tasks.open_tasks()
                if re.search(r"\b(blocked|waiting|stuck|depends)\b", t["title"], re.I)]
    seen = set()
    yesterday = [x for x in yesterday if not (x.lower() in seen or seen.add(x.lower()))]
    branch = git(["rev-parse", "--abbrev-ref", "HEAD"], project_dir) if project_dir else ""
    lines = ["Yesterday:"] + [f"• {x}" for x in yesterday or ["(nothing recorded)"]]
    lines += ["Today:"] + [f"• {x}" for x in today or ([f"Continue on {branch}"] if branch else ["(no open tasks)"])]
    lines += ["Blockers:"] + [f"• {x}" for x in blockers or ["None"]]
    return {"text": "\n".join(lines), "yesterday": yesterday, "today": today, "blockers": blockers}


# ------------------------------------------------------------------- focus
class Focus:
    def __init__(self, on_end=None):
        self.until = 0.0
        self.minutes = 0
        self.label = ""
        self.on_end = on_end
        self._gen = 0

    @property
    def active(self):
        return time.time() < self.until

    def start(self, minutes=25, label=""):
        self.minutes, self.label = int(minutes), label
        self.until = time.time() + self.minutes * 60
        self._gen += 1
        gen = self._gen

        def wait():
            while time.time() < self.until and gen == self._gen:
                time.sleep(1)
            if gen == self._gen and self.on_end:
                self.on_end(self.minutes)
        threading.Thread(target=wait, daemon=True).start()

    def stop(self):
        self._gen += 1
        self.until = 0.0

    def state(self):
        return {"active": self.active, "remaining": max(0, int(self.until - time.time())),
                "minutes": self.minutes, "label": self.label}


# ------------------------------------------------------------ work context
class Contexts:
    """'Park this as login bug' saves the open apps, project and git branch;
    'resume login bug' brings them back."""

    def __init__(self, file=None):
        self.file = file or storage.path("contexts.json")
        self.items = storage.read_json(self.file, []) or []

    def park(self, name, windows, project_dir=""):
        branch = git(["rev-parse", "--abbrev-ref", "HEAD"], project_dir) if project_dir else ""
        apps, seen = [], set()
        for _, title, exe in windows:
            if exe and exe not in seen and exe not in ("explorer", "applicationframehost", "python", "electron"):
                seen.add(exe)
                apps.append({"exe": exe, "title": title[:120]})
        ctx = {"id": uuid.uuid4().hex[:8], "name": name.strip(), "apps": apps[:10], "project_dir": project_dir,
               "branch": branch, "saved": dt.datetime.now().isoformat(timespec="minutes")}
        self.items = [c for c in self.items if c["name"].lower() != ctx["name"].lower()] + [ctx]
        storage.write_json(self.file, self.items)
        return ctx

    def find(self, name):
        n = name.lower().strip()
        exact = [c for c in self.items if c["name"].lower() == n]
        if exact:
            return exact[-1]
        part = [c for c in self.items if n in c["name"].lower() or c["name"].lower() in n]
        return part[-1] if part else None

    def delete(self, ctx_id):
        self.items = [c for c in self.items if c["id"] != ctx_id]
        storage.write_json(self.file, self.items)
