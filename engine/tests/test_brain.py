import datetime as dt
import json
import os
import tempfile
import time
import unittest

import numpy as np

from tests import _env  # noqa: E402

setUpModule, tearDownModule = _env.module_data_dir()   # own data folder, restored after

from src.brain.memory import MemoryStore  # noqa: E402
from src.brain.llm import JsonFieldStreamer  # noqa: E402
from src.brain.briefing import Briefing  # noqa: E402
from src.brain.assistant import Assistant  # noqa: E402
from src.life.tasks import TaskStore  # noqa: E402
from src.life.notes import NoteStore  # noqa: E402
from src.life.activity import ActivityTracker  # noqa: E402
from src.life.meeting import MeetingRecorder  # noqa: E402
from src.voice.tts import SentenceChunker  # noqa: E402
from src.ai.agent_controller import AgentController  # noqa: E402
from tests.test_agent import FakeApps, FakeOS  # noqa: E402


class FakeLLM:
    def __init__(self):
        self.json_answers = []
        self.stream_answer = '{"tool": "none", "args": {}, "say": "Hello there. How can I help?"}'
        self.text_answer = "Canberra is the capital."
        self.calls = []

    def embed(self, texts):
        return None                     # exercise keyword retrieval path

    def chat_json(self, messages, schema, **kw):
        self.calls.append(("json", messages))
        return self.json_answers.pop(0) if self.json_answers else {}

    def chat_text(self, messages, **kw):
        self.calls.append(("text", messages))
        return self.text_answer

    def stream(self, messages, schema=None, **kw):
        self.calls.append(("stream", messages))
        for i in range(0, len(self.stream_answer), 7):
            yield self.stream_answer[i:i + 7]

    def ready(self):
        return True


class FakeSpeaker:
    def __init__(self):
        self.said = []
        self.busy = False

    def say(self, text, lang="en"):
        self.said.append((text, lang))

    def interrupt(self):
        pass

    def wait_done(self, timeout=0):
        pass


class StreamingTests(unittest.TestCase):
    def test_json_field_streamer_extracts_say_progressively(self):
        raw = '{"tool": "desktop", "args": {"command": "open spotify"}, "say": "Opening Spotify \\"now\\" — enjoy!"}'
        s, out = JsonFieldStreamer("say"), ""
        for i in range(0, len(raw), 3):
            out += s.feed(raw[i:i + 3])
        self.assertEqual(out, 'Opening Spotify "now" — enjoy!')

    def test_sentence_chunker_starts_early(self):
        c = SentenceChunker()
        parts = c.feed("Good morning Rahul, yesterday you worked on snap air for three hours. ")
        parts += c.feed("Want me to open it? ")
        parts += c.flush()
        self.assertEqual(parts[0], "Good morning Rahul,")
        self.assertIn("Want me to open it?", parts)


