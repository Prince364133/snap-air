"""Cross-device sync: protocol vectors (shared with the Dart tests), LWW merge, adapters,
pairing rules and a full loopback pair -> sync -> command session.

    engine/.venv/Scripts/python.exe -m unittest tests.test_sync -v      (from engine/)
"""
import asyncio
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("SNAP_AIR_DATA", os.path.join(tempfile.gettempdir(), "snapy_sync_tests"))

from src.sync import crypto as C  # noqa: E402
from src.sync import merge as M  # noqa: E402
from src.sync import protocol as P  # noqa: E402
from src.sync.pairing import Identity, PairingManager, PeerStore  # noqa: E402
from src.sync.records import ListStoreAdapter, MemoryAdapter, SettingsProfileAdapter, SyncMeta  # noqa: E402
from src.sync.session import CommandError, Outbox, SyncEngine, validate_command  # noqa: E402
from src.sync.transport import SyncServer, connect, run_session  # noqa: E402

VEC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "core", "conformance", "sync"))


def load(name):
    with open(os.path.join(VEC, name), encoding="utf-8") as f:
        return json.load(f)


def read_json(p, default=None):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(p, data):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(data, f)


class KeyBox:
    """Stand-in for secrets_store in tests (records what was stored)."""

    def __init__(self):
        self.d = {}

    def get(self, k):
        return self.d.get(k, "")

    def set(self, k, v):
        self.d[k] = v


class FakeStore:
    def __init__(self, items=None):
        self.items = items or []
        self.lock = threading.RLock()
        self.saves = 0

    def _save(self):
        self.saves += 1


class FakeSettings:
    def __init__(self, d):
        self.d = dict(d)

    def as_dict(self):
        return dict(self.d)

    def update(self, ch):
        self.d.update({k: v for k, v in ch.items() if k in self.d})


# --------------------------------------------------------------------------- vectors
class HandshakeVectors(unittest.TestCase):
    def test_cases(self):
        data = load("handshake.json")
        self.assertEqual(data["prologue"], P.PROLOGUE.decode())
        n = 0
        for case in data["cases"]:
            with self.subTest(case["name"]):
                c, s = case["client"], case["server"]
                for side in (c, s):
                    self.assertEqual(C.public_key(bytes.fromhex(side["static_priv"])).hex(), side["static_pub"])
                    self.assertEqual(C.public_key(bytes.fromhex(side["eph_priv"])).hex(), side["eph_pub"])
                psk = bytes.fromhex(case["psk"]) if case["psk"] else None
                m1, m2 = case["m1"].encode(), case["m2"].encode()
                th = P.transcript_hash(m1, m2)
                self.assertEqual(th.hex(), case["th"])
                ce, cs = bytes.fromhex(c["eph_priv"]), bytes.fromhex(c["static_priv"])
                E_s, S_s = bytes.fromhex(s["eph_pub"]), bytes.fromhex(s["static_pub"])
                dhs = [C.dh(ce, E_s), C.dh(ce, S_s), C.dh(cs, E_s), C.dh(cs, S_s)]
                self.assertEqual([d.hex() for d in dhs], [case["dh"][k] for k in ("ee", "es", "se", "ss")])
                self.assertEqual(P.salt_for(psk).hex(), case["salt"])
                keys = P.derive(*dhs, psk, th)
                self.assertEqual({k: v.hex() for k, v in keys.items()}, case["keys"])
                self.assertEqual(json.loads(case["m3"])["mac"], C.b64u(P.confirm_mac(keys["mk_s"], b"server", th)))
                self.assertEqual(json.loads(case["m4"])["mac"], C.b64u(P.confirm_mac(keys["mk_c"], b"client", th)))
                # the Python encoder reproduces the vector bytes exactly
                cli = P.ClientHandshake(cs, c["id"], c["name"], S_s, case["mode"], psk, s["id"], eph_priv=ce,
                                        nonce=bytes.fromhex(c["nonce"]))
                self.assertEqual(cli.message1(), m1)
                cli.read_message2(m2)
                cli.read_confirm(case["m3"].encode())
                self.assertEqual(cli.message4(), case["m4"].encode())
                if psk:                                    # a wrong secret can't verify the server's MAC
                    bad = P.ClientHandshake(cs, c["id"], c["name"], S_s, "pair", b"\x00" * 32, s["id"],
                                            eph_priv=ce, nonce=bytes.fromhex(c["nonce"]))
                    bad.message1()
                    bad.read_message2(m2)
                    with self.assertRaises(P.HandshakeError):
                        bad.read_confirm(case["m3"].encode())
                n += 1
        self.assertEqual(n, 2)


