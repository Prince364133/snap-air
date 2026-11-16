"""Regression tests for the 2026-11-16 production-readiness audit (docs/AUDIT_2026-11-16.md).
Each test names the finding it covers."""
import json
import os
import socket
import tempfile
import threading
import unittest
from unittest import mock

from tests import _env

setUpModule, tearDownModule = _env.module_data_dir()


# ---------------------------------------------------------------- A-01 hermetic tests
class HermeticEnvTests(unittest.TestCase):
    def test_no_internet_and_no_local_ollama(self):
        import requests
        with self.assertRaises(requests.RequestException):
            requests.get("https://example.com", timeout=2)
        from src.brain.llm import LLM
        llm = LLM(settings={})
        self.assertFalse(llm.available(timeout=0.5))        # even when a real Ollama is running
        self.assertFalse(llm.ensure_server())               # and it is never spawned

    def test_loopback_servers_still_work(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        try:
            c = socket.create_connection(srv.getsockname(), timeout=2)
            c.close()
        finally:
            srv.close()

    def test_data_and_settings_are_temporary(self):
        appdata = os.environ.get("APPDATA") or "~"
        self.assertNotIn(os.path.join(appdata, "SnapAir"), os.environ["SNAP_AIR_DATA"])
        self.assertTrue(os.environ["SNAP_AIR_SETTINGS"].startswith(_env.ROOT))


# ---------------------------------------------------------------- A-03 settings types
class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.dir = _env.isolated_data(self)
        self.path = os.path.join(self.dir, "settings.json")

    def make(self):
        from src.config import Settings
        return Settings(self.path)

    def test_floats_stay_numbers(self):
        s = self.make()
        s.update({"tts_speed": "1.2", "continuation_wait_s": 2, "end_of_speech_s": 0.6})
        self.assertEqual(s["tts_speed"], 1.2)
        self.assertIsInstance(s["continuation_wait_s"], float)
        with open(self.path, encoding="utf-8") as f:
            saved = json.load(f)
        self.assertIsInstance(saved["tts_speed"], float)          # not "1.2": phones reject strings

    def test_bad_values_are_ignored(self):
        s = self.make()
        for v in ("abc", float("nan"), float("inf"), None, True, [1]):
            s.update({"tts_speed": v})
            self.assertEqual(s["tts_speed"], 1.0, v)
        s.update({"mic_sensitivity": "7.0"})
        self.assertEqual(s["mic_sensitivity"], 7)
        s.update({"wake_words": 5})
        self.assertEqual(s["wake_words"], ["snapy", "snappy", "hey snapy", "snap"])

    def test_false_strings_are_false(self):
        s = self.make()
        s.update({"tts_enabled": "false"})
        self.assertIs(s["tts_enabled"], False)
        s.update({"tts_enabled": "on"})
        self.assertIs(s["tts_enabled"], True)

    def test_load_repairs_values_stored_as_text(self):
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump({"tts_speed": "1.1", "max_utterance_s": "abc", "agent_name": "Mitra"}, f)
        s = self.make()
        self.assertEqual(s["tts_speed"], 1.1)
        self.assertEqual(s["max_utterance_s"], 20)               # wrong type: default kept
        self.assertEqual(s["agent_name"], "Mitra")

    def test_path_is_resolved_when_created(self):
        from src import config
        with mock.patch.dict(os.environ, {"SNAP_AIR_SETTINGS": self.path}):
            self.assertEqual(config.Settings().path, self.path)

    def test_concurrent_updates(self):
        s = self.make()
        errors = []

        def worker(i):
            try:
                for n in range(40):
                    s.update({"voice_scroll_amount": i * 100 + n, "agent_name": f"N{i}-{n}"})
                    s.as_dict()
            except Exception as e:          # noqa: BLE001
                errors.append(e)
        ts = [threading.Thread(target=worker, args=(i,)) for i in range(6)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(errors, [])
        with open(self.path, encoding="utf-8") as f:
            self.assertIn("agent_name", json.load(f))          # never a half-written file


# ---------------------------------------------------------------- A-05 token not inherited
class TokenEnvTests(unittest.TestCase):
    def test_token_is_removed_from_the_environment(self):
        from src.server import auth
        env = {"SNAPY_WS_TOKEN": "tok-123", "OTHER": "x"}
        self.assertEqual(auth.load_or_create_token(env), "tok-123")
        self.assertNotIn("SNAPY_WS_TOKEN", env)                  # children of the engine never see it
        self.assertEqual(env["OTHER"], "x")


# ---------------------------------------------------------------- A-04 open_editor
class OpenEditorTests(unittest.TestCase):
    def setUp(self):
        from src.ai.agent_controller import OSActions
        self.o = OSActions.__new__(OSActions)

    def run_editor(self, path, which):
        calls = []
        with mock.patch("src.ai.agent_controller.shutil.which", side_effect=which), \
                mock.patch("src.ai.agent_controller.subprocess.Popen", side_effect=lambda *a, **k: calls.append((a, k))), \
                mock.patch("src.ai.agent_controller.os.startfile", create=True,
                           side_effect=lambda p: calls.append((("startfile", p), {}))):
            used = self.o.open_editor(path)
        return used, calls

    def test_no_shell_and_path_is_one_argument(self):
        path = os.path.join(tempfile.gettempdir(), 'proj" & calc & "')
        used, calls = self.run_editor(path, lambda exe: r"C:\Tools\code.exe" if exe == "code" else None)
        self.assertEqual(used, "code")
        (args, kw), = calls
        self.assertEqual(args[0], [r"C:\Tools\code.exe", os.path.abspath(path)])
        self.assertNotIn("shell", kw)

    def test_batch_launcher_with_cmd_metacharacters_is_skipped(self):
        path = os.path.join(tempfile.gettempdir(), "a&b")
        used, calls = self.run_editor(path, lambda exe: r"C:\VS\bin\code.cmd" if exe == "code" else None)
        self.assertEqual(used, "explorer")
        self.assertEqual(calls[0][0][0], "startfile")

    def test_missing_editors_fall_back_to_explorer(self):
        used, calls = self.run_editor(tempfile.gettempdir(), lambda exe: None)
        self.assertEqual(used, "explorer")                        # shell=True used to "succeed" always


# ---------------------------------------------------------------- A-06/A-07 downloads
class FakeResp:
    def __init__(self, body, status=200, length=None, headers=None):
        self.body, self.status_code = body, status
        self.headers = {"Content-Length": str(len(body) if length is None else length), **(headers or {})}

    def raise_for_status(self):
        if self.status_code >= 400:
            import requests
            raise requests.HTTPError(f"{self.status_code}")

    def iter_content(self, n):
        for i in range(0, len(self.body), 4):
            yield self.body[i:i + 4]

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=_env.ROOT)

    def test_truncated_body_is_resumed_not_installed(self):
        from src import setup_assets as S
        full = b"0123456789abcdef"
        replies = [FakeResp(full[:6], length=len(full)),                       # closes early, no error
                   FakeResp(full[6:], status=206, length=len(full) - 6)]
        seen = []

        def get(url, headers=None, **k):
            seen.append(dict(headers or {}))
            return replies.pop(0)
        head = mock.Mock(headers={"content-length": str(len(full))})
        s = S.Setup()
        s.plan(True, False, False, False)
        s._cancel.wait = lambda t: False
        dest = os.path.join(self.dir, "model.bin")
        with mock.patch.object(S.requests, "head", return_value=head), mock.patch.object(S.requests, "get", side_effect=get):
            s.fetch("speech", [("https://x/model.bin", dest)])
        with open(dest, "rb") as f:
            self.assertEqual(f.read(), full)
        self.assertEqual(seen[1], {"Range": "bytes=6-"})
        self.assertFalse(os.path.exists(dest + ".part"))

    def test_complete_part_file_is_finalised_without_a_request(self):
        from src import setup_assets as S
        dest = os.path.join(self.dir, "done.bin")
        with open(dest + ".part", "wb") as f:
            f.write(b"x" * 8)
        s = S.Setup()
        s.plan(True, False, False, False)
        head = mock.Mock(headers={"content-length": "8"})
        with mock.patch.object(S.requests, "head", return_value=head), \
                mock.patch.object(S.requests, "get", side_effect=AssertionError("no download needed")):
            s.fetch("speech", [("https://x/done.bin", dest)])
        self.assertEqual(os.path.getsize(dest), 8)                # used to fail with 416 four times

    def test_download_file_refuses_truncation(self):
        from src import setup_assets as S
        dest = os.path.join(self.dir, "voice.onnx")
        with mock.patch.object(S.requests, "get", return_value=FakeResp(b"abc", length=10)):
            with self.assertRaises(S.IncompleteDownload):
                S.download_file("https://x/voice.onnx", dest)
        self.assertFalse(os.path.exists(dest))
        self.assertFalse(os.path.exists(dest + ".part"))
        with mock.patch.object(S.requests, "get", return_value=FakeResp(b"abcdefghij")):
            S.download_file("https://x/voice.onnx", dest)
        self.assertEqual(os.path.getsize(dest), 10)

    def test_installer_must_be_complete_and_signed(self):
        from src import setup_assets as S
        p = os.path.join(self.dir, "OllamaSetup.exe")
        with open(p, "wb") as f:
            f.write(b"MZ" + b"0" * 98)
        with self.assertRaises(RuntimeError):
            S.verify_installer(p, 5000, signature_fn=lambda p: ("Valid", "CN=Ollama Inc."))
        for status, subject in (("NotSigned", ""), ("HashMismatch", "CN=Ollama Inc."), ("Valid", "CN=Someone Else")):
            with self.assertRaises(RuntimeError, msg=status):
                S.verify_installer(p, 100, signature_fn=lambda p, r=(status, subject): r)
        S.verify_installer(p, 100, signature_fn=lambda p: ("Valid", "CN=Ollama Inc., O=Ollama Inc."))


# ---------------------------------------------------------------- A-09 bounded diagnostics
class DiagBoundTests(unittest.TestCase):
    def test_distinct_codes_are_capped(self):
        _env.isolated_data(self)
        from src import diag
        diag.reset()
        old = diag.MAX_CODES
        diag.MAX_CODES = 3
        try:
            for i in range(10):
                diag.record(f"dyn.{i}", ValueError("x"), quiet=True)
            counts = diag.summary()["counts"]
            self.assertLessEqual(len(counts), 4)
            self.assertEqual(counts[diag.OVERFLOW], 7)
        finally:
            diag.MAX_CODES = old
            diag.reset()


# ---------------------------------------------------------------- A-10 attention robustness
class AttentionRobustnessTests(unittest.TestCase):
    def test_malformed_limit_does_not_break_nudges(self):
        from src.life.attention import AttentionTracker, NudgeEngine
        d = tempfile.mkdtemp(dir=_env.ROOT)
        settings = {"attention_limits": {"YouTube": "abc", "Instagram": None, "Reddit": "15"}}
        tr = AttentionTracker(folder=d, settings=settings)
        import datetime as dt
        t = dt.datetime(2026, 11, 16, 14, 0).timestamp()          # mid-afternoon: not bedtime
        tr._roll(t)
        tr.sites_ms = {"YouTube": 99 * 60000, "Reddit": 20 * 60000}
        ne = NudgeEngine(folder=d, settings=settings)
        cand = ne._candidate(tr, t, {}, [], True)
        self.assertEqual(cand[0], "limit_over")                   # Reddit's valid limit still works
        self.assertEqual(cand[2]["app"], "Reddit")

    def test_failing_observer_is_recorded_not_fatal(self):
        from src import diag
        from src.life import activity as act
        a = act.ActivityTracker(settings={}, folder=tempfile.mkdtemp(dir=_env.ROOT))
        seen = []

        def bad(*args):
            raise ValueError("boom")
        a.observers += [bad, lambda *args: seen.append(args)]
        a.running = True
        polls = iter(range(2))

        def fake_fg():
            try:
                next(polls)
            except StopIteration:
                a.running = False
            return 1, "chrome", "YouTube - Google Chrome"
        before = diag.summary()["counts"].get("activity.observer", 0)
        with mock.patch.object(act, "_foreground_full", fake_fg), mock.patch.object(act, "_idle_seconds", lambda: 0.0), \
                mock.patch.object(act, "detect_call", lambda: None), mock.patch.object(act.time, "sleep", lambda s: None):
            a.interval = 0
            a._loop()
        self.assertTrue(seen)                                      # the next observer still ran
        self.assertGreater(diag.summary()["counts"].get("activity.observer", 0), before)


# ---------------------------------------------------------------- A-08 meeting counter
class MeetingPendingTests(unittest.TestCase):
    def test_pending_counter_is_exact_under_threads(self):
        import numpy as np
        from src.life.meeting import MeetingRecorder
        m = MeetingRecorder(transcribe_fn=lambda a: "")
        m._offsets = {"mic": 0.0}
        audio = np.zeros(16, dtype=np.float32)          # silence: the worker skips it quickly
        ts = [threading.Thread(target=lambda: [m._queue("mic", audio) for _ in range(200)]) for _ in range(4)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        import time
        end = time.time() + 10
        while m._pending and time.time() < end:
            time.sleep(0.02)
        self.assertEqual(m._pending, 0)


# ---------------------------------------------------------------- A-02 AI desktop commands
class AiCommandConfirmTests(unittest.TestCase):
    def test_code_running_commands_from_the_ai_need_a_yes(self):
        from tests.test_brain import make_world
        a, events, fos = make_world()
        for cmd in ("run my project", "git pull", "open a terminal", "type del /s /q C:\\ and press enter"):
            a.pending = None
            fos.calls.clear()
            a._run_tool("desktop", {"command": cmd}, "something the user said", "en", False)
            self.assertEqual(a.pending, {"kind": "action", "command": cmd}, cmd)
            self.assertEqual(fos.calls, [], cmd)
        a.pending = None
        a._run_tool("desktop", {"command": "scroll down"}, "scroll down", "en", False)
        self.assertIsNone(a.pending)                                # everyday commands still just run


# ---------------------------------------------------------------- A-11/A-12 engine wiring (main.py)
class EngineWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import importlib
        import sys
        cls.main = sys.modules.get("main") or importlib.import_module("main")

    def test_recap_time_is_normalised(self):
        h = self.main._hhmm
        self.assertEqual(h("9:30", "18:00"), "09:30")
        self.assertEqual(h("18.45", "18:00"), "18:45")
        for bad in ("", None, "25:00", "soon", "9"):
            self.assertEqual(h(bad, "18:00"), "18:00", bad)

    def test_delete_all_data_removes_exports_and_contexts(self):
        from src import storage
        m = self.main
        exp = os.path.join(storage.data_dir(), "export-2026-11-01.json")
        with open(exp, "w", encoding="utf-8") as f:
            json.dump({"memories": ["secret"]}, f)
        m.assistant.contexts.items = [{"id": "c1", "name": "work", "windows": []}]
        m.assistant.history.append({"role": "user", "content": "private"})
        m.delete_all_data()
        self.assertFalse(os.path.exists(exp))
        self.assertEqual(m.assistant.contexts.items, [])
        self.assertEqual(m.assistant.history, [])

    def test_installer_runs_only_after_verification(self):
        m = self.main
        ran = []
        with mock.patch("requests.get", return_value=FakeResp(b"MZ-not-really", length=13)), \
                mock.patch("src.setup_assets.verify_installer", side_effect=RuntimeError("bad signature")), \
                mock.patch.object(m.subprocess, "run", side_effect=lambda *a, **k: ran.append(a)),                 mock.patch.object(m, "models_payload", return_value={}), mock.patch.object(m, "toast"):
            m._ollama_install.update(status=None)
            m.install_ollama()
        self.assertEqual(ran, [])                                   # never executed
        self.assertEqual(m._ollama_install["status"], "error")


# ---------------------------------------------------------------- C-01..C-04 shared core data
class CoreDataTests(unittest.TestCase):
    def test_memory_rule_categories_are_in_the_schema_enum(self):
        from src import core_loader as core
        enum = set(core.schema("memory_fact")["properties"]["category"]["enum"])
        idx = core.read_json("intents/index.json")
        bad = []
        for f in idx["files"]:
            for domain, entries in core.read_json(f"intents/{f}").items():
                for e in entries if isinstance(entries, list) else []:
                    if isinstance(e, dict) and "category" in e and e["category"] not in enum:
                        bad.append((f, domain, e.get("id"), e["category"]))
        self.assertEqual(bad, [])

    def test_desktop_write_leaves_creative_requests_to_the_ai(self):
        from src.ai.agent_controller import AgentController
        from tests.test_agent import FakeApps, FakeOS
        fos = FakeOS()
        a = AgentController(settings={}, os_actions=fos, app_index=FakeApps())
        for t in ("write me a poem about rain", "write a story about a dragon"):
            fos.calls.clear()
            self.assertNotEqual(a.execute_intent(t).action, "type", t)
            self.assertFalse([c for c in fos.calls if c and c[0] == "type"], t)
        self.assertEqual(a.execute_intent("write hello world").action, "type")
        self.assertEqual(a.execute_intent("type a quick note for later").action, "type")

    def test_meeting_note_transcript_matches_schema(self):
        from src.life.meeting import MeetingRecorder
        from src.life.notes import NoteStore, transcript_text
        notes = NoteStore(os.path.join(tempfile.mkdtemp(dir=_env.ROOT), "notes.json"))
        m = MeetingRecorder(notes=notes)
        m.capture_devices = False
        m.start("Standup", sources=("mic",))
        m.add_text("mic", "We ship the API on Friday.")
        out = m.stop(wait=False)
        tr = out["note"]["transcript"]
        self.assertEqual(tr, [{"t": tr[0]["t"], "who": "You", "text": "We ship the API on Friday."}])
        self.assertIn("You: We ship the API on Friday.", transcript_text(tr))


if __name__ == "__main__":
    unittest.main()
