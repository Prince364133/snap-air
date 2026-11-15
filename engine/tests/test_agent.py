import json
import os
import tempfile
import unittest

from src.ai.agent_controller import AgentController
from src.config import Settings


class FakeOS:
    def __init__(self):
        self.calls = []
        self.windows = {"chrome": (101, "GitHub - Google Chrome")}

    def __getattr__(self, name):
        def rec(*a, **k):
            self.calls.append((name,) + a)
        return rec

    def find_window(self, name):
        self.calls.append(("find_window", name))
        for key, v in self.windows.items():
            if key in name:
                return v
        return None

    def clipboard(self):
        return "copied text from clipboard"


class FakeApps:
    apps = {"spotify": ("appid", "SpotifyAB.Spotify"), "visual studio code": ("lnk", "code.lnk"),
            "google chrome": ("lnk", "chrome.lnk")}

    def find(self, name):
        name = {"vs code": "visual studio code", "chrome": "google chrome"}.get(name, name)
        return (name, self.apps[name]) if name in self.apps else None

    def launch(self, target):
        pass


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.settings = Settings(os.path.join(self.tmp, "s.json"))
        self.os = FakeOS()
        self.notes, self.ui, self.paused = [], [], []
        self.a = AgentController(settings=self.settings, os_actions=self.os, app_index=FakeApps())
        self.a.play_youtube = lambda q: self.os.calls.append(("youtube", q))
        self.a.set_callbacks(notes_callback=self.notes.append,
                             ui_callback=lambda act, **k: self.ui.append(act),
                             gesture_callback=self.paused.append)

    def run_(self, text, **kw):
        self.os.calls.clear()
        return self.a.execute_intent(text, **kw)

    def first(self, name):
        return next((c for c in self.os.calls if c[0] == name), None)

    # --- whisper output style: capitals + punctuation
    def test_whisper_punctuation_is_handled(self):
        r = self.run_("Snap. Pause.")
        self.assertTrue(r.ok)
        self.assertEqual(self.first("media"), ("media", "playpause"))

    def test_wake_word_required_in_always_on_mode(self):
        self.assertEqual(self.run_("so I was telling him to scroll down", require_wake=True).action, "ignored")
        self.assertEqual(self.os.calls, [])
        self.assertTrue(self.run_("Hey Snap, scroll down.", require_wake=True).ok)

    def test_wake_word_variants(self):
        for t in ("Snap, next tab", "Hey snap next tab", "Okay Snap. Next tab.", "Snap air, next tab",
                  "Um, snap, next tab"):
            self.assertEqual(self.run_(t, require_wake=True).action, "tab", t)

    def test_snap_inside_sentence_is_not_a_wake_word(self):
        self.assertEqual(self.run_("let me take a snap shot of this", require_wake=True).action, "ignored")
        self.assertEqual(self.run_("open snapchat", require_wake=True).action, "ignored")

    def test_bare_wake_word_arms_listening(self):
        self.assertEqual(self.run_("Hey Snap.").action, "wake")

    def test_unknown_does_nothing(self):
        r = self.run_("Snap, what's the meaning of life")
        self.assertFalse(r.ok)
        self.assertEqual(r.action, "unknown")
        self.assertIsNone(self.first("open_url"))

    def test_hallucinations_ignored(self):
        for t in ("Thank you.", "you", ""):
            self.assertEqual(self.run_(t).action, "ignored")

    # --- scrolling
    def test_scroll_amounts(self):
        self.run_("scroll down")
        self.assertEqual(self.first("wheel"), ("wheel", -600))
        self.run_("Snap, scroll up three times.")
        self.assertEqual(self.first("wheel"), ("wheel", 1800))
        self.run_("scroll down a bit")
        self.assertEqual(self.first("wheel"), ("wheel", -240))
        self.run_("down")
        self.assertEqual(self.first("wheel"), ("wheel", -600))

    def test_page_down_presses_key(self):
        self.run_("page down")
        self.assertEqual(self.first("press"), ("press", "pagedown"))

    def test_top_bottom(self):
        self.run_("go to top")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "home"))
        self.run_("scroll to the bottom")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "end"))

    def test_repeat_last(self):
        self.run_("scroll down")
        self.run_("again")
        self.assertEqual(self.first("wheel"), ("wheel", -600))

    def test_autoscroll_start_stop(self):
        r = self.run_("keep scrolling")
        self.assertEqual(r.action, "autoscroll")
        self.assertEqual(self.a.autoscroll_dir, -1)
        self.run_("stop")
        self.assertEqual(self.a.autoscroll_dir, 0)

    # --- switching
    def test_switch_app_and_tabs(self):
        self.run_("switch app")
        self.assertEqual(self.first("hotkey"), ("hotkey", "alt", "tab"))
        self.run_("next tab")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "tab"))
        self.run_("tab switch")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "tab"))
        self.run_("previous tab")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "shift", "tab"))
        self.run_("switch to tab three")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "3"))

    def test_switch_to_named_window(self):
        r = self.run_("Snap, switch to Chrome.")
        self.assertEqual(r.action, "focus")
        self.assertEqual(self.first("focus_window"), ("focus_window", 101))

    def test_switch_to_closed_app_launches_it(self):
        r = self.run_("switch to spotify")
        self.assertEqual(r.action, "launch")

    # --- apps / web
    def test_open_app_and_website(self):
        self.assertEqual(self.run_("open spotify").action, "launch")
        self.run_("open youtube")
        self.assertEqual(self.first("open_url"), ("open_url", "https://www.youtube.com"))
        self.run_("open github.com")
        self.assertEqual(self.first("open_url"), ("open_url", "https://github.com"))
        r = self.run_("open flurbo")
        self.assertFalse(r.ok)

    def test_open_already_running_app_focuses_it(self):
        self.assertEqual(self.run_("open chrome").action, "focus")

    def test_youtube(self):
        self.run_("Snap, open YouTube and play lo-fi hip hop.")
        self.assertEqual(self.first("youtube"), ("youtube", "lo fi hip hop"))
        self.run_("play coding music on youtube")
        self.assertEqual(self.first("youtube"), ("youtube", "coding music"))
        self.run_("play interstellar soundtrack")
        self.assertEqual(self.first("youtube"), ("youtube", "interstellar soundtrack"))
        self.run_("play")
        self.assertEqual(self.first("media"), ("media", "playpause"))

    def test_search_keeps_original_case(self):
        self.run_("Snap, search for Python asyncio tutorial.")
        self.assertIn("Python%20asyncio%20tutorial", self.first("open_url")[1])

    # --- keyboard/editing
    def test_press_and_type(self):
        self.run_("press control shift t")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "shift", "t"))
        self.run_("press enter")
        self.assertEqual(self.first("press"), ("press", "enter", 1))
        self.run_("Snap, type Hello World.")
        self.assertEqual(self.first("type_text"), ("type_text", "Hello World"))
        self.run_("copy")
        self.assertEqual(self.first("hotkey"), ("hotkey", "ctrl", "c"))

    def test_volume(self):
        self.run_("volume up")
        self.assertEqual(self.first("media"), ("media", "volumeup", 5))
        self.run_("turn the volume down by 20")
        self.assertEqual(self.first("media"), ("media", "volumedown", 10))
        self.run_("mute")
        self.assertEqual(self.first("media"), ("media", "volumemute"))

    def test_mouse_by_voice(self):
        self.run_("click")
        self.assertEqual(self.first("click"), ("click",))
        self.run_("right click")
        self.assertEqual(self.first("click"), ("click", "right"))
        self.run_("double click")
        self.assertEqual(self.first("click"), ("click",))

    # --- snap air
    def test_settings_and_notes(self):
        self.run_("Snap, open Snap Air settings.")
        self.run_("open settings")
        self.assertEqual(self.ui, ["open_settings", "open_settings"])
        self.run_("Snap, take note: Remember to review the PR.")
        self.assertEqual(self.notes[-1], "Remember to review the PR")
        self.run_("write a note call mom")
        self.assertEqual(self.notes[-1], "call mom")
        self.run_("note clipboard")
        self.assertEqual(self.notes[-1], "copied text from clipboard")

    def test_windows_settings_is_not_snap_settings(self):
        self.ui.clear()
        self.run_("open windows settings")
        self.assertEqual(self.ui, [])

    def test_pause_gestures(self):
        self.run_("pause gestures")
        self.run_("resume gestures")
        self.assertEqual(self.paused, [True, False])

    # --- developer
    def test_project_commands_need_folder(self):
        r = self.run_("run project")
        self.assertFalse(r.ok)
        self.assertIn("open_settings", self.ui)

    def test_run_project_detects_command(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "package.json"), "w") as f:
            json.dump({"scripts": {"dev": "vite", "start": "node ."}}, f)
        self.settings.update({"project_dir": d})
        r = self.run_("run the project")
        self.assertTrue(r.ok)
        self.assertEqual(self.first("run_terminal"), ("run_terminal", "npm run dev", d))
        self.run_("git status")
        self.assertEqual(self.first("run_terminal"), ("run_terminal", "git status", d))

    def test_compound(self):
        r = self.run_("go back and then scroll down")
        self.assertEqual(r.action, "compound")
        names = [c[0] for c in self.os.calls]
        self.assertIn("hotkey", names)
        self.assertIn("wheel", names)


if __name__ == "__main__":
    unittest.main()
