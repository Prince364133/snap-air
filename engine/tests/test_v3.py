"""Keyboard control, cloud brain, model compatibility, key storage, Snapy wake word."""
import json
import os
import tempfile
import unittest

TMP = tempfile.mkdtemp()
os.environ["SNAP_AIR_DATA"] = TMP

from src.os_control import keys as K  # noqa: E402
from src.brain import cloud as C  # noqa: E402
from src.brain.llm import compatibility, is_compatible  # noqa: E402
from src import secrets_store  # noqa: E402
from src.ai.agent_controller import AgentController  # noqa: E402
from tests.test_agent import FakeApps, FakeOS  # noqa: E402


class KeyboardTests(unittest.TestCase):
    def combo(self, t, **kw):
        c = K.parse_combo(t, **kw)
        return c and c["keys"]

    def test_combos_and_misheard_letters(self):
        self.assertEqual(self.combo("press windows plus h"), ["win", "h"])
        self.assertEqual(self.combo("press one window plus edge"), ["win", "h"])      # the user's real utterance
        self.assertEqual(self.combo("control see"), ["ctrl", "c"])
        self.assertEqual(self.combo("ctrl+shift+esc"), ["ctrl", "shift", "esc"])
        self.assertEqual(self.combo("alt f4"), ["alt", "f4"])
        self.assertEqual(self.combo("hit f twelve"), ["f12"])
        self.assertEqual(self.combo("windows period"), ["win", "."])
        self.assertEqual(K.parse_combo("press enter 3 times")["times"], 3)
        self.assertIsNone(K.parse_combo("scroll down", require_modifier=True))
        self.assertIsNone(K.parse_combo("open spotify", require_modifier=True))

    def test_named_windows_actions(self):
        self.assertEqual(K.find_shortcut("open voice typing")[0], ("win", "h"))
        self.assertEqual(K.find_shortcut("Snappy, clipboard history.")[0], ("win", "v"))
        self.assertEqual(K.find_shortcut("show the emoji panel")[0], ("win", "."))
        self.assertEqual(K.find_shortcut("task manager")[0], ("ctrl", "shift", "esc"))
        self.assertIsNone(K.find_shortcut("open settings"))          # Snapy's own settings, not Windows'

    def test_agent_runs_keys_instead_of_searching_for_an_app(self):
        fos = FakeOS()
        a = AgentController(settings={}, os_actions=fos, app_index=FakeApps())
        for text, call in [("press one window plus edge", ("hotkey", "win", "h")),
                           ("open voice typing", ("hotkey", "win", "h")),
                           ("windows v", ("hotkey", "win", "v")),
                           ("control shift t", ("hotkey", "ctrl", "shift", "t"))]:
            fos.calls.clear()
            r = a.execute_intent(text)
            self.assertTrue(r.ok, text)
            self.assertIn(call, fos.calls, text)
        fos.calls.clear()
        r = a.execute_intent("press control alt delete")
        self.assertFalse(r.ok)
        self.assertEqual(fos.calls, [])
        a.execute_intent("lock the screen")
        self.assertIn(("lock",), fos.calls)


