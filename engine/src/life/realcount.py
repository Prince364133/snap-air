"""Real Count data and answers, shared by every platform.

Daily files in <data>/realcount/:
  YYYY-MM-DD.json        {"apps": {pkg: {"reels": n, "reel_ms": ms}}}   (written by the phone's counter)
                         + {"videos": {id: {"count": n, "ms": ms}}}            (long videos, Windows counter)
  usage-YYYY-MM-DD.json  {"screen_ms": ms, "per_app_ms": {pkg: ms}, "opens": {pkg: n}}
Reels/shorts ("apps") and long videos ("videos") are counted and answered separately.

Answers "how many reels did I watch this week?", "screen time today", "how long was I on
Instagram?" (English + Hinglish), builds the weekly summary and checks daily limits.
"""
import datetime as dt
import json
import os
import re

from src import appdata, core_loader as core, storage


def fmt(ms, lang="en"):
    m = int(ms // 60000)
    return core.t("time.hours_minutes", lang, h=m // 60, m=m % 60) if m >= 60 else core.t("time.minutes", lang, m=m)


def classify(text):
    """What a usage question asks (no data needed): {"period", "app", "reels", "videos", "screen"}.
    period: today | this_week | yesterday; app: the app word of a time-on-app question (or None).
    Patterns: core/intents realcount_* domains; spec in core/README.md."""
    low = text.lower().strip()
    _, pm = core.first_match("realcount_period", low)
    word = pm.group("period") if pm else None
    period = core.slot_values("realcount.period").get(word, core.slot_values("realcount.period_default"))
    entry, am = core.first_match("realcount_app", low)
    app = None
    if am:
        g = am.groupdict()
        app = (g.get("app") or g.get("app2") or "").strip()
        if entry.get("last_word") and app:
            app = app.split()[-1]
    return {"period": period, "app": app or None, "reels": core.any_match("realcount_reels", low),
            "videos": core.any_match("realcount_videos", low), "screen": core.any_match("realcount_screen", low)}


class RealCount:
    def __init__(self, folder=None, app_labels=None, today=None):
        self.folder = folder or os.path.join(storage.data_dir(), "realcount")
        os.makedirs(self.folder, exist_ok=True)
        self.labels = dict(app_labels or {})
        for a in appdata.get("android.social_apps", []) or []:
            self.labels.setdefault(a["package"], a["label"])
        for k, v in (core.config("realcount.web_labels", {}) or {}).items():     # browser-counted ids
            if k != "_comment":
                self.labels.setdefault(k, v)
        self.today = today                      # fn() -> date, for tests; default: the clock

    def _today(self, today=None):
        return today or (self.today() if self.today else dt.date.today())

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
            "videos": {k: {"count": int(v.get("count") or 0), "ms": int(v.get("ms") or 0)}
                       for k, v in (self._read(f"{d.isoformat()}.json").get("videos") or {}).items()},
            "has_usage": bool(u),
        }

    def range(self, days, end=None):
        end = end or self._today()
        tot = {"screen_ms": 0, "per_app_ms": {}, "reels": {}, "videos": {"count": 0, "ms": 0}, "days": 0,
               "usage_days": 0}
        for i in range(days):
            d = self.day(end - dt.timedelta(days=i))
            if d["screen_ms"] or d["reels"]:
                tot["days"] += 1
            tot["usage_days"] += 1 if d["has_usage"] else 0
            for v in d["videos"].values():
                tot["videos"]["count"] += v["count"]
                tot["videos"]["ms"] += v["ms"]
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
    def _period(self, period, today=None):
        days = core.slot_values("realcount.period_days")[period]
        back = core.slot_values("realcount.period_end_offset_days")[period]
        return days, self._today(today) - dt.timedelta(days=back)

    def answer(self, text, lang="en", today=None):
        """A spoken/typed question about usage -> answer text, or None if it isn't one."""
        q = classify(text)
        days, end = self._period(q["period"], today)
        when = core.t("realcount.period." + q["period"], lang)
        if q["app"]:
            pkg = self.find_app(q["app"])
            if pkg:
                t = self.range(days, end)
                ms, reels = t["per_app_ms"].get(pkg, 0), t["reels"].get(pkg, 0)
                extra = core.t("realcount.app_time_reels", lang, reels=reels) if reels else ""
                return core.t("realcount.app_time", lang, time=fmt(ms, lang), app=self.label(pkg), when=when, extra=extra)
        if q["reels"]:
            t = self.range(days, end)
            total = sum(t["reels"].values())
            if not total:
                msg = core.t("realcount.no_reels", lang, when=when)
                return msg if t["days"] else msg + " " + core.t("realcount.turn_on", lang)
            top = sorted(t["reels"].items(), key=lambda kv: -kv[1])[:3]
            parts = ", ".join(core.t("realcount.reels_part", lang, n=n, app=self.label(p)) for p, n in top if n)
            return core.t("realcount.reels_total", lang, total=total, when=when, parts=parts)
        if q["videos"]:
            v = self.range(days, end)["videos"]
            return core.t("realcount.videos_total", lang, n=v["count"], when=when, time=fmt(v["ms"], lang)) \
                if v["count"] else core.t("realcount.no_videos", lang, when=when)
        if q["screen"]:
            t = self.range(days, end)
            if not t["screen_ms"]:
                return core.t("realcount.no_screen_time", lang, when=when)
            top = sorted(t["per_app_ms"].items(), key=lambda kv: -kv[1])[:3]
            parts = ", ".join(core.t("realcount.screen_part", lang, app=self.label(p), time=fmt(ms, lang)) for p, ms in top)
            avg = core.t("realcount.screen_avg", lang, time=fmt(t["screen_ms"] / max(1, t["days"]), lang)) if days > 1 else ""
            return core.t("realcount.screen_time", lang, when=when, time=fmt(t["screen_ms"], lang), avg=avg, parts=parts)
        return None

    def weekly_summary(self, end=None, lang="en", today=None):
        end = end or self._today(today)
        this, last = self.range(7, end), self.range(7, end - dt.timedelta(days=7))
        reels, prev = sum(this["reels"].values()), sum(last["reels"].values())
        social = sum(ms for p, ms in this["per_app_ms"].items() if p in self.labels)
        if this["usage_days"]:
            line = core.t("realcount.weekly", lang, reels=reels, social=fmt(social, lang), screen=fmt(this["screen_ms"], lang))
        else:                                   # no usage stats (e.g. a PC): never claim "0 min" screen time
            line = core.t("realcount.weekly_no_screen", lang, reels=reels, social=fmt(social, lang))
        if prev:
            change = round((reels - prev) * 100 / prev)
            if not change:
                line += core.t("realcount.weekly_same", lang)
            else:
                line += core.t("realcount.weekly_more" if change > 0 else "realcount.weekly_less", lang, pct=abs(change))
        return line

    # ------------------------------------------------------------ limits
    @staticmethod
    def limit_state(used_ms, limit_min):
        """'ok' | 'near' | 'over' for a daily time limit in minutes (thresholds: core/rules/limits.json)."""
        if not limit_min:
            return "ok"
        lim = core.config("android.realcount.limits", {}) or {}
        frac = used_ms / (limit_min * 60000)
        return "over" if frac >= lim.get("over_fraction", 1.0) else "near" if frac >= lim.get("near_fraction", 0.8) else "ok"
