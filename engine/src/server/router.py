"""Message router: one table of {message type -> handler} instead of a long if/elif.

A handler takes (msg, ctx) and may return a dict, which is sent back to the client
that asked (other clients are reached through send_all as before). Handlers may be
plain functions or coroutines. An exception inside one handler is recorded under
"ws.handler" and the connection keeps going (before, it closed the HUD's link).
"""
import inspect
import json

from websockets.exceptions import ConnectionClosed

from src import diag


class Router:
    def __init__(self):
        self.handlers = {}

    def on(self, *types):
        def deco(fn):
            for t in types:
                if t in self.handlers:
                    raise ValueError(f"duplicate handler for {t!r}")
                self.handlers[t] = fn
            return fn
        return deco

    def types(self):
        return sorted(self.handlers)

    async def dispatch(self, msg, ctx, reply):
        """Run the handler for msg["type"]; `reply` is an async fn sending a dict to this client.
        Returns False for an unknown type (ignored, as before)."""
        fn = self.handlers.get(msg.get("type"))
        if fn is None:
            return False
        try:
            out = fn(msg, ctx)
            if inspect.isawaitable(out):
                out = await out
            if out is not None:
                await reply(out)
        except ConnectionClosed:
            raise                                   # normal disconnect: the connection handler ends
        except Exception as e:                      # noqa: BLE001 - one bad message must not drop the HUD
            diag.record("ws.handler", e, type=msg.get("type"))
        return True


def encode(payload):
    return json.dumps(payload, default=str)
