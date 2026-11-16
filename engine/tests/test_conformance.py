"""Shared-core conformance: every golden case in core/conformance/*.json against the Python runtime.

The Dart runtime runs the same files with the same per-suite rules (core/README.md,
"Conformance"). A failure lists the case ids, so both runtimes can be compared case by case.
"""
import datetime as dt
import json
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src import core_loader as core  # noqa: E402

DEFAULT_SETTINGS = {"agent_name": "Snapy", "wake_words": ["snapy", "snappy", "hey snapy", "snap"]}


# ------------------------------------------------------------------ one runner per suite
def _phone(case):
    from src.brain.phone_intents import parse
    return {"action": parse(case["input"], dt.datetime.fromisoformat(case["now"]))}


def _yes_no(case):
    return {"match": core.any_match(case["domain"], case["input"].strip())}


def _hinglish(case):
    from src.brain import hinglish
    from src.brain.assistant import Assistant
    return {"command": hinglish.normalize_command(case["input"]),
            "question_or_creative": hinglish.is_question_or_creative(case["input"]),
            "lang": Assistant.detect_lang(case["input"])}


def _polite(case):
    from src.ai import agent_controller as A
    return {"plain": A.plain(A.normalize_text(case["input"])), "plain_original": A.plain_original(case["input"])}


def _ordinal(case):
    from src.ai import agent_controller as A
    rest, n = A.ordinal(A.normalize_text(case["input"]))
    return {"rest": rest, "n": n}


def _play(case):
    from src.ai import agent_controller as A
    rest, n = A.ordinal(A.plain(A.normalize_text(case["input"])))
    return {"q": A.play_request(rest), "n": n}


def _time(case):
    from src.life.tasks import parse_when
    when, rest = parse_when(case["input"], dt.datetime.fromisoformat(case["now"]))
    return {"when": when.isoformat(timespec="minutes") if when else None, "rest": rest}


def _realcount(case):
    from src.life.realcount import classify
    return classify(case["input"])


def _realcount_answer(case):
    """Answers from fixture files: case.files {name: json} are the day files in an empty folder."""
    import shutil
    import tempfile
    from src.life.realcount import RealCount
    folder = tempfile.mkdtemp(prefix="snapy_rc_")
    try:
        for name, data in (case.get("files") or {}).items():
            with open(os.path.join(folder, name), "w", encoding="utf-8") as f:
                json.dump(data, f)
        today = dt.date.fromisoformat(case["today"])
        rc = RealCount(folder=folder, today=lambda: today)
        lang = case.get("lang", "en")
        if case.get("weekly"):
            return {"answer": rc.weekly_summary(lang=lang)}
        return {"answer": rc.answer(case["input"], lang=lang)}
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def _wake(case):
    from src.ai import agent_controller as A
    s = dict(DEFAULT_SETTINGS, **(case.get("settings") or {}))
    heard, rest = A.strip_wake(case["input"], s["agent_name"], s["wake_words"])
    return {"heard": heard, "rest": rest}


def _unfinished(case):
    from src.voice.voice_listener import sounds_unfinished
    return {"unfinished": bool(sounds_unfinished(case["input"]))}


def _memory(case):
    from src.brain.memory import MemoryStore, is_secret
    text = case["input"]
    out = []
    for e in core.domain("memory_extract"):
        m = e["rx"].search(text)
        if not m:
            continue
        groups = [g.strip().rstrip(".") for g in m.groups() if g]
        if groups:
            out.append({"key": e.get("key"), "text": e["template"].format(*groups), "category": e["category"],
                        "importance": e["importance"]})
    m = MemoryStore.EXPLICIT.match(text.strip())
    return {"secret": is_secret(text), "extract": out, "explicit": m.group("fact") if m else None}


def _phone_device(case):
    # Android-only domain (camera / SOS / meeting phrases): Windows has no handler, but the
    # data must behave the same in both runtimes (core/README.md §4.8).
    low = re.sub(r"\s+", " ", re.sub(r"[.,!?;]+", " ", case["input"].lower())).strip()
    cams = core.slot_values("phone_device.camera")
    for e in core.domain("phone_device"):
        m = e["rx"].search(low)
        if m:
            cam = m.groupdict().get("camera")
            return {"intent": e["intent"], "camera": cams.get(cam.lower(), cam) if cam else None}
    return {"intent": None, "camera": None}


def _task_title(case):
    from src.life.tasks import clean_title
    return {"title": clean_title(case["input"])}


RUNNERS = {"phone_intents": _phone, "yes_no": _yes_no, "hinglish": _hinglish, "polite": _polite,
           "ordinal": _ordinal, "play": _play, "time_parse": _time, "realcount": _realcount, "realcount_answer": _realcount_answer, "wake": _wake,
           "unfinished": _unfinished, "memory": _memory, "task_title": _task_title, "phone_device": _phone_device}


def load_suites():
    folder = core.path("conformance")
    out = {}
    for name in sorted(os.listdir(folder)):
        if name.endswith(".json"):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                out[name[:-5]] = json.load(f)
    return out


