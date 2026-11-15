// The phone's real stores as lib/sync SyncStore kinds (same contract as
// engine/src/sync/records.py): memory_fact, task, note carry their sync fields natively
// (id/updated/device/deleted/schema_version, tombstones kept); settings_profile is one record
// ("profile") over the synced subset of settings.json; attention_day is this phone's Real Count
// days (id "<device>:<YYYY-MM-DD>") plus days received from peers; activity_day (desktop
// activity) is relayed: the phone has none of its own and keeps what peers send.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;

import '../sync/merge.dart';
import '../sync/sync_store.dart';
import 'core_data.dart';
import 'py.dart';
import 'realcount.dart';
import 'stores.dart';

String contentHash(Object? content) => hash.sha256.convert(utf8.encode(jsonEncode(_sortKeys(content)))).toString().substring(0, 32);

Object? _sortKeys(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sortKeys(v[k])};
  }
  if (v is List) return v.map(_sortKeys).toList();
  return v;
}

/// The sidecar for kinds whose store has no sync fields: `data/sync/meta.json` {kind: {id: {u,d,h,x}}}.
class SyncMeta {
  final String path;
  final Map<String, dynamic> data;
  SyncMeta(this.path) : data = Map<String, dynamic>.from((readJson(path) as Map?) ?? const {});
  Map<String, dynamic> kind(String k) => (data[k] ??= <String, dynamic>{}) as Map<String, dynamic>;
  void save() => writeJson(path, data);
}

class _ListSync implements SyncStore {
  @override
  final String kind;
  final Map<String, Map<String, dynamic>> Function() _records;
  final void Function(List<Map<String, dynamic>>) _apply;
  final void Function(Iterable<String>) _purge;
  final void Function()? onApplied;
  _ListSync(this.kind, this._records, this._apply, this._purge, {this.onApplied});

  @override
  Future<Map<String, Rec>> records() async => _records();
  @override
  Future<void> apply(List<Rec> records) async {
    _apply(records);
    onApplied?.call();
  }

  @override
  Future<void> purge(List<String> ids) async => _purge(ids);
}

SyncStore taskSyncStore(TaskStore s, {void Function()? onApplied}) =>
    _ListSync('task', s.syncRecords, s.syncApply, s.syncPurge, onApplied: onApplied);
SyncStore noteSyncStore(NoteStore s, {void Function()? onApplied}) =>
    _ListSync('note', s.syncRecords, s.syncApply, s.syncPurge, onApplied: onApplied);
SyncStore memorySyncStore(MemoryStore s, {void Function()? onApplied}) =>
    _ListSync('memory_fact', s.syncRecords, s.syncApply, s.syncPurge, onApplied: onApplied);

/// settings_profile: one record, id "profile", fields = the schema's non-sync properties.
class SettingsProfileSync implements SyncStore {
  static const recordId = 'profile';
  final Settings settings;
  final SyncMeta meta;
  final String device;
  final int version;
  final List<String> fields;
  final int Function() nowMs;

  SettingsProfileSync(CoreData core, this.settings, this.meta, this.device, {int Function()? nowMs})
      : version = core.schemaVersion('settings_profile'),
        fields = [for (final k in (core.schema('settings_profile')['properties'] as Map).keys) if (!syncFields.contains(k)) k as String],
        nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  @override
  String get kind => 'settings_profile';

  Map<String, dynamic> _content() => {for (final f in fields) if (settings.get(f) != null) f: deepCopy(settings.get(f))};

  @override
  Future<Map<String, Rec>> records() async {
    final m = meta.kind(kind);
    final content = _content();
    final h = contentHash(content);
    var e = m[recordId] as Map?;
    if (e == null || e['h'] != h) {
      e = m[recordId] = {'u': fmtTs(nowMs()), 'd': device, 'h': h, 'x': false, 'v': version};
      meta.save();
    }
    return {
      recordId: {...content, 'id': recordId, 'updated': e['u'], 'device': e['d'], 'deleted': false, 'schema_version': version},
    };
  }

