"""Application messages carried inside the encrypted channel, and the sync engine.

Messages (JSON objects, "type" field):
  manifest  {"kinds": {kind: {id: [updated, device]}}}   sent by both sides after the handshake
            and again every sync.resync_interval_s; the receiver answers with
  records   {"kind", "records": [...]}                   the records the peer lacks or has older
            (batches of sync.batch_records), then
  sync_end  {"sent": n}                                  end of this side's answer to a manifest
  cmd       {"id", "cmd": {"type": ...}}                 send-to-laptop / send-to-phone
  ack       {"id"}                                       command received
  ping / pong / bye

Commands (cmd.type): link {url} | note {text} | text {text} | start_my_day |
  focus {minutes} | resume_context {name}.
"""
import json
import threading
import time
import uuid
from urllib.parse import urlparse

from src.sync import conf
from src.sync import merge as M


class CommandError(ValueError):
    pass


def validate_command(cmd, cfg=conf.get):
    """Normalised copy of a command, or CommandError. Unknown fields are dropped."""
    if not isinstance(cmd, dict):
        raise CommandError("command must be an object")
    t = cmd.get("type")
    if t not in cfg("commands"):
        raise CommandError("unknown command")
    limit = int(cfg("max_text_chars"))
    if t == "link":
        url = cmd.get("url")
        if not isinstance(url, str) or len(url) > limit:
            raise CommandError("link needs a url")
        p = urlparse(url.strip())
        if p.scheme not in ("http", "https") or not p.netloc:
            raise CommandError("only http(s) links")
        out = {"type": t, "url": url.strip()}
        if isinstance(cmd.get("title"), str):
            out["title"] = cmd["title"][:200]
        return out
    if t in ("note", "text"):
        text = cmd.get("text")
        if not isinstance(text, str) or not text.strip() or len(text) > limit:
            raise CommandError(t + " needs text")
        return {"type": t, "text": text}
    if t == "start_my_day":
        return {"type": t}
    if t == "focus":
        m = cmd.get("minutes")
        if isinstance(m, bool) or not isinstance(m, (int, float)) or not 1 <= int(m) <= int(cfg("max_focus_minutes")):
            raise CommandError("focus needs minutes")
        return {"type": t, "minutes": int(m)}
    if t == "resume_context":
        name = cmd.get("name")
        if not isinstance(name, str) or not name.strip() or len(name) > 200:
            raise CommandError("resume_context needs a name")
        return {"type": t, "name": name.strip()}
    raise CommandError("unknown command")


class SyncEngine:
    """Runs LWW sync over a set of adapters (records.Adapter)."""

    def __init__(self, adapters, now_ms=None, cfg=conf.get):
        self.adapters = {a.kind: a for a in adapters}
        self.now_ms = now_ms or (lambda: int(time.time() * 1000))
        self.cfg = cfg
        self.lock = threading.RLock()

    def manifest_msg(self):
        with self.lock:
            return {"type": "manifest", "kinds": {k: M.manifest(a.records()) for k, a in self.adapters.items()}}

    def answer(self, manifest_msg):
        """The records messages answering a peer's manifest, followed by sync_end."""
        kinds = manifest_msg.get("kinds") if isinstance(manifest_msg.get("kinds"), dict) else {}
        batch = max(1, int(self.cfg("batch_records")))
        out, sent = [], 0
        with self.lock:
            for k, a in self.adapters.items():
                theirs = kinds.get(k) if isinstance(kinds.get(k), dict) else {}
                recs = M.to_send(a.records(), theirs)
                sent += len(recs)
                for i in range(0, len(recs), batch):
                    out.append({"type": "records", "kind": k, "records": recs[i:i + batch]})
        out.append({"type": "sync_end", "sent": sent})
        return out

    def receive(self, records_msg):
        """Merge a records message. Returns (applied, rejected)."""
        a = self.adapters.get(records_msg.get("kind"))
        recs = records_msg.get("records")
        if a is None or not isinstance(recs, list):
            return 0, len(recs) if isinstance(recs, list) else 0
        now = self.now_ms()
        with self.lock:
            local = a.records()
            merged, applied, rejected = M.merge(local, recs, now, int(self.cfg("max_clock_skew_s")) * 1000)
            if applied:
                a.apply([merged[i] for i in applied])
        return len(applied), rejected

    def purge(self):
        now = self.now_ms()
        days = self.cfg("tombstone_days")
        n = 0
        with self.lock:
            for a in self.adapters.values():
                ids = M.purge_tombstones(a.records(), now, days)
                if ids:
                    a.purge(ids)
                    n += len(ids)
        return n


class Outbox:
    """Commands waiting for a peer that isn't connected: [{id, peer, cmd, ts}] in sync/outbox.json."""

    def __init__(self, path, read, write, clock=time.time, cfg=conf.get):
        self.path, self._read, self._write, self.clock, self.cfg = path, read, write, clock, cfg
        self.lock = threading.RLock()
        data = read(path, []) or []
        self.items = [x for x in data if isinstance(x, dict) and x.get("id") and x.get("peer")]

    def _trim(self):
        cutoff = self.clock() - float(self.cfg("outbox_ttl_s"))
        self.items = [x for x in self.items if x.get("ts", 0) >= cutoff][-int(self.cfg("outbox_max")):]

    def add(self, peer, cmd):
        with self.lock:
            item = {"id": uuid.uuid4().hex, "peer": peer, "cmd": cmd, "ts": self.clock()}
            self.items.append(item)
            self._trim()
            self._write(self.path, self.items)
            return item

    def pending(self, peer):
        with self.lock:
            self._trim()
            return [dict(x) for x in self.items if x["peer"] == peer]

    def done(self, cmd_id):
        with self.lock:
            before = len(self.items)
            self.items = [x for x in self.items if x["id"] != cmd_id]
            if len(self.items) != before:
                self._write(self.path, self.items)

    def drop_peer(self, peer):
        with self.lock:
            self.items = [x for x in self.items if x["peer"] != peer]
            self._write(self.path, self.items)


def encode(msg):
    return json.dumps(msg, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
