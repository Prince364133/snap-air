"""asyncio LAN transport: the laptop's listener (SyncServer), a client (connect), and the
session loop both ends run after the handshake (see protocol.py / session.py)."""
import asyncio
import struct
import time

from src import diag
from src.sync import conf
from src.sync import crypto as C
from src.sync import protocol as P
from src.sync.session import CommandError, validate_command


class FrameError(Exception):
    pass


async def read_frame(reader, max_bytes):
    head = await reader.readexactly(4)
    n = struct.unpack(">I", head)[0]
    if n == 0 or n > max_bytes:
        raise FrameError("frame size out of range")
    return await reader.readexactly(n)


async def write_frame(writer, body):
    writer.write(P.frame(body))
    await writer.drain()


class Connection:
    """One authenticated session with a peer."""

    def __init__(self, reader, writer, channel, peer_id, peer_name, cfg=conf.get):
        self.reader, self.writer, self.channel = reader, writer, channel
        self.peer_id, self.peer_name, self.cfg = peer_id, peer_name, cfg
        self._wlock = asyncio.Lock()
        self.closed = False
        self.synced_at = None
        try:
            self.host = writer.get_extra_info("peername")[0]
        except (TypeError, IndexError):
            self.host = None

    async def send(self, msg):
        async with self._wlock:
            await write_frame(self.writer, self.channel.send_json(msg))

    async def recv(self):
        body = await read_frame(self.reader, int(self.cfg("max_frame_bytes")))
        return self.channel.open_json(body)

    async def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.writer.close()
            await self.writer.wait_closed()
        except (OSError, ConnectionError, asyncio.CancelledError):
            pass


async def run_session(conn, engine, on_command=None, on_event=None, outbox=None, cfg=conf.get):
    """Sync, deliver commands and keep the link alive until it closes. Never raises."""
    emit = on_event or (lambda *a, **k: None)
    keepalive = float(cfg("keepalive_s"))
    idle = float(cfg("idle_timeout_s"))
    resync = float(cfg("resync_interval_s"))
    last_rx = last_manifest = time.monotonic()
    applied_total = 0
    try:
        await conn.send(engine.manifest_msg())
        for item in (outbox.pending(conn.peer_id) if outbox else []):
            await conn.send({"type": "cmd", "id": item["id"], "cmd": item["cmd"]})
        while not conn.closed:
            try:
                msg = await asyncio.wait_for(conn.recv(), timeout=keepalive)
            except asyncio.TimeoutError:
                now = time.monotonic()
                if now - last_rx > idle:
                    break
                await conn.send({"type": "ping"})
                if now - last_manifest > resync:
                    last_manifest = now
                    await conn.send(engine.manifest_msg())
                continue
            last_rx = time.monotonic()
            t = msg.get("type")
            if t == "manifest":
                for out in await asyncio.get_running_loop().run_in_executor(None, engine.answer, msg):
                    await conn.send(out)
            elif t == "records":
                applied, rejected = await asyncio.get_running_loop().run_in_executor(None, engine.receive, msg)
                applied_total += applied
                if applied:
                    emit("changed", peer=conn.peer_id, kind=msg.get("kind"), applied=applied)
                if rejected:
                    diag.record("sync.rejected", ValueError("records rejected"), quiet=True, n=rejected)
            elif t == "sync_end":
                conn.synced_at = time.time()
                emit("synced", peer=conn.peer_id, applied=applied_total)
                applied_total = 0
            elif t == "cmd":
                cid = msg.get("id") if isinstance(msg.get("id"), str) else ""
                try:
                    cmd = validate_command(msg.get("cmd"), cfg)
                except CommandError:
                    await conn.send({"type": "ack", "id": cid, "ok": False})
                    continue
                await conn.send({"type": "ack", "id": cid, "ok": True})
                if on_command:
                    try:
                        on_command(conn.peer_id, cmd)
                    except Exception as e:          # noqa: BLE001 - a bad handler must not drop sync
                        diag.record("sync.on_command", e, type=cmd.get("type"))
            elif t == "ack":
                if outbox and isinstance(msg.get("id"), str):
                    outbox.done(msg["id"])
            elif t == "ping":
                await conn.send({"type": "pong"})
            elif t == "bye":
                break
    except (asyncio.IncompleteReadError, ConnectionError, OSError, FrameError, C.CryptoError, P.HandshakeError):
        pass                                        # peer went away or sent garbage: just close
    except Exception as e:                          # noqa: BLE001
        diag.record("sync.session", e, quiet=True)
    finally:
        await conn.close()