class FrameVectors(unittest.TestCase):
    def test_frames(self):
        data = load("frames.json")
        c2s, s2c = bytes.fromhex(data["keys"]["c2s"]), bytes.fromhex(data["keys"]["s2c"])
        server = P.Channel(s2c, c2s)            # receives c2s
        client = P.Channel(c2s, s2c)            # receives s2c
        for f in data["c2s"]:
            self.assertEqual(server.open(bytes.fromhex(f["frame"])).decode(), f["plaintext"])
        for f in data["s2c"]:
            self.assertEqual(client.open(bytes.fromhex(f["frame"])).decode(), f["plaintext"])
        # sealing reproduces the frames byte for byte
        fresh = P.Channel(c2s, s2c)
        self.assertEqual([fresh.seal(f["plaintext"].encode()).hex() for f in data["c2s"]],
                         [f["frame"] for f in data["c2s"]])
        for neg in data["negative"]:
            with self.subTest(neg["name"]):
                ch = P.Channel(b"\x00" * 32, c2s if neg["direction"] == "c2s" else s2c)
                ch.recv_ctr = neg["expect_ctr"]
                with self.assertRaises(C.CryptoError):
                    ch.open(bytes.fromhex(neg["frame"]))
                self.assertEqual(ch.recv_ctr, neg["expect_ctr"])


class MergeVectors(unittest.TestCase):
    def setUp(self):
        self.data = load("merge.json")

    def test_merge(self):
        for case in self.data["merge"]:
            with self.subTest(case["name"]):
                merged, applied, rejected = M.merge({x["id"]: x for x in case["local"]}, case["incoming"],
                                                    M.parse_ts(case["now"]), case["max_skew_s"] * 1000)
                self.assertEqual(applied, case["expect"]["applied"])
                self.assertEqual(rejected, case["expect"]["rejected"])
                self.assertEqual(merged, case["expect"]["merged"])

    def test_to_send_purge(self):
        for case in self.data["to_send"]:
            got = [x["id"] for x in M.to_send({x["id"]: x for x in case["local"]}, case["peer_manifest"])]
            self.assertEqual(got, case["expect_ids"])
        for case in self.data["purge"]:
            got = M.purge_tombstones({x["id"]: x for x in case["local"]}, M.parse_ts(case["now"]),
                                     case["retention_days"])
            self.assertEqual(got, case["expect_ids"])

    def test_timestamps(self):
        ts = self.data["timestamps"]
        for v in ts["valid"]:
            self.assertEqual(M.parse_ts(v["input"]), v["ms"], v["input"])
        for s in ts["invalid"]:
            with self.assertRaises(ValueError):
                M.parse_ts(s)
        for f in ts["format"]:
            self.assertEqual(M.fmt_ts(f["ms"]), f["text"])

    def test_commands(self):
        for c in self.data["commands"]["valid"]:
            self.assertEqual(validate_command(c)["type"], c["type"])
        for c in self.data["commands"]["invalid"]:
            with self.assertRaises(CommandError, msg=json.dumps(c)):
                validate_command(c)


