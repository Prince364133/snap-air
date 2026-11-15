import datetime as dt
import os
import tempfile
import time
import unittest

TMP = tempfile.mkdtemp()
os.environ["SNAP_AIR_DATA"] = TMP

from src.life.tasks import TaskStore, parse_when, clean_title, human_time  # noqa: E402
from src.life.notes import NoteStore  # noqa: E402
from src.life.activity import ActivityTracker, extract_project, extract_site  # noqa: E402

NOW = dt.datetime(2026, 11, 16, 9, 30)   # Monday 09:30


class TimeParsingTests(unittest.TestCase):
    def check(self, text, expected, title=None):
        when, rest = parse_when(text, NOW)
        self.assertEqual(when, expected, text)
        if title is not None:
            self.assertEqual(clean_title(rest), title, text)

    def test_relative(self):
        self.check("remind me to stretch in 10 minutes", NOW + dt.timedelta(minutes=10), "stretch")
        self.check("remind me in an hour to call mom", NOW + dt.timedelta(hours=1), "call mom")
        self.check("drink water in half an hour", NOW + dt.timedelta(minutes=30), "drink water")
        self.check("10 minute baad padhai ka reminder lagao", NOW + dt.timedelta(minutes=10), "padhai")

    def test_clock(self):
        self.check("remind me to push the PR at 5", NOW.replace(hour=17, minute=0), "push the PR")
        self.check("call Arun at 5:30 pm", NOW.replace(hour=17, minute=30), "call Arun")
        self.check("standup at 10 am", NOW.replace(hour=10, minute=0), "standup")
        self.check("submit report at 9", NOW.replace(hour=21, minute=0))     # 9 am already passed -> 9 pm
        self.check("lunch at noon", NOW.replace(hour=12, minute=0))

    def test_days(self):
        self.check("remind me tomorrow at 9am to send the invoice",
                   dt.datetime(2026, 11, 17, 9, 0), "send the invoice")
        self.check("pay rent on friday", dt.datetime(2026, 11, 20, 9, 0), "pay rent")
        self.check("call dad tonight", NOW.replace(hour=20, minute=0), "call dad")
        self.check("kal 10 baje meeting", dt.datetime(2026, 11, 17, 9, 0))   # no clock parsed -> default 9

    def test_no_time(self):
        self.check("add a task to update the README", None, "update the README")

    def test_human_time(self):
        self.assertEqual(human_time(NOW.replace(hour=17, minute=0), NOW), "today at 5:00 PM")
        self.assertEqual(human_time(dt.datetime(2026, 11, 17, 9, 0), NOW), "tomorrow at 9:00 AM")


class TaskStoreTests(unittest.TestCase):
    def setUp(self):
        self.store = TaskStore(os.path.join(tempfile.mkdtemp(), "tasks.json"))

    def test_reminder_fires_once_and_snooze(self):
        t = self.store.add_from_text("remind me to push the PR in 5 minutes", now=NOW)
        self.assertEqual(t["title"], "push the PR")
        self.assertEqual(self.store.due_reminders(NOW), [])
        due = self.store.due_reminders(NOW + dt.timedelta(minutes=6))
        self.assertEqual([d["id"] for d in due], [t["id"]])
        self.assertEqual(self.store.due_reminders(NOW + dt.timedelta(minutes=7)), [])
        self.store.snooze(t["id"], 10, now=NOW + dt.timedelta(minutes=7))
        self.assertEqual(len(self.store.due_reminders(NOW + dt.timedelta(minutes=18))), 1)

    def test_find_complete_persist(self):
        self.store.add("Push the PR")
        self.store.add("Email Arun the deck")
        t = self.store.find("the deck for arun")
        self.assertEqual(t["title"], "Email Arun the deck")
        self.store.complete(t["id"])
        again = TaskStore(self.store.file)
        self.assertEqual([x["title"] for x in again.open_tasks()], ["Push the PR"])
        self.assertEqual(len(again.done_on(storage_today())), 1)


def storage_today():
    return dt.datetime.now().strftime("%Y-%m-%d")


