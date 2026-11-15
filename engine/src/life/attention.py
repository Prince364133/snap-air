"""Attention on Windows: counts Shorts / Reels watched in the browser and offers gentle nudges.

The same idea as the phone's Real Count chip, built from what Windows can see: the
foreground browser window's title (Chrome/Edge/Firefox put the page title there) and,
when available, a coarse hint from the address bar ("/shorts/", "/reels/", "/watch").

  AttentionTracker  pure counting logic: feed it (exe, title, time) observations from the
                    activity tracker's foreground polling; it counts items, keeps per-day
                    totals and writes <data>/realcount/YYYY-MM-DD.json in the phone's shape
                    {"apps": {"web.youtube.shorts": {"reels": n, "reel_ms": ms}}, ...}.
  NudgeEngine       pure decision logic: counters + time + state -> a nudge or None, with a
                    global cooldown, quiet rules and dismissal memory kept in the data dir.
  BrowserUrlReader  thin Windows adapter (UI Automation) that reads the address bar.

Privacy: titles and URLs are only looked at in memory, never stored. Files hold counts
and durations per site id. Thresholds and copy come from shared data (appdata / core
i18n) with the defaults below as fallbacks; every key is listed in the module docs of
the report. No blocking, no shame: counting beats blocking.
"""
import datetime as dt
import os
import re
import threading
import time
import uuid

from src import appdata, storage
from src import diag  # noqa: E402

IDLE_AWAY_S = 120


# ------------------------------------------------------------------ shared data
def rule(key, default):
    """windows.attention.<key>, then the phone's android.realcount.<key>, then default."""
    v = appdata.get("windows.attention." + key, None)
    if v is None:
        v = appdata.get("android.realcount." + key, None)
    return default if v is None else v


def _num(key, default):
    try:
        return float(rule(key, default))
    except (TypeError, ValueError):
        return float(default)


# English fallbacks for i18n keys (core/i18n/<lang>.json wins when it has the key)
DEFAULT_TEXT = {
    "nudge.win.title": "Quick check-in",
    "nudge.win.session_reels.1": "{reels} {kind} in {minutes} min — keep going or take a 2-minute reset?",
    "nudge.win.session_reels.2": "{reels} {kind} so far this sitting. Still enjoying it?",
    "nudge.win.session_reels.soft.1": "{reels} {kind} so far.",
    "nudge.win.switches.1": "{n} switches to {app} in an hour — stuck on something? I can start a {focus}-min focus.",
    "nudge.win.switches.soft.1": "{app}: {n} visits this hour.",
    "nudge.limit_near.1": "{minutes} of your {limit} minutes on {app} today.",
    "nudge.limit_near.soft.1": "{app}: {minutes} of {limit} min.",
    "nudge.limit_over.1": "You’ve reached your {limit} minutes on {app} today.",
    "nudge.limit_over.soft.1": "{app}: past today’s {limit} min.",
    "nudge.bedtime.1": "It’s past your bedtime. Wind down?",
    "nudge.bedtime.soft.1": "It’s late.",
    "nudge.win.focus_guard.1": "You’re in focus until {until}. Open {app} anyway?",
    "nudge.win.focus_guard.soft.1": "Focus until {until}.",
    "nudge.dismiss": "Dismiss",
    "nudge.win.action.reset": "2-min reset",
    "nudge.win.action.focus": "Start focus {focus} min",
    "nudge.win.action.open_anyway": "Open anyway",
    "nudge.win.action.back_to_focus": "Back to focus",
    "reset.title": "2-minute reset",
    "reset.step.breathe": "Breathe in slowly for 4… and out for 6.",
    "reset.step.stand": "Stand up, roll your shoulders, look far away.",
    "reset.step.water": "Have a sip of water.",
    "reset.done": "Done",
    "attention.weekly.title": "Your week",
    "attention.weekly.windows": "This week on this PC: {reels} shorts and reels ({minutes} in short-video feeds) and {videos} videos.",
    "attention.answer.videos": "You started {n} videos today and watched about {minutes}.",
    "attention.answer.no_videos": "No videos counted today.",
}

_i18n_cache = {}


def _i18n_table(lang):
    """UI strings from core/i18n through the shared loader (finds core/ in the repo, the
    PyInstaller bundle or the Android app), English merged underneath."""
    if lang in _i18n_cache:
        return _i18n_cache[lang]
    try:
        from src import core_loader
        table = dict(core_loader.strings(lang))
    except Exception:                       # never let missing text stop counting
        table = {}
    _i18n_cache[lang] = table
    return table


def text(key, lang="en", **kw):
    s = _i18n_table(lang).get(key) or (_i18n_table("en").get(key) if lang != "en" else None) \
        or DEFAULT_TEXT.get(key) or key
    try:
        return s.format(**kw)
    except (KeyError, IndexError, ValueError):
        return s


