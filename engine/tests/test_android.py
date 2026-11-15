"""The full shared brain running in Android mode (what the Flutter app calls through Chaquopy)."""
import json
import os
import tempfile
import time
import unittest


from src.platform import android as A  # noqa: E402


class AndroidCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # android.init() points SNAP_AIR_DATA at the phone's folder for the whole process:
        # save and restore both variables so later modules keep their own folders
        cls._env = {k: os.environ.get(k) for k in ("SNAP_AIR_DATA", "SNAP_AIR_SETTINGS")}
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

    @classmethod
    def tearDownClass(cls):
        A._core = None
        for k, v in cls._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

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
        pass                                                     # meeting notes now work on Android (see below)

    def test_snapy_actions_and_keys(self):
        ui = [e for e in self.say("show some party emojis") if e.get("type") == "ui_action"]
        self.assertEqual(ui[0]["action"], "emoji")
        from src import secrets_store
        secrets_store.set_cipher(lambda b: b[::-1], lambda b: b[::-1])     # stand-in for Android Keystore
        try:
            json.loads(self.c.set_api_key("gemini", "test-key-123"))
            self.assertEqual(secrets_store.get_key("cloud_gemini"), "test-key-123")
            with open(os.path.join(os.environ["SNAP_AIR_DATA"], "secrets.json"), encoding="utf-8") as f:
                raw = f.read()
            self.assertNotIn("test-key-123", raw)
        finally:
            secrets_store.set_key("cloud_gemini", "")
            secrets_store._cipher = None

    def test_voice_pause_logic_and_wake_phrases(self):
        self.assertTrue(self.c.sounds_unfinished("open youtube and"))
        self.assertFalse(self.c.sounds_unfinished("open youtube"))
        cfg = json.loads(self.c.voice_config())
        self.assertEqual(cfg["locale"], "en-IN")
        self.assertIn("hey snappy", cfg["wake_phrases"])
        self.c.settings.update({"agent_name": "Meera", "voice_language": "hi"})
        try:
            cfg = json.loads(self.c.voice_config())
            self.assertEqual(cfg["wake_phrases"][:2], ["meera", "hey meera"])      # renamed assistant
            self.assertEqual(cfg["locale"], "hi-IN")
        finally:
            self.c.settings.update({"agent_name": "Snapy", "voice_language": "auto"})

    def phone(self, text, wait=1.0):
        json.loads(self.c.next_events(0.01))
        self.c.send(text)
        time.sleep(0.05)
        return json.loads(self.c.next_events(wait))

    def test_whatsapp_needs_a_yes_and_uses_contacts(self):
        class Contacts:
            def find(self, name):
                book = {"rahul": [{"name": "Rahul Sharma", "number": "+919800000001"}]}
                return json.dumps(book.get(name.lower(), []))
        self.c.contacts = Contacts()
        ev = self.phone("WhatsApp Rahul I am running 10 minutes late")
        self.assertFalse(self.ops(ev))                                         # nothing sent yet
        self.assertIn("Rahul Sharma", self.reply(ev))
        ev = self.phone("haan bhej do")
        o = self.ops(ev)[0]
        self.assertEqual((o["op"], o["kwargs"]["number"], o["kwargs"]["text"]),
                         ("whatsapp_send", "+919800000001", "I am running 10 minutes late"))
        self.phone("call rahul")
        self.assertFalse(self.ops(self.phone("nahi")))                         # cancelled
        self.assertIn("couldn't find", self.reply(self.phone("call Zorawar")))

    def test_clock_maps_torch_and_screen(self):
        o = self.ops(self.phone("wake me up at 6 am"))[0]
        self.assertEqual((o["op"], o["kwargs"]["hour"], o["kwargs"]["minute"]), ("alarm", 6, 0))
        self.assertEqual(self.ops(self.phone("10 minute ka timer laga do"))[0]["kwargs"]["seconds"], 600)
        self.assertEqual(self.ops(self.phone("airport ka rasta batao"))[0]["kwargs"]["place"], "airport")
        self.assertEqual(self.ops(self.phone("torch on"))[0]["kwargs"], {"on": True})
        from src.brain.phone_intents import parse
        for not_phone in ("go to settings", "go to chrome", "open whatsapp", "play arijit songs", "volume up",
                          "remind me to push the PR at 5 pm", "go back"):
            self.assertIsNone(parse(not_phone), not_phone)
        self.assertEqual(self.ops(self.phone("tap the second video"))[0]["kwargs"]["query"], "second video")
        nodes = [{"name": "Home", "type": "HyperlinkControl", "rect": [0, 0, 100, 60]},
                 {"name": "Lofi hip hop radio beats to relax", "type": "ListItemControl", "rect": [0, 200, 1080, 800]},
                 {"name": "Arijit Singh best songs jukebox", "type": "ListItemControl", "rect": [0, 820, 1080, 1420]}]
        r = json.loads(self.c.find_on_screen("second video", json.dumps(nodes)))
        self.assertEqual(r["index"], 2)

    def test_real_count_answers_limits_and_summary(self):
        self.c.update_usage(json.dumps({"screen_ms": 3 * 3600000, "per_app_ms": {"com.instagram.android": 45 * 60000}}))
        rc_dir = self.c.realcount.folder
        import datetime as dt
        with open(os.path.join(rc_dir, f"{dt.date.today()}.json"), "w", encoding="utf-8") as f:
            json.dump({"apps": {"com.instagram.android": {"reels": 37, "reel_ms": 0}}}, f)
        self.assertIn("37", self.reply(self.phone("aaj kitni reels dekhi")))
        self.assertIn("3h 0m", self.reply(self.phone("what's my screen time today?")))
        self.assertIn("45 min on Instagram", self.reply(self.phone("kitna time instagram pe")))
        self.assertIn("37 reels", self.c.weekly_summary())
        lim = json.loads(self.c.set_limit("com.instagram.android", 30))
        self.assertEqual(lim["limits"], {"com.instagram.android": 30})
        from src.life.realcount import RealCount
        self.assertEqual(RealCount.limit_state(45 * 60000, 30), "over")
        json.loads(self.c.set_limit("com.instagram.android", 0))
        self.assertEqual(json.loads(self.c.limits_json())["limits"], {})

    def test_meeting_notes_from_phone_speech(self):
        self.assertIn("meeting notes", self.reply(self.say("take meeting notes")).lower())
        self.assertTrue(self.c.meeting.recording)
        self.c.add_meeting_text("We agreed the API ships on Friday.")
        self.c.add_meeting_text("Rahul will update the README by tomorrow.")
        self.say("stop taking notes", wait=8)
        end = time.time() + 15                                  # the note is built after "wrapping up…"
        while time.time() < end and not any(n.get("kind") == "meeting" for n in self.c.notes.items):
            time.sleep(0.2)
        self.assertFalse(self.c.meeting.recording)
        self.assertTrue(any(n.get("kind") == "meeting" for n in self.c.notes.items))

    def test_android_data_is_central(self):
        from src import appdata
        self.assertEqual(appdata.get("android.key_actions")["alt+left"], "back")
        pkgs = [a["package"] for a in appdata.get("android.social_apps")]
        for p in ("com.instagram.android", "com.google.android.youtube", "in.mohalla.video", "com.snapchat.android"):
            self.assertIn(p, pkgs)


if __name__ == "__main__":
    unittest.main()
