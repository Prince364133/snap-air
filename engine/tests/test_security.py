"""WebSocket security: only the HUD (right token, Electron origin) may connect.

Starts a real websockets server with the engine's handshake hook on a free port,
then connects the way a web page, a stray tool and the HUD would.
"""
import asyncio
import os
import socket
import stat
import tempfile
import threading
import unittest

TMP = tempfile.mkdtemp()      # used only inside the tests that write the token file (restored after)

import websockets  # noqa: E402
from websockets.exceptions import InvalidStatus  # noqa: E402
from websockets.sync.client import connect  # noqa: E402

from src.server import auth  # noqa: E402
from src.server.router import Router  # noqa: E402

TOKEN = "test-token-" + "x" * 32


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        cls.ready = threading.Event()
        cls.loop = asyncio.new_event_loop()

        async def echo(ws):
            async for m in ws:
                await ws.send("echo:" + m)

        async def main():
            cls.stop = asyncio.Event()
            async with websockets.serve(echo, "127.0.0.1", cls.port,
                                        process_request=auth.process_request(TOKEN, auth.DEFAULT_ORIGINS)):
                cls.ready.set()
                await cls.stop.wait()

        cls.thread = threading.Thread(target=lambda: cls.loop.run_until_complete(main()), daemon=True)
        cls.thread.start()
        assert cls.ready.wait(10), "server didn't start"

    @classmethod
    def tearDownClass(cls):
        cls.loop.call_soon_threadsafe(cls.stop.set)
        cls.thread.join(5)
        cls.loop.close()

    def url(self, token=None):
        return f"ws://127.0.0.1:{self.port}/" + (f"?token={token}" if token is not None else "")

    def status(self, url, origin=None):
        """HTTP status the handshake was refused with, or 101 when it was accepted."""
        try:
            with connect(url, origin=origin, open_timeout=5) as ws:
                ws.send("hi")
                self.assertEqual(ws.recv(timeout=5), "echo:hi")
                return 101
        except InvalidStatus as e:
            return e.response.status_code

    def test_no_token_rejected(self):
        self.assertEqual(self.status(self.url()), 401)
        self.assertEqual(self.status(self.url(""), origin="file://"), 401)

    def test_wrong_token_rejected(self):
        self.assertEqual(self.status(self.url("nope"), origin="file://"), 401)
        self.assertEqual(self.status(self.url(TOKEN[:-1]), origin="null"), 401)

    def test_browser_origin_rejected_even_with_token(self):
        self.assertEqual(self.status(self.url(TOKEN), origin="https://evil.example"), 403)
        self.assertEqual(self.status(self.url(TOKEN), origin="http://localhost:3000"), 403)
        self.assertEqual(self.status(self.url(TOKEN), origin="chrome-extension://abc"), 403)

    def test_hud_accepted(self):
        self.assertEqual(self.status(self.url(TOKEN), origin="null"), 101)       # older Electron
        self.assertEqual(self.status(self.url(TOKEN), origin="file://"), 101)    # Chromium file:// pages
        self.assertEqual(self.status(self.url(TOKEN)), 101)                      # non-browser client with token


class CheckTests(unittest.TestCase):
    def test_check_function(self):
        ok = auth.check("/?token=abc", {"Origin": "null"}, "abc", ["null"])
        self.assertIsNone(ok)
        self.assertEqual(auth.check("/?token=abd", {"Origin": "null"}, "abc", ["null"])[0], 401)
        self.assertEqual(auth.check("/?token=abc", {"Origin": "https://evil.example"}, "abc", ["null"])[0], 403)
        self.assertEqual(auth.check("/?token=abc", {}, "", ["null"])[0], 401)           # no token configured: closed
        self.assertEqual(auth.check("/?token=%C3%A9", {}, "abc", ["null"])[0], 401)     # non-ASCII doesn't crash

    def test_token_env_and_file(self):
        prev = os.environ.get("SNAP_AIR_DATA")
        os.environ["SNAP_AIR_DATA"] = TMP
        try:
            self._token_env_and_file()
        finally:
            if prev is None:
                os.environ.pop("SNAP_AIR_DATA", None)
            else:
                os.environ["SNAP_AIR_DATA"] = prev

    def _token_env_and_file(self):
        self.assertEqual(auth.load_or_create_token({"SNAPY_WS_TOKEN": "from-electron"}), "from-electron")
        t = auth.load_or_create_token({})
        self.assertGreaterEqual(len(t), 40)
        with open(auth.token_file(), encoding="utf-8") as f:
            self.assertEqual(f.read(), t)
        self.assertNotEqual(auth.load_or_create_token({}), t)                  # fresh every launch
        if os.name != "nt":                                                   # Windows: %APPDATA% ACL
            self.assertEqual(stat.S_IMODE(os.stat(auth.token_file()).st_mode), 0o600)


class RouterTests(unittest.TestCase):
    def test_dispatch_reply_and_errors(self):
        r = Router()
        got = []

        @r.on("ping")
        def ping(d, ctx):
            return {"type": "pong"}

        @r.on("boom")
        def boom(d, ctx):
            raise ValueError("bad")

        async def reply(p):
            got.append(p)

        async def go():
            self.assertTrue(await r.dispatch({"type": "ping"}, None, reply))
            self.assertTrue(await r.dispatch({"type": "boom"}, None, reply))        # recorded, not raised
            self.assertFalse(await r.dispatch({"type": "nope"}, None, reply))
        asyncio.run(go())
        self.assertEqual(got, [{"type": "pong"}])
        with self.assertRaises(ValueError):
            r.on("ping")(lambda d, c: None)


if __name__ == "__main__":
    unittest.main()
