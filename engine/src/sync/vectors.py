"""Generate the interop vectors in core/conformance/sync/ from the Python implementation.

    engine/.venv/Scripts/python.exe -m src.sync.vectors      (run from engine/)

Deterministic: every key, nonce and secret is derived from a label, so re-running gives the
same files. The Dart tests (mobile/test/sync_test.dart) and engine/tests/test_sync.py both
check these files, which is what proves the two implementations interoperate.
"""
import json
import os
import sys

from src.sync import crypto as C
from src.sync import merge as M
from src.sync import protocol as P

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OUT = os.path.join(ROOT, "core", "conformance", "sync")


def det(label, n=32):
    return C.sha256(b"snapy-sync-vectors/" + label.encode())[:n]


def hx(b):
    return b.hex()


def handshake_case(name, mode):
    cs, ce, ss_, se_ = det(name + "/client-static"), det(name + "/client-eph"), det(name + "/server-static"), \
        det(name + "/server-eph")
    cn, sn = det(name + "/client-nonce", 16), det(name + "/server-nonce", 16)
    psk = det(name + "/pairing-secret") if mode == "pair" else None
    cid, cname = "android-3f9c2a71be", "Priya\u2019s Pixel \u0928\u092e\u0938\u094d\u0924\u0947"
    sid, sname = "windows-a1b2c3d4e5", "DESKTOP-SNAPY"
    S_c = C.public_key(cs)

    def resolve(m, i, pk):
        assert pk == S_c
        return psk

    cli = P.ClientHandshake(cs, cid, cname, C.public_key(ss_), mode, psk, sid, eph_priv=ce, nonce=cn)
    srv = P.ServerHandshake(ss_, sid, sname, resolve, eph_priv=se_, nonce=sn)
    m1 = cli.message1()
    m2 = srv.read_message1(m1)
    cli.read_message2(m2)
    m3 = srv.message3()
    cli.read_confirm(m3)
    m4 = cli.message4()
    srv.read_message4(m4)
    assert cli.keys == srv.keys
    k = cli.keys
    E_s, E_c, S_s = C.public_key(se_), C.public_key(ce), C.public_key(ss_)
    return {
        "name": name, "mode": mode,
        "client": {"id": cid, "name": cname, "static_priv": hx(cs), "static_pub": hx(S_c), "eph_priv": hx(ce),
                   "eph_pub": hx(E_c), "nonce": hx(cn)},
        "server": {"id": sid, "name": sname, "static_priv": hx(ss_), "static_pub": hx(S_s), "eph_priv": hx(se_),
                   "eph_pub": hx(E_s), "nonce": hx(sn)},
        "psk": hx(psk) if psk else None,
        "psk_b64u": C.b64u(psk) if psk else None,
        "m1": m1.decode("utf-8"), "m2": m2.decode("utf-8"), "m3": m3.decode("utf-8"), "m4": m4.decode("utf-8"),
        "th": hx(cli.th),
        "dh": {"ee": hx(C.dh(ce, E_s)), "es": hx(C.dh(ce, S_s)), "se": hx(C.dh(cs, E_s)), "ss": hx(C.dh(cs, S_s))},
        "salt": hx(P.salt_for(psk)),
        "keys": {"c2s": hx(k["c2s"]), "s2c": hx(k["s2c"]), "mk_c": hx(k["mk_c"]), "mk_s": hx(k["mk_s"])},
        "wrong_psk_m3_differs": mode == "pair",
    }


def frames(keys):
    c2s, s2c = bytes.fromhex(keys["c2s"]), bytes.fromhex(keys["s2c"])
    client = P.Channel(c2s, s2c)
    msgs_c = [{"type": "manifest", "kinds": {"task": {"a1": ["2026-11-15T09:30:00.000Z", "android-3f9c2a71be"]}}},
              {"type": "cmd", "id": "c1", "cmd": {"type": "note", "text": "Buy milk \u2615 \u0926\u0942\u0927"}},
              {"type": "ping"}]
    msgs_s = [{"type": "sync_end", "sent": 0}, {"type": "ack", "id": "c1", "ok": True}]
    server = P.Channel(s2c, c2s)
    out_c = []
    for m in msgs_c:
        pt = P.encode_json(m)
        out_c.append({"plaintext": pt.decode("utf-8"), "frame": hx(client.seal(pt))})
    out_s = []
    for m in msgs_s:
        pt = P.encode_json(m)
        out_s.append({"plaintext": pt.decode("utf-8"), "frame": hx(server.seal(pt))})
    first = bytes.fromhex(out_c[0]["frame"])
    tampered = bytearray(first)
    tampered[20] ^= 0x01
    bad_ctr = bytearray(first)
    bad_ctr[7] = 0x05                               # counter field says 5
    return {"c2s": out_c, "s2c": out_s,
            "negative": [
                {"name": "tampered ciphertext", "direction": "c2s", "expect_ctr": 0, "frame": hx(bytes(tampered))},
                {"name": "counter skips ahead (replay/reorder)", "direction": "c2s", "expect_ctr": 0,
                 "frame": hx(bytes(bad_ctr))},
                {"name": "replay of frame 0 after it was accepted", "direction": "c2s", "expect_ctr": 1,
                 "frame": out_c[0]["frame"]},
                {"name": "frame for the other direction", "direction": "s2c", "expect_ctr": 0,
                 "frame": out_c[0]["frame"]},
                {"name": "too short", "direction": "c2s", "expect_ctr": 0, "frame": "0000000000000000"},
            ]}


