"""Record adapters: turn the engine's existing stores into synced records and back.

The stores (MemoryStore, TaskStore, NoteStore, Settings) don't carry sync metadata, so
each adapter keeps it in a sidecar, <data dir>/sync/meta.json:
  {kind: {id: {"u": updated, "d": device, "h": content hash, "x": deleted}}}
A local change is detected by the content hash: a new or changed item gets updated=now and
device=this device; an item that disappeared becomes a tombstone. Records written by a
peer store the peer's stamp, so they are not re-detected as local edits.

Interface every adapter implements (the Dart SyncStore mirrors it):
  kind                 wire name, matching core/schemas/<kind>.schema.json
  records()  -> {id: record}   all current records incl. tombstones (refreshes local changes)
  apply(list[record])          write winning records (already merged) into the store
  purge(ids)                   forget tombstones past the retention window
"""
import copy
import hashlib
import json
import threading

from src.sync import merge as M

KINDS = ("memory_fact", "task", "note", "settings_profile", "activity_day", "attention_day")


def schema_version(kind):
    try:
        from src import core_loader
        return int(core_loader.schema(kind).get("x-schema-version", 1))
    except Exception:            # noqa: BLE001 - schema missing: version 1
        return 1


def content_hash(content):
    raw = json.dumps(content, sort_keys=True, ensure_ascii=False, separators=(",", ":"), default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


class SyncMeta:
    """The sidecar file. `read`/`write` default to src.storage JSON helpers."""

    def __init__(self, path, read=None, write=None):
        if read is None or write is None:
            from src import storage
            read, write = read or storage.read_json, write or storage.write_json
        self.path, self._read, self._write = path, read, write
        self.lock = threading.RLock()
        data = self._read(path, {}) or {}
        self.data = data if isinstance(data, dict) else {}

    def kind(self, kind):
        return self.data.setdefault(kind, {})

    def save(self):
        with self.lock:
            self._write(self.path, self.data)


class Adapter:
    kind = ""

    def records(self):
        raise NotImplementedError

    def apply(self, recs):
        raise NotImplementedError

    def purge(self, ids):
        raise NotImplementedError


class MemoryAdapter(Adapter):
    """In-memory store for tests and for peers that only relay (implements the full contract)."""

    def __init__(self, kind, recs=None):
        self.kind = kind
        self.items = {r["id"]: r for r in (recs or [])}

    def records(self):
        return copy.deepcopy(self.items)

    def apply(self, recs):
        for r in recs:
            self.items[r["id"]] = copy.deepcopy(r)

    def purge(self, ids):
        for i in ids:
            self.items.pop(i, None)


class ListStoreAdapter(Adapter):
    """A store holding a list of dicts with an "id" (TaskStore.items, NoteStore.items,
    MemoryStore.memories) behind store.lock, persisted by store._save().

    local_only: fields that stay on this device (not sent, kept on apply), e.g. memory
    usage counters that change on every read.
    native_updated: the store's own "updated" field (local time, seconds): rewritten from
    the synced stamp on apply so the store's own logic keeps working.
    """

    def __init__(self, kind, store, meta, device_id, now_ms, items_attr="items", local_only=(),
                 native_updated=False, insert_front=False):
        self.kind, self.store, self.meta, self.device_id, self.now_ms = kind, store, meta, device_id, now_ms
        self.items_attr, self.local_only = items_attr, tuple(local_only)
        self.native_updated, self.insert_front = native_updated, insert_front
        self.version = schema_version(kind)

    def _items(self):
        return getattr(self.store, self.items_attr)

    def _content(self, item):
        skip = set(M.SYNC_FIELDS) | set(self.local_only)
        return {k: v for k, v in item.items() if k not in skip}

    def _wire(self, i, m, item):
        base = {"id": i, "updated": m["u"], "device": m["d"], "deleted": bool(m.get("x")),
                "schema_version": int(m.get("v") or self.version)}
        if m.get("x") or item is None:
            return base
        return {**copy.deepcopy(self._content(item)), **base}

    def records(self):
        out = {}
        with self.store.lock, self.meta.lock:
            meta = self.meta.kind(self.kind)
            now = M.fmt_ts(self.now_ms())
            seen, dirty = set(), False
            for item in self._items():
                i = item.get("id")
                if not isinstance(i, str) or not i:
                    continue
                seen.add(i)
                h = content_hash(self._content(item))
                m = meta.get(i)
                if m is None or m.get("x") or m.get("h") != h:
                    m = meta[i] = {"u": now, "d": self.device_id, "h": h, "x": False, "v": self.version}
                    dirty = True
                out[i] = self._wire(i, m, item)
            for i, m in meta.items():
                if i in seen:
                    continue
                if not m.get("x"):              # deleted locally since the last look
                    m.update({"u": now, "d": self.device_id, "x": True, "h": ""})
                    dirty = True
                out[i] = self._wire(i, m, None)
            if dirty:
                self.meta.save()
        return out

    def _store_item(self, rec, old):
        item = {k: copy.deepcopy(v) for k, v in rec.items() if k not in M.SYNC_FIELDS and k not in self.local_only}
        item["id"] = rec["id"]
        if old:
            for k in self.local_only:
                if k in old:
                    item[k] = old[k]
        if self.native_updated:
            import datetime as dt
            ms = M.parse_ts(rec["updated"])
            local = dt.datetime.fromtimestamp(ms / 1000).replace(microsecond=0)
            item["updated"] = local.isoformat(timespec="seconds")
        return item

    def apply(self, recs):
        if not recs:
            return 0
        n = 0
        with self.store.lock, self.meta.lock:
            meta = self.meta.kind(self.kind)
            items = self._items()
            index = {it.get("id"): k for k, it in enumerate(items)}
            removed = set()
            for rec in recs:
                i = rec["id"]
                pos = index.get(i)
                if rec.get("deleted"):
                    if pos is not None:
                        removed.add(i)
                    meta[i] = {"u": rec["updated"], "d": rec["device"], "h": "", "x": True,
                               "v": int(rec.get("schema_version") or self.version)}
                    n += 1
                    continue
                item = self._store_item(rec, items[pos] if pos is not None else None)
                if pos is not None:
                    items[pos] = item
                elif self.insert_front:
                    items.insert(0, item)
                    index = {it.get("id"): k for k, it in enumerate(items)}
                else:
                    items.append(item)
                    index[i] = len(items) - 1
                meta[i] = {"u": rec["updated"], "d": rec["device"], "h": content_hash(self._content(item)),
                           "x": False, "v": int(rec.get("schema_version") or self.version)}
                n += 1
            if removed:
                setattr(self.store, self.items_attr, [it for it in items if it.get("id") not in removed])
            self.store._save()
            self.meta.save()
        return n

    def purge(self, ids):
        with self.meta.lock:
            meta = self.meta.kind(self.kind)
            for i in ids:
                if meta.get(i, {}).get("x"):
                    meta.pop(i, None)
            self.meta.save()


class SettingsProfileAdapter(Adapter):
    """The synced subset of settings (core/schemas/settings_profile) as one record, id "profile"."""

    kind = "settings_profile"
    RECORD_ID = "profile"

    def __init__(self, settings, meta, device_id, now_ms, fields=None):
        self.settings, self.meta, self.device_id, self.now_ms = settings, meta, device_id, now_ms
        self.version = schema_version(self.kind)
        if fields is None:
            try:
                from src import core_loader
                props = core_loader.schema(self.kind)["properties"]
            except Exception:    # noqa: BLE001
                props = {}
            fields = [k for k in props if k not in M.SYNC_FIELDS]
        known = settings.as_dict()
        self.fields = [f for f in fields if f in known]
        self.lock = threading.RLock()

    def _content(self):
        d = self.settings.as_dict()
        return {k: d[k] for k in self.fields if k in d}

    def records(self):
        with self.lock, self.meta.lock:
            meta = self.meta.kind(self.kind)
            content = self._content()
            h = content_hash(content)
            m = meta.get(self.RECORD_ID)
            if m is None or m.get("h") != h:
                m = meta[self.RECORD_ID] = {"u": M.fmt_ts(self.now_ms()), "d": self.device_id, "h": h, "x": False,
                                            "v": self.version}
                self.meta.save()
            return {self.RECORD_ID: {**copy.deepcopy(content), "id": self.RECORD_ID, "updated": m["u"],
                                     "device": m["d"], "deleted": False, "schema_version": self.version}}

    def apply(self, recs):
        n = 0
        with self.lock, self.meta.lock:
            for rec in recs:
                if rec.get("id") != self.RECORD_ID or rec.get("deleted"):
                    continue
                self.settings.update({k: rec[k] for k in self.fields if k in rec})
                self.meta.kind(self.kind)[self.RECORD_ID] = {"u": rec["updated"], "d": rec["device"],
                                                             "h": content_hash(self._content()), "x": False,
                                                             "v": self.version}
                n += 1
            if n:
                self.meta.save()
        return n

    def purge(self, ids):
        pass


class DaySummaryAdapter(Adapter):
    """Day summaries (activity_day / attention_day): each device authors its own days,
    id "<device>:<YYYY-MM-DD>". Days from peers are kept in <data dir>/sync/remote_<kind>.json
    for the HUD/phone to show; they never touch the local trackers.

    provider() -> list of {"date": "YYYY-MM-DD", ...summary fields}
    """

    def __init__(self, kind, provider, meta, device_id, now_ms, remote_path, read=None, write=None, keep_days=30):
        if read is None or write is None:
            from src import storage
            read, write = read or storage.read_json, write or storage.write_json
        self.kind, self.provider, self.meta, self.device_id, self.now_ms = kind, provider, meta, device_id, now_ms
        self.remote_path, self._read, self._write, self.keep_days = remote_path, read, write, keep_days
        self.version = schema_version(kind)
        self.lock = threading.RLock()
        data = self._read(remote_path, {}) or {}
        self.remote = data if isinstance(data, dict) else {}

    def _local(self):
        try:
            days = self.provider() or []
        except Exception:        # noqa: BLE001 - a tracker problem must not stop sync
            days = []
        return {d["date"]: d for d in days if isinstance(d, dict) and isinstance(d.get("date"), str)}

    def records(self):
        out = {}
        with self.lock, self.meta.lock:
            meta = self.meta.kind(self.kind)
            dirty = False
            for date, day in self._local().items():
                i = f"{self.device_id}:{date}"
                content = {k: v for k, v in day.items() if k not in M.SYNC_FIELDS}
                h = content_hash(content)
                m = meta.get(i)
                if m is None or m.get("h") != h:
                    m = meta[i] = {"u": M.fmt_ts(self.now_ms()), "d": self.device_id, "h": h, "x": False}
                    dirty = True
                out[i] = {**copy.deepcopy(content), "id": i, "updated": m["u"], "device": m["d"], "deleted": False,
                          "schema_version": self.version}
            if dirty:
                self.meta.save()
            for i, r in self.remote.items():
                out.setdefault(i, r)
        return out

    def apply(self, recs):
        n = 0
        with self.lock:
            for r in recs:
                if str(r.get("id", "")).startswith(self.device_id + ":"):
                    continue            # our own days come from the tracker, never from a peer
                self.remote[r["id"]] = copy.deepcopy(r)
                n += 1
            self._trim()
            if n:
                self._write(self.remote_path, self.remote)
        return n

    def _trim(self):
        import datetime as dt
        cutoff = (dt.datetime.fromtimestamp(self.now_ms() / 1000) - dt.timedelta(days=self.keep_days)).strftime("%Y-%m-%d")
        for i in [i for i, r in self.remote.items() if str(r.get("date", "9999")) < cutoff]:
            self.remote.pop(i, None)

    def purge(self, ids):
        with self.lock:
            for i in ids:
                self.remote.pop(i, None)
            self._write(self.remote_path, self.remote)

    def peer_days(self):
        with self.lock:
            return sorted(self.remote.values(), key=lambda r: (r.get("device", ""), r.get("date", "")))
