"""Tests for the companion features added from the product spec."""
import datetime as dt
import json
import os
import tempfile
import time
import unittest

from tests import _env  # noqa: E402

setUpModule, tearDownModule = _env.module_data_dir()   # own data folder, restored after

from src.brain import hinglish  # noqa: E402
from src.brain.llm import ThinkFilter, recommend_model  # noqa: E402
from src.brain.memory import MemoryStore, is_secret  # noqa: E402
from src.life.activity import call_from_titles  # noqa: E402
from src.life.meeting import heuristic_notes  # noqa: E402
from src.life.tasks import parse_when  # noqa: E402
from src.life.workday import Contexts, standup_draft  # noqa: E402
from tests.test_brain import FakeLLM, make_world, replies, wait_idle  # noqa: E402


class HinglishTests(unittest.TestCase):
    def test_commands(self):
        cases = {"youtube kholo": "open youtube", "neeche scroll karo": "scroll down", "awaaz badhao": "volume up",
                 "awaaz kam karo na": "volume down", "yaar kuch lofi chala do": "play lofi",
                 "youtube pe arijit ke gaane chalao": "play arijit ke gaane on youtube", "chrome pe jao": "switch to chrome",
                 "tab band karo": "close tab", "agla gaana": "next song",
                 "यूट्यूब खोलो": "open youtube"}   # Devanagari
        for text, expected in cases.items():
            self.assertEqual(hinglish.normalize_command(text), expected, text)
        self.assertIsNone(hinglish.normalize_command("open spotify"))

    def test_questions_and_creative_requests_are_never_executed(self):
        for t in ("write me a poem", "explain recursion", "what is this?", "can you tell me a joke", "isko samjhao"):
            self.assertTrue(hinglish.is_question_or_creative(t), t)
        self.assertFalse(hinglish.is_question_or_creative("open spotify"))


class MemorySafetyTests(unittest.TestCase):
    def setUp(self):
        self.m = MemoryStore(folder=tempfile.mkdtemp(), llm=FakeLLM())

    def test_secret_filter(self):
        for t in ("my wifi password is hunter2", "OTP is 482913", "card 4111 1111 1111 1111",
                  "key sk-abcdefghijklmnopqrstuv", "my bank pin is 4421"):
            self.assertTrue(is_secret(t), t)
            self.assertIsNone(self.m.add(t))
        self.assertEqual(self.m.extract_rules("remember my password is hunter2"), [])
        self.assertEqual(self.m.memories, [])

    def test_rule_extraction_without_llm_and_keyed_upsert(self):
        m = MemoryStore(folder=tempfile.mkdtemp(), llm=None)
        m.extract_rules("My name is Arjun and I work as a senior developer")
        m.extract_rules("I start work at 9:30 am")
        m.extract_rules("call me AJ")
        m.extract_rules("I start work at 10 am")          # replaces, not duplicates
        texts = [x["text"] for x in m.memories]
        self.assertIn("Usually starts work at 10 am", texts)
        self.assertNotIn("Usually starts work at 9:30 am", texts)
        self.assertEqual(m.profile["preferred_name"], "AJ")
        self.assertEqual(m.profile["role"], "senior developer")
        self.assertIn("AJ", m.about_me())

    def test_llm_consolidation_delete_op(self):
        old = self.m.add("Works from the Pune office", "work", 3)
        self.m.llm.json_answers = [{"memories": [{"op": "delete", "id": old["id"], "text": "x", "category": "fact",
                                                  "importance": 3}]}]
        applied = self.m.extract_and_consolidate("I don't work from the Pune office anymore, I moved")
        self.assertEqual(applied[0][0], "delete")
        self.assertIsNone(self.m.get(old["id"]))

    def test_reflection_writes_insights(self):
        for fact in ("Codes late at night", "Drinks chai while debugging", "Prefers keyboard shortcuts",
                     "Reviews pull requests after lunch", "Keeps a running todo list", "Likes TypeScript"):
            self.m.add(fact, "routine", 4)
        self.m.llm.json_answers = [{"insights": ["Does deep work late at night"]}]
        made = self.m.reflect(threshold=20)
        self.assertEqual([x["text"] for x in made], ["Does deep work late at night"])
        self.assertEqual(self.m.reflect(threshold=20), [])      # nothing new since


