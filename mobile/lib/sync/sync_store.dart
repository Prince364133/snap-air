/// Storage interfaces the sync layer needs. The Android data layer (lib/core_runtime)
/// implements [SyncStore] per record kind; [InMemorySyncStore] is the reference/test version.
library;

import 'dart:convert';

import 'merge.dart';

/// Wire kind names = `core/schemas/<kind>.schema.json`.
const syncKinds = ['memory_fact', 'task', 'note', 'settings_profile', 'activity_day', 'attention_day'];

/// One synced record type. Same contract as engine/src/sync/records.py Adapter:
/// * [records] returns every current record INCLUDING tombstones, each carrying
///   id, updated (ISO-8601 UTC, use fmtTs), device, deleted, schema_version.
///   A local edit must set updated = now and device = this device id; a local delete must
///   keep a tombstone {id, updated, device, deleted: true} instead of dropping the row.
/// * [apply] writes records that already won the LWW merge (store them as given,
///   keeping the peer's updated/device so they are not re-detected as local edits).
/// * [purge] forgets tombstones older than the retention window.
abstract class SyncStore {
  String get kind;
  Future<Map<String, Rec>> records();
  Future<void> apply(List<Rec> records);
  Future<void> purge(List<String> ids);
}

class InMemorySyncStore implements SyncStore {
  @override
  final String kind;
  final Map<String, Rec> items;

  InMemorySyncStore(this.kind, [List<Rec>? initial])
      : items = {for (final r in initial ?? const <Rec>[]) r['id'] as String: _copy(r)};

  static Rec _copy(Rec r) => Map<String, dynamic>.from(jsonDecode(jsonEncode(r)) as Map);

  @override
  Future<Map<String, Rec>> records() async => {for (final e in items.entries) e.key: _copy(e.value)};

  @override
  Future<void> apply(List<Rec> records) async {
    for (final r in records) {
      items[r['id'] as String] = _copy(r);
    }
  }

  @override
  Future<void> purge(List<String> ids) async {
    for (final i in ids) {
      items.remove(i);
    }
  }

  /// Helpers for local edits (what a real store does on every change).
  void localUpsert(Rec fields, String device, int nowMs) {
    items[fields['id'] as String] = {
      ...fields,
      'updated': fmtTs(nowMs),
      'device': device,
      'deleted': false,
      'schema_version': fields['schema_version'] ?? 1,
    };
  }

  void localDelete(String id, String device, int nowMs) {
    items[id] = {'id': id, 'updated': fmtTs(nowMs), 'device': device, 'deleted': true, 'schema_version': 1};
  }
}

/// Secret storage passed in by the app. On Android this MUST be backed by the Android
/// Keystore (e.g. an AES-GCM key in AndroidKeyStore wrapping the values, exposed through a
/// MethodChannel from Kotlin) - the sync layer never writes the private key anywhere else.
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// For tests only: keeps values in memory.
class InMemoryKeyStore implements SecureKeyStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