class ConformanceTests(unittest.TestCase):
    def test_every_golden_case(self):
        suites = load_suites()
        self.assertTrue(suites, "no conformance files")
        failures, total = [], 0
        for name, suite in suites.items():
            run = RUNNERS[suite["suite"]]
            for case in suite["cases"]:
                total += 1
                got = json.loads(json.dumps(run(case)))
                if got != case["expect"]:
                    failures.append(f"{case['id']}: {case['input']!r}\n    expected {case['expect']}\n    got      {got}")
        print(f"\n[conformance] {total} cases, {len(failures)} failed")
        self.assertFalse(failures, "\n".join(failures))

    def test_case_ids_unique(self):
        ids = [c["id"] for s in load_suites().values() for c in s["cases"]]
        self.assertEqual(len(ids), len(set(ids)))


class CoreFormatTests(unittest.TestCase):
    def test_all_core_json_parses_and_has_no_control_chars(self):
        for dirpath, _, files in os.walk(core.core_dir()):
            for f in files:
                p = os.path.join(dirpath, f)
                with open(p, encoding="utf-8") as fh:
                    text = fh.read()
                bad = [hex(ord(c)) for c in text if ord(c) < 32 and c not in "\n\r\t"]
                self.assertFalse(bad, f"control characters in {p}: {bad}")
                if f.endswith(".json"):
                    json.loads(text)

    def test_patterns_are_portable_and_compile(self):
        pats = core.all_patterns()
        self.assertGreater(len(pats), 50)
        for fname, dname, pid, src in pats:
            core.check_portable(src)                     # no lookbehind, atomic, inline flags, \Z, (?P
            re.compile(core.to_python(src), re.ASCII)

    def test_domains_are_declared(self):
        idx = core.read_json("intents/index.json")
        for fname in idx["files"]:
            for dname in core.read_json(f"intents/{fname}")["domains"]:
                self.assertIn(dname, idx["domains"], f"{fname}: undeclared domain {dname}")

    def test_config_tree_has_one_source_per_fact(self):
        core.reload()
        core.config_tree()                               # raises on a leaf defined in two fragments
        from src import appdata
        with open(appdata._base_file(), encoding="utf-8") as f:
            base = json.load(f)
        self.assertEqual(appdata._overlaps(base, core.config_tree()), [])

    def test_legacy_appdata_paths(self):
        from src import appdata
        for k in ["android.social_apps", "android.key_actions", "android.selectors", "android.view_types",
                  "android.contact_aliases", "android.speech_locales", "android.wake_model", "android.wake_phrases",
                  "android.app_links", "android.min_reel_dwell_ms", "android.screen_time_refresh_s",
                  "android.realcount.nudges", "ordinals", "emoji_sets", "web.youtube_search", "cloud.providers",
                  "timings.interruption_memory_s", "ollama.host"]:
            self.assertIsNotNone(appdata.get(k), k)
        self.assertEqual(appdata.get("ordinals.fourth"), 4)

    def test_i18n_files_match_english(self):
        m = core.manifest()["i18n"]
        en = core.read_json(f"{m['dir']}/en.json")
        ph = re.compile(r"\{[A-Za-z_]+\}")
        # core/README.md §8: en is complete and the fallback; a language may leave keys out
        # (they show in English) but never adds keys en lacks, and keeps en's placeholders.
        for lang in m["languages"]:
            d = core.read_json(f"{m['dir']}/{lang}.json")
            self.assertEqual(set(d) - {"_meta"} - set(en), set(), lang)
            for k, v in d.items():
                if k != "_meta":
                    self.assertEqual(sorted(ph.findall(en[k])), sorted(ph.findall(v)), f"{lang}:{k}")

    def test_i18n_translated_groups_complete(self):
        # every key the translators already had (the original shared groups) stays translated
        m = core.manifest()["i18n"]
        base = core.read_json(f"{m['dir']}/hi.json")
        for lang in m["languages"]:
            if lang == "en":
                continue
            d = core.read_json(f"{m['dir']}/{lang}.json")
            self.assertEqual(set(base) - set(d), set(), lang)

    def test_nudge_copy_keys_exist(self):
        en = core.strings("en")
        for trigger, variants in core.config("android.realcount.nudge_copy").items():
            if trigger == "_comment":
                continue
            for keys in variants.values():
                for k in keys:
                    self.assertIn(k, en, k)

    def test_prompts_and_tools(self):
        system = core.prompt("system", agent_name="Meera")
        self.assertIn("You are Meera,", system)
        self.assertNotIn("{{", system)
        names = [t["name"] for t in core.tools()["tools"]]
        self.assertEqual(core.action_schema()["properties"]["tool"]["enum"], ["none"] + names)
        layout = [n for row in core.tools()["prompt_layout"] for n in row]
        self.assertEqual(sorted(layout), sorted(names))

    def test_schemas_are_2020_12_with_sync_fields(self):
        for name in ("memory_fact", "task", "note", "activity_day", "attention_day", "settings_profile"):
            s = core.schema(name)
            self.assertEqual(s["$schema"], "https://json-schema.org/draft/2020-12/schema")
            self.assertIn("schema_version", s["required"])
            if s.get("x-synced"):
                for f in ("id", "updated", "device", "deleted"):
                    self.assertIn(f, s["required"], f"{name}.{f}")

    def test_version_is_semver(self):
        self.assertRegex(core.version(), r"^\d+\.\d+\.\d+$")


if __name__ == "__main__":
    unittest.main()