class LLMClientTests(unittest.TestCase):
    def test_think_filter_split_across_chunks(self):
        f = ThinkFilter()
        out = "".join(f.feed(c) for c in ["Hel", "lo <thi", "nk>private reasoning</th", "ink> wor", "ld"])
        self.assertEqual(out + f.buf, "Hello  world")

    def test_model_recommendation(self):
        self.assertEqual(recommend_model(8, 3), "qwen3:1.7b")
        self.assertEqual(recommend_model(12, 6), "qwen3:4b")
        self.assertEqual(recommend_model(16, 10), "qwen3:8b")
        self.assertEqual(recommend_model(16, 1), "qwen3:1.7b")       # busy 16 GB laptop (measured case)
        self.assertEqual(recommend_model(32, 20), "qwen3:14b")


class TimeParserTests(unittest.TestCase):
    def test_late_night_rollover_and_hinglish(self):
        now = dt.datetime(2026, 11, 16, 23, 30)
        self.assertEqual(parse_when("call mom at 4", now)[0], dt.datetime(2026, 11, 17, 16, 0))
        self.assertEqual(parse_when("at 11 deploy", now)[0], dt.datetime(2026, 11, 17, 11, 0))
        self.assertEqual(parse_when("kal subah gym", now)[0], dt.datetime(2026, 11, 17, 9, 0))
        self.assertEqual(parse_when("standup tomorrow evening", now)[0], dt.datetime(2026, 11, 17, 18, 0))


class CallAwarenessTests(unittest.TestCase):
    def test_call_titles(self):
        self.assertEqual(call_from_titles(["Meet - abc-defg-hij - Google Chrome"]), "Google Meet")
        self.assertEqual(call_from_titles(["Zoom Meeting"]), "Zoom")
        self.assertEqual(call_from_titles(["Meeting with Arun | Microsoft Teams"]), "Teams")
        self.assertIsNone(call_from_titles(["Gmail - Google Chrome", "Chat | Microsoft Teams"]))


class MeetingFallbackTests(unittest.TestCase):
    def test_heuristics_without_llm(self):
        notes = heuristic_notes([{"t": 0, "who": "You", "text": "I'll send the deck by Friday."},
                                 {"t": 20, "who": "Others", "text": "We agreed to ship on Monday. Can you check the logs?"}])
        self.assertEqual(notes["decisions"], ["We agreed to ship on Monday."])
        mine = [a for a in notes["action_items"] if a["mine"]]
        self.assertEqual([a["task"] for a in mine], ["I'll send the deck by Friday."])