class MemoryTests(unittest.TestCase):
    def setUp(self):
        self.llm = FakeLLM()
        self.m = MemoryStore(folder=tempfile.mkdtemp(), llm=self.llm)

    def test_explicit_remember_third_person_and_dedupe(self):
        a = self.m.explicit_remember("Remember that my manager's name is Arun")
        self.assertEqual(a["text"], "User's manager's name is Arun")
        self.assertEqual(a["importance"], 5)
        self.m.explicit_remember("remember my manager's name is Arun")
        self.assertEqual(len(self.m.memories), 1)

    def test_retrieval_prefers_relevant(self):
        self.m.add("Prefers Slack over email for work messages", "preference", 4)
        self.m.add("Favourite food is masala dosa", "preference", 3)
        self.m.add("Standup is at 10:00 on weekdays", "routine", 3)
        hits = self.m.retrieve("should I email or slack the team?", k=2)
        self.assertIn("Slack", hits[0]["memory"]["text"])
        self.assertEqual(self.m.retrieve("what time is standup", k=1)[0]["memory"]["text"],
                         "Standup is at 10:00 on weekdays")

    def test_extraction_add_update_and_prefilter(self):
        self.assertFalse(self.m.worth_extracting("scroll down"))
        self.assertFalse(self.m.worth_extracting("what is the capital of France"))
        old = self.m.add("Works on the billing project", "project", 3)
        self.llm.json_answers = [{"memories": [
            {"op": "update", "id": old["id"], "text": "Works on the snap-air project", "category": "project", "importance": 4},
            {"op": "add", "text": "Prefers dark mode", "category": "preference", "importance": 3}]}]
        applied = self.m.extract_and_consolidate("I moved from billing to the snap-air project and I prefer dark mode")
        self.assertEqual([op for op, _ in applied], ["update", "add"])
        upd = self.m.get(old["id"])
        self.assertEqual(upd["text"], "Works on the snap-air project")
        self.assertEqual(upd["history"][0]["text"], "Works on the billing project")   # no silent loss
        # The extraction prompt included the similar existing memory for consolidation
        prompt = self.llm.calls[-1][1][1]["content"]
        self.assertIn(old["id"], prompt)

    def test_forget_and_persistence(self):
        self.m.add("Allergic to peanuts", "fact", 5)
        self.m.add("Likes lofi music while coding", "preference", 3)
        gone = self.m.forget("the peanut allergy")
        self.assertEqual(gone["text"], "Allergic to peanuts")
        again = MemoryStore(folder=self.m.folder)
        self.assertEqual([x["text"] for x in again.memories], ["Likes lofi music while coding"])

    def test_context_block_has_profile_and_core(self):
        self.m.update_profile({"name": "Rahul", "role": "developer", "editor": "Antigravity IDE"})
        self.m.add("Call me Rahul bhai", "instruction", 5)
        profile, mems = self.m.context_block("anything")
        self.assertIn("Name: Rahul", profile)
        self.assertIn("Call me Rahul bhai", mems)


def make_world():
    folder = tempfile.mkdtemp()
    llm = FakeLLM()
    memory = MemoryStore(folder=os.path.join(folder, "memory"), llm=llm)
    tasks = TaskStore(os.path.join(folder, "tasks.json"))
    notes = NoteStore(os.path.join(folder, "notes.json"))
    activity = ActivityTracker(settings={}, folder=os.path.join(folder, "activity"))
    fos = FakeOS()
    agent = AgentController(settings={}, os_actions=fos, app_index=FakeApps())
    agent.play_youtube = lambda q: fos.calls.append(("youtube", q))
    briefing = Briefing(memory, tasks, notes, activity, settings={}, agent=agent)
    events = []
    transcripts = iter(["We agreed the API ships Friday.", "Rahul will update the README by tomorrow."])
    meeting = MeetingRecorder(transcribe_fn=lambda a: next(transcripts, ""), llm=llm, notes=notes, tasks=tasks,
                              memory=memory, on_update=lambda s: None)
    meeting.capture_devices = False
    speaker = FakeSpeaker()
    a = Assistant({"follow_up_seconds": 8}, agent, memory, tasks, notes, activity, briefing, meeting, llm,
                  speaker, emit=events.append)
    return a, events, fos


def wait_idle(a, timeout=5):
    end = time.time() + timeout
    time.sleep(0.05)
    while (not a._q.empty() or a.working) and time.time() < end:
        time.sleep(0.05)
    time.sleep(0.1)


def replies(events):
    return [e["text"] for e in events if e["type"] == "chat_message" and e["role"] == "assistant" and e["final"]]


