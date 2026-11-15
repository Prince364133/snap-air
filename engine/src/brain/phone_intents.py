"""Phone actions from what the user said (English, Hinglish, Devanagari Hindi).

Pure parsing: text -> one structured action from a fixed catalog, or None. The phone then
runs a fixed, hand-written script for that action (Google Play: the AI picks the action,
it never improvises taps). Anything that sends or calls is confirmed by the user first.

Catalog: whatsapp, sms, call, alarm, timer, navigate, torch, panel, type, tap
Patterns and word tables: core/intents/*.json (domain "phone"), core/rules/vocab.json.
The slot rules below are specified in core/README.md ("phone" domain) for the Dart runtime.
"""
import re

from src import core_loader as core


def _clean(s):
    return re.sub(r"\s+", " ", (s or "").strip(" .,!?:\"'")).strip()


def _num_words(s):
    s = s.strip().lower()
    return int(s) if s.isdigit() else (core.config("vocab.numbers.phone", {}) or {}).get(s)


def _timer_seconds(n, unit):
    u = unit.lower()
    table = core.config("vocab.timer_units", {}) or {}
    for rule in table.get("rules", []):
        if u.startswith(tuple(rule["prefixes"])):
            return n * rule["seconds"]
    return n * table.get("default_seconds", 60)


def _span(t, m, group):
    return t[m.start(group):m.end(group)]


def parse(text):
    """-> {"kind": ..., ...} or None. `text` is the user's words (wake word already removed)."""
    t = _clean(text)
    low = t.lower()
    slots = core.slot_values("phone")
    not_names = set(slots["not_names"])
    for entry, m in core.matches("phone", low):
        kind = entry["intent"]
        g = m.groupdict()
        if kind in ("whatsapp", "sms"):
            name = _clean(g["name"])
            if not name or name in not_names:
                continue
            # keep the user's original casing for the message
            return {"kind": kind, "contact": name, "text": _clean(_span(t, m, "text"))}
        if kind == "call":
            name = _clean(g["name"])
            if not name or name in not_names:
                continue
            return {"kind": "call", "contact": name, "video": low.startswith(slots["video_call_prefix"])}
        if kind == "alarm":
            from src.life.tasks import parse_when
            when, _ = parse_when(g["when"])
            if when is None:
                continue
            return {"kind": "alarm", "hour": when.hour, "minute": when.minute, "label": slots["alarm_label"]}
        if kind == "timer":
            n = _num_words(g["n"])
            if not n:
                continue
            return {"kind": "timer", "seconds": _timer_seconds(n, g["unit"])}
        if kind == "navigate":
            place = _clean(_span(t, m, "place"))
            return {"kind": "navigate", "place": place} if place else None
        if kind == "torch":
            return {"kind": "torch", "on": g["state"].lower() in slots["torch_on"]}
        if kind == "panel":
            p = g["panel"].lower().replace("-", "")
            return {"kind": "panel", "panel": slots["panel"].get(p, slots["panel_default"])}
        if kind == "type":
            return {"kind": "type", "text": _clean(_span(t, m, "text"))}
        if kind == "tap":
            target = _clean(g["target"])
            # "open whatsapp" / "open settings" are app launches, handled by the command grammar
            if low.startswith("open ") and not core.any_match("phone_tap_open_ok", target):
                return None
            return {"kind": "tap", "target": target} if target else None
    return None


class _AnyOf:
    """Drop-in for the old YES/NO regexes: .match()/.search() -> truthy when any core pattern matches."""

    def __init__(self, domain):
        self.domain = domain

    def match(self, text):
        return core.any_match(self.domain, text or "")

    search = match


YES = _AnyOf("phone_yes")
NO = _AnyOf("phone_no")


def is_yes(text):
    return core.any_match("phone_yes", (text or "").strip())


def is_no(text):
    return core.any_match("phone_no", (text or "").strip())