class CompanionFlowTests(unittest.TestCase):
    def setUp(self):
        self.a, self.events, self.os = make_world()

    def say(self, text, source="voice"):
        self.events.clear()
        self.a.handle(text, source)
        wait_idle(self.a, timeout=8)
        return replies(self.events)

    def test_youtube_kholo_runs_instantly_without_llm(self):
        self.say("youtube kholo")
        self.assertIn(("open_url", "https://www.youtube.com"), self.os.calls)
        self.assertEqual([c for c in self.a.llm.calls if c[0] == "stream"], [])

    def test_write_me_a_poem_is_not_typed(self):
        self.say("write me a poem about rain")
        self.assertNotIn("type_text", [c[0] for c in self.os.calls])
        self.assertTrue([c for c in self.a.llm.calls if c[0] == "stream"])

    def test_hinglish_reply_language(self):
        self.say("mujhe ek joke sunao yaar", source="typed")          # typed: mirror the user's script
        ctx = self.a.llm.calls[-1][1][1]["content"]
        self.assertIn("Reply language: Hinglish", ctx)
        self.say("mujhe ek joke sunao yaar", source="voice")          # spoken: Devanagari so a native voice reads it
        ctx = self.a.llm.calls[-1][1][1]["content"]
        self.assertIn("Devanagari", ctx)

    def test_what_do_you_know_about_me(self):
        self.a.memory.update_profile({"name": "Arjun", "role": "senior developer"})
        r = self.say("what do you know about me?")
        self.assertIn("Arjun", r[-1])
        self.assertIn({"type": "ui_action", "action": "open_drawer", "tab": "memory"},
                      [e for e in self.events if e.get("type") == "ui_action"])

    def test_timer(self):
        r = self.say("set a timer for 10 minutes")
        self.assertIn("10 minutes", r[-1])
        t = self.a.tasks.open_tasks()[0]
        self.assertEqual(t["source"], "timer")

    def test_focus_mode(self):
        r = self.say("focus for 45 minutes")
        self.assertTrue(self.a.focus.active)
        self.assertIn("45", r[-1])
        self.say("stop focus")
        self.assertFalse(self.a.focus.active)

    def test_open_drawer_notes_today_filter(self):
        self.a.notes.add("Call the bank")
        r = self.say("open the drawer and tell me what notes we created today")
        self.assertIn("Call the bank", r[-1])
        ui = [e for e in self.events if e.get("type") == "ui_action"]
        self.assertIn({"type": "ui_action", "action": "open_drawer", "tab": "notes", "filter": "today"}, ui)

    def test_standup_draft(self):
        self.a.tasks.add("Fix login bug")
        r = self.say("prepare my standup")
        self.assertIn("stand-up is ready", r[-1])
        note = self.a.notes.items[0]
        self.assertEqual(note["kind"], "standup")
        self.assertIn("Today:", note["text"])
        self.assertIn("Fix login bug", note["text"])

    def test_park_and_resume(self):
        self.a.contexts = Contexts(os.path.join(tempfile.mkdtemp(), "contexts.json"))
        self.os.list_windows = lambda: [(1, "main.py - snap-air - Visual Studio Code", "code"),
                                        (2, "Jira - Google Chrome", "chrome")]
        r = self.say("park this as login bug")
        self.assertIn("login bug", r[-1])
        self.os.calls.clear()
        r = self.say("resume login bug")
        self.assertIn("Back to", r[-1])

    def test_no_llm_fallback_explains_once(self):
        self.a.llm.ready = lambda: False
        r1 = self.say("tell me something interesting about space")
        r2 = self.say("and another thing about stars")
        self.assertIn("Settings", r1[-1])
        self.assertNotEqual(r1[-1], r2[-1])
        r3 = self.say("hello")
        self.assertIn("Hi", r3[-1])

    def test_quiet_during_calls(self):
        self.a.in_call = "Teams"
        self.say("remind me in 10 minutes to stretch")
        self.assertEqual(self.a.speaker.said, [])         # shown, never spoken
        self.assertTrue(self.a.tasks.open_tasks())

    def test_voice_onboarding_hands_free(self):
        settings = {}
        self.a.settings = settings
        self.a.begin_voice_onboarding()
        wait_idle(self.a)
        self.say("my name is Meera")
        self.say("around 9:30")
        self.say("haan")
        r = self.say("no")
        self.assertIn("Meera", r[-1])
        self.assertTrue(self.a.memory.profile["onboarded"])
        self.assertEqual(self.a.memory.profile["work_start"], "09:30")
        self.assertEqual(settings["activity_tracking"], True)
        self.assertEqual(settings["start_at_login"], False)

    def test_start_my_day_skips_what_is_already_open(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "package.json"), "w") as f:
            json.dump({"scripts": {"dev": "vite"}}, f)
        self.a.memory.update_profile({"projects": [{"name": "snap-air", "path": d}],
                                      "routine": {"last_project": "snap-air"}})
        self.os.list_windows = lambda: [(1, "app.js - snap-air - Antigravity IDE", "antigravity ide")]
        r = self.say("start my day")
        self.assertNotIn("open_editor", [c[0] for c in self.os.calls])      # editor already has the project
        self.assertIn(("run_terminal", "npm run dev", d), self.os.calls)
        self.os.calls.clear()
        r = self.say("start my day")
        self.assertEqual([c for c in self.os.calls if c[0] == "run_terminal"], [])   # no duplicate dev server
        self.assertIn("already", r[-1].lower())

    def test_meeting_bookmark(self):
        self.say("start taking notes")
        self.say("mark that")
        self.assertEqual(len(self.a.meeting.bookmarks), 1)
        self.a.meeting.recording = False


class WorkdayTests(unittest.TestCase):
    def test_standup_from_tasks_without_git(self):
        from src.life.tasks import TaskStore
        ts = TaskStore(os.path.join(tempfile.mkdtemp(), "t.json"))
        t = ts.add("Ship the API")
        ts.complete(t["id"])
        ts.add("Waiting on design review (blocked)")
        d = standup_draft("", ts, now=dt.datetime.now() + dt.timedelta(days=1))
        self.assertIn("Ship the API", d["yesterday"])
        self.assertEqual(len(d["blockers"]), 1)


if __name__ == "__main__":
    unittest.main()
