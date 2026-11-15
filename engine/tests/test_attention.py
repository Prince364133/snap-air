"""Windows attention: counting Shorts/Reels from browser titles, nudges, weekly card, file format."""
import datetime as dt
import json
import os
import shutil
import tempfile
import unittest

from tests import _env  # noqa: E402

setUpModule, tearDownModule = _env.module_data_dir()   # own data folder, restored after

from src.life import attention as A  # noqa: E402
from src.life.attention import AttentionTracker, NudgeEngine, clean_title, text  # noqa: E402
from src.life.realcount import RealCount  # noqa: E402


def at(day, hh, mm=0):
    return dt.datetime.combine(day, dt.time(hh, mm)).timestamp()


class Clock:
    def __init__(self, t):
        self.t = t

    def __call__(self):
        return self.t


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.settings = {}
        self.today = dt.date.today()
        self.clock = Clock(at(self.today, 14))
        self.urls = {}
        self.media = None
        self.tr = AttentionTracker(folder=self.dir, settings=self.settings, clock=self.clock,
                                   url_fn=lambda h: self.urls.get("now"), media_fn=lambda: self.media)
        self.ne = NudgeEngine(folder=self.dir, settings=self.settings)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def feed(self, items, step=1.0, exe="chrome", browser=" - Google Chrome", url=None):
        """items: [(page title, seconds on screen)]; polls every `step` s like the activity loop."""
        events = []
        for i, (title, secs) in enumerate(items):
            if url:
                self.urls["now"] = url(i)
            n = max(1, int(round(secs / step)))
            for _ in range(n):
                events += self.tr.observe(exe, title + browser, self.clock.t, 0.0, hwnd=1)
                self.clock.t += step
        return events

    def shorts(self, n, secs=6, start=0):
        return [(f"Clip {start + i} #shorts - YouTube", secs) for i in range(n)]

    def leave(self, secs=2):
        self.feed([("main.py - snap-air - Visual Studio Code", secs)], exe="code", browser="")


