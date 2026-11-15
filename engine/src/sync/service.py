"""SyncService: the one object the engine talks to.

    svc = SyncService(adapters, on_command=fn(peer_id, cmd), on_event=fn(kind, **data))
    svc.start(); svc.pairing_qr_payload(); svc.paired_devices(); svc.unpair(id)
    svc.send_command(peer_id | None, {"type": "focus", "minutes": 25}); svc.sync_now(); svc.stop()

Runs its own asyncio loop on a daemon thread; every public method is thread-safe.
Files (all under <data dir>/sync/): identity.json (public), peers.json, meta.json,
outbox.json, remote_<kind>.json. The private key goes to secrets_store (DPAPI).
"""
import asyncio
import json
import os
import threading
import time

from src import diag
from src.sync import conf
from src.sync import crypto as C
from src.sync.discovery import Advertiser
from src.sync.pairing import Identity, PairingManager, PeerStore, lan_addresses
from src.sync.session import Outbox, SyncEngine, validate_command
from src.sync.transport import SyncServer


def _storage_io():
    from src import storage
    return storage.read_json, storage.write_json


class SyncService:
    def __init__(self, adapters, on_command=None, on_event=None, folder=None, key_get=None, key_set=None,
                 read=None, write=None, clock=time.time, cfg=conf.get, advertise=True, name=None):
        self.adapters = list(adapters)
        self.on_command, self.on_event = on_command, on_event
        if read is None or write is None:
            read, write = _storage_io()
        if folder is None:
            from src import storage
            folder = os.path.join(storage.data_dir(), "sync")
        os.makedirs(folder, exist_ok=True)
        self.folder, self._read, self._write = folder, read, write
        self.key_get, self.key_set, self.clock, self.cfg = key_get, key_set, clock, cfg
        self.advertise, self.name = advertise, name
        self.identity = Identity.load_or_create(self._p("identity.json"), read, write, key_get, key_set, name=name)
        self.peers = PeerStore(self._p("peers.json"), read, write)
        self.pairing = PairingManager(clock)
        self.outbox = Outbox(self._p("outbox.json"), read, write, clock, cfg)
        self.engine = SyncEngine(self.adapters, lambda: int(self.clock() * 1000), cfg)
        self.port = None
        self._loop = self._thread = self._server = self._adv = None
        self._ready = threading.Event()

    def _p(self, name):
        return os.path.join(self.folder, name)

    # ------------------------------------------------------------ lifecycle
    def start(self, port=None, host=None):
        if self._thread:
            return self.port
        self._loop = asyncio.new_event_loop()
        err = {}

        def run():
            asyncio.set_event_loop(self._loop)
            try:
                self._server = SyncServer(self.identity, self.peers, self.pairing, self.engine, self.outbox,
                                          self._command, self._event, self.cfg, self.clock)
                self.port = self._loop.run_until_complete(self._server.start(host, port))
            except Exception as e:                  # noqa: BLE001 - port taken etc.
                err["e"] = e
                self._ready.set()
                return
            self._ready.set()
            self._loop.call_later(3600, self._purge_tick)
            self._loop.run_forever()

        self._thread = threading.Thread(target=run, daemon=True, name="snapy-sync")
        self._thread.start()
        self._ready.wait(10)
        if "e" in err:
            self._thread = None
            raise err["e"]
        if self.advertise:
            self._adv = Advertiser(self.identity.device_id, self.port, lan_addresses(), self.cfg)
            self._adv.start()
        self.engine.purge()
        return self.port

    def stop(self):
        if self._adv:
            self._adv.stop()
            self._adv = None
        if not self._thread:
            return
        try:
            asyncio.run_coroutine_threadsafe(self._server.stop(), self._loop).result(5)
        except Exception as e:                      # noqa: BLE001
            diag.record("sync.stop", e, quiet=True)
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(5)
        self._thread = None
        self._ready.clear()

    @property
    def running(self):
        return self._thread is not None

    def _purge_tick(self):
        try:
            self.engine.purge()
        except Exception as e:                      # noqa: BLE001
            diag.record("sync.purge", e, quiet=True)
        self._loop.call_later(3600, self._purge_tick)

    def _run(self, coro, timeout=10):
        if not self._thread:
            coro.close()
            raise RuntimeError("sync is not running")
        return asyncio.run_coroutine_threadsafe(coro, self._loop).result(timeout)

    # ------------------------------------------------------------ callbacks
    def _command(self, peer_id, cmd):
        if self.on_command:
            self.on_command(peer_id, cmd)

    def _event(self, kind, **data):
        if self.on_event:
            self.on_event(kind, **data)

    # ------------------------------------------------------------ API
    def pairing_qr_payload(self):
        """Start a pairing window. Returns {"qr": <text to encode>, "expires_at", ...}.
        The text holds a one-time secret: show it only on screen, never log or store it."""
        if not self._thread:
            raise RuntimeError("sync is not running")
        secret, expires = self.pairing.start()
        hosts = lan_addresses()
        body = {"v": 1, "t": "snapy-pair", "id": self.identity.device_id, "name": self.identity.name,
                "hosts": hosts, "port": int(self.port), "secret": C.b64u(secret),
                "pk": C.b64u(self.identity.public_key), "exp": int(expires)}
        return {"qr": json.dumps(body, separators=(",", ":"), ensure_ascii=False), "expires_at": int(expires),
                "device_id": self.identity.device_id, "name": self.identity.name, "hosts": hosts, "port": self.port}

    def cancel_pairing(self):
        self.pairing.cancel()

    def paired_devices(self):
        live = set(self._server.connections) if self._server else set()
        return [{**p, "connected": p["id"] in live} for p in self.peers.public_list()]

    def unpair(self, peer_id):
        ok = self.peers.remove(peer_id)
        self.outbox.drop_peer(peer_id)
        if self._thread and self._server:
            try:
                self._run(self._server.drop(peer_id))
            except Exception as e:                  # noqa: BLE001
                diag.record("sync.unpair", e, quiet=True)
        return ok

    def send_command(self, peer_id, cmd):
        """peer_id None = every paired device. Returns {peer_id: "sent" | "queued"}."""
        cmd = validate_command(cmd, self.cfg)
        targets = [peer_id] if peer_id else [p["id"] for p in self.peers.public_list()]
        out = {}
        for t in targets:
            if not self.peers.get(t):
                continue
            if self._thread:
                out[t] = self._run(self._server.send_command(t, cmd))
            else:
                self.outbox.add(t, cmd)
                out[t] = "queued"
        return out

    def sync_now(self):
        """Re-exchange manifests with every connected device. Returns how many were asked."""
        return self._run(self._server.sync_now()) if self._thread else 0

    def status(self):
        return {"running": self.running, "device_id": self.identity.device_id, "name": self.identity.name,
                "port": self.port, "discovery": self._adv.mode if self._adv else None,
                "pairing_until": int(self.pairing.expires_at) or None, "devices": self.paired_devices()}
