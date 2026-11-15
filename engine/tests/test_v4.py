"""Screen understanding (element finding), native Indian voices, custom agent name."""
import os
import tempfile
import unittest

os.environ.setdefault("SNAP_AIR_DATA", tempfile.mkdtemp())

from src.os_control import screen  # noqa: E402
from src.ai.agent_controller import AgentController  # noqa: E402
from tests.test_agent import FakeApps, FakeOS  # noqa: E402


def el(name, ctype, rect, depth=5):
    return screen.Element(name, ctype, rect, None, depth)


# A YouTube-like page: caption buttons, nav links, search box, a 3x2 video grid
PAGE = [
    el("Minimize", "ButtonControl", (1400, 0, 1440, 30), 2), el("Close", "ButtonControl", (1480, 0, 1520, 30), 2),
    el("Home", "HyperlinkControl", (4, 181, 68, 257)), el("Shorts", "HyperlinkControl", (4, 257, 68, 333)),
    el("Search", "ComboBoxControl", (600, 120, 1000, 160)), el("Subscribe", "ButtonControl", (1200, 300, 1300, 330)),
    el("Learn Python in one hour full beginner course", "HyperlinkControl", (140, 400, 570, 640)),
    el("Lofi hip hop radio beats to relax and study to", "HyperlinkControl", (630, 400, 1060, 640)),
    el("How transformers work explained visually", "HyperlinkControl", (1120, 400, 1550, 640)),
    el("Cooking the perfect biryani at home", "HyperlinkControl", (140, 700, 570, 940)),
    el("Top 10 VS Code extensions every developer needs", "HyperlinkControl", (630, 700, 1060, 940)),
    el("Relaxing piano music for deep focus", "HyperlinkControl", (1120, 700, 1550, 940)),
]


class ScreenFindTests(unittest.TestCase):
    def name(self, q):
        e, _ = screen.find(q, PAGE)
        return e and e.name

    def test_positions(self):
        self.assertTrue(self.name("the second video").startswith("Lofi"))
        self.assertTrue(self.name("click the video on the top left").startswith("Learn Python"))
        self.assertTrue(self.name("video on the bottom right").startswith("Relaxing piano"))
        self.assertTrue(self.name("the last video").startswith("Relaxing piano"))
        self.assertTrue(self.name("doosra video").startswith("Lofi"))       # Hinglish ordinal

    def test_names_and_types(self):
        self.assertTrue(self.name("the transformers video").startswith("How transformers"))
        self.assertEqual(self.name("search box"), "Search")
        self.assertEqual(self.name("subscribe button"), "Subscribe")
        self.assertEqual(self.name("shorts"), "Shorts")

    def test_never_clicks_window_controls_by_accident(self):
        only_chrome = [e for e in PAGE if e.name in ("Minimize", "Close")]
        e, why = screen.find("the second video", only_chrome)
        self.assertIsNone(e)
        e, _ = screen.find("the first button", PAGE)
        self.assertEqual(e.name, "Subscribe")
        self.assertEqual(self.name("minimize"), "Minimize")                 # only when named

    def test_unknown_target(self):
        e, why = screen.find("the purple dinosaur button", PAGE)
        self.assertIsNone(e)
        self.assertIn("couldn't find", why)

    def test_describe(self):
        d = screen.describe(PAGE)
        self.assertIn("hyperlink", d["summary"])
        self.assertNotIn("Minimize", [i["name"] for i in d["items"]])      # window buttons are noise
        self.assertEqual(d["items"][0]["name"], "Search")


class NativeVoiceTests(unittest.TestCase):
    def test_script_language_routing(self):
        from src.voice.tts import Speaker
        sp = Speaker.__new__(Speaker)
        sp.settings = {}
        self.assertEqual(sp._script_lang("आज मीटिंग है", "hi"), "hi")
        self.assertEqual(sp._script_lang("Aaj meeting hai", "hinglish"), "en")      # Latin -> English voice
        self.assertEqual(sp._script_lang("नमस्कार", "mr"), "mr")
        self.assertEqual(sp._script_lang("నమస్కారం", "en"), "te")

    def test_piper_hindi_synthesis_if_downloaded(self):
        path = os.path.join(os.environ.get("APPDATA", ""), "SnapAir", "models", "piper", "hi_IN-rohan-medium.onnx")
        if not os.path.exists(path):
            self.skipTest("Hindi voice not downloaded")
        from src.voice.piper_voice import PiperVoice
        audio, sr = PiperVoice(path).synthesize("नमस्ते, आप कैसे हैं?")
        self.assertGreater(len(audio) / sr, 0.6)
        self.assertLessEqual(float(abs(audio).max()), 1.0)


class AgentNameTests(unittest.TestCase):
    def agent(self, name):
        return AgentController(settings={"agent_name": name}, os_actions=FakeOS(), app_index=FakeApps())

    def test_custom_name_and_fuzzy_spelling(self):
        a = self.agent("Meera")
        self.assertEqual(a.strip_wake_word("Meera, next tab."), (True, "next tab"))
        self.assertEqual(a.strip_wake_word("Hey Mira, open spotify"), (True, "open spotify"))
        self.assertFalse(a.strip_wake_word("meet her later")[0])
        self.assertFalse(a.strip_wake_word("mirror is broken")[0])
        self.assertEqual(a.strip_wake_original("Hey Mira, Take note Buy Milk"), "Take note Buy Milk")

    def test_default_and_builtin_still_work(self):
        a = self.agent("Jarvis")
        self.assertTrue(a.strip_wake_word("Jarvis open youtube")[0])
        self.assertTrue(a.strip_wake_word("Snappy, next tab")[0])          # Snapy always answers too