def r(i, updated, device, deleted=False, **extra):
    return {"id": i, "updated": updated, "device": device, "deleted": deleted, "schema_version": 1, **extra}


A, W = "android-3f9c2a71be", "windows-a1b2c3d4e5"
NOW = "2026-11-15T12:00:00.000Z"


def merge_cases():
    cases = [
        ("remote newer wins", [r("t1", "2026-11-15T09:00:00.000Z", W, title="old")],
         [r("t1", "2026-11-15T10:00:00.000Z", A, title="new")]),
        ("local newer kept", [r("t1", "2026-11-15T11:00:00.000Z", W, title="mine")],
         [r("t1", "2026-11-15T10:00:00.000Z", A, title="theirs")]),
        ("new record added", [], [r("n1", "2026-11-15T10:00:00.000Z", A, text="hi")]),
        ("tie broken by greater device id", [r("t1", "2026-11-15T10:00:00.000Z", A, title="android")],
         [r("t1", "2026-11-15T10:00:00.000Z", W, title="windows")]),
        ("tie, local device greater keeps local", [r("t1", "2026-11-15T10:00:00.000Z", W, title="windows")],
         [r("t1", "2026-11-15T10:00:00.000Z", A, title="android")]),
        ("full tie keeps local", [r("t1", "2026-11-15T10:00:00.000Z", W, title="L")],
         [r("t1", "2026-11-15T10:00:00.000Z", W, title="R")]),
        ("newer tombstone deletes", [r("t1", "2026-11-15T09:00:00.000Z", W, title="x")],
         [r("t1", "2026-11-15T09:30:00.000Z", A, deleted=True)]),
        ("older tombstone loses to edit", [r("t1", "2026-11-15T10:00:00.000Z", W, title="edited")],
         [r("t1", "2026-11-15T09:30:00.000Z", A, deleted=True)]),
        ("newer edit resurrects over tombstone", [r("t1", "2026-11-15T09:00:00.000Z", W, deleted=True)],
         [r("t1", "2026-11-15T09:30:00.000Z", A, title="back")]),
        ("tombstone vs tombstone tie by device", [r("t1", "2026-11-15T09:00:00.000Z", A, deleted=True)],
         [r("t1", "2026-11-15T09:00:00.000Z", W, deleted=True)]),
        ("offsets compare by instant", [r("t1", "2026-11-15T15:00:00+05:30", W, title="ist 09:30Z")],
         [r("t1", "2026-11-15T09:31:00Z", A, title="09:31Z")]),
        ("no-offset time is UTC", [r("t1", "2026-11-15T09:31:00", W, title="naive 09:31Z")],
         [r("t1", "2026-11-15T15:00:00+05:30", A, title="09:30Z")]),
        ("millisecond precision", [r("t1", "2026-11-15T09:00:00.001Z", W, title="L")],
         [r("t1", "2026-11-15T09:00:00.002Z", A, title="R")]),
        ("sub-millisecond digits ignored (tie -> device)", [r("t1", "2026-11-15T09:00:00.0019Z", W, title="L")],
         [r("t1", "2026-11-15T09:00:00.001Z", A, title="R")]),
        ("far-future record rejected", [r("t1", "2026-11-15T09:00:00.000Z", W, title="L")],
         [r("t1", "2026-11-20T09:00:00.000Z", A, title="future")]),
        ("malformed records rejected",
         [], [{"id": "", "updated": "2026-11-15T09:00:00Z", "device": A},
              {"id": "x1", "updated": "yesterday", "device": A},
              {"id": "x2", "updated": "2026-11-15T09:00:00Z", "device": ""},
              {"id": "x3", "updated": "2026-11-15T09:00:00Z", "device": A, "deleted": "yes"},
              r("ok", "2026-11-15T09:00:00.000Z", A, title="valid")]),
        ("batch with duplicate ids keeps the newest",
         [], [r("d1", "2026-11-15T09:00:00.000Z", A, title="first"),
              r("d1", "2026-11-15T09:05:00.000Z", A, title="second"),
              r("d1", "2026-11-15T09:01:00.000Z", W, title="third")]),
    ]
    out = []
    now_ms = M.parse_ts(NOW)
    for name, local, incoming in cases:
        merged, applied, rejected = M.merge({x["id"]: x for x in local}, incoming, now_ms, 86400 * 1000)
        out.append({"name": name, "now": NOW, "max_skew_s": 86400, "local": local, "incoming": incoming,
                    "expect": {"applied": applied, "rejected": rejected,
                               "merged": {i: merged[i] for i in sorted(merged)}}})
    return out


