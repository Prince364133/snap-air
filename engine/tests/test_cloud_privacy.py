"""Cloud privacy: redaction of outgoing messages and the one-time "what's sent" consent."""
import os
import tempfile
import unittest

TMP = tempfile.mkdtemp()      # set per test (and restored): other modules rely on their own SNAP_AIR_DATA

from src.brain import cloud as C  # noqa: E402
from src import secrets_store  # noqa: E402


class RedactionTests(unittest.TestCase):
    def test_email_phone_card(self):
        r = C.redact("mail john.doe@example.co.in, call +91 98765 43210 or (555) 123-4567, card 4111 1111 1111 1111")
        self.assertNotIn("john.doe", r)
        self.assertNotIn("98765", r)
        self.assertNotIn("123-4567", r)
        self.assertNotIn("4111", r)
        self.assertEqual(r.count("[phone]"), 2)
        self.assertIn("[email]", r)
        self.assertIn("[card]", r)

    def test_keys(self):
        r = C.redact("keys: sk-proj-abcdefghijklmnop1234 AIzaSyA1234567890abcdefghijklmnopqrstu "
                     "ghp_abcdefghijklmnopqrstuvwxyz0123456789 and tok A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6")
        self.assertNotIn("sk-proj", r)
        self.assertNotIn("AIza", r)
        self.assertNotIn("ghp_", r)
        self.assertNotIn("A1b2C3", r)
        self.assertEqual(r.count("[key]"), 4)

    def test_user_paths(self):
        r = C.redact(r"open C:\Users\saavi\Desktop\plan.txt, C:/Users/saavi/x and /home/bob/notes.md")
        self.assertNotIn("saavi", r)
        self.assertNotIn("bob", r)
        self.assertIn(r"C:\Users\[user]\Desktop\plan.txt", r)
        self.assertIn("/home/[user]/notes.md", r)
        self.assertIn(r"C:\Users\Public\x", C.redact(r"C:\Users\Public\x"))

    def test_leaves_ordinary_text_alone(self):
        for t in ("Meeting at 2026-11-15 10:30 with 3 people", "Remind me in 25 minutes",
                  "order 1234 5678 1234 5679 is not a card",          # fails the Luhn check
                  "qwen3:1.7b runs at 12 tokens/s", "internationalization is a long word"):
            self.assertEqual(C.redact(t), t, t)

    def test_messages_copy(self):
        msgs = [{"role": "user", "content": "my email is a@b.io"}, {"role": "user", "content": None}]
        out = C.redact_messages(msgs)
        self.assertEqual(out[0]["content"], "my email is [email]")
        self.assertEqual(msgs[0]["content"], "my email is a@b.io")       # local copy untouched
        self.assertIs(C.redact_messages(msgs, enabled=False), msgs)


class FakeResp:
    status_code = 200

    def __init__(self, text="OK"):
        self._text = text

    def json(self):
        return {"choices": [{"message": {"content": self._text}}]}

    def close(self):
        pass


class Local:
    busy = None

    def ready(self):
        return True

    def stream(self, *a, **k):
        yield "local"

    def chat_text(self, *a, **k):
        return "local"


class ConsentTests(unittest.TestCase):
    def setUp(self):
        self._prev = os.environ.get("SNAP_AIR_DATA")
        os.environ["SNAP_AIR_DATA"] = TMP
        secrets_store.set_key("cloud_openai", "sk-test-1234567890")
        self.sent = []
        self._post = C.requests.post
        C.requests.post = lambda url, **kw: (self.sent.append(kw["json"]), FakeResp())[1]

    def tearDown(self):
        C.requests.post = self._post
        if self._prev is None:
            os.environ.pop("SNAP_AIR_DATA", None)
        else:
            os.environ["SNAP_AIR_DATA"] = self._prev

    def make(self, **settings):
        s = {"cloud_provider": "openai", "ai_provider": "cloud", **settings}
        cl = C.CloudLLM(s)
        cl._online = (9e18, True)
        return s, cl

    def test_redacts_what_is_sent(self):
        s, cl = self.make()
        cl.chat_text([{"role": "user", "content": "email me at x@y.com"}])
        self.assertEqual(self.sent[0]["messages"][0]["content"], "email me at [email]")
        s["cloud_redact"] = False
        cl.chat_text([{"role": "user", "content": "email me at x@y.com"}])
        self.assertEqual(self.sent[1]["messages"][0]["content"], "email me at x@y.com")

    def test_no_cloud_call_until_allowed(self):
        s, cl = self.make(cloud_preview_ack=False)
        cl.require_ack = True
        shown = []
        cl.on_preview = shown.append
        b = C.Brain(Local(), cl, s)
        self.assertFalse(b.is_cloud)
        self.assertEqual(b.chat_text([{"role": "user", "content": "call 555 123 4567 tonight"}]), "local")
        self.assertEqual("".join(b.stream([{"role": "user", "content": "hi"}])), "local")
        self.assertEqual(self.sent, [])                                    # nothing left the PC
        self.assertEqual(len(shown), 1)                                    # asked once, not per call
        self.assertIn("[phone]", shown[0]["messages"][0]["content"])
        with self.assertRaises(C.CloudConsentRequired):
            cl.chat_text([{"role": "user", "content": "x"}])
        self.assertEqual(cl.test()[1], "OK")                               # the key check may still run
        s["cloud_preview_ack"] = True
        self.assertTrue(b.is_cloud)
        self.assertEqual(b.chat_text([{"role": "user", "content": "hi"}]), "OK")

    def test_without_require_ack_nothing_changes(self):
        s, cl = self.make()                                                # Android / plain dict settings
        self.assertTrue(C.Brain(Local(), cl, s).is_cloud)


if __name__ == "__main__":
    unittest.main()
