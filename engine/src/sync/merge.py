"""Last-writer-wins merge for synced records. Pure functions, no I/O.

A record is a dict with at least
  id (str), updated (ISO-8601; 'Z' or an offset, a time with no offset is read as UTC),
  device (str), deleted (bool, tombstone), schema_version (int).
Order: the later `updated` (millisecond precision) wins; on a tie the lexically greater
`device` wins; a full tie keeps the local copy. Deletes are ordinary records with
deleted=true, so they win or lose like any edit, and are purged after the retention window.
The Dart port (mobile/lib/sync/merge.dart) follows the same rules; both are checked against
core/conformance/sync/merge.json.
"""
import datetime as dt
import re

# One grammar for both runtimes (the Dart port uses the same expression):
# YYYY-MM-DD[T or space]HH:MM[:SS[.fraction]][Z | +HH:MM | +HHMM]; fraction digits past
# milliseconds are dropped; no offset = UTC. Out-of-range fields are errors, not rollovers.
_RX = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?"
                 r"(Z|z|[+-]\d{2}:?\d{2})?$")
SYNC_FIELDS = ("id", "updated", "device", "deleted", "schema_version")
_EPOCH = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)


def parse_ts(text):
    """ISO-8601 -> epoch milliseconds (int). Raises ValueError on anything else."""
    if not isinstance(text, str):
        raise ValueError("timestamp must be a string")
    m = _RX.match(text.strip())
    if not m:
        raise ValueError("not an ISO-8601 date-time")
    y, mo, d, h, mi = (int(m.group(i)) for i in range(1, 6))
    sec = int(m.group(6) or 0)
    ms = int((m.group(7) or "0")[:3].ljust(3, "0"))
    if h > 23 or mi > 59 or sec > 59:
        raise ValueError("time out of range")
    base = dt.datetime(y, mo, d, h, mi, sec, tzinfo=dt.timezone.utc)      # validates the date
    off = 0
    tz = m.group(8)
    if tz and tz not in ("Z", "z"):
        oh, om = int(tz[1:3]), int(tz[-2:])
        if oh > 23 or om > 59:
            raise ValueError("offset out of range")
        off = (oh * 60 + om) * (1 if tz[0] == "+" else -1)
    delta = base - _EPOCH
    return (delta.days * 86400 + delta.seconds - off * 60) * 1000 + ms


def fmt_ts(ms):
    """epoch ms -> 'YYYY-MM-DDTHH:MM:SS.mmmZ' (the form every Snapy device writes)."""
    d = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(milliseconds=int(ms))
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond // 1000:03d}Z"


def stamp(rec):
    return parse_ts(rec["updated"]), str(rec.get("device") or "")


def wins(a, b):
    """True when a should replace b."""
    ta, da = stamp(a)
    tb, db = stamp(b)
    return ta > tb or (ta == tb and da > db)


def valid(rec, now_ms=None, max_skew_ms=None):
    """Structural check of an incoming record; rejects far-future stamps (clock skew)."""
    if not isinstance(rec, dict):
        return False
    if not isinstance(rec.get("id"), str) or not rec["id"] or len(rec["id"]) > 200:
        return False
    if not isinstance(rec.get("device"), str) or not rec["device"]:
        return False
    if "deleted" in rec and not isinstance(rec["deleted"], bool):
        return False
    try:
        t = parse_ts(rec.get("updated"))
    except (ValueError, TypeError):
        return False
    if now_ms is not None and max_skew_ms is not None and t > now_ms + max_skew_ms:
        return False
    return True


def manifest(local):
    """{id: [updated, device]} for a dict of records (tombstones included)."""
    return {i: [r["updated"], r["device"]] for i, r in local.items()}


def to_send(local, peer_manifest):
    """Local records the peer lacks or holds an older version of, sorted by id."""
    out = []
    for i in sorted(local):
        r = local[i]
        theirs = peer_manifest.get(i)
        if theirs is None:
            out.append(r)
            continue
        try:
            if wins(r, {"updated": theirs[0], "device": theirs[1]}):
                out.append(r)
        except (ValueError, TypeError, IndexError, KeyError):
            out.append(r)                     # their entry is unreadable: ours is the good copy
    return out


def merge(local, incoming, now_ms=None, max_skew_ms=None):
    """Merge incoming records into a copy of `local` ({id: record}).

    Returns (merged, applied_ids, rejected_count): applied_ids are the ids whose incoming
    version won (sorted), in the order they should be written to the store.
    """
    merged = dict(local)
    applied, rejected = set(), 0
    for r in incoming:
        if not valid(r, now_ms, max_skew_ms):
            rejected += 1
            continue
        cur = merged.get(r["id"])
        if cur is None or wins(r, cur):
            merged[r["id"]] = r
            applied.add(r["id"])
    return merged, sorted(applied), rejected


def purge_tombstones(local, now_ms, retention_days):
    """Ids of tombstones older than the retention window (the caller drops them)."""
    cutoff = now_ms - int(retention_days) * 86400 * 1000
    out = []
    for i, r in local.items():
        if r.get("deleted"):
            try:
                if parse_ts(r["updated"]) < cutoff:
                    out.append(i)
            except (ValueError, TypeError, KeyError):
                out.append(i)
    return sorted(out)
