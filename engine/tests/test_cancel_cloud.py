"""Cancelling downloads, and cloud provider routing (no network: requests is faked)."""
import json
import os
import tempfile
import threading
import unittest
from unittest import mock

os.environ.setdefault("SNAP_AIR_DATA", tempfile.mkdtemp())

from src.brain import cloud as cloud_mod  # noqa: E402
from src.brain.cloud import Brain, CloudLLM  # noqa: E402
from src.brain.llm import LLM  # noqa: E402
from src.setup_assets import Setup, SetupCancelled  # noqa: E402


class FakeResp:
    def __init__(self, status=200, body=None, lines=(), chunks=(), headers=None, on_chunk=None):
        self.status_code, self._body, self._lines = status, body or {}, list(lines)
        self._chunks, self.headers, self._on_chunk = list(chunks), headers or {}, on_chunk
        self.text = json.dumps(self._body)
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def json(self):
        return self._body

    def iter_lines(self, decode_unicode=False):
        yield from self._lines

    def iter_content(self, n):
        for i, c in enumerate(self._chunks):
            yield c
            if self._on_chunk:
                self._on_chunk(i)

    def raise_for_status(self):
        if self.status_code >= 400:
            raise cloud_mod.requests.HTTPError(str(self.status_code))

    def close(self):
        self.closed = True


class LocalStub:
    busy = threading.Event()

    def __init__(self, ready=True):
        self._ready = ready

    def ready(self):
        return self._ready

    def chat_text(self, *a, **k):
        return "local answer"


def anthropic_cloud(key="sk-test"):
    c = CloudLLM({"cloud_provider": "anthropic"})
    c._online = (9e18, True)                       # pretend the connectivity check already passed
    return c, mock.patch.object(cloud_mod.secrets_store, "get_key", return_value=key)


class AnthropicRequestTests(unittest.TestCase):
    def test_request_shape_for_current_haiku(self):
        c, keyp = anthropic_cloud()
        sent = {}

        def post(url, json=None, headers=None, **k):
            sent.update(url=url, body=json, headers=headers)
            return FakeResp(body={"content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "OK"}]})
        with keyp, mock.patch.object(cloud_mod.requests, "post", side_effect=post):
            out = c.chat_text([{"role": "system", "content": "Be brief"}, {"role": "user", "content": "ping"}],
                              max_tokens=5, temperature=0)
        self.assertEqual(out, "OK")                          # thinking blocks are skipped
        b = sent["body"]
        self.assertEqual(sent["url"], "https://api.anthropic.com/v1/messages")
        self.assertEqual(b["model"], "claude-haiku-5-5")
        self.assertNotIn("temperature", b)                   # Haiku 5.5 rejects non-default sampling
        self.assertGreaterEqual(b["max_tokens"], 1024)       # room for thinking before the answer
        self.assertEqual(b["system"], "Be brief")
        self.assertEqual(b["messages"], [{"role": "user", "content": "ping"}])
        self.assertEqual(sent["headers"]["x-api-key"], "sk-test")

    def test_stream_yields_only_text_and_raises_on_error_event(self):
        ev = lambda d: "data: " + json.dumps(d)  # noqa: E731
        ok = FakeResp(lines=[ev({"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "hm"}}),
                             ev({"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hel"}}),
                             ev({"type": "content_block_delta", "delta": {"type": "text_delta", "text": "lo"}})])
        self.assertEqual("".join(CloudLLM._sse_texts(ok, "anthropic")), "Hello")
        bad = FakeResp(lines=[ev({"type": "error", "error": {"message": "Overloaded"}})])
        with self.assertRaisesRegex(RuntimeError, "Overloaded"):
            list(CloudLLM._sse_texts(bad, "anthropic"))


class RejectedKeyTests(unittest.TestCase):
    def test_bad_key_is_not_ready_and_brain_uses_local(self):
        c, keyp = anthropic_cloud("wrong")
        with keyp, mock.patch.object(cloud_mod.requests, "post",
                                     return_value=FakeResp(401, {"error": {"message": "invalid x-api-key"}})):
            self.assertTrue(c.ready())
            with self.assertRaises(RuntimeError):
                c.test()
            self.assertTrue(c.key_rejected())
            self.assertFalse(c.ready())
            for mode in ("auto", "cloud"):
                b = Brain(LocalStub(), c, {"ai_provider": mode})
                self.assertFalse(b.is_cloud, mode)
        # a different key is given a fresh chance
        with mock.patch.object(cloud_mod.secrets_store, "get_key", return_value="new"):
            self.assertFalse(c.key_rejected())

    def test_server_errors_do_not_mark_key_rejected(self):
        c, keyp = anthropic_cloud()
        with keyp, mock.patch.object(cloud_mod.requests, "post", return_value=FakeResp(529, {"error": {"message": "x"}})):
            with self.assertRaises(RuntimeError):
                c.test()
            self.assertFalse(c.key_rejected())


class SetupCancelTests(unittest.TestCase):
    def setUp(self):
        self.s = Setup()
        self.s.plan(need_speech=True, need_voice=True, need_runtime=False, need_brain=False)
        self.dir = tempfile.mkdtemp()

    def test_cancel_stops_download_mid_file_and_keeps_part(self):
        dest = os.path.join(self.dir, "model.bin")
        get = FakeResp(206, chunks=[b"a" * 10, b"b" * 10, b"c" * 10],
                       on_chunk=lambda i: self.s.cancel() if i == 0 else None)
        with mock.patch("src.setup_assets.requests.head", return_value=FakeResp(headers={"content-length": "30"})), \
                mock.patch("src.setup_assets.requests.get", return_value=get) as g:
            self.assertTrue(self.s.try_start())
            with self.assertRaises(SetupCancelled):
                self.s.fetch("speech", [("http://x/model.bin", dest)])
        self.assertEqual(g.call_count, 1)                       # no retry after a cancel
        self.assertFalse(os.path.exists(dest))
        self.assertEqual(os.path.getsize(dest + ".part"), 10)   # resumable later
        st = self.s.state()
        self.assertTrue(st["cancelled"])
        self.assertFalse(st["complete"])
        self.assertEqual({i["state"] for i in st["items"]}, {"cancelled"})

    def test_only_one_run_until_the_worker_finishes(self):
        self.assertTrue(self.s.try_start())
        self.s.cancel()
        self.assertTrue(self.s.running)            # worker still unwinding
        self.assertFalse(self.s.try_start())       # so Retry can't start a second run
        self.s.finish()
        self.assertTrue(self.s.try_start())
        self.assertFalse(self.s.cancelled)         # a new run starts uncancelled


class PullCancelTests(unittest.TestCase):
    def test_cancel_pull_stops_and_reports_cancelled(self):
        llm = LLM(settings={}, host="http://127.0.0.1:1")
        lines = [json.dumps({"status": "pulling", "total": 100, "completed": i}).encode() for i in (10, 20, 30)]

        class Stream(FakeResp):
            def iter_lines(self_inner, decode_unicode=False):
                for i, line in enumerate(lines):
                    if i == 1:
                        llm.cancel_pull()
                    yield line
        with mock.patch("src.brain.llm.requests.post", return_value=Stream()):
            self.assertFalse(llm.pull("qwen3:1.7b"))
        self.assertTrue(llm.pull_cancelled())
        self.assertIsNone(llm.pulling)
        self.assertIsNone(llm.last_error)


if __name__ == "__main__":
    unittest.main()
