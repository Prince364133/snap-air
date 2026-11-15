"""Cross-device sync (laptop <-> phone over the LAN, end-to-end encrypted, no server).

protocol.py  handshake + encrypted frames      merge.py     pure last-writer-wins
records.py   adapters over the engine's stores  session.py   sync engine, commands, outbox
transport.py asyncio listener/client            discovery.py mDNS (zeroconf) / UDP beacon
pairing.py   identity, QR secret, pinned peers  service.py   SyncService (the engine's API)
"""
import os
import time


def build_engine_service(memory, tasks, notes, settings, activity_days=None, attention_days=None,
                         on_command=None, on_event=None, **kw):
    """SyncService wired to the engine's stores (main.py calls this when sync_enabled is on).

    activity_days / attention_days: optional callables returning day summaries
    [{"date": "YYYY-MM-DD", ...}] for this device.
    """
    from src import storage
    from src.sync import conf
    from src.sync.records import DaySummaryAdapter, ListStoreAdapter, SettingsProfileAdapter, SyncMeta
    from src.sync.service import SyncService

    folder = os.path.join(storage.data_dir(), "sync")
    os.makedirs(folder, exist_ok=True)
    meta = SyncMeta(os.path.join(folder, "meta.json"))
    # identity first: the adapters stamp records with this device id
    from src.sync.pairing import Identity
    ident = Identity.load_or_create(os.path.join(folder, "identity.json"), storage.read_json, storage.write_json,
                                    kw.get("key_get"), kw.get("key_set"))
    dev = ident.device_id

    def now_ms():
        return int(time.time() * 1000)

    keep = int(conf.get("day_summary_days"))
    adapters = [
        ListStoreAdapter("memory_fact", memory, meta, dev, now_ms, items_attr="memories",
                         local_only=("last_used", "uses"), native_updated=True),
        ListStoreAdapter("task", tasks, meta, dev, now_ms),
        ListStoreAdapter("note", notes, meta, dev, now_ms, insert_front=True),
        SettingsProfileAdapter(settings, meta, dev, now_ms),
        DaySummaryAdapter("activity_day", activity_days or (lambda: []), meta, dev, now_ms,
                          os.path.join(folder, "remote_activity_day.json"), keep_days=keep),
        DaySummaryAdapter("attention_day", attention_days or (lambda: []), meta, dev, now_ms,
                          os.path.join(folder, "remote_attention_day.json"), keep_days=keep),
    ]
    return SyncService(adapters, on_command=on_command, on_event=on_event, folder=folder, **kw)