class CountingTests(Base):
    def test_title_cleaning(self):
        self.assertEqual(clean_title("(3) Cat video #shorts - YouTube - Google Chrome"), ["Cat video #shorts", "YouTube"])
        self.assertEqual(clean_title("Song - YouTube and 2 more pages - Personal - Microsoft​ Edge")[-2:],
                         ["YouTube", "Personal"])
        site, page, name = self.tr.match_site("msedge", "Song - YouTube and 2 more pages - Personal - Microsoft​ Edge")
        self.assertEqual(site["site"], "youtube")
        site, _, _ = self.tr.match_site("chrome", "Instagram tips for beginners - YouTube - Google Chrome")
        self.assertEqual(site["site"], "youtube")          # the site is the last segment, not a word in the title
        self.assertIsNone(self.tr.match_site("code", "YouTube - Visual Studio Code")[0])

    def test_shorts_flow_counts_each_item(self):
        self.feed(self.shorts(5))
        self.leave()
        snap = self.tr.snapshot()
        self.assertEqual(snap["today"], 5)
        self.assertEqual(snap["by"][0]["id"], "web.youtube.shorts")
        self.assertGreaterEqual(snap["reel_ms"], 25000)

    def test_quick_flicks_are_ignored(self):
        self.feed(self.shorts(6, secs=1, start=0), step=0.5)       # flicked past in a second each
        self.feed(self.shorts(2, secs=5, start=10))
        self.leave()
        self.assertEqual(self.tr.snapshot()["today"], 2)

    def test_home_page_and_other_sites_dont_count(self):
        self.feed([("YouTube", 30), ("Pull requests - GitHub", 30)])
        self.leave()
        snap = self.tr.snapshot()
        self.assertEqual((snap["today"], snap["videos"]), (0, 0))

    def test_feed_rhythm_without_url_or_hashtag(self):
        # titles look like normal videos, but they change every few seconds: a Shorts feed
        self.feed([(f"Funny moment {i} - YouTube", 7) for i in range(5)])
        self.leave()
        self.assertEqual(self.tr.snapshot()["today"], 5)
        self.assertEqual(self.tr.snapshot()["videos"], 0)

    def test_two_quick_pages_are_not_a_feed(self):
        self.feed([("lofi beats - YouTube", 6), ("cooking pasta - YouTube", 6)])
        self.leave()
        self.assertEqual(self.tr.snapshot()["today"], 0)

    def test_long_video_counts_start_and_minutes(self):
        self.feed([("How CPUs work - YouTube", 300)])
        self.leave()
        snap = self.tr.snapshot()
        self.assertEqual((snap["today"], snap["videos"]), (0, 1))
        self.assertGreaterEqual(snap["video_ms"], 295000)

    def test_long_video_needs_media_playing_when_known(self):
        self.media = False                                  # a page left open, nothing playing
        self.feed([("python tutorial - YouTube", 300)])
        self.assertEqual(self.tr.snapshot()["videos"], 0)

    def test_url_hints(self):
        self.feed([(f"Clip {i} - YouTube", 4) for i in range(3)], url=lambda i: f"youtube.com/shorts/id{i}")
        self.feed([("Big talk - YouTube", 20)], url=lambda i: "youtube.com/watch?v=abc")
        self.leave()
        snap = self.tr.snapshot()
        self.assertEqual((snap["today"], snap["videos"]), (3, 1))

    def test_instagram_reels_by_url_when_the_title_stays(self):
        self.feed([("Instagram", 5) for _ in range(4)], url=lambda i: f"instagram.com/reels/r{i}/")
        self.leave()
        self.assertEqual(self.tr.snapshot()["by"], [{"id": "web.instagram.reels", "label": "Instagram Reels", "count": 4}])

    def test_private_windows_are_ignored(self):
        self.feed(self.shorts(4), browser=" - InPrivate - Microsoft Edge")
        self.assertEqual(self.tr.snapshot()["today"], 0)

    def test_counting_off(self):
        self.settings["attention_enabled"] = False
        self.feed(self.shorts(4))
        self.assertEqual(self.tr.snapshot()["today"], 0)

    def test_amber_at_soft_limit(self):
        self.settings["attention_soft_limit"] = 3
        self.feed(self.shorts(3))
        self.assertEqual(self.tr.snapshot()["level"], "amber")

    def test_fast_poll_while_on_a_video_site(self):
        self.assertIsNone(self.tr.poll_interval)
        self.feed(self.shorts(1))
        self.assertEqual(self.tr.poll_interval, 1.0)
        self.leave()
        self.assertIsNone(self.tr.poll_interval)


class FileFormatTests(Base):
    def test_realcount_file_shape_and_answers(self):
        rc_file = os.path.join(self.dir, "realcount", f"{self.today.isoformat()}.json")
        os.makedirs(os.path.dirname(rc_file), exist_ok=True)
        with open(rc_file, "w", encoding="utf-8") as f:           # the phone's data must survive our writes
            json.dump({"apps": {"com.instagram.android": {"reels": 7, "reel_ms": 60000}}}, f)
        self.tr = AttentionTracker(folder=self.dir, settings=self.settings, clock=self.clock)
        self.feed(self.shorts(12))
        self.feed([("Big talk - YouTube", 120)])
        self.leave()
        self.tr.flush()
        with open(rc_file, encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data["apps"]["com.instagram.android"], {"reels": 7, "reel_ms": 60000})
        self.assertEqual(data["apps"]["web.youtube.shorts"]["reels"], 12)
        self.assertIsInstance(data["apps"]["web.youtube.shorts"]["reel_ms"], int)
        self.assertEqual(data["videos"]["web.youtube.videos"]["count"], 1)
        with open(os.path.join(self.dir, "attention", f"{self.today.isoformat()}.json"), encoding="utf-8") as f:
            raw = json.dumps(data) + f.read()
        self.assertNotIn("Clip", raw)                              # no titles stored, ever
        self.assertNotIn("Big talk", raw)
        # the shared answer module reads it
        plain = RealCount(folder=os.path.join(self.dir, "realcount"))
        self.assertIn("19", plain.answer("how many shorts did I watch today?"))
        ans = self.tr.answer("how many shorts did I watch today?")
        self.assertIn("12 on YouTube Shorts", ans)
        self.assertIn("19", ans)
        self.assertIn("1 videos", self.tr.answer("how many videos did I watch today?"))
        self.assertIsNone(self.tr.answer("open youtube"))

    def test_restart_resumes_todays_counts(self):
        self.feed(self.shorts(4))
        self.leave()
        self.tr.flush()
        again = AttentionTracker(folder=self.dir, settings=self.settings, clock=self.clock)
        again.observe("code", "x - Visual Studio Code", self.clock.t)
        self.assertEqual(again.snapshot()["today"], 4)


