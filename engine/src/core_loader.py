"""The shared core/ folder (data + rules both apps load), for the Python runtime.

core/ is the single source for prompts, intents, the tool catalog, phone/social rules,
nudges, limits and UI strings. The Windows engine and the Android app both read it; the
format is specified in core/README.md (the Dart runtime implements the same contract).

Where core/ is found (first that exists):
  $SNAPY_CORE_DIR                      explicit override (tests, tools)
  <dir that holds src/>/core           Android (Chaquopy copies core/ next to src/) and frozen layouts
  <repo>/core                          running from the repo (engine/src -> ../../core)
  sys._MEIPASS/core                    PyInstaller bundle

Regex dialect: core patterns are written in the common subset of Python `re` and
ECMAScript/Dart RegExp, with named groups as (?<name>...). Here they are translated to
(?P<name>...), macros ({{NAME}}) are expanded, and they are compiled once with
re.ASCII (\\b \\w \\d \\s mean the same as in JS/Dart) plus re.IGNORECASE when the file says so.
"""
import json
import os
import re
import sys
import threading

_lock = threading.RLock()
_cache = {}

_FORBIDDEN = [
    (re.compile(r"\(\?<[=!]"), "lookbehind"),
    (re.compile(r"\(\?>"), "atomic group"),
    (re.compile(r"(?<!\\)[*+?}][+]"), "possessive quantifier"),
    (re.compile(r"\(\?[aiLmsux-]+[):]"), "inline flags"),
    (re.compile(r"\\[AZz]"), "\\A / \\Z anchors (use ^ and $)"),
    (re.compile(r"\(\?P"), "Python-only (?P...) syntax (write (?<name>...))"),
    (re.compile(r"\\k<|\(\?P="), "named backreference"),
]
_MACRO = re.compile(r"\{\{([A-Z_]+)\}\}")
_NAMED = re.compile(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>")


class CoreError(Exception):
    pass


# ------------------------------------------------------------------ files
def core_dir():
    with _lock:
        if "dir" in _cache:
            return _cache["dir"]
        here = os.path.dirname(os.path.abspath(__file__))           # .../src
        parent = os.path.dirname(here)                               # engine/ (repo) or the app root
        cands = [os.environ.get("SNAPY_CORE_DIR") or "",
                 os.path.join(parent, "core"),
                 os.path.join(os.path.dirname(parent), "core")]
        meipass = getattr(sys, "_MEIPASS", None)
        if meipass:
            cands.append(os.path.join(meipass, "core"))
        for c in cands:
            if c and os.path.isfile(os.path.join(c, "manifest.json")):
                _cache["dir"] = c
                return c
        raise CoreError("core/ folder not found (looked in: " + ", ".join(c for c in cands if c) + ")")


def path(rel):
    return os.path.join(core_dir(), *rel.split("/"))


def read_json(rel):
    with _lock:
        key = ("json", rel)
        if key not in _cache:
            with open(path(rel), encoding="utf-8") as f:
                _cache[key] = json.load(f)
        return _cache[key]


def read_text(rel):
    with _lock:
        key = ("text", rel)
        if key not in _cache:
            with open(path(rel), encoding="utf-8") as f:
                _cache[key] = f.read().replace("\r\n", "\n").rstrip("\n")
        return _cache[key]


def version():
    return read_text("VERSION").strip()


def manifest():
    return read_json("manifest.json")


def reload():
    """Forget everything loaded (tests that point SNAPY_CORE_DIR elsewhere)."""
    with _lock:
        _cache.clear()


# ------------------------------------------------------------------ config tree
_META_KEYS = ("_meta",)


def _merge(base, extra, where, owner, src):
    for k, v in extra.items():
        p = f"{where}.{k}" if where else k
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _merge(base[k], v, p, owner, src)
        elif k in base and k != "_comment":
            raise CoreError(f"config path '{p}' is defined in both {owner.get(p, '?')} and {src}")
        else:
            base[k] = json.loads(json.dumps(v))
            owner[p] = src


def config_tree():
    """All core/rules fragments deep-merged (manifest order). A leaf may come from one file only."""
    with _lock:
        if "config" not in _cache:
            tree, owner = {}, {}
            for rel in manifest()["config"]:
                frag = {k: v for k, v in read_json(rel).items() if k not in _META_KEYS}
                _merge(tree, frag, "", owner, rel)
            _cache["config"], _cache["config_owner"] = tree, owner
        return _cache["config"]


def config(dotted, default=None):
    node = config_tree()
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node


# ------------------------------------------------------------------ prompts
def prompt(name, **values):
    """core/prompts/<name>.md with {{var}} placeholders filled. Unknown placeholders stay as they are."""
    text = read_text(f"prompts/{name}.md")
    if name == "system" and "tools" not in values:
        values["tools"] = tools_prompt()
    for k, v in values.items():
        text = text.replace("{{" + k + "}}", str(v))
    return text


def prompt_json(name):
    return read_json(f"prompts/{name}.json")


# ------------------------------------------------------------------ tools
def tools():
    return read_json("tools/tools.json")


def tools_prompt():
    cat = tools()
    by_name = {t["name"]: t for t in cat["tools"]}
    return "\n".join(" | ".join(by_name[n]["prompt"] for n in row) for row in cat["prompt_layout"])


def action_schema():
    """The structured answer the AI must give: {say, tool, args}."""
    cat = tools()
    return {
        "type": "object",
        "properties": {
            "say": {"type": "string"},
            "tool": {"type": "string", "enum": [cat["response"]["none_tool"]] + [t["name"] for t in cat["tools"]]},
            "args": {"type": "object", "properties": {k: {"type": v["type"]} for k, v in cat["args"].items()}},
        },
        "required": list(cat["response"]["required"]),
    }


# ------------------------------------------------------------------ schemas
def schema(name):
    return read_json(f"schemas/{name}.schema.json")


# ------------------------------------------------------------------ i18n
def strings(lang="en"):
    with _lock:
        key = ("i18n", lang)
        if key not in _cache:
            m = manifest()["i18n"]
            base = dict(read_json(f"{m['dir']}/{m['default']}.json"))
            if lang != m["default"] and lang in m["languages"]:
                base.update(read_json(f"{m['dir']}/{lang}.json"))
            base.pop("_meta", None)
            _cache[key] = base
        return _cache[key]


_PH = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


def t(key, lang="en", **values):
    """A UI/reply string with {placeholders} filled (falls back to English, then to the key)."""
    s = strings(lang).get(key)
    if s is None:
        s = strings("en").get(key, key)
    return _PH.sub(lambda m: str(values[m.group(1)]) if m.group(1) in values else m.group(0), s)


# ------------------------------------------------------------------ intents
def _intent_files():
    idx = read_json("intents/index.json")
    return idx, [(f, read_json(f"intents/{f}")) for f in idx["files"]]


def macros():
    with _lock:
        if "macros" not in _cache:
            out = {}
            _, files = _intent_files()
            for fname, data in files:
                for k, v in (data.get("macros") or {}).items():
                    if k in out:
                        raise CoreError(f"macro {k} defined twice ({fname})")
                    out[k] = v
            words = config("ordinals", {}) or {}
            out["ORDINALS"] = "|".join(sorted(map(re.escape, words), key=len, reverse=True))
            _cache["macros"] = out
        return _cache["macros"]


def check_portable(pattern):
    """Raise CoreError if a core pattern uses syntax outside the Python/Dart common subset."""
    for rx, what in _FORBIDDEN:
        if rx.search(pattern):
            raise CoreError(f"non-portable regex ({what}): {pattern}")


def expand(pattern):
    """Expand {{MACROS}} (recursively) -> portable source (still (?<name>...))."""
    mac = macros()
    for _ in range(5):
        new = _MACRO.sub(lambda m: mac[m.group(1)] if m.group(1) in mac else m.group(0), pattern)
        if new == pattern:
            break
        pattern = new
    left = _MACRO.search(pattern)
    if left:
        raise CoreError(f"unknown macro {left.group(0)} in {pattern}")
    return pattern


def to_python(pattern):
    """Portable source -> Python source: (?<name> becomes (?P<name>."""
    return _NAMED.sub(r"(?P<\1>", pattern)


def compile_pattern(pattern, ignore_case=True):
    key = ("rx", pattern, ignore_case)
    with _lock:
        if key not in _cache:
            src = expand(pattern)
            check_portable(src)
            _cache[key] = re.compile(to_python(src), re.ASCII | (re.IGNORECASE if ignore_case else 0))
        return _cache[key]


def domain_type(name):
    idx, _ = _intent_files()
    d = idx["domains"].get(name)
    if d is None:
        raise CoreError(f"unknown intent domain {name}")
    return d["type"]


def domain(name):
    """Entries of one domain from every language file, ready to use.

    first_match/any/strip/rewrite/extract/fragment -> list of dicts with "rx" (compiled) added,
    first_match sorted by "order" (stable: file order, then position). words -> list. map -> dict."""
    with _lock:
        key = ("domain", name)
        if key in _cache:
            return _cache[key]
        kind = domain_type(name)
        _, files = _intent_files()
        if kind == "words":
            out = []
            for _, data in files:
                out += list((data.get("domains") or {}).get(name) or [])
        elif kind == "map":
            out = {}
            for _, data in files:
                out.update((data.get("domains") or {}).get(name) or {})
        else:
            out = []
            for fname, data in files:
                ic = bool((data.get("flags") or {}).get("ignore_case", True))
                for e in (data.get("domains") or {}).get(name) or []:
                    item = dict(e, file=fname)
                    if kind == "fragment":
                        item["source"] = to_python(expand(e["pattern"]))
                    else:
                        item["rx"] = compile_pattern(e["pattern"], ic)
                    out.append(item)
            if kind == "first_match":
                out.sort(key=lambda e: e.get("order", 0))
        _cache[key] = out
        return out


def any_match(name, text):
    return any(e["rx"].search(text) for e in domain(name))


def strip(name, text):
    """Remove the first match of each entry, in order."""
    for e in domain(name):
        text = e["rx"].sub("", text, count=1)
    return text


def _template(tmpl):
    """$1 / ${name} replace templates -> Python re templates."""
    t = tmpl.replace("\\", "\\\\")
    t = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", r"\\g<\1>", t)
    return re.sub(r"\$(\d+)", r"\\g<\1>", t)


def rewrite(name, text):
    """Replace every match of each entry with its replace template, in order."""
    for e in domain(name):
        text = e["rx"].sub(_template(e.get("replace", "")), text)
    return text


def first_match(name, text):
    """(entry, match) of the first entry (by order) that matches, else (None, None)."""
    for e in domain(name):
        m = e["rx"].search(text)
        if m:
            return e, m
    return None, None


def matches(name, text):
    """Every (entry, match) in order — for consumers that validate slots and may move on."""
    for e in domain(name):
        m = e["rx"].search(text)
        if m:
            yield e, m


def replace_with(entry, match):
    """Expand an entry's replace template for a match (whole-match replacement, like re.sub on one hit)."""
    s = match.string
    return s[:match.start()] + match.expand(_template(entry.get("replace", ""))) + s[match.end():]


def fragment(name):
    """An unanchored pattern fragment (Python source) to build bigger patterns from."""
    return "".join(e["source"] for e in domain(name))


def slot_values(dotted):
    node = read_json("intents/index.json")["slot_values"]
    for part in dotted.split("."):
        node = node[part]
    return node


def all_patterns():
    """(file, domain, id, portable source) for every pattern in core (used by the conformance tests)."""
    idx, files = _intent_files()
    out = []
    for fname, data in files:
        for dname, entries in (data.get("domains") or {}).items():
            if idx["domains"].get(dname, {}).get("type") in ("words", "map"):
                continue
            for e in entries:
                out.append((fname, dname, e.get("id"), expand(e["pattern"])))
    return out
