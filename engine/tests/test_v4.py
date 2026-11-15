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
        self.assertEqual(d["items"][0]["type"], "button")


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
