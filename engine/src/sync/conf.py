"""Sync tunables. Every value can be changed without a rebuild through appdata
(src/data/app.json, core/rules or the user's %APPDATA%\\SnapAir\\app.json) under "sync.<key>".

The defaults below are the only place these numbers live in the engine; the Dart side keeps
the same keys in mobile/lib/sync/sync_config.dart.
"""

DEFAULTS = {
    "port": 47390,                    # TCP port of the laptop's sync listener
    "bind_host": "0.0.0.0",           # LAN-facing; the protocol authenticates every peer
    "service_type": "_snapy._tcp.local.",
    "beacon_group": "239.255.42.99",  # fallback discovery (no zeroconf): UDP multicast beacon
    "beacon_port": 47391,
    "pairing_ttl_s": 300,             # one-time pairing secret lifetime (5 minutes)
    "pairing_max_attempts": 5,        # failed pairing handshakes before the secret is burned
    "handshake_timeout_s": 10,
    "idle_timeout_s": 600,            # close a quiet session after this long
    "keepalive_s": 30,                # ping interval on an open session
    "resync_interval_s": 60,          # re-exchange manifests on an open session
    "max_frame_bytes": 4 * 1024 * 1024,
    "batch_records": 200,             # records per "records" message
    "tombstone_days": 30,             # keep deletions this long so they reach every device
    "max_clock_skew_s": 86400,        # records stamped further in the future are rejected
    "day_summary_days": 30,           # activity/attention day summaries kept from peers
    "outbox_ttl_s": 86400,            # undelivered send-to-phone commands expire after this
    "outbox_max": 50,
    "max_text_chars": 10000,          # note/text command payload limit
    "max_focus_minutes": 480,
    "commands": ["link", "note", "text", "start_my_day", "focus", "resume_context"],
}


def get(key):
    """sync.<key> from appdata, falling back to DEFAULTS (works without the engine's data files)."""
    default = DEFAULTS[key]
    try:
        from src import appdata
        v = appdata.get("sync." + key, default)
    except Exception:          # noqa: BLE001 - appdata unavailable (tests, tools)
        v = default
    return default if v is None else v