class NotesTests(unittest.TestCase):
    def test_add_search_today(self):
        n = NoteStore(os.path.join(tempfile.mkdtemp(), "notes.json"))
        n.add("Buy milk")
        n.add("Standup summary", kind="meeting", title="Standup", summary=["API ready"])
        self.assertEqual(len(n.on_day(storage_today())), 2)
        self.assertEqual(n.search("standup")[0]["title"], "Standup")


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.sessions = []
        self.breaks = []
        self.settings = {"break_reminder_minutes": 50}
        self.tr = ActivityTracker(settings=self.settings, folder=self.folder, interval=2,
                                  on_session_start=lambda now, gap: self.sessions.append(now),
                                  on_break_due=self.breaks.append)

    def feed(self, exe, title, seconds, start, idle=0):
        t = start
        while t < start + seconds:
            self.tr.sample(exe, title, idle, t)
            t += 2
        return t

    def test_project_and_site_extraction(self):
        self.assertEqual(extract_project("antigravity ide", "snap-air - Antigravity IDE - Diff: main.py"), "snap-air")
        self.assertEqual(extract_project("code", "main.py - billing-api - Visual Studio Code"), "billing-api")
        self.assertIsNone(extract_project("chrome", "snap-air - Google Chrome"))
        self.assertEqual(extract_site("chrome", "lofi hip hop radio - YouTube - Google Chrome"), "YouTube")
        self.assertEqual(extract_site("msedge", "Pull requests · org/repo · GitHub - Work - Microsoft Edge"), "GitHub")

    def test_aggregation_idle_private_and_exclusions(self):
        t0 = dt.datetime(2026, 11, 16, 9, 5).timestamp()
        t = self.feed("antigravity ide", "snap-air - Antigravity IDE", 600, t0)
        t = self.feed("chrome", "lofi - YouTube - Google Chrome", 120, t)
        t = self.feed("chrome", "secret - Google Chrome (Incognito)", 120, t)   # private: not stored
        t = self.feed("1password", "Vault", 60, t)                              # excluded
        t = self.feed("chrome", "Docs - Google Chrome", 300, t, idle=200)       # away: not counted
        s = self.tr.summary("2026-11-16")
        apps = {a["exe"]: a["seconds"] for a in s["top_apps"]}
        self.assertAlmostEqual(apps["antigravity ide"], 600, delta=4)
        self.assertAlmostEqual(apps["chrome"], 120, delta=6)
        self.assertNotIn("1password", apps)
        self.assertEqual(s["projects"][0]["name"], "snap-air")
        self.assertEqual(s["sites"][0]["name"], "YouTube")
        self.assertAlmostEqual(self.tr.time_on("youtube", "2026-11-16")[0], 120, delta=6)
        self.assertEqual(len(self.sessions), 1)
        self.tr.flush()
        self.assertTrue(os.path.exists(os.path.join(self.folder, "2026-11-16.json")))

    def test_new_session_after_long_break(self):
        t0 = dt.datetime(2026, 11, 16, 9, 0).timestamp()
        t = self.feed("code", "x - Visual Studio Code", 60, t0)
        self.feed("code", "x - Visual Studio Code", 60, t + 5 * 3600)
        self.assertEqual(len(self.sessions), 2)

    def test_break_nudge_after_continuous_work(self):
        t0 = dt.datetime(2026, 11, 16, 9, 0).timestamp()
        self.feed("code", "x - Visual Studio Code", 51 * 60, t0)
        self.assertEqual(len(self.breaks), 1)

    def test_routine_learning(self):
        for day in range(9, 14):   # Mon 9 .. Fri 13 Nov
            t0 = dt.datetime(2026, 11, day, 9, 10 + day % 3).timestamp()
            t = self.feed("antigravity ide", "snap-air - Antigravity IDE", 300, t0)
            t = self.feed("chrome", "Gmail - Google Chrome", 200, t)
            self.tr.flush()
            self.tr.day, self.tr.data, self.tr.last_t = None, None, None
        r = self.tr.routine(today=dt.date(2026, 11, 16))
        self.assertEqual(r["days_observed"], 5)
        self.assertTrue(r["typical_start"].startswith("09:1"))
        self.assertEqual([a["exe"] for a in r["usual_first_apps"]][:2], ["antigravity ide", "chrome"])
        self.assertEqual(r["last_project"], "snap-air")


if __name__ == "__main__":
    unittest.main()