class NudgeTests(Base):
    def check(self, events=(), **kw):
        return self.ne.check(self.tr, self.clock.t, events=events, **kw)

    def test_session_nudge_and_global_cooldown(self):
        self.feed(self.shorts(30, secs=4))
        n = self.check()
        self.assertEqual(n["trigger"], "session_reels")
        self.assertIn("30 Shorts", n["text"])
        self.assertEqual([a["id"] for a in n["actions"]], ["reset", "dismiss"])
        self.assertEqual(n["reset"]["seconds"], 120)
        self.assertEqual(len(n["reset"]["steps"]), 3)
        self.feed(self.shorts(30, secs=4, start=100))
        self.assertIsNone(self.check())                             # max one nudge per 20 min
        self.feed(self.shorts(60, secs=20, start=200))              # 20 more minutes of the same feed
        n2 = self.check()
        self.assertEqual(n2["trigger"], "session_reels")

    def test_quiet_during_calls_and_meetings(self):
        self.feed(self.shorts(30, secs=4))
        self.assertIsNone(self.check(in_call="Teams"))
        self.assertIsNone(self.check(meeting=True))
        self.assertIsNotNone(self.check())

    def test_softer_copy_after_two_dismissals(self):
        self.feed(self.shorts(30, secs=4))
        n = self.check()
        self.assertFalse(n["soft"])
        self.ne.action(n["id"], "dismiss", t=self.clock.t)
        self.ne.action("other", "dismiss", t=self.clock.t)
        self.clock.t += 21 * 60
        self.feed(self.shorts(30, secs=4, start=100))
        self.tr.session_count = 60
        n = self.check()
        self.assertTrue(n["soft"])
        self.assertEqual(n["text"], text("nudge.win.session_reels.soft.1", reels=60, kind="Shorts"))

    def test_focus_guard(self):
        focus = {"active": True, "remaining": 1500}
        ev = self.feed([("Home - YouTube", 2)])
        self.assertTrue(any(e["type"] == "entered" and e["site"] == "YouTube" for e in ev))
        n = self.check(events=ev, focus=focus)
        self.assertEqual(n["trigger"], "focus_guard")
        self.assertIn("in focus until", n["text"])
        self.assertEqual([a["id"] for a in n["actions"]], ["back_to_focus", "open_anyway"])
        # during focus nothing else nudges
        self.clock.t += 21 * 60
        self.feed(self.shorts(40, secs=4))
        self.assertIsNone(self.check(focus=focus))

    def test_bedtime_once_per_night(self):
        self.clock.t = at(self.today, 23, 30) - 3600
        self.feed(self.shorts(2))
        self.clock.t = at(self.today, 23, 30)
        n = self.check()
        self.assertEqual(n["trigger"], "bedtime")
        self.clock.t += 40 * 60
        self.assertIsNone(self.check())
        self.settings["attention_bedtime"] = "off"
        self.ne.st["fired"].clear()
        self.assertIsNone(self.check())

    def test_bedtime_quiet_when_away(self):
        self.clock.t = at(self.today, 23, 30)
        self.assertIsNone(self.check(active=False))

    def test_switches_offer_focus(self):
        for i in range(12):
            self.feed([(f"Video {i} - YouTube", 2)])
            self.leave(5)
        n = self.check()
        self.assertEqual(n["trigger"], "switches")
        self.assertIn("12 switches to YouTube", n["text"])
        self.assertIn("focus", [a["id"] for a in n["actions"]])
        self.assertEqual(self.ne.action(n["id"], "focus", t=self.clock.t)["focus"], 25)

    def test_daily_soft_limit(self):
        self.settings["attention_limits"] = {"youtube": 10}
        self.feed([("lecture - YouTube", 9 * 60)], step=3)
        n = self.check()
        self.assertEqual(n["trigger"], "limit_near")
        self.clock.t += 21 * 60
        self.feed([("lecture - YouTube", 2 * 60)], step=3)
        n = self.check()
        self.assertEqual(n["trigger"], "limit_over")
        self.assertIn("10 minutes on YouTube", n["text"])

    def test_nudges_off(self):
        self.settings["attention_nudges"] = False
        self.feed(self.shorts(30, secs=4))
        self.assertIsNone(self.check())

    def test_cooldown_survives_restart(self):
        self.feed(self.shorts(30, secs=4))
        self.assertIsNotNone(self.check())
        self.ne = NudgeEngine(folder=self.dir, settings=self.settings)
        self.tr.session_count = 60
        self.assertIsNone(self.check())

    def test_no_shame_words_in_copy(self):
        keys = set(A.DEFAULT_TEXT) | {k for k in A._i18n_table("en") if k.startswith(("nudge.", "reset.", "attention."))}
        for k in keys:
            self.assertIsNone(NudgeEngine.BANNED.search(text(k)), k)