  @override
  Future<void> apply(List<Rec> records) async {
    for (final r in records) {
      if (r['id'] != recordId || r['deleted'] == true) continue;
      settings.update({for (final f in fields) if (r.containsKey(f)) f: r[f]});
      meta.kind(kind)[recordId] = {'u': r['updated'], 'd': r['device'], 'h': contentHash(_content()), 'x': false, 'v': version};
      meta.save();
    }
  }

  @override
  Future<void> purge(List<String> ids) async {}
}

/// Day summaries: our own days come from [local]; peers' days are kept in `remote_KIND.json`.
class DaySummarySync implements SyncStore {
  @override
  final String kind;
  final List<Map<String, dynamic>> Function() local;
  final SyncMeta meta;
  final String device;
  final String remotePath;
  final int keepDays;
  final int version;
  final int Function() nowMs;
  final Map<String, dynamic> remote;

  DaySummarySync(CoreData core, this.kind, this.local, this.meta, this.device, this.remotePath,
      {this.keepDays = 30, int Function()? nowMs})
      : version = core.schemaVersion(kind),
        nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        remote = Map<String, dynamic>.from((readJson(remotePath) as Map?) ?? const {});

  @override
  Future<Map<String, Rec>> records() async {
    final m = meta.kind(kind);
    final out = <String, Rec>{};
    var dirty = false;
    List<Map<String, dynamic>> days;
    try {
      days = local();
    } catch (_) {
      days = const [];
    }
    for (final day in days) {
      final date = day['date'];
      if (date is! String) continue;
      final id = '$device:$date';
      final content = {for (final e in day.entries) if (!syncFields.contains(e.key)) e.key: e.value};
      final h = contentHash(content);
      var e = m[id] as Map?;
      if (e == null || e['h'] != h) {
        e = m[id] = {'u': fmtTs(nowMs()), 'd': device, 'h': h, 'x': false};
        dirty = true;
      }
      out[id] = {...content, 'id': id, 'updated': e['u'], 'device': e['d'], 'deleted': false, 'schema_version': version};
    }
    if (dirty) meta.save();
    for (final e in remote.entries) {
      out.putIfAbsent(e.key, () => Map<String, dynamic>.from(e.value as Map));
    }
    return out;
  }

  @override
  Future<void> apply(List<Rec> records) async {
    var n = 0;
    for (final r in records) {
      if ('${r['id']}'.startsWith('$device:')) continue; // our own days come from the counter
      remote['${r['id']}'] = deepCopy(r);
      n++;
    }
    final cutoff = isoDate(DateTime.fromMillisecondsSinceEpoch(nowMs()).subtract(Duration(days: keepDays)));
    remote.removeWhere((_, r) => '${(r as Map)['date'] ?? '9999'}'.compareTo(cutoff) < 0);
    if (n > 0) writeJson(remotePath, remote);
  }

  @override
  Future<void> purge(List<String> ids) async {}
}

/// This phone's Real Count days as attention_day summaries (the last [days] days with data).
List<Map<String, dynamic>> attentionDays(RealCount rc, {int days = 30, DateTime? today}) {
  final out = <Map<String, dynamic>>[];
  final t = today ?? DateTime.now();
  for (var i = 0; i < days; i++) {
    final d = DateTime(t.year, t.month, t.day - i);
    final date = isoDate(d);
    final hasDay = File('${rc.folder}/$date.json').existsSync() || File('${rc.folder}/usage-$date.json').existsSync();
    if (!hasDay) continue;
    final usage = (readJson('${rc.folder}/usage-$date.json') as Map?) ?? const {};
    final counter = (readJson('${rc.folder}/$date.json') as Map?) ?? const {};
    out.add({
      'date': date,
      'screen_ms': (usage['screen_ms'] as num?)?.toInt() ?? 0,
      'per_app_ms': usage['per_app_ms'] ?? const {},
      'opens': usage['opens'] ?? const {},
      'apps': counter['apps'] ?? const {},
      if (counter['nudges'] != null) 'nudges': counter['nudges'],
    });
  }
  return out;
}
