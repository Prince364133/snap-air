"""Hinglish / Hindi (Devanagari) -> English command normaliser, so everyday
commands like "youtube kholo", "neeche scroll karo", "awaaz badhao" run
instantly through the command grammar without the LLM.

Rules live in core/intents (domains transliteration, normalize_*, question_or_creative);
the pipeline is specified in core/README.md ("Hinglish normaliser").
"""
import re

from src import core_loader as core


def __getattr__(name):
    # read-only views kept for callers/tests that inspected the old constants
    if name == "DEVANAGARI":
        return dict(core.domain("transliteration"))
    if name == "RULES":
        return [(e["pattern"], e["replace"]) for e in core.domain("normalize")]
    raise AttributeError(name)


def to_latin(text):
    out = text
    for dev, lat in sorted(core.domain("transliteration").items(), key=lambda x: -len(x[0])):
        out = out.replace(dev, lat)
    return out


def normalize_command(text):
    """Return an English command for a Hinglish/Hindi command, else None."""
    t = to_latin(text).lower().strip()
    t = core.rewrite("normalize_punct", t)
    t = core.strip("normalize_prefix", re.sub(r"\s+", " ", t)).strip()
    t = core.strip("normalize_suffix", t)
    entry, m = core.first_match("normalize", t)
    if entry is None:
        return None
    out = core.replace_with(entry, m).strip()
    out = core.rewrite("normalize_fillers", out)
    return out if out != t else None


def is_question_or_creative(text):
    """'write me a poem', 'explain X', '...?' must go to the LLM, never be typed/executed."""
    return core.any_match("question_or_creative", text.strip())


def has_devanagari(text):
    return core.any_match("script_devanagari", text or "")


def markers():
    return set(core.domain("hinglish_markers"))