class SyncServer:
    """Laptop listener. Accepts phones in pair mode (with the live QR secret) or session mode
    (pinned key). One live connection per peer; a newer one replaces the older."""

    def __init__(self, identity, peers, pairing, engine, outbox=None, on_command=None, on_event=None,
                 cfg=conf.get, clock=time.time):
        self.identity, self.peers, self.pairing, self.engine = identity, peers, pairing, engine
        self.outbox, self.on_command, self.on_event, self.cfg, self.clock = outbox, on_command, on_event, cfg, clock
        self.connections = {}
        self._server = None
        self._tasks = set()

    def _emit(self, kind, **data):
        if self.on_event:
            try:
                self.on_event(kind, **data)
            except Exception as e:                  # noqa: BLE001
                diag.record("sync.on_event", e, quiet=True)

    async def start(self, host=None, port=None):
        self._server = await asyncio.start_server(self._handle, host or self.cfg("bind_host"),
                                                  self.cfg("port") if port is None else port)
        return self._server.sockets[0].getsockname()[1]

    async def stop(self):
        for c in list(self.connections.values()):
            try:
                await c.send({"type": "bye"})
            except Exception:                       # noqa: BLE001
                pass
            await c.close()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    async def _handshake(self, reader, writer):
        maxb = int(self.cfg("max_frame_bytes"))
        used = {}

        def resolve(mode, client_id, client_pk):
            if mode == "pair":
                psk = self.pairing.active()
                if psk is None:
                    raise P.HandshakeError("no pairing in progress")
                used["psk"] = psk
                return psk
            pinned = self.peers.public_key(client_id)
            if pinned is None or not C.equal(pinned, client_pk):
                raise P.HandshakeError("unknown device")
            return None

        hs = P.ServerHandshake(self.identity.private_key, self.identity.device_id, self.identity.name, resolve)
        m1 = await read_frame(reader, maxb)
        m2 = hs.read_message1(m1)
        psk = used.get("psk")
        await write_frame(writer, m2)
        await write_frame(writer, hs.message3())
        try:
            hs.read_message4(await read_frame(reader, maxb))
        except P.HandshakeError:
            if hs.mode == "pair":
                self.pairing.failed()
            raise
        if hs.mode == "pair":
            if not self.pairing.consume(psk):
                raise P.HandshakeError("pairing secret expired")
            self.peers.add(hs.client_id, hs.client_name, hs.client_static, self.clock())
            self._emit("paired", peer=hs.client_id, name=hs.client_name)
        return hs

    async def _handle(self, reader, writer):
        try:
            hs = await asyncio.wait_for(self._handshake(reader, writer), float(self.cfg("handshake_timeout_s")))
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, OSError, FrameError,
                P.HandshakeError, C.CryptoError):
            try:
                writer.close()
            except OSError:
                pass
            return
        conn = Connection(reader, writer, hs.channel(), hs.client_id, hs.client_name, self.cfg)
        old = self.connections.get(conn.peer_id)
        if old:
            await old.close()
        self.connections[conn.peer_id] = conn
        self.peers.seen(conn.peer_id, conn.host, self.clock())
        self._emit("connected", peer=conn.peer_id)
        try:
            await run_session(conn, self.engine, self.on_command, self.on_event, self.outbox, self.cfg)
        finally:
            if self.connections.get(conn.peer_id) is conn:
                del self.connections[conn.peer_id]
            self._emit("disconnected", peer=conn.peer_id)

    async def send_command(self, peer_id, cmd):
        """Deliver now if connected, else queue in the outbox. Returns "sent" | "queued"."""
        cmd = validate_command(cmd, self.cfg)
        item = self.outbox.add(peer_id, cmd) if self.outbox else {"id": "", "cmd": cmd}
        conn = self.connections.get(peer_id)
        if conn and not conn.closed:
            try:
                await conn.send({"type": "cmd", "id": item["id"], "cmd": cmd})
                return "sent"
            except (ConnectionError, OSError):
                pass
        return "queued"

    async def sync_now(self):
        n = 0
        for c in list(self.connections.values()):
            try:
                await c.send(self.engine.manifest_msg())
                n += 1
            except (ConnectionError, OSError):
                pass
        return n

    async def drop(self, peer_id):
        c = self.connections.pop(peer_id, None)
        if c:
            await c.close()


async def connect(host, port, identity, server_pk, mode="session", psk=None, expect_server_id=None, cfg=conf.get):
    """Client side: open a TCP connection and run the handshake. Returns a Connection."""
    maxb = int(cfg("max_frame_bytes"))
    reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), float(cfg("handshake_timeout_s")))
    try:
        hs = P.ClientHandshake(identity.private_key, identity.device_id, identity.name, server_pk, mode, psk,
                               expect_server_id)

        async def go():
            await write_frame(writer, hs.message1())
            hs.read_message2(await read_frame(reader, maxb))
            hs.read_confirm(await read_frame(reader, maxb))
            await write_frame(writer, hs.message4())
        await asyncio.wait_for(go(), float(cfg("handshake_timeout_s")))
    except BaseException:
        writer.close()
        raise
    return Connection(reader, writer, hs.channel(), hs.server_id, hs.server_name, cfg)