class AssistantTests(unittest.TestCase):
    def setUp(self):
        self.a, self.events, self.os = make_world()

    def say(self, text, source="voice"):
        self.events.clear()
        self.a.handle(text, source)
        wait_idle(self.a)
        return replies(self.events)

    def test_reminder_is_instant_and_spoken(self):
        r = self.say("Snap, remind me to push the PR at 5 pm")
        self.assertIn("push the PR", r[-1])
        self.assertEqual(self.a.tasks.open_tasks()[0]["title"], "push the PR")
        self.assertTrue(self.a.speaker.said)
        self.assertEqual([c for c in self.a.llm.calls if c[0] == "stream"], [])   # no LLM needed

    def test_hinglish_reminder(self):
        self.say("10 minute baad padhai ka reminder lagao")
        self.assertEqual(self.a.tasks.open_tasks()[0]["title"], "padhai")

    def test_remember_and_forget(self):
        self.say("remember that my standup is at 10 am")
        self.assertIn("standup", self.a.memory.memories[0]["text"])
        self.say("forget my standup time")
        self.assertEqual(self.a.memory.memories, [])

    def test_remember_to_is_a_task_not_a_memory(self):
        self.say("remember to buy milk tonight")
        self.assertEqual(self.a.tasks.open_tasks()[0]["title"], "buy milk")
        self.assertEqual(self.a.memory.memories, [])

    def test_take_note_is_not_a_meeting(self):
        self.say("take note call the bank today")
        self.assertFalse(self.a.meeting.recording)

    def test_desktop_command_fast_path(self):
        self.say("switch to chrome")
        self.assertIn(("focus_window", 101), self.os.calls)

    def test_llm_conversation_streams_into_speech(self):
        r = self.say("how are you doing today?")
        self.assertEqual(r[-1], "Hello there. How can I help?")
        self.assertEqual(self.a.speaker.said[0][0], "Hello there.")
        sys_ctx = self.a.llm.calls[-1][1][1]["content"]
        self.assertIn("TIME:", sys_ctx)

    def test_llm_tool_desktop_and_risky_confirmation(self):
        self.a.llm.stream_answer = json.dumps({"tool": "desktop", "args": {"command": "play lofi hip hop on youtube"},
                                               "say": "Chalo, lofi laga deta hoon."})
        self.say("I need some calm music to focus")
        self.assertIn(("youtube", "lofi hip hop"), self.os.calls)
        self.a.llm.stream_answer = json.dumps({"tool": "desktop", "args": {"command": "close chrome"},
                                               "say": "Okay."})
        r = self.say("get rid of the browser")
        self.assertIn("confirm", r[-1])
        self.assertNotIn("alt", [c[1] for c in self.os.calls if c[0] == "hotkey"])
        self.say("yes")
        self.assertIn(("hotkey", "alt", "f4"), self.os.calls)

    def test_web_search_tool_answers_from_results(self):
        class Web:
            @staticmethod
            def web_search(q, k=4):
                return [{"title": "Canberra - Wikipedia", "url": "https://w", "snippet": "Canberra is the capital"}]
        self.a.web = Web
        self.a.llm.stream_answer = json.dumps({"tool": "web_search", "args": {"query": "capital of australia"},
                                               "say": "Let me check."})
        r = self.say("what's the capital of australia")
        self.assertEqual(r[-1], "Canberra is the capital.")
        prompt = self.a.llm.calls[-1][1][1]["content"]
        self.assertIn("Canberra - Wikipedia", prompt)

    def test_start_my_day_runs_plan(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "package.json"), "w") as f:
            json.dump({"scripts": {"dev": "vite"}}, f)
        self.a.memory.update_profile({"projects": [{"name": "snap-air", "path": d}],
                                      "routine": {"last_project": "snap-air",
                                                  "usual_first_apps": [{"exe": "chrome", "name": "Chrome"}]}})
        r = self.say("let's start the day")
        names = [c[0] for c in self.os.calls]
        self.assertIn("open_editor", names)
        self.assertIn(("run_terminal", "npm run dev", d), self.os.calls)
        self.assertIn("All set", r[-1])

    def test_briefing_offer_then_yes(self):
        d = tempfile.mkdtemp()
        self.a.memory.update_profile({"name": "Rahul", "projects": [{"name": "snap-air", "path": d}],
                                      "routine": {"last_project": "snap-air"}})
        r = self.say("good morning")
        self.assertIn("Rahul", r[-1])
        self.assertIsNotNone(self.a.pending)
        self.say("haan")
        self.assertIn("open_editor", [c[0] for c in self.os.calls])

    def test_meeting_notes_end_to_end(self):
        self.a.llm.json_answers = [{"title": "API sync", "summary": ["API ships Friday"], "decisions": ["Ship Friday"],
                                    "action_items": [{"task": "Update the README", "owner": "me", "due": "tomorrow"},
                                                     {"task": "Review PR", "owner": "Arun", "due": ""}]}]
        self.say("start taking notes, standup is starting")
        self.assertTrue(self.a.meeting.recording)
        rng = np.random.default_rng(0)
        for _ in range(2):   # two 20 s windows of "speech", arriving one after the other
            self.a.meeting.feed("mic", (rng.standard_normal(16000 * 20) * 0.1).astype(np.float32))
            time.sleep(1.2)
        self.say("stop taking notes")
        end = time.time() + 10
        while not self.a.notes.items and time.time() < end:
            time.sleep(0.1)
        time.sleep(0.3)
        note = self.a.notes.items[0]
        self.assertEqual(note["kind"], "meeting")
        self.assertEqual(note["title"], "API sync")
        self.assertIn("Rahul will update the README", note["transcript"])
        self.assertIn("You: Rahul will update the README", note["transcript"])   # mic = "You"
        # action items wait for review instead of silently becoming tasks
        self.assertEqual(self.a.tasks.open_tasks(), [])
        self.assertTrue(note["review_pending"])
        mine = [a for a in note["actions"] if a["mine"]]
        self.assertEqual([a["task"] for a in mine], ["Update the README"])
        task = self.a.meeting.review_action(note, mine[0]["id"], "accept")
        self.assertEqual(task["title"], "Update the README")
        other = [a for a in note["actions"] if not a["mine"]][0]
        self.a.meeting.review_action(note, other["id"], "not_mine")
        self.assertFalse(note["review_pending"])
        self.assertEqual([t["title"] for t in self.a.tasks.open_tasks()], ["Update the README"])

    def test_notes_today_and_tasks_queries(self):
        self.a.notes.add("Call the bank")
        self.a.tasks.add("Push the PR")
        self.assertIn("Call the bank", self.say("what notes did we create today?")[-1])
        self.assertIn("Push the PR", self.say("what are my tasks")[-1])
        self.assertIn("marked", self.say("I finished push the PR")[-1])

    def test_memory_learning_runs_in_background(self):
        self.a.learn_after_quiet = 0.2
        self.a.llm.json_answers = [{"memories": [{"op": "add", "text": "Manager is Arun", "category": "person",
                                                  "importance": 4}]}]
        self.say("my manager Arun always wants updates on Slack, that's how we work")
        end = time.time() + 3
        while not self.a.memory.memories and time.time() < end:
            time.sleep(0.05)
        self.assertEqual(self.a.memory.memories[0]["text"], "Manager is Arun")


class BriefingTests(unittest.TestCase):
    def test_once_per_day_and_not_in_call(self):
        a, _, _ = make_world()
        b = a.briefing
        now = dt.datetime(2026, 11, 16, 9, 0)
        self.assertFalse(b.should_greet(now, in_call="Teams"))
        self.assertTrue(b.should_greet(now))
        b.mark_greeted(now)
        self.assertFalse(b.should_greet(now.replace(hour=14)))
        self.assertTrue(b.should_greet(now + dt.timedelta(days=1)))


if __name__ == "__main__":
    unittest.main()


class WakeWordSafetyTests(unittest.TestCase):
    def test_prompt_never_contains_wake_word(self):
        # With "Snap" in Whisper's prompt, room noise became "Snap, open YouTube" 11/12 times.
        from src.voice.voice_listener import COMMAND_PROMPT
        self.assertNotIn("snap", COMMAND_PROMPT.lower())

    def test_hallucination_loops_are_dropped(self):
        from src.voice.voice_listener import looks_hallucinated
        self.assertTrue(looks_hallucinated("Snap, open YouTube. Snap, open YouTube. Snap, open YouTube."))
        self.assertFalse(looks_hallucinated("Snap, remind me at 5. Then open YouTube."))
