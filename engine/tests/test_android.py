"""The full shared brain running in Android mode (what the Flutter app calls through Chaquopy)."""
import json
import os
import tempfile
import time
import unittest

os.environ.setdefault("SNAP_AIR_DATA", tempfile.mkdtemp())

from src.platform import android as A  # noqa: E402


class AndroidCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        d = tempfile.mkdtemp()
        os.environ["SNAP_AIR_SETTINGS"] = os.path.join(d, "settings.json")
        A._core = None
        A.init(d)
        cls.c = A.core()
        cls.c.settings.update({"ai_provider": "cloud"})          # no local model / key in tests
        cls.c.set_apps(json.dumps([{"label": "WhatsApp", "package": "com.whatsapp"},
                                   {"label": "Instagram", "package": "com.instagram.android"},
                                   {"label": "Spotify", "package": "com.spotify.music"}]))
        cls.c.agent.play_youtube = lambda q, n=1: cls.c.os.open_url(f"https://www.youtube.com/results?search_query={q}&n={n}")

    def say(self, text, wait=4.0):
        json.loads(self.c.next_events(0.01))                    # drain
        self.c.send(text)
        events, end = [], time.time() + wait
        while time.time() < end:
            batch = json.loads(self.c.next_events(0.3))
            events += batch
            if any(e.get("type") == "chat_message" and e.get("role") == "assistant" and e.get("final", True) for e in batch):
                time.sleep(0.2)
                events += json.loads(self.c.next_events(0.05))
                break
        return events

    @staticmethod
    def ops(events):
        return [e for e in events if e.get("type") == "op"]

    @staticmethod
    def reply(events):
        msgs = [e["text"] for e in events if e.get("type") == "chat_message" and e.get("role") == "assistant"]
        return msgs[-1] if msgs else ""

    def test_apps_open_in_the_app_not_the_website(self):
        self.assertEqual(self.ops(self.say("open whatsapp"))[0]["kwargs"], {"package": "com.whatsapp"})
        self.assertEqual(self.ops(self.say("instagram kholo"))[0]["kwargs"], {"package": "com.instagram.android"})
        o = self.ops(self.say("switch to spotify"))[0]
        self.assertEqual((o["op"], o["args"]), ("launch_app", ["com.spotify.music"]))

    def test_media_navigation_and_nth_video(self):
        self.assertEqual(self.ops(self.say("awaaz badhao"))[0]["args"][0], "volumeup")
        self.assertEqual(self.ops(self.say("go back"))[0]["args"], ["alt", "left"])
        o = self.ops(self.say("play arijit singh songs, the 4th video"))[0]
        self.assertIn("n=4", o["args"][0])

    def test_reminders_become_android_alarms(self):
        ev = self.say("remind me to push the PR at 11:59 pm")
        self.assertIn("push the PR", self.reply(ev))
        rem = [e for e in ev if e.get("type") == "reminders"]
        self.assertTrue(rem and any(i["title"] == "push the PR" for i in rem[-1]["items"]))
        self.assertGreater(rem[-1]["items"][0]["at_ms"], 0)

    def test_memory_and_honest_limits(self):
        self.say("remember that my manager is Arun")
        self.assertIn("Arun", self.reply(self.say("what do you know about me?")))
        self.assertIn("can't take meeting notes", self.reply(self.say("take meeting notes")))

    def test_snapy_actions_and_keys(self):
        ui = [e for e in self.say("show some party emojis") if e.get("type") == "ui_action"]
        self.assertEqual(ui[0]["action"], "emoji")
        from src import secrets_store
        secrets_store.set_cipher(lambda b: b[::-1], lambda b: b[::-1])     # stand-in for Android Keystore
        try:
            json.loads(self.c.set_api_key("gemini", "test-key-123"))
            self.assertEqual(secrets_store.get_key("cloud_gemini"), "test-key-123")
            raw = open(os.path.join(os.environ["SNAP_AIR_DATA"], "secrets.json"), encoding="utf-8").read()
            self.assertNotIn("test-key-123", raw)
        finally:
            secrets_store.set_key("cloud_gemini", "")
            secrets_store._cipher = None

    def test_android_data_is_central(self):
        from src import appdata
        self.assertEqual(appdata.get("android.key_actions")["alt+left"], "back")
        pkgs = [a["package"] for a in appdata.get("android.social_apps")]
        for p in ("com.instagram.android", "com.google.android.youtube", "in.mohalla.video", "com.snapchat.android"):
            self.assertIn(p, pkgs)


if __name__ == "__main__":
    unittest.main()