if __name__ == "__main__":
    unittest.main()


class VoiceLicenceTests(unittest.TestCase):
    def speaker(self, settings):
        from src.voice.tts import Speaker
        sp = Speaker.__new__(Speaker)
        sp.settings, sp._piper, sp._downloading = settings, {}, {"te_IN-padmavathi-medium", "hi_IN-rohan-medium",
                                                                 "hi_IN-priyamvada-medium"}
        sp._windows_voice = lambda lang: None            # no Windows Hindi voice on the test machine
        return sp

    def test_non_commercial_voices_need_opt_in(self):
        from src.voice.piper_voice import CATALOG
        self.assertTrue(all(not e[3] for e in CATALOG["hi"]))          # every Hindi Piper voice is NC
        sp = self.speaker({"indic_voices": {"hi": "hi_IN-rohan-medium"}})
        self.assertIsNone(sp._native_voice("hi"))                       # not used without opt-in

    def test_commercial_voice_preferred(self):
        from src.voice.piper_voice import CATALOG
        te = [e for e in CATALOG["te"] if e[3]]
        self.assertEqual(te[0][0], "te_IN-padmavathi-medium")
        sp = self.speaker({"indic_voices": {"te": "te_IN-maya-medium"}})   # NC choice is ignored
        sp._native_voice("te")
        self.assertNotIn("te_IN-maya-medium", sp._downloading)


class VisionParseTests(unittest.TestCase):
    def test_point_parsing(self):
        from src.os_control.vision import _parse_point
        self.assertEqual(_parse_point('{"found": true, "x": 500, "y": 250, "label": "Play"}'), (0.5, 0.25, "Play"))
        self.assertEqual(_parse_point('sure: {"found": true, "x": 0.5, "y": 0.25}')[:2], (0.5, 0.25))
        self.assertIsNone(_parse_point('{"found": false}'))
        self.assertIsNone(_parse_point('{"x": 4000, "y": 10}'))
        self.assertIsNone(_parse_point("no json"))


class ScreenTaskTests(unittest.TestCase):
    def setUp(self):
        from unittest import mock
        self._p = mock.patch("time.sleep", lambda s: None)
        self._p.start()

    def tearDown(self):
        self._p.stop()

    def assistant(self, plan=None):
        from src.brain.assistant import Assistant
        a = Assistant.__new__(Assistant)
        a.settings, a.vision = {}, None
        a.agent = AgentController(settings={}, os_actions=FakeOS(), app_index=FakeApps())
        a.replies, a.clicked, a.typed = [], [], []
        a.reply = lambda text, *x, **k: a.replies.append((text, k.get("error", False))) or text
        a.emit = lambda m: None
        a._s = lambda k, d=None: d

        class FakeScreen:
            Element = screen.Element
            find = staticmethod(screen.find)

            @staticmethod
            def snapshot(*x, **k):
                class Root:
                    Name = "Videos"
                return list(PAGE), Root()

            @staticmethod
            def click(el, **k):
                a.clicked.append(el.name)

            @staticmethod
            def type_into(el, text, submit=False):
                a.typed.append((el.name, text))
        a.screen = FakeScreen

        class FakeLLM:
            calls = 0

            def ready(self):
                return True

            def chat_json(self, msgs, schema, **k):
                FakeLLM.calls += 1
                return (plan or [{"action": "done"}]).pop(0) if plan else {"action": "done"}
        a.llm = FakeLLM()
        return a

    def test_chain_runs_without_model(self):
        a = self.assistant()
        a.screen_task("type lofi in the search box and then click the second video")
        self.assertEqual(a.typed, [("Search", "lofi")])
        self.assertTrue(a.clicked[0].startswith("Lofi"))
        self.assertEqual(a.replies[-1][0], "Done.")
        self.assertEqual(a.llm.calls, 0)

    def test_find_and_open_it(self):
        a = self.assistant()
        a.screen_task("find the biryani video and open it")
        self.assertTrue(a.clicked[0].startswith("Cooking"))

    def test_failed_step_is_not_reported_done(self):
        a = self.assistant()
        a.screen_task("click the purple dinosaur button")
        self.assertTrue(a.replies[-1][1])                      # error, not "Done."

    def test_model_loop_stops_before_risky_click(self):
        PAGE.append(el("Delete account", "ButtonControl", (0, 5, 60, 30)))       # first in reading order
        try:
            a = self.assistant(plan=[{"action": "click", "id": 0}])
            a.screen_task("make the page tidy please")
            # whatever the model picked first, a destructive button is never clicked without being named
            self.assertNotIn("Delete account", a.clicked)
            self.assertIn("confirm", a.replies[-1][0])
        finally:
            PAGE.pop()