def to_send_cases():
    local = {x["id"]: x for x in [r("a", "2026-11-15T10:00:00.000Z", W, title="a"),
                                  r("b", "2026-11-15T09:00:00.000Z", W, title="b"),
                                  r("c", "2026-11-15T09:00:00.000Z", W, deleted=True),
                                  r("d", "2026-11-15T09:00:00.000Z", W, title="d"),
                                  r("e", "2026-11-15T09:00:00.000Z", A, title="e")]}
    peer = {"a": ["2026-11-15T09:00:00.000Z", A], "b": ["2026-11-15T10:00:00.000Z", A],
            "d": ["2026-11-15T09:00:00.000Z", A], "e": ["2026-11-15T09:00:00.000Z", A],
            "z": ["2026-11-15T09:00:00.000Z", A]}
    sent = [x["id"] for x in M.to_send(local, peer)]
    return [{"name": "send what the peer lacks or has older", "local": list(local.values()), "peer_manifest": peer,
             "expect_ids": sent}]


def purge_cases():
    local = [r("old", "2026-10-01T00:00:00.000Z", W, deleted=True), r("new", "2026-11-10T00:00:00.000Z", W, deleted=True),
             r("live", "2026-01-01T00:00:00.000Z", W, title="kept: not a tombstone")]
    ids = M.purge_tombstones({x["id"]: x for x in local}, M.parse_ts(NOW), 30)
    return [{"name": "drop tombstones older than 30 days", "now": NOW, "retention_days": 30, "local": local,
             "expect_ids": ids}]


def ts_cases():
    good = ["2026-11-15T09:30:00Z", "2026-11-15T09:30:00.123Z", "2026-11-15T09:30:00.123456Z",
            "2026-11-15T15:00:00+05:30", "2026-11-15T15:00:00.5+05:30", "2026-11-15T04:00:00-05:30",
            "2026-11-15T09:30:00", "2026-11-15T09:30", "1970-01-01T00:00:00Z", "2026-11-15 09:30:00+0530",
            "2028-02-29T23:59:59.999Z", " 2026-11-15T09:30:00Z "]
    bad = ["", "yesterday", "2026-13-01T00:00:00Z", "15/11/2026", "2026-11-15", "2026-02-30T00:00:00Z",
           "2026-11-15T24:00:00Z", "2026-11-15T09:60:00Z", "2026-11-15T09:30:60Z", "20261115T093000Z",
           "2026-11-15T09:30:00+25:00", "2026-11-15T09:30:00 Z"]
    return {"valid": [{"input": s, "ms": M.parse_ts(s)} for s in good],
            "invalid": bad,
            "format": [{"ms": M.parse_ts("2026-11-15T09:30:00.123Z"), "text": "2026-11-15T09:30:00.123Z"},
                       {"ms": 0, "text": "1970-01-01T00:00:00.000Z"}]}


def commands():
    ok = [{"type": "link", "url": "https://example.com/a?b=1"}, {"type": "note", "text": "Call mom"},
          {"type": "text", "text": "OTP-free text"}, {"type": "start_my_day"}, {"type": "focus", "minutes": 25},
          {"type": "resume_context", "name": "Snapy sync"}]
    bad = [{"type": "link", "url": "javascript:alert(1)"}, {"type": "link", "url": "file:///C:/x"},
           {"type": "note", "text": "   "}, {"type": "focus", "minutes": 0}, {"type": "focus", "minutes": 100000},
           {"type": "focus", "minutes": True}, {"type": "shell", "cmd": "rm -rf"}, {"type": "resume_context"}]
    return {"valid": ok, "invalid": bad}


def build():
    hs = [handshake_case("pair", "pair"), handshake_case("session", "session")]
    return {
        "handshake.json": {"_comment": "Handshake vectors: both runtimes must derive th/keys/macs from m1/m2 bytes "
                                       "exactly as given (see engine/src/sync/protocol.py).",
                           "prologue": P.PROLOGUE.decode(), "cases": hs},
        "frames.json": {"_comment": "Encrypted frames with the session keys of handshake case 'session'.",
                        "keys": hs[1]["keys"], **frames(hs[1]["keys"])},
        "merge.json": {"_comment": "LWW merge outcomes (engine/src/sync/merge.py).", "merge": merge_cases(),
                       "to_send": to_send_cases(), "purge": purge_cases(), "timestamps": ts_cases(),
                       "commands": commands()},
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, data in build().items():
        with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print("wrote", os.path.join(OUT, name))


if __name__ == "__main__":
    sys.exit(main())