# --------------------------------------------------------------------------- adapters
class Adapters(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.t = [1_794_735_000_000]
        self.meta = SyncMeta(os.path.join(self.dir, "meta.json"), read_json, write_json)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def now(self):
        return self.t[0]

    def test_detects_edits_and_deletes(self):
        store = FakeStore([{"id": "a", "title": "one", "done": False}])
        ad = ListStoreAdapter("task", store, self.meta, "windows-x", self.now)
        r1 = ad.records()["a"]
        self.assertEqual((r1["device"], r1["deleted"], r1["title"]), ("windows-x", False, "one"))
        self.t[0] += 1000
        self.assertEqual(ad.records()["a"]["updated"], r1["updated"])          # unchanged: same stamp
        store.items[0]["title"] = "two"
        self.assertGreater(M.parse_ts(ad.records()["a"]["updated"]), M.parse_ts(r1["updated"]))
        self.t[0] += 1000
        store.items.clear()
        tomb = ad.records()["a"]
        self.assertTrue(tomb["deleted"])
        self.assertNotIn("title", tomb)
        # persisted: a new adapter over the same sidecar still knows the tombstone
        ad2 = ListStoreAdapter("task", store, SyncMeta(os.path.join(self.dir, "meta.json"), read_json, write_json),
                               "windows-x", self.now)
        self.assertTrue(ad2.records()["a"]["deleted"])

    def test_apply_keeps_local_only_and_stamp(self):
        store = FakeStore([{"id": "m1", "text": "old", "uses": 7, "updated": "2026-11-15T09:00:00"}])
        ad = ListStoreAdapter("memory_fact", store, self.meta, "windows-x", self.now, items_attr="items",
                              local_only=("uses", "last_used"), native_updated=True)
        ad.records()
        rec = {"id": "m1", "updated": "2026-11-15T11:00:00.000Z", "device": "android-y", "deleted": False,
               "schema_version": 1, "text": "new"}
        ad.apply([rec, {**rec, "id": "m2", "text": "fresh"}])
        self.assertEqual(store.items[0]["text"], "new")
        self.assertEqual(store.items[0]["uses"], 7)
        self.assertNotIn("device", store.items[0])
        out = ad.records()
        self.assertEqual((out["m1"]["updated"], out["m1"]["device"]), (rec["updated"], "android-y"))
        self.assertEqual(out["m2"]["text"], "fresh")
        ad.apply([{"id": "m1", "updated": "2026-11-15T12:00:00.000Z", "device": "android-y", "deleted": True}])
        self.assertEqual([i["id"] for i in store.items], ["m2"])
        self.assertTrue(ad.records()["m1"]["deleted"])
        ad.purge(["m1"])
        self.assertNotIn("m1", ad.records())

    def test_settings_profile(self):
        s = FakeSettings({"agent_name": "Snapy", "voice_language": "en", "camera_index": 0})
        ad = SettingsProfileAdapter(s, self.meta, "windows-x", self.now, fields=["agent_name", "voice_language"])
        r = ad.records()["profile"]
        self.assertNotIn("camera_index", r)
        ad.apply([{**r, "agent_name": "Jarvis", "updated": "2026-11-16T00:00:00.000Z", "device": "android-y"}])
        self.assertEqual(s.d["agent_name"], "Jarvis")
        self.assertEqual(ad.records()["profile"]["device"], "android-y")


# --------------------------------------------------------------------------- pairing
class Pairing(unittest.TestCase):
    def test_secret_expiry_single_use_attempts(self):
        t = [1000.0]
        pm = PairingManager(lambda: t[0], ttl_s=300, max_attempts=3)
        s, exp = pm.start()
        self.assertEqual(exp, 1300.0)
        self.assertEqual(pm.active(), s)
        t[0] = 1300.0
        self.assertIsNone(pm.active())                       # expired after 5 minutes
        s, _ = pm.start()
        self.assertTrue(pm.consume(s))
        self.assertIsNone(pm.active())                       # single use
        self.assertFalse(pm.consume(s))
        s, _ = pm.start()
        for _ in range(3):
            pm.failed()
        self.assertIsNone(pm.active())                       # burned after failures

    def test_identity_key_not_in_json(self):
        d = tempfile.mkdtemp()
        try:
            box = KeyBox()
            p = os.path.join(d, "identity.json")
            ident = Identity.load_or_create(p, read_json, write_json, box.get, box.set, name="Laptop")
            with open(p, encoding="utf-8") as f:
                raw = f.read()
            self.assertNotIn(box.d["sync_static_key"], raw)
            self.assertNotIn(C.b64u(ident.private_key), repr(ident))
            again = Identity.load_or_create(p, read_json, write_json, box.get, box.set)
            self.assertEqual((again.device_id, again.public_key), (ident.device_id, ident.public_key))
            self.assertTrue(ident.device_id.startswith("windows-"))
        finally:
            shutil.rmtree(d, ignore_errors=True)


# --------------------------------------------------------------------------- loopback session
def ident(name):
    return Identity(name, name, C.new_private_key())


class Loopback(unittest.TestCase):
    """Real TCP on 127.0.0.1: pair with the QR secret, reconnect in session mode, sync both
    ways (incl. a tombstone), deliver commands in both directions, refuse strangers."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def p(self, n):
        return os.path.join(self.dir, n)

    def test_full_flow(self):
        asyncio.run(self._flow())

    async def _flow(self):
        laptop, phone = ident("windows-aaaa"), ident("android-bbbb")
        lap_tasks = MemoryAdapter("task", [
            {"id": "t1", "updated": "2026-11-15T09:00:00.000Z", "device": laptop.device_id, "deleted": False,
             "schema_version": 1, "title": "laptop task"},
            {"id": "t2", "updated": "2026-11-15T09:00:00.000Z", "device": laptop.device_id, "deleted": False,
             "schema_version": 1, "title": "will be deleted on phone"}])
        ph_tasks = MemoryAdapter("task", [
            {"id": "t2", "updated": "2026-11-15T10:00:00.000Z", "device": phone.device_id, "deleted": True,
             "schema_version": 1},
            {"id": "t3", "updated": "2026-11-15T10:00:00.000Z", "device": phone.device_id, "deleted": False,
             "schema_version": 1, "title": "phone task"}])
        now = lambda: M.parse_ts("2026-11-15T12:00:00.000Z")  # noqa: E731
        lap_engine, ph_engine = SyncEngine([lap_tasks], now), SyncEngine([ph_tasks], now)
        peers = PeerStore(self.p("peers.json"), read_json, write_json)
        pairing = PairingManager()
        outbox = Outbox(self.p("outbox.json"), read_json, write_json)
        got_lap, events = [], []
        server = SyncServer(laptop, peers, pairing, lap_engine, outbox, on_command=lambda p, c: got_lap.append((p, c)),
                            on_event=lambda k, **d: events.append(k))
        port = await server.start("127.0.0.1", 0)
        try:
            # no pairing window -> pair attempt refused
            with self.assertRaises(Exception):
                await connect("127.0.0.1", port, phone, laptop.public_key, "pair", b"\x01" * 32, laptop.device_id)
            # wrong secret -> refused, nothing pinned
            secret, _ = pairing.start()
            with self.assertRaises(Exception):
                c = await connect("127.0.0.1", port, phone, laptop.public_key, "pair", b"\x02" * 32, laptop.device_id)
            self.assertIsNone(peers.get(phone.device_id))
            # right secret -> paired
            conn = await connect("127.0.0.1", port, phone, laptop.public_key, "pair", secret, laptop.device_id)
            await conn.send({"type": "bye"})
            await conn.close()
            await asyncio.sleep(0.1)
            self.assertIsNotNone(peers.get(phone.device_id))
            self.assertIn("paired", events)
            # the secret was single use
            with self.assertRaises(Exception):
                await connect("127.0.0.1", port, ident("android-evil"), laptop.public_key, "pair", secret,
                              laptop.device_id)
            # an unpaired device can't open a session, even claiming a paired id
            impostor = Identity(phone.device_id, "x", C.new_private_key())
            with self.assertRaises(Exception):
                c = await connect("127.0.0.1", port, impostor, laptop.public_key, "session")
                await c.recv()
            # a client that pinned the wrong laptop key fails the handshake
            with self.assertRaises(Exception):
                await connect("127.0.0.1", port, phone, C.public_key(C.new_private_key()), "session")

            # queue a command while the phone is away
            self.assertEqual(await server.send_command(phone.device_id, {"type": "focus", "minutes": 25}), "queued")

            # session: sync both ways + commands
            got_phone = []
            conn = await connect("127.0.0.1", port, phone, laptop.public_key, "session", None, laptop.device_id)
            session = asyncio.create_task(run_session(conn, ph_engine, on_command=lambda p, c: got_phone.append(c)))
            for _ in range(100):
                if len(lap_tasks.items) == 3 and len(ph_tasks.items) == 3 and got_phone:
                    break
                await asyncio.sleep(0.05)
            await conn.send({"type": "cmd", "id": "x1", "cmd": {"type": "link", "url": "https://example.com"}})
            await conn.send({"type": "cmd", "id": "x2", "cmd": {"type": "link", "url": "javascript:1"}})
            self.assertEqual(await server.send_command(phone.device_id, {"type": "note", "text": "hi"}), "sent")
            for _ in range(100):
                if got_lap and len(got_phone) >= 2:
                    break
                await asyncio.sleep(0.05)
            self.assertEqual(lap_tasks.items, ph_tasks.items)
            self.assertTrue(lap_tasks.items["t2"]["deleted"])
            self.assertEqual(lap_tasks.items["t3"]["title"], "phone task")
            self.assertEqual(ph_tasks.items["t1"]["title"], "laptop task")
            self.assertEqual(got_phone[0], {"type": "focus", "minutes": 25})
            self.assertEqual(got_phone[1], {"type": "note", "text": "hi"})
            self.assertEqual(got_lap, [(phone.device_id, {"type": "link", "url": "https://example.com"})])
            await asyncio.sleep(0.1)
            self.assertEqual(outbox.pending(phone.device_id), [])            # acked -> removed
            self.assertIn("synced", events)
            await conn.send({"type": "bye"})
            await asyncio.wait_for(session, 5)
        finally:
            await server.stop()

    def test_replayed_frame_closes_session(self):
        asyncio.run(self._replay())

    async def _replay(self):
        laptop, phone = ident("windows-cccc"), ident("android-dddd")
        peers = PeerStore(self.p("peers2.json"), read_json, write_json)
        peers.add(phone.device_id, "p", phone.public_key)
        got = []
        server = SyncServer(laptop, peers, PairingManager(), SyncEngine([MemoryAdapter("task")]),
                            on_command=lambda p, c: got.append(c))
        port = await server.start("127.0.0.1", 0)
        try:
            conn = await connect("127.0.0.1", port, phone, laptop.public_key, "session")
            body = conn.channel.send_json({"type": "cmd", "id": "1", "cmd": {"type": "start_my_day"}})
            conn.writer.write(P.frame(body))
            conn.writer.write(P.frame(body))           # exact replay
            conn.writer.write(P.frame(conn.channel.send_json({"type": "cmd", "id": "2",
                                                              "cmd": {"type": "start_my_day"}})))
            await conn.writer.drain()
            await asyncio.sleep(0.3)
            self.assertEqual(len(got), 1)              # the replay killed the session before cmd 2
            self.assertNotIn(phone.device_id, server.connections)
            await conn.close()
        finally:
            await server.stop()


class RealStores(unittest.TestCase):
    """build_engine_service over the engine's real TaskStore / NoteStore / MemoryStore / Settings."""

    def test_real_stores_roundtrip(self):
        from src import storage
        from src.brain.memory import MemoryStore
        from src.config import Settings
        from src.life.notes import NoteStore
        from src.life.tasks import TaskStore
        from src.sync import build_engine_service
        d = tempfile.mkdtemp()
        old = os.environ.get("SNAP_AIR_DATA")
        os.environ["SNAP_AIR_DATA"] = d
        try:
            box = KeyBox()
            tasks, notes = TaskStore(storage.path("tasks.json")), NoteStore(storage.path("notes.json"))
            memory = MemoryStore(folder=os.path.join(d, "memory"))
            settings = Settings(os.path.join(d, "settings.json"))
            t = tasks.add("Pay rent")
            notes.add("Wifi password is on the fridge")
            memory.add("Prefers tea over coffee", category="preference", dedupe=False)
            svc = build_engine_service(memory, tasks, notes, settings, key_get=box.get, key_set=box.set,
                                       advertise=False)
            eng = svc.engine
            man = eng.manifest_msg()["kinds"]
            self.assertEqual(len(man["task"]), 1)
            self.assertEqual(len(man["note"]), 1)
            self.assertEqual(len(man["memory_fact"]), 1)
            self.assertIn("profile", man["settings_profile"])
            rec = eng.adapters["task"].records()[t["id"]]
            self.assertEqual(rec["device"], svc.identity.device_id)
            # a phone edit + a phone-created task + a phone delete of the note
            nid = notes.items[0]["id"]
            later = M.fmt_ts(M.parse_ts(rec["updated"]) + 60000)
            applied, rejected = eng.receive({"kind": "task", "records": [
                {**rec, "title": "Pay rent today", "updated": later, "device": "android-p"},
                {"id": "ph1", "title": "From phone", "remind_at": None, "done": False, "fired": False,
                 "created": "2026-11-15T09:00:00", "updated": later, "device": "android-p", "deleted": False,
                 "schema_version": 1}]})
            self.assertEqual((applied, rejected), (2, 0))
            eng.receive({"kind": "note", "records": [{"id": nid, "updated": later, "device": "android-p",
                                                      "deleted": True, "schema_version": 1}]})
            self.assertEqual(tasks.get(t["id"])["title"], "Pay rent today")
            self.assertEqual(tasks.get("ph1")["title"], "From phone")
            self.assertEqual(notes.items, [])
            # persisted to the stores' own files, without sync fields
            on_disk = storage.read_json(storage.path("tasks.json"))
            self.assertEqual({x["id"] for x in on_disk}, {t["id"], "ph1"})
            self.assertNotIn("device", on_disk[0])
            # the applied versions are not re-detected as local edits
            again = eng.adapters["task"].records()
            self.assertEqual(again[t["id"]]["device"], "android-p")
            self.assertTrue(eng.adapters["note"].records()[nid]["deleted"])
            # settings profile from the phone
            prof = eng.adapters["settings_profile"].records()["profile"]
            eng.receive({"kind": "settings_profile", "records": [{**prof, "agent_name": "Jarvis", "updated": later,
                                                                  "device": "android-p", "camera_index": 3}]})
            self.assertEqual(settings["agent_name"], "Jarvis")
            self.assertEqual(settings["camera_index"], 0)            # device-only setting untouched
            # no private key in any file in the data dir
            priv = box.d["sync_static_key"]
            for root, _, files in os.walk(d):
                for f in files:
                    with open(os.path.join(root, f), encoding="utf-8", errors="ignore") as fh:
                        self.assertNotIn(priv, fh.read(), f)
        finally:
            if old is None:
                os.environ.pop("SNAP_AIR_DATA", None)
            else:
                os.environ["SNAP_AIR_DATA"] = old
            shutil.rmtree(d, ignore_errors=True)


class ServiceSmoke(unittest.TestCase):
    """SyncService on its own thread: QR payload shape, pairing window, unpair (no mDNS)."""

    def test_service(self):
        from src.sync.service import SyncService
        d = tempfile.mkdtemp()
        box = KeyBox()
        svc = SyncService([MemoryAdapter("task")], folder=d, key_get=box.get, key_set=box.set, read=read_json,
                          write=write_json, advertise=False, name="Test laptop")
        try:
            port = svc.start(port=0, host="127.0.0.1")
            self.assertTrue(port)
            qr = svc.pairing_qr_payload()
            body = json.loads(qr["qr"])
            self.assertEqual(set(body), {"v", "t", "id", "name", "hosts", "port", "secret", "pk", "exp"})
            self.assertEqual(len(C.unb64u(body["secret"])), 32)
            self.assertEqual(C.unb64u(body["pk"]), svc.identity.public_key)
            self.assertEqual(body["port"], port)
            self.assertEqual(svc.paired_devices(), [])
            for name in os.listdir(d):                  # the secret is never written to disk
                with open(os.path.join(d, name), encoding="utf-8") as f:
                    self.assertNotIn(body["secret"], f.read())

            async def pair():
                phone = ident("android-eeee")
                c = await connect("127.0.0.1", port, phone, C.unb64u(body["pk"]), "pair", C.unb64u(body["secret"]),
                                  body["id"])
                await c.send({"type": "bye"})
                await c.close()
                return phone
            phone = asyncio.run(pair())
            import time
            time.sleep(0.2)
            self.assertEqual([p["id"] for p in svc.paired_devices()], [phone.device_id])
            self.assertEqual(svc.send_command(None, {"type": "start_my_day"}), {phone.device_id: "queued"})
            self.assertTrue(svc.unpair(phone.device_id))
            self.assertEqual(svc.paired_devices(), [])
        finally:
            svc.stop()
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