def fmt_min(ms):
    m = int(ms // 60000)
    return f"{m // 60}h {m % 60}m" if m >= 60 else f"{m} min"


# ------------------------------------------------------------------ site catalogue
# site -> how to spot it in a browser title, and which ids its short / long videos count under.
DEFAULT_SITES = [
    {"site": "youtube", "label": "YouTube", "segment_re": r"^YouTube$", "home_re": r"^YouTube$",
     "short": {"id": "web.youtube.shorts", "label": "YouTube Shorts", "kind": "Shorts",
               "url_re": r"youtube\.com/shorts/", "title_re": r"#shorts?\b"},
     "long": {"id": "web.youtube.videos", "label": "YouTube videos", "url_re": r"youtube\.com/watch"}},
    {"site": "instagram", "label": "Instagram", "segment_re": r"\bInstagram\b",
     "short": {"id": "web.instagram.reels", "label": "Instagram Reels", "kind": "Reels",
               "url_re": r"instagram\.com/reels?/", "title_re": r"\breels?\b"}},
    {"site": "facebook", "label": "Facebook", "segment_re": r"\bFacebook\b",
     "short": {"id": "web.facebook.reels", "label": "Facebook Reels", "kind": "Reels",
               "url_re": r"facebook\.com/(?:reels?/|watch/reels)", "title_re": r"\breels?\b"}},
    {"site": "tiktok", "label": "TikTok", "segment_re": r"\bTikTok\b",
     "short": {"id": "web.tiktok", "label": "TikTok", "kind": "videos", "url_re": r"tiktok\.com", "all": True}},
]
DEFAULT_DISTRACTING = ["YouTube", "Instagram", "Facebook", "TikTok", "Reddit", "X", "Netflix",
                       "Prime Video", "Hotstar"]
BROWSER_NAME = re.compile(r"^(?:Google Chrome|Chromium|Microsoft.?\s?Edge|Brave|Mozilla Firefox|Firefox|Opera|"
                          r"Vivaldi|Arc)$", re.I)
SPLIT = re.compile(r"\s[-–—|•·]\s")
PRIVATE_MARKERS = ("inprivate", "incognito", "private browsing", "- private")


def _compile_sites(raw):
    out = []
    for s in raw or []:
        try:
            c = dict(s)
            c["_seg"] = re.compile(s["segment_re"], re.I)
            c["_home"] = re.compile(s["home_re"], re.I) if s.get("home_re") else None
            for part in ("short", "long"):
                if s.get(part):
                    p = dict(s[part])
                    p["_url"] = re.compile(p["url_re"], re.I) if p.get("url_re") else None
                    p["_title"] = re.compile(p["title_re"], re.I) if p.get("title_re") else None
                    c[part] = p
            out.append(c)
        except (KeyError, TypeError, re.error) as e:
            print("[Attention] bad site entry:", e)
    return out


def clean_title(title):
    """Page part of a browser window title: no '(3)' badge, no ' and 2 more pages', no browser name."""
    t = re.sub(r"^\(\d+\+?\)\s*", "", (title or "").strip())
    t = re.sub(r"\s+and \d+ more (?:pages?|tabs?)", "", t)
    parts = [p.strip() for p in SPLIT.split(t) if p.strip()]
    while len(parts) > 1 and BROWSER_NAME.match(parts[-1].replace("​", "")):
        parts.pop()
    return parts


# ------------------------------------------------------------------ tracker
class _Item:
    __slots__ = ("key", "site", "kind", "start", "counted", "video")

    def __init__(self, key, site, kind, start):
        self.key, self.site, self.kind, self.start = key, site, kind, start
        self.counted = False
        self.video = False


class AttentionTracker:
    """Counts short videos (and long-video starts) from foreground-window observations.

    observe() is fed every poll (~1-3 s). An item = one page in a short-video context; it is
    counted once it has been on screen for min_dwell_s (quick flicks are ignored). Without
    an address-bar hint, a run of quick title changes on a video site is taken as a feed.
    """

    def __init__(self, folder=None, settings=None, clock=time.time, url_fn=None, media_fn=None,
                 extra_site_fn=None):
        base = folder or storage.data_dir()
        self.rc_folder = os.path.join(base, "realcount")
        self.att_folder = os.path.join(base, "attention")
        os.makedirs(self.rc_folder, exist_ok=True)
        os.makedirs(self.att_folder, exist_ok=True)
        self.settings = settings
        self.clock = clock
        self.url_fn = url_fn            # hwnd -> address-bar text or None (used in memory only)
        self.media_fn = media_fn        # -> True/False playing, or None when unknown
        self.extra_site_fn = extra_site_fn   # (exe, title) -> friendly site name (activity.extract_site)
        self.sites = _compile_sites(rule("sites", DEFAULT_SITES))
        self.distracting = {s.lower() for s in rule("distracting_sites", DEFAULT_DISTRACTING)}
        self.min_dwell_s = _num("count.min_dwell_s", 2.5)
        self.video_start_s = _num("count.video_start_s", 10)
        self.video_guess_s = _num("count.video_guess_s", 60)
        self.run_min = int(_num("count.feed_run_min", 3))
        self.gap_cap_s = _num("count.gap_cap_s", 10)
        self.idle_cap_s = _num("count.short_idle_cap_s", 300)
        self.fast_poll_s = _num("count.fast_poll_s", 1.0)
        self.session_gap_s = _num("nudges.session_gap_min", 10) * 60
        self.lock = threading.RLock()
        self.day = None
        self.counts, self.videos, self.sites_ms, self.opens = {}, {}, {}, {}
        self.entries = {}               # site -> [t, ...] (memory only, last hour)
        self.item = None
        self.rhythm = {}                # site -> {"run": [dwell], "active": bool, "last": t}
        self.prev_site = None
        self.last_t = None
        self.last_active_t = None
        self.session_start = self.session_last = None
        self.session_count = 0
        self.session_id = 0
        self._dirty = False
        self._last_flush = 0.0
        self.paused_until = 0.0

    # ------------------------------------------------------------ settings
    def _s(self, k, d):
        if self.settings is None:
            return d
        v = self.settings.get(k)
        return d if v is None else v

    @property
    def enabled(self):
        return bool(self._s("attention_enabled", True))

    # ------------------------------------------------------------ catalogue
    def short_ids(self):
        return {s["short"]["id"]: s["short"].get("label", s["label"]) for s in self.sites if s.get("short")}

    def labels(self):
        out = self.short_ids()
        out.update({s["long"]["id"]: s["long"].get("label", s["label"]) for s in self.sites if s.get("long")})
        return out

    def match_site(self, exe, title):
        """(site entry or None, cleaned page title, friendly site name or None)."""
        from src.life.activity import BROWSERS
        if exe not in BROWSERS or not title:
            return None, "", None
        parts = clean_title(title)
        for p in reversed(parts):
            for s in self.sites:
                if s["_seg"].search(p):
                    return s, " - ".join(parts), s["label"]
        name = None
        if self.extra_site_fn:
            try:
                name = self.extra_site_fn(exe, title)
            except Exception:
                name = None
        return None, " - ".join(parts), name

    def classify(self, site, page, url):
        short, long_ = site.get("short"), site.get("long")
        if url:
            if short and short.get("_url") and short["_url"].search(url) and \
                    (not short.get("all") or not (site.get("_home") and site["_home"].search(page))):
                return "short"
            if long_ and long_.get("_url") and long_["_url"].search(url):
                return "long"
            return "browse"
        if short and (short.get("all") or (short.get("_title") and short["_title"].search(page))):
            return "short"
        if self.rhythm.get(site["site"], {}).get("active"):
            return "short"
        if site.get("_home") and site["_home"].search(page):
            return "browse"
        return "candidate"

    # ------------------------------------------------------------ files
    def _rc_file(self, day):
        return os.path.join(self.rc_folder, f"{day}.json")

    def _att_file(self, day):
        return os.path.join(self.att_folder, f"{day}.json")

    def _load_day(self, day):
        rc = storage.read_json(self._rc_file(day), None) or {}
        mine = set(self.labels())
        self.counts = {k: {"reels": int(v.get("reels") or 0), "reel_ms": int(v.get("reel_ms") or 0)}
                       for k, v in (rc.get("apps") or {}).items() if k in mine}
        self.videos = {k: {"count": int(v.get("count") or 0), "ms": int(v.get("ms") or 0)}
                       for k, v in (rc.get("videos") or {}).items() if k in mine}
        att = storage.read_json(self._att_file(day), None) or {}
        self.sites_ms = {k: int(v) for k, v in (att.get("sites_ms") or {}).items()}
        self.opens = {k: int(v) for k, v in (att.get("opens") or {}).items()}

    def _roll(self, t):
        day = dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d")
        if day != self.day:
            if self.day is not None:
                self.flush()
            self.day = day
            self._load_day(day)
            self.item = None
            self.session_count, self.session_start, self.session_last = 0, None, None

    def flush(self):
        """Merge our ids into the day's realcount file (other ids, e.g. the phone's, are kept)."""
        with self.lock:
            if self.day is None or not self._dirty:
                return
            p = self._rc_file(self.day)
            rc = storage.read_json(p, None) or {}
            apps = rc.setdefault("apps", {})
            for k, v in self.counts.items():
                apps[k] = {"reels": int(v["reels"]), "reel_ms": int(v["reel_ms"])}
            if self.videos:
                vids = rc.setdefault("videos", {})
                for k, v in self.videos.items():
                    vids[k] = {"count": int(v["count"]), "ms": int(v["ms"])}
            storage.write_json(p, rc)
            storage.write_json(self._att_file(self.day), {
                "schema_version": 1, "date": self.day,
                "sites_ms": {k: int(v) for k, v in self.sites_ms.items()},
                "opens": dict(self.opens)})
            self._dirty = False
            self._last_flush = self.clock()

    # ------------------------------------------------------------ counting
    def _count_short(self, site, n, ms, t, events):
        sid = site["short"]["id"]
        c = self.counts.setdefault(sid, {"reels": 0, "reel_ms": 0})
        c["reels"] += n
        c["reel_ms"] += int(ms)
        if self.session_last is None or t - self.session_last > self.session_gap_s:
            self.session_start, self.session_count = t, 0
            self.session_id += 1
        self.session_count += n
        self.session_last = t
        self._dirty = True
        events.append({"type": "counted", "id": sid, "n": n})

    def _end_item(self, it, t, events):
        dwell = t - it.start
        site = it.site
        rh = self.rhythm.setdefault(site["site"], {"run": [], "active": False, "last": t})
        rh["last"] = t
        if it.kind == "short":
            if not it.counted and dwell >= self.min_dwell_s:
                self._count_short(site, 1, 0, t, events)
            if rh["active"] and dwell >= self.video_guess_s:
                rh.update(run=[], active=False)       # a long stay: no longer flicking through a feed
            return
        if it.kind != "candidate":
            return
        if it.video or dwell >= self.video_guess_s:
            rh.update(run=[], active=False)
        elif dwell >= self.min_dwell_s:
            rh["run"].append(dwell)
            if not rh["active"] and len(rh["run"]) >= self.run_min and site.get("short"):
                rh["active"] = True                   # quick title changes = a feed: count the run
                self._count_short(site, len(rh["run"]), sum(rh["run"]) * 1000, t, events)
            del rh["run"][:-20]

    def observe(self, exe, title, t=None, idle_s=0.0, hwnd=None):
        """One foreground observation -> list of events ({"type": "entered"|"counted"|"video", ...})."""
        t = self.clock() if t is None else t
        exe = (exe or "").lower()
        events = []
        with self.lock:
            self._roll(t)
            if not exe:                               # Snapy's own window / nothing: keep state as is
                return events
            gap = min(t - self.last_t, self.gap_cap_s) if self.last_t else 0.0
            gap = max(0.0, gap)
            self.last_t = t
            if idle_s < IDLE_AWAY_S:
                self.last_active_t = t
            if not self.enabled or t < self.paused_until or any(m in (title or "").lower() for m in PRIVATE_MARKERS):
                self._close_item(t, events)
                self.prev_site = None
                return events
            site, page, name = self.match_site(exe, title)
            # visits and time per distracting site (for "14 switches in an hour" and daily limits)
            dsite = name if name and name.lower() in self.distracting else None
            if dsite and dsite != self.prev_site:
                self.entries.setdefault(dsite, []).append(t)
                self.opens[dsite] = self.opens.get(dsite, 0) + 1
                self._dirty = True
                events.append({"type": "entered", "site": dsite})
            self.prev_site = dsite
            for k in list(self.entries):
                self.entries[k] = [x for x in self.entries[k] if t - x <= 3600]
            playing = self._playing()
            if dsite and gap and (idle_s < IDLE_AWAY_S or playing):
                self.sites_ms[dsite] = self.sites_ms.get(dsite, 0) + int(gap * 1000)
                self._dirty = True
            # the current item (one short / one video page)
            key = kind = None
            if site:
                rh = self.rhythm.get(site["site"])
                if rh and t - rh["last"] > self.session_gap_s and not (self.item and self.item.site is site):
                    rh.update(run=[], active=False)   # back after a while: the feed guess starts over
                url = None
                if self.url_fn and hwnd and bool(self._s("attention_read_urls", True)):
                    try:
                        url = self.url_fn(hwnd)
                    except Exception:
                        url = None
                kind = self.classify(site, page, url)
                key = (site["site"], page, url or "")
            it = self.item
            if it and key != it.key:
                self._end_item(it, t, events)
                it = self.item = None
            if key and it is None:
                it = self.item = _Item(key, site, kind, t)
            if it:
                if it.kind == "candidate" and self.rhythm.get(it.site["site"], {}).get("active"):
                    it.kind = "short"
                self._advance(it, t, gap, idle_s, playing, events)
            if self._dirty and t - self._last_flush >= 30:
                self.flush()
        return events

    def _close_item(self, t, events):
        if self.item:
            self._end_item(self.item, t, events)
            self.item = None

    def _playing(self):
        if not self.media_fn:
            return None
        try:
            return self.media_fn()
        except Exception as e:
            diag.record("attention.media_state", e, quiet=True)
            return None

    def _advance(self, it, t, gap, idle_s, playing, events):
        dwell = t - it.start
        if it.kind == "short":
            if gap and idle_s < self.idle_cap_s:
                c = self.counts.setdefault(it.site["short"]["id"], {"reels": 0, "reel_ms": 0})
                c["reel_ms"] += int(gap * 1000)
                self._dirty = True
            if not it.counted and dwell >= self.min_dwell_s:
                it.counted = True
                self._count_short(it.site, 1, 0, t, events)
        elif it.kind in ("long", "candidate") and it.site.get("long"):
            need = self.video_start_s if it.kind == "long" else self.video_guess_s
            vid = it.site["long"]["id"]
            if not it.video and dwell >= need and playing is not False:
                it.video = True
                v = self.videos.setdefault(vid, {"count": 0, "ms": 0})
                v["count"] += 1
                v["ms"] += int(dwell * 1000)
                self._dirty = True
                events.append({"type": "video", "id": vid})
            elif it.video and gap and playing is not False:
                self.videos[vid]["ms"] += int(gap * 1000)
                self._dirty = True

    # ------------------------------------------------------------ queries
    @property
    def poll_interval(self):
        """Poll faster while a video site is in front, so quick swipes are seen."""
        return self.fast_poll_s if self.item is not None else None

    def total_today(self):
        return sum(v["reels"] for v in self.counts.values())

    def entries_last_hour(self, site, t=None):
        t = self.clock() if t is None else t
        return len([x for x in self.entries.get(site, []) if t - x <= 3600])

    def soft_limit(self):
        v = int(self._s("attention_soft_limit", 0) or 0)
        return v if v > 0 else int(_num("chip.soft_limit_items", 40))

    def snapshot(self):
        with self.lock:
            total = self.total_today()
            lim = self.soft_limit()
            amber_at = _num("chip.amber_at", 1.0)
            labels = self.labels()
            return {
                "type": "attention", "enabled": self.enabled, "day": self.day,
                "today": total, "reel_ms": sum(v["reel_ms"] for v in self.counts.values()),
                "by": sorted(({"id": k, "label": labels.get(k, k), "count": v["reels"]}
                              for k, v in self.counts.items() if v["reels"]), key=lambda x: -x["count"]),
                "videos": sum(v["count"] for v in self.videos.values()),
                "video_ms": sum(v["ms"] for v in self.videos.values()),
                "session": self.session_count if self.session_last and self.clock() - self.session_last <= self.session_gap_s else 0,
                "soft_limit": lim,
                "level": "amber" if lim and total >= lim * amber_at else "ok",
                "paused": self.clock() < self.paused_until,
            }

    def pause(self, minutes=None):
        minutes = _num("nudges.pause_counting_min", 60) if minutes is None else minutes
        with self.lock:
            self.paused_until = self.clock() + float(minutes) * 60

    # ------------------------------------------------------------ answers
    REELS_WORD = re.compile(r"\b(reels?|shorts?)\b", re.I)
    VIDEOS_Q = re.compile(r"\b(how many|kitni|kitne)\b.*\bvideos?\b|\bvideos?\b.*\b(kitni|kitne)\b", re.I)

    def realcount(self):
        from src.life.realcount import RealCount
        return RealCount(folder=self.rc_folder, app_labels=self.labels())

    def answer(self, question, lang="en"):
        """'how many shorts did I watch today?' -> text (via the shared realcount answers), else None."""
        q = question or ""
        self.flush()
        if self.REELS_WORD.search(q):
            return self.realcount().answer(q)
        if self.VIDEOS_Q.search(q) and not re.search(r"\b(week|hafte|yesterday|kal)\b", q, re.I):
            with self.lock:
                n = sum(v["count"] for v in self.videos.values())
                ms = sum(v["ms"] for v in self.videos.values())
            return text("attention.answer.videos", lang, n=n, minutes=fmt_min(ms)) if n else \
                text("attention.answer.no_videos", lang)
        return None


# ------------------------------------------------------------------ nudges
def _hm(s, default):
    try:
        h, m = str(s).split(":")
        return int(h) * 60 + int(m)
    except (ValueError, AttributeError):
        return _hm(default, "23:00") if default != s else 23 * 60


def _minutes(v):
    """A per-site limit from settings as whole minutes (0 = no limit); a malformed value
    ("abc", None) used to raise inside every foreground poll and silence all nudges."""
    try:
        return max(0, int(float(v)))
    except (TypeError, ValueError):
        return 0


def _clock_text(t):
    d = dt.datetime.fromtimestamp(t)
    return f"{(d.hour % 12) or 12}:{d.minute:02d}"


class NudgeEngine:
    """Decides whether to nudge. Global rules: at most one nudge per min_gap_min, never during
    calls or meeting notes, softer copy after soften_after_dismissals dismissals today, during
    focus only the focus guard, between bedtime and wake only the bedtime nudge."""

    TRIGGERS = ("session_reels", "switches", "limit_over", "limit_near", "bedtime", "focus_guard")
    BANNED = re.compile(r"addict|hooked|wasting|lazy|shame|junk", re.I)

    def __init__(self, folder=None, settings=None, lang="en"):
        base = folder or storage.data_dir()
        self.file = os.path.join(base, "attention", "nudges.json")
        os.makedirs(os.path.dirname(self.file), exist_ok=True)
        self.settings = settings
        self.lang = lang
        self.lock = threading.RLock()
        self.st = storage.read_json(self.file, None) or {}
        self.st.setdefault("fired", {})
        self.st.setdefault("pending", {})
        self._weekly_checked = 0.0

    def _s(self, k, d):
        if self.settings is None:
            return d
        v = self.settings.get(k)
        return d if v is None else v

    def _save(self):
        storage.write_json(self.file, self.st)

    def _day(self, t):
        day = dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d")
        if self.st.get("day") != day:
            self.st.update(day=day, shown=0, dismissed=0)
        return day

    @property
    def soft(self):
        return int(self.st.get("dismissed") or 0) >= int(_num("nudges.soften_after_dismissals", 2))

    def _copy_keys(self, trigger, soft):
        defaults = {
            "session_reels": {"normal": ["nudge.win.session_reels.1", "nudge.win.session_reels.2"],
                              "soft": ["nudge.win.session_reels.soft.1"]},
            "switches": {"normal": ["nudge.win.switches.1"], "soft": ["nudge.win.switches.soft.1"]},
            "limit_near": {"normal": ["nudge.limit_near.1"], "soft": ["nudge.limit_near.soft.1"]},
            "limit_over": {"normal": ["nudge.limit_over.1"], "soft": ["nudge.limit_over.soft.1"]},
            "bedtime": {"normal": ["nudge.bedtime.1"], "soft": ["nudge.bedtime.soft.1"]},
            "focus_guard": {"normal": ["nudge.win.focus_guard.1"], "soft": ["nudge.win.focus_guard.soft.1"]},
        }
        table = appdata.get("windows.attention.nudge_copy." + trigger, None) or defaults[trigger]
        keys = table.get("soft" if soft else "normal") or table.get("normal") or defaults[trigger]["normal"]
        return keys

    def bedtime_window(self, t):
        b = str(self._s("attention_bedtime", "") or "")
        if b.lower() == "off":
            return False
        bed = _hm(b or rule("nudges.bedtime", "23:00"), "23:00")
        wake = _hm(rule("nudges.wake", "06:00"), "06:00")
        d = dt.datetime.fromtimestamp(t)
        now = d.hour * 60 + d.minute
        return (now >= bed or now < wake) if bed > wake else (bed <= now < wake)

    def _night(self, t):
        d = dt.datetime.fromtimestamp(t)
        if d.hour < 12:
            d -= dt.timedelta(days=1)
        return d.strftime("%Y-%m-%d")

    # ------------------------------------------------------------ decide
    def check(self, tracker, t=None, in_call=False, meeting=False, focus=None, events=(), active=True):
        """-> banner dict for the HUD, or None."""
        t = tracker.clock() if t is None else t
        if not bool(self._s("attention_nudges", True)):
            return None
        with self.lock:
            self._day(t)
            if in_call or meeting:
                return None
            gap_s = _num("nudges.min_gap_min", 20) * 60
            if t - float(self.st.get("last_t") or 0) < gap_s:
                return None
            cand = self._candidate(tracker, t, focus or {}, events, active)
            if not cand:
                return None
            trigger, fire_key, kw, actions = cand
            return self._make(trigger, fire_key, kw, actions, t)

    def _candidate(self, tr, t, focus, events, active):
        fired = self.st["fired"]
        focus_min = int(_num("nudges.focus_min", 25))
        if focus.get("active"):
            for e in events:
                if e.get("type") == "entered":
                    until = _clock_text(t + float(focus.get("remaining") or 0))
                    return ("focus_guard", "focus_guard",
                            {"until": until, "app": e["site"]}, ["back_to_focus", "open_anyway"])
            return None
        if self.bedtime_window(t):
            key = "bedtime:" + self._night(t)
            if active and key not in fired:
                return "bedtime", key, {}, ["reset", "dismiss"]
            return None
        if not active:
            return None
        # a long sitting in a short-video feed
        th = int(_num("nudges.session_reels", 30))
        if tr.session_count >= th:
            k = f"session:{tr.session_id}:{tr.day}"
            last = int(fired.get(k, 0) or 0)
            if tr.session_count >= last + th:
                kind = self._kind_label(tr)
                mins = max(1, int(round((t - (tr.session_start or t)) / 60)))
                return ("session_reels", k, {"reels": tr.session_count, "kind": kind, "minutes": mins,
                                             "_mark": tr.session_count}, ["reset", "dismiss"])
        # switching back to the same site again and again
        per_hour = int(_num("nudges.opens_per_hour", 12))
        for site in list(tr.entries):
            n = tr.entries_last_hour(site, t)
            k = f"switches:{site}"
            if n >= per_hour and t - float(fired.get(k, 0) or 0) >= 3600:
                return ("switches", k, {"n": n, "app": site, "focus": focus_min, "_mark": t}, ["focus", "dismiss"])
        # daily soft limits per site (off unless the user set one)
        limits = self._s("attention_limits", {}) or {}
        near_f = _num("limits.near_fraction", 0.8)
        over_f = _num("limits.over_fraction", 1.0)
        for site, ms in tr.sites_ms.items():
            lim = next((n for k, v in limits.items() if str(k).lower() == site.lower() and (n := _minutes(v)) > 0), 0)
            if not lim:
                continue
            frac = ms / (lim * 60000)
            kw = {"app": site, "minutes": int(ms // 60000), "limit": lim}
            if frac >= over_f and f"limit_over:{site}:{tr.day}" not in fired:
                return "limit_over", f"limit_over:{site}:{tr.day}", kw, ["reset", "dismiss"]
            if near_f <= frac < over_f and f"limit_near:{site}:{tr.day}" not in fired:
                return "limit_near", f"limit_near:{site}:{tr.day}", kw, ["dismiss"]
        return None

    @staticmethod
    def _kind_label(tr):
        sid = tr.item.site["short"]["id"] if tr.item and tr.item.site.get("short") else None
        site = next((s for s in tr.sites if s.get("short") and s["short"]["id"] == sid), None)
        return site["short"].get("kind", "videos") if site else "shorts"

    def _make(self, trigger, fire_key, kw, actions, t):
        mark = kw.pop("_mark", t)
        soft = self.soft
        keys = self._copy_keys(trigger, soft)
        shown = int(self.st.get("shown") or 0)
        body = text(keys[shown % len(keys)], self.lang, **kw)
        focus_min = int(_num("nudges.focus_min", 25))
        labels = {"reset": text("nudge.win.action.reset", self.lang),
                  "focus": text("nudge.win.action.focus", self.lang, focus=focus_min),
                  "dismiss": text("nudge.dismiss", self.lang),
                  "open_anyway": text("nudge.win.action.open_anyway", self.lang),
                  "back_to_focus": text("nudge.win.action.back_to_focus", self.lang)}
        nid = uuid.uuid4().hex[:10]
        self.st["fired"][fire_key] = mark
        self.st["last_t"] = t
        self.st["shown"] = shown + 1
        self.st["pending"] = {k: v for k, v in self.st["pending"].items() if t - v.get("t", 0) < 86400}
        self.st["pending"][nid] = {"trigger": trigger, "t": t}
        # keep the fired table small: drop dated entries older than yesterday
        since = (dt.datetime.fromtimestamp(t) - dt.timedelta(days=1)).strftime("%Y-%m-%d")
        self.st["fired"] = {k: v for k, v in self.st["fired"].items()
                            if not re.search(r"\d{4}-\d{2}-\d{2}$", k) or k[-10:] >= since}
        self._save()
        return {"type": "banner", "kind": "nudge", "id": nid, "trigger": trigger, "soft": soft,
                "title": text("nudge.win.title", self.lang), "text": body,
                "actions": [{"id": a, "label": labels[a]} for a in actions],
                "reset": reset_payload(self.lang) if "reset" in actions else None}

    # ------------------------------------------------------------ user's answer
    def action(self, nudge_id, action, t=None):
        """The user tapped a nudge button. Returns what the caller should do:
        {"reset": seconds} | {"focus": minutes} | {} (dismissed / ignored)."""
        t = time.time() if t is None else t
        with self.lock:
            self._day(t)
            p = self.st["pending"].pop(nudge_id, None)
            out = {"trigger": p["trigger"] if p else None}
            if action in ("dismiss", "open_anyway", "close"):
                self.st["dismissed"] = int(self.st.get("dismissed") or 0) + 1
            elif action == "reset":
                out["reset"] = int(_num("nudges.reset_s", 120))
            elif action == "focus":
                out["focus"] = int(_num("nudges.focus_min", 25))
            self._save()
            return out

    # ------------------------------------------------------------ weekly report
    def weekly(self, tracker, t=None, in_call=False, meeting=False, focus_active=False):
        """Sunday card, once per ISO week, from the shared realcount summary."""
        t = tracker.clock() if t is None else t
        if not bool(self._s("attention_weekly_report", True)) or in_call or meeting or focus_active:
            return None
        if t - self._weekly_checked < _num("weekly.check_every_s", 600):
            return None
        self._weekly_checked = t
        d = dt.datetime.fromtimestamp(t)
        if d.isoweekday() != int(_num("habits.report_weekday", 7)):
            return None
        if d.hour * 60 + d.minute < _hm(rule("weekly.after", "10:00"), "10:00"):
            return None
        y, w, _ = d.isocalendar()
        week = f"{y}-W{w:02d}"
        with self.lock:
            if self.st.get("weekly") == week:
                return None
            tracker.flush()
            rc = tracker.realcount()
            total = rc.range(7, d.date())
            videos, short_ms = self._week_extra(tracker, d.date())
            if not total["screen_ms"] and not sum(total["reels"].values()) and not videos:
                return None
            if total["screen_ms"]:
                body = rc.weekly_summary(d.date())
            else:       # this PC has no screen-time totals: don't claim "0 min screen time"
                body = text("attention.weekly.windows", self.lang, reels=sum(total["reels"].values()),
                            minutes=fmt_min(short_ms), videos=videos)
            self.st["weekly"] = week
            self._save()
        return {"type": "banner", "kind": "weekly", "title": text("attention.weekly.title", self.lang), "text": body}

    @staticmethod
    def _week_extra(tracker, end):
        """(videos started, ms in this PC's short-video feeds) over the 7 days ending `end`."""
        n, ms, mine = 0, 0, set(tracker.short_ids())
        for i in range(7):
            p = os.path.join(tracker.rc_folder, f"{(end - dt.timedelta(days=i)).isoformat()}.json")
            data = storage.read_json(p, None) or {}
            n += sum(int(v.get("count") or 0) for v in (data.get("videos") or {}).values())
            ms += sum(int(v.get("reel_ms") or 0) for k, v in (data.get("apps") or {}).items() if k in mine)
        return n, ms


def reset_payload(lang="en"):
    """The 2-minute guided reset: steps and timings from shared data."""
    total = int(_num("nudges.reset_s", 120))
    steps = rule("reset.steps", ["reset.step.breathe", "reset.step.stand", "reset.step.water"]) or []
    each = max(10, total // max(1, len(steps)))
    return {"seconds": total, "title": text("reset.title", lang), "done": text("reset.done", lang),
            "steps": [{"text": text(k, lang), "seconds": each} for k in steps]}


# ------------------------------------------------------------------ Windows adapter
class BrowserUrlReader:
    """Reads a browser's address bar through UI Automation (in memory only; callers keep
    just a coarse hint). The edit control is cached per window, so repeat reads are cheap."""

    def __init__(self, names=None, max_search_s=0.25):
        self.names = list(names or rule("address_bar_names", [
            "Address and search bar", "Search or enter web address", "Search with Google or enter address",
            "Search or enter address", "Address field"]))
        self.max_search_s = max_search_s
        self._cache = {}
        self._failed = {}
        self._com = {}
        try:
            import uiautomation as auto
            self.auto = auto
        except Exception:
            self.auto = None

    def __call__(self, hwnd):
        if self.auto is None or not hwnd:
            return None
        if time.time() - self._failed.get(hwnd, 0) < 30:
            return None
        auto = self.auto
        try:
            # COM stays initialised for the polling thread (the cached control lives in it)
            tid = threading.get_ident()
            if tid not in self._com:
                self._com[tid] = auto.UIAutomationInitializerInThread()
            ctrl = self._cache.get(hwnd)
            if ctrl is None:
                root = auto.ControlFromHandle(hwnd)
                for n in self.names:
                    c = root.EditControl(searchDepth=14, Name=n)
                    if c.Exists(self.max_search_s, 0.05):
                        ctrl = c
                        break
                if ctrl is None:
                    self._mark_failed(hwnd)
                    return None
                if len(self._cache) > 20:
                    self._cache.clear()
                self._cache[hwnd] = ctrl
            return ctrl.GetValuePattern().Value or None
        except Exception as e:
            diag.record("attention.url_read", e, quiet=True)
            self._cache.pop(hwnd, None)
            self._mark_failed(hwnd)
            return None

    def _mark_failed(self, hwnd):
        if len(self._failed) > 200:              # window handles come and go: keep the table bounded
            now = time.time()
            self._failed = {h: t for h, t in self._failed.items() if now - t < 30}
        self._failed[hwnd] = time.time()
