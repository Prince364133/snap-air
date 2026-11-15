"""Tasks & reminders with natural-language times ("at 5", "in 10 minutes",
"tomorrow 9am", "10 minute baad"), stored in tasks.json."""
import datetime as dt
import re
import threading
import uuid

from src import core_loader as core
from src import storage

# Word tables: core/rules/vocab.json (vocab.numbers.time, vocab.time). The order of the number
# words is the regex alternation order.
_T = core.config("vocab.time", {}) or {}
NUM = core.config("vocab.numbers.time", {}) or {}
WEEKDAYS = list(_T.get("weekdays", []))
_NUMRX = r"(\d+(?:\.\d+)?|" + "|".join(NUM) + ")"
_UNIT = _T.get("unit_minutes", {})


def _num(s):
    s = s.strip().lower()
    try:
        return float(s)
    except ValueError:
        return NUM.get(s)


def _unit_minutes(u):
    u = u.lower().rstrip("s") if u.lower() not in ("s",) else "s"
    return _UNIT.get(u, _UNIT.get(u[:3], None) if u else None)


def _clock(h, m, ampm, now, day=None):
    h, m = int(h), int(m or 0)
    if ampm:
        ampm = ampm.replace(".", "").lower()
        if ampm.startswith("p") and h < 12:
            h += 12
        if ampm.startswith("a") and h == 12:
            h = 0
    base = day or now.date()
    cand = dt.datetime.combine(base, dt.time(h % 24, m))
    if day is None and not ampm and h <= 12:
        # "at 5" -> the next 5 o'clock that's still ahead; prefer afternoon for 1-7
        options = [cand, cand + dt.timedelta(hours=12)] if h < 12 else [cand]
        lo, hi = _T.get("afternoon_first_hours", [1, 6])
        if lo <= h <= hi:        # "at 4" means 4 PM; 7+ could be either, take the next one
            options = [cand + dt.timedelta(hours=12), cand]
        for c in options:
            if c > now:
                return c
        return options[0] + dt.timedelta(days=1)
    if day is None and cand <= now:
        cand += dt.timedelta(days=1)
    return cand


def parse_when(text, now=None):
    """Return (datetime | None, text_without_time_phrase)."""
    now = now or dt.datetime.now()
    t = " " + text.strip() + " "
    low = t.lower()
    when = None
    span = None

    def take(m, value):
        nonlocal when, span
        if when is None:
            when, span = value, m.span()

    # relative: "in 10 minutes", "after 2 hours", "10 minute baad", "in half an hour"
    for rx in (r"\b(?:in|after)\s+" + _NUMRX + r"\s*(seconds?|secs?|minutes?|mins?|m|hours?|hrs?|h)\b",
               r"\b" + _NUMRX + r"\s*(seconds?|minutes?|mins?|ghante|hours?|hrs?)\s+(?:baad|bad|later|from now)\b"):
        m = re.search(rx, low)
        if m:
            n = _num(m.group(1))
            unit = m.group(2).replace("ghante", "hour")
            mins = _unit_minutes(unit)
            if n is not None and mins:
                take(m, now + dt.timedelta(minutes=n * mins))

    # day words
    day = None
    dm = re.search(r"\b(tomorrow|kal|day after tomorrow|tonight|this evening|this afternoon|this morning|shaam ko|subah)\b", low)
    if dm:
        w = dm.group(1)
        day = now.date() + dt.timedelta(days=_T.get("day_offsets", {}).get(w, 0))
    wm = re.search(r"\b(?:on |next |this )?(" + "|".join(WEEKDAYS) + r")\b", low)
    if wm and not day:
        target = WEEKDAYS.index(wm.group(1))
        delta = (target - now.weekday()) % 7 or 7
        day = now.date() + dt.timedelta(days=delta)

    # clock time: "at 5", "at 5:30 pm", "5pm", "17:30", "at noon"
    cm = re.search(r"\b(?:at|by|@)\s*(\d{1,2})(?::|\.)?(\d{2})?\s*(a\.?m\.?|p\.?m\.?)?(?=\W)", low) or \
        re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?=\W)", low) or \
        re.search(r"\b(\d{1,2}):(\d{2})()(?=\W)", low)
    if cm and when is None:
        h = int(cm.group(1))
        if h <= 23:
            when = _clock(h, cm.group(2), cm.group(3) or None, now, day)
            span = cm.span()
    nm = re.search(r"\b(?:at )?(noon|midday|midnight)\b", low)
    if nm and when is None:
        when = dt.datetime.combine(day or now.date(), dt.time(0 if nm.group(1) == "midnight" else 12))
        if when <= now:
            when += dt.timedelta(days=1)
        span = nm.span()

    if when is None and day is not None:
        defaults = _T.get("day_default_hours", {})
        hour = defaults.get(dm.group(1) if dm else "", _T.get("fallback_hour", 9))
        # "kal subah" / "tomorrow evening": a part of day anywhere in the phrase sets the hour
        pod = re.search(r"\b(subah|morning|dopahar|afternoon|shaam|evening|raat|night)\b", low)
        if pod:
            hour = _T["part_of_day_hours"][pod.group(1)]
        when = dt.datetime.combine(day, dt.time(hour))
        if when <= now:
            when = now + dt.timedelta(minutes=_T.get("past_day_fallback_min", 30))

    rest = t
    for m in (span and (span,)) or ():
        rest = rest[:m[0]] + " " + rest[m[1]:]
    for rx in (r"\b(day after tomorrow|tomorrow|kal|tonight|this evening|this afternoon|this morning|shaam ko|subah|"
               r"aaj raat|raat ko|(?:in the )?(?:morning|evening|afternoon|night)|shaam|dopahar|raat)\b",
               r"\b(?:on |next |this )?(" + "|".join(WEEKDAYS) + r")\b") if when else ():
        rest = re.sub(rx, " ", rest, flags=re.I)
    rest = re.sub(r"\s+", " ", rest).strip(" ,.")
    return when, rest