class WeeklyTests(Base):
    def write_day(self, day, reels):
        p = os.path.join(self.dir, "realcount", f"{day.isoformat()}.json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump({"apps": {"web.youtube.shorts": {"reels": reels, "reel_ms": reels * 20000}}}, f)

    def test_sunday_card_once_per_week(self):
        sunday = dt.date(2026, 11, 15)
        self.write_day(sunday - dt.timedelta(days=1), 40)
        self.clock.t = at(sunday, 9)
        self.assertIsNone(self.ne.weekly(self.tr))                  # before the report time
        self.ne._weekly_checked = 0
        self.clock.t = at(sunday, 11)
        b = self.ne.weekly(self.tr)
        self.assertEqual(b["kind"], "weekly")
        self.assertIn("40 shorts and reels", b["text"])
        self.assertNotIn("screen time", b["text"])                  # no fake "0 min" from this PC
        self.ne._weekly_checked = 0
        self.clock.t = at(sunday, 15)
        self.assertIsNone(self.ne.weekly(self.tr))                  # once a week
        self.ne = NudgeEngine(folder=self.dir, settings=self.settings)
        self.assertIsNone(self.ne.weekly(self.tr))                  # also after a restart
        self.write_day(sunday + dt.timedelta(days=6), 5)
        self.clock.t = at(sunday + dt.timedelta(days=7), 11)
        self.ne._weekly_checked = 0
        self.assertIsNotNone(self.ne.weekly(self.tr))

    def test_not_on_other_days_or_when_off(self):
        self.write_day(dt.date(2026, 11, 16), 10)
        self.clock.t = at(dt.date(2026, 11, 16), 11)                # Monday
        self.assertIsNone(self.ne.weekly(self.tr))
        self.settings["attention_weekly_report"] = False
        self.clock.t = at(dt.date(2026, 11, 22), 11)
        self.ne._weekly_checked = 0
        self.assertIsNone(self.ne.weekly(self.tr))


class ActivityHookTests(unittest.TestCase):
    def test_activity_tracker_exposes_observers(self):
        from src.life.activity import ActivityTracker
        a = ActivityTracker(folder=tempfile.mkdtemp())
        self.assertEqual(a.observers, [])
        self.assertIsNone(a.interval_fn)


if __name__ == "__main__":
    unittest.main()