class FakeResp:
    def __init__(self, lines=None, body=None, status=200):
        self.lines, self.body, self.status_code = lines or [], body, status

    def iter_lines(self, decode_unicode=True):
        yield from self.lines

    def json(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def close(self):
        pass


class CloudTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.orig = C.requests.post
        secrets_store.set_key("cloud_gemini", "AIzaTESTKEY1234567")
        secrets_store.set_key("cloud_openai", "sk-test-1234567890")

    def tearDown(self):
        C.requests.post = self.orig

    def test_key_is_encrypted_at_rest(self):
        raw = open(os.path.join(TMP, "secrets.json")).read()
        self.assertNotIn("AIzaTESTKEY", raw)
        self.assertEqual(secrets_store.get_key("cloud_gemini"), "AIzaTESTKEY1234567")
        self.assertEqual(secrets_store.masked("cloud_gemini"), "•••• 4567")

    def test_gemini_streaming(self):
        chunks = ['{"say": "Hello', ' there!", "tool": "none", "args": {}}']
        lines = [f"data: {json.dumps({'candidates': [{'content': {'parts': [{'text': c}]}}]})}" for c in chunks]

        def fake_post(url, **kw):
            self.calls.append((url, kw))
            return FakeResp(lines)
        C.requests.post = fake_post
        cl = C.CloudLLM({"cloud_provider": "gemini"})
        out = "".join(cl.stream([{"role": "system", "content": "sys"}, {"role": "user", "content": "hi"}], schema={}))
        self.assertEqual(json.loads(out)["say"], "Hello there!")
        url, kw = self.calls[0]
        self.assertIn(f"{C.PROVIDERS['gemini']['model']}:streamGenerateContent", url)   # default from app.json
        self.assertEqual(kw["headers"]["x-goog-api-key"], "AIzaTESTKEY1234567")
        self.assertEqual(kw["json"]["generationConfig"]["responseMimeType"], "application/json")
        self.assertIn("sys", kw["json"]["systemInstruction"]["parts"][0]["text"])

    def test_openai_streaming_and_errors(self):
        lines = ['data: {"choices": [{"delta": {"content": "{\\"say\\": \\"Hi\\""}}]}',
                 'data: {"choices": [{"delta": {"content": ", \\"tool\\": \\"none\\", \\"args\\": {}}"}}]}',
                 "data: [DONE]"]
        C.requests.post = lambda url, **kw: (self.calls.append((url, kw)), FakeResp(lines))[1]
        cl = C.CloudLLM({"cloud_provider": "openai"})
        out = "".join(cl.stream([{"role": "system", "content": "s"}, {"role": "user", "content": "x"}], schema={}))
        self.assertEqual(json.loads(out)["say"], "Hi")
        self.assertEqual(self.calls[0][1]["headers"]["Authorization"], "Bearer sk-test-1234567890")
        C.requests.post = lambda url, **kw: FakeResp(body={"error": {"message": "Invalid API key"}}, status=401)
        with self.assertRaises(RuntimeError) as e:
            cl.chat_text([{"role": "user", "content": "x"}])
        self.assertIn("Invalid API key", str(e.exception))

    def test_brain_routing(self):
        class Local:
            def ready(self):
                return True

            def stream(self, *a, **k):
                yield "local"
        cl = C.CloudLLM({"cloud_provider": "gemini"})
        cl.online = lambda: True
        settings = {"ai_provider": "auto", "cloud_provider": "gemini"}
        b = C.Brain(Local(), cl, settings)
        self.assertTrue(b.is_cloud)
        self.assertFalse(b.for_purpose("memory").is_cloud)            # memory learning stays local by default
        settings["ai_provider"] = "local"
        self.assertFalse(b.is_cloud)
        settings["ai_provider"] = "cloud"
        C.requests.post = lambda url, **kw: (_ for _ in ()).throw(C.requests.ConnectionError("offline"))
        self.assertEqual("".join(b.stream([{"role": "system", "content": "s"}])), "local")   # falls back


class CompatibilityTests(unittest.TestCase):
    def test_cpu_laptop_blocks_big_models(self):
        hw = {"ram_total": 15.3, "ram_free": 1.0, "cores": 16, "gpu_vram": 0}
        c = compatibility(hw)
        ok = {m["name"]: m["compatible"] for m in c["models"]}
        self.assertTrue(ok["qwen3:1.7b"] and ok["qwen3:4b"])
        self.assertFalse(ok["qwen3:8b"] or ok["qwen3:14b"] or ok["gemma3:12b"])
        self.assertEqual(c["recommended"], "qwen3:1.7b")
        self.assertIn("Not compatible", [m for m in c["models"] if m["name"] == "qwen3:14b"][0]["reason"])
        self.assertEqual(len(c["models"]), 15)
        self.assertGreaterEqual(min(m["params"] for m in c["models"]), 1.0)
        self.assertLessEqual(max(m["params"] for m in c["models"]), 15)

    def test_small_and_gpu_machines(self):
        self.assertEqual(compatibility({"ram_total": 8, "ram_free": 3, "cores": 4, "gpu_vram": 0})["recommended"], "qwen3:1.7b")
        big = compatibility({"ram_total": 32, "ram_free": 20, "cores": 16, "gpu_vram": 12})
        self.assertTrue(all(m["compatible"] for m in big["models"]))
        self.assertEqual(is_compatible("qwen3:14b", {"ram_total": 8, "ram_free": 3, "cores": 4, "gpu_vram": 0})[0], False)


class WakeWordTests(unittest.TestCase):
    def test_snapy_variants(self):
        a = AgentController(settings={"wake_words": ["snapy", "snappy", "snap"]}, os_actions=FakeOS(), app_index=FakeApps())
        for t in ("Snappy, next tab.", "Hey Snapy, next tab", "Snap, next tab", "Okay Snappy. Next tab."):
            self.assertEqual(a.execute_intent(t, require_wake=True).action, "tab", t)
        self.assertEqual(a.execute_intent("snapchat is fun", require_wake=True).action, "ignored")


if __name__ == "__main__":
    unittest.main()


class EngineImportTest(unittest.TestCase):
    def test_main_module_builds_without_starting(self):
        """Catches startup NameErrors (the unit tests never import main.py otherwise)."""
        import importlib
        import sys
        os.environ["SNAP_AIR_SETTINGS"] = os.path.join(TMP, "settings_import.json")
        mod = sys.modules.get("main") or importlib.import_module("main")
        # "none" is valid too: a machine with no Ollama and no cloud key has no brain yet
        self.assertIn(mod.state["brain"], ("local", "cloud", "none"))
        self.assertTrue(hasattr(mod, "brain") and hasattr(mod, "assistant"))
        for t in ("chat", "execute_command", "request", "cloud_preview_ack", "cancel_setup", "model_select"):
            self.assertIn(t, mod.router.handlers)
        self.assertTrue(mod.cloud.require_ack)                   # no cloud call before the user allows it