def clean_title(text):
    t = core.strip("task_title_prefix", text.strip())
    t = core.strip("task_title_suffix", t)
    return t.strip(" ,.").strip() or text.strip()


def human_time(when, now=None):
    if not when:
        return ""
    now = now or dt.datetime.now()
    w = when if isinstance(when, dt.datetime) else dt.datetime.fromisoformat(when)
    hm = w.strftime("%I:%M %p").lstrip("0")
    if w.date() == now.date():
        return f"today at {hm}"
    if w.date() == now.date() + dt.timedelta(days=1):
        return f"tomorrow at {hm}"
    return w.strftime("%a %d %b at ") + hm


class TaskStore:
    def __init__(self, file=None):
        self.file = file or storage.path("tasks.json")
        self.lock = threading.RLock()
        self.items = storage.read_json(self.file, []) or []

    def _save(self):
        storage.write_json(self.file, self.items)

    def add(self, title, remind_at=None, source="voice", now=None):
        with self.lock:
            item = {"id": uuid.uuid4().hex[:10], "title": title.strip(),
                    "remind_at": remind_at.isoformat(timespec="minutes") if isinstance(remind_at, dt.datetime) else remind_at,
                    "done": False, "fired": False, "created": (now or dt.datetime.now()).isoformat(timespec="seconds"),
                    "source": source}
            self.items.append(item)
            self._save()
            return item

    def add_from_text(self, text, source="voice", now=None):
        when, rest = parse_when(text, now)
        return self.add(clean_title(rest), when, source, now)

    def get(self, task_id):
        return next((t for t in self.items if t["id"] == task_id), None)

    def update(self, task_id, **changes):
        with self.lock:
            t = self.get(task_id)
            if not t:
                return None
            for k in ("title", "remind_at", "done"):
                if k in changes:
                    t[k] = changes[k]
            if "remind_at" in changes:
                t["fired"] = False
            if changes.get("done"):
                t["done_at"] = dt.datetime.now().isoformat(timespec="seconds")
            self._save()
            return t

    def complete(self, task_id):
        return self.update(task_id, done=True)

    def delete(self, task_id):
        with self.lock:
            self.items = [t for t in self.items if t["id"] != task_id]
            self._save()

    def snooze(self, task_id, minutes=10, now=None):
        when = (now or dt.datetime.now()) + dt.timedelta(minutes=minutes)
        return self.update(task_id, remind_at=when.isoformat(timespec="minutes"))

    def find(self, query):
        q = query.lower().strip()
        open_items = [t for t in self.items if not t["done"]]
        exact = [t for t in open_items if q in t["title"].lower()]
        if exact:
            return exact[0]
        words = [w for w in re.findall(r"\w+", q) if len(w) > 2]
        scored = sorted(((sum(w in t["title"].lower() for w in words), t) for t in open_items),
                        key=lambda x: -x[0])
        return scored[0][1] if scored and scored[0][0] > 0 else None

    def open_tasks(self):
        return sorted([t for t in self.items if not t["done"]],
                      key=lambda t: (t["remind_at"] is None, t["remind_at"] or "", t["created"]))

    def done_on(self, day):
        return [t for t in self.items if t["done"] and (t.get("done_at") or "").startswith(day)]

    def due_reminders(self, now=None):
        """Tasks whose reminder time has come and haven't fired yet (marks them fired)."""
        now = now or dt.datetime.now()
        due = []
        with self.lock:
            for t in self.items:
                if t["done"] or t.get("fired") or not t.get("remind_at"):
                    continue
                try:
                    when = dt.datetime.fromisoformat(t["remind_at"])
                except ValueError:
                    continue
                if when <= now:
                    t["fired"] = True
                    due.append(t)
            if due:
                self._save()
        return due
