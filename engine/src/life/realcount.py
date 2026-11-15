"""Real Count data and answers, shared by every platform.

Daily files in <data>/realcount/:
  YYYY-MM-DD.json        {"apps": {pkg: {"reels": n, "reel_ms": ms}}}   (written by the phone's counter)
  usage-YYYY-MM-DD.json  {"screen_ms": ms, "per_app_ms": {pkg: ms}, "opens": {pkg: n}}

Answers "how many reels did I watch this week?", "screen time today", "how long was I on
Instagram?" (English + Hinglish), builds the weekly summary and checks daily limits.
"""
import datetime as dt
import json
import os
import re

from src import appdata, storage


def fmt(ms):
    m = int(ms // 60000)
    return f"{m // 60}h {m % 60}m" if m >= 60 else f"{m} min"


class RealCount:
    def __init__(self, folder=None, app_labels=None):
        self.folder = folder or os.path.join(storage.data_dir(), "realcount")
        os.makedirs(self.folder, exist_ok=True)
        self.labels = dict(app_labels or {})
        for a in appdata.get("android.social_apps", []) or []:
            self.labels.setdefault(a["package"], a["label"])

    # ------------------------------------------------------------ files
    def _read(self, name):
        try:
            with open(os.path.join(self.folder, name), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def save_usage(self, usage, day=None):
        day = day or dt.date.today()
        with open(os.path.join(self.folder, f"usage-{day.isoformat()}.json"), "w", encoding="utf-8") as f:
            json.dump(usage, f)

    def day(self, d):
        u = self._read(f"usage-{d.isoformat()}.json")
        r = (self._read(f"{d.isoformat()}.json").get("apps") or {})
        return {
            "screen_ms": int(u.get("screen_ms") or 0),
            "per_app_ms": {k: int(v) for k, v in (u.get("per_app_ms") or {}).items()},
            "reels": {k: int(v.get("reels") or 0) for k, v in r.items()},
            "reel_ms": {k: int(v.get("reel_ms") or 0) for k, v in r.items()},
        }

    def range(self, days, end=None):
        end = end or dt.date.today()
        tot = {"screen_ms": 0, "per_app_ms": {}, "reels": {}, "days": 0}
        for i in range(days):
            d = self.day(end - dt.timedelta(days=i))
            if d["screen_ms"] or d["reels"]:
                tot["days"] += 1
            tot["screen_ms"] += d["screen_ms"]
            for k, v in d["per_app_ms"].items():
                tot["per_app_ms"][k] = tot["per_app_ms"].get(k, 0) + v
            for k, v in d["reels"].items():
                tot["reels"][k] = tot["reels"].get(k, 0) + v
        return tot

    def label(self, pkg):
        return self.labels.get(pkg, pkg.split(".")[-1].title())

    def find_app(self, name):
        n = name.lower().strip()
        for pkg, label in self.labels.items():
            if label.lower() == n or n in label.lower().split() or n == pkg:
                return pkg
        return None

    # ------------------------------------------------------------ answers
    PERIOD = re.compile(r"\b(today|aaj|this week|is hafte|week|yesterday|kal)\b")
    REELS_Q = re.compile(r"\b(how many|kitni|kitne|count)\b.*\b(reels?|shorts?|videos?)\b|\b(reels?|shorts?)\b.*\b(kitni|kitne|count|how many)\b")
    SCREEN_Q = re.compile(r"\b(screen ?time|phone (?:time|usage)|how (?:long|much) (?:have|did) i (?:use|used|been on) (?:my|the) phone"
                          r"|phone kitna (?:chalaya|use kiya)|kitna phone)\b")
    APP_Q = re.compile(r"\b(?:how (?:much time|long)|kitna time|kitni der)\b.*?\b(?:on|in|pe|par)\s+([a-z][a-z ]+?)\b(?:\s+(?:today|aaj|this week|yesterday|kal|pe|par|spent|bitaya))?\s*[?.!]*$")

    APP_Q_HI = re.compile(r"(?:kitna time|kitni der)\s+([a-z][a-z ]*?)\s+(?:pe|par)\b|\b([a-z][a-z ]*?)\s+(?:pe|par)\s+(?:kitna time|kitni der)")

    def _period(self, low):
        m = self.PERIOD.search(low)
        w = m.group(1) if m else "today"
        if w in ("this week", "is hafte", "week"):
            return 7, "this week", dt.date.today()
        if w in ("yesterday", "kal"):
            return 1, "yesterday", dt.date.today() - dt.timedelta(days=1)
        return 1, "today", dt.date.today()

    def answer(self, text):
        """A spoken/typed question about usage -> answer text, or None if it isn't one."""
        low = text.lower().strip()
        days, when, end = self._period(low)
        m = self.APP_Q.search(low)
        hi = None if m else self.APP_Q_HI.search(low)
        if m or hi:
            pkg = self.find_app(m.group(1) if m else (hi.group(1) or hi.group(2)).split()[-1])
            if pkg:
                t = self.range(days, end)
                ms, reels = t["per_app_ms"].get(pkg, 0), t["reels"].get(pkg, 0)
                extra = f", and watched {reels} reels" if reels else ""
                return f"You spent {fmt(ms)} on {self.label(pkg)} {when}{extra}."
        if self.REELS_Q.search(low):
            t = self.range(days, end)
            total = sum(t["reels"].values())
            if not total:
                return f"No reels or shorts counted {when}." + ("" if t["days"] else " Turn on Real Count to start counting.")
            top = sorted(t["reels"].items(), key=lambda kv: -kv[1])[:3]
            parts = ", ".join(f"{n} on {self.label(p)}" for p, n in top if n)
            return f"You watched {total} reels and shorts {when}: {parts}."
        if self.SCREEN_Q.search(low):
            t = self.range(days, end)
            if not t["screen_ms"]:
                return f"I don't have screen time for {when} yet."
            top = sorted(t["per_app_ms"].items(), key=lambda kv: -kv[1])[:3]
            parts = ", ".join(f"{self.label(p)} {fmt(ms)}" for p, ms in top)
            avg = f" (about {fmt(t['screen_ms'] / max(1, t['days']))} a day)" if days > 1 else ""
            return f"Your screen time {when} is {fmt(t['screen_ms'])}{avg}. Most used: {parts}."
        return None

    def weekly_summary(self, end=None):
        end = end or dt.date.today()
        this, last = self.range(7, end), self.range(7, end - dt.timedelta(days=7))
        reels, prev = sum(this["reels"].values()), sum(last["reels"].values())
        social = sum(ms for p, ms in this["per_app_ms"].items() if p in self.labels)
        line = f"This week: {reels} reels and shorts, {fmt(social)} on social apps, {fmt(this['screen_ms'])} total screen time."
        if prev:
            change = round((reels - prev) * 100 / prev)
            line += f" That's {abs(change)}% {'more' if change > 0 else 'less'} reels than last week." if change else " Same as last week."
        return line

    # ------------------------------------------------------------ limits
    @staticmethod
    def limit_state(used_ms, limit_min):
        """'ok' | 'near' (>=80%) | 'over' (>=100%) for a daily time limit in minutes."""
        if not limit_min:
            return "ok"
        frac = used_ms / (limit_min * 60000)
        return "over" if frac >= 1 else "near" if frac >= 0.8 else "ok"
