// Snapy's local stores on Android: JSON files in <files>/snapy/ (the same layout the Python
// engine used under Chaquopy, so existing data is kept):
//   settings.json · tasks.json · notes.json · memory/{memories,profile}.json
//   memory/journal/DAY.json · memory/conversations/DAY.jsonl · realcount/…
// Records follow core/schemas (memory_fact, task, note): schema_version, id, updated, device,
// deleted (tombstones are kept so deletions sync). Unknown fields are preserved.
// Python reference: engine/src/life/tasks.py, life/notes.py, brain/memory.py, config.py.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../sync/merge.dart';
import 'core_data.dart';
import 'py.dart';
import 'rules.dart';

// ------------------------------------------------------------------ files
dynamic readJson(String path, [dynamic def]) {
  try {
    final f = File(path);
    if (!f.existsSync()) return def;
    return jsonDecode(f.readAsStringSync());
  } catch (_) {
    return def;
  }
}

/// Atomic write (tmp + rename), pretty-printed like the Python engine.
void writeJson(String path, dynamic data) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  final tmp = File('$path.tmp');
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  tmp.renameSync(path);
}

void appendJsonl(String path, Map<String, dynamic> row) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('${jsonEncode(row)}\n', mode: FileMode.append);
}

/// Injectable clock (tests).
typedef Clock = DateTime Function();

// ------------------------------------------------------------------ sync metadata
// `updated` is the sync stamp: ISO-8601 UTC with milliseconds (lib/sync/merge.dart fmtTs), the
// format the LAN sync compares; `created`/`remind_at` stay local times as in the Python stores.
String syncStamp(DateTime t) => fmtTs(t.millisecondsSinceEpoch);

/// A legacy local timestamp (no offset) -> the UTC sync stamp.
String _legacyStamp(Object? local, DateTime fallback) {
  final d = local is String ? parseIsoLocal(local) : null;
  return syncStamp(d ?? fallback);
}

/// Device id `android-HASH`, made once and kept in `data/device.json` (fallback when there is no sync identity).
String deviceId(String dataDir) {
  final p = '$dataDir/device.json';
  final d = readJson(p);
  if (d is Map && d['device'] is String) return d['device'] as String;
  final id = 'android-${randomHex(12)}';
  writeJson(p, {'device': id});
  return id;
}

class _RecordList {
  final String file;
  final String kind;
  final int schemaVersion;
  final String device;
  final Clock now;
  List<Map<String, dynamic>> items;

  _RecordList(this.file, this.kind, this.schemaVersion, this.device, this.now, {List<dynamic>? legacy})
      : items = [] {
    final raw = readJson(file) ?? legacy ?? [];
    items = [for (final r in raw as List) if (r is Map) Map<String, dynamic>.from(r)];
    var fixed = false;
    for (final r in items) {
      fixed = _ensure(r) || fixed;
    }
    if (fixed) save();
  }

  /// Older (Python/Chaquopy) records lack the sync fields: add them once.
  bool _ensure(Map<String, dynamic> r) {
    var changed = false;
    void put(String k, Object v) {
      if (!r.containsKey(k)) {
        r[k] = v;
        changed = true;
      }
    }

    put('schema_version', schemaVersion);
    put('id', randomHex(10));
    // the Python stores kept a local 'updated' (no offset): convert it to the UTC sync stamp
    if (r['updated'] is String && !RegExp(r'(Z|z|[+-]\d{2}:?\d{2})$').hasMatch(r['updated'] as String)) {
      r['updated'] = _legacyStamp(r['updated'], now());
      changed = true;
    }
    put('updated', _legacyStamp(r['created'], now()));
    put('device', device);
    put('deleted', false);
    return changed;
  }

  Map<String, dynamic> stamp(Map<String, dynamic> r) {
    r['schema_version'] = schemaVersion;
    r['updated'] = syncStamp(now());
    r['device'] = device;
    r.putIfAbsent('deleted', () => false);
    return r;
  }

  Iterable<Map<String, dynamic>> get live => items.where((r) => r['deleted'] != true);

  Map<String, dynamic>? get(String id) {
    for (final r in items) {
      if (r['id'] == id && r['deleted'] != true) return r;
    }
    return null;
  }

  void save() => writeJson(file, items);

  void tombstone(String id) {
    for (final r in items) {
      if (r['id'] == id && r['deleted'] != true) {
        r['deleted'] = true;
        stamp(r);
      }
    }
    save();
  }

  /// Every record incl. tombstones, without the device-local fields.
  Map<String, Map<String, dynamic>> records({Set<String> localOnly = const {}}) => {
        for (final r in items)
          r['id'] as String: {
            for (final e in (deepCopy(r) as Map<String, dynamic>).entries)
              if (!localOnly.contains(e.key)) e.key: e.value,
          },
      };

  /// Records that already won the merge: stored as given (peer stamp kept), local-only fields kept.
  void apply(List<Map<String, dynamic>> recs, {Set<String> localOnly = const {}, bool insertFront = false}) {
    for (final rec in recs) {
      final i = items.indexWhere((r) => r['id'] == rec['id']);
      final item = Map<String, dynamic>.from(deepCopy(rec) as Map);
      item.putIfAbsent('schema_version', () => schemaVersion);
      item.putIfAbsent('deleted', () => false);
      if (i >= 0) {
        for (final k in localOnly) {
          if (items[i].containsKey(k)) item[k] = items[i][k];
        }
        items[i] = item;
      } else if (insertFront) {
        items.insert(0, item);
      } else {
        items.add(item);
      }
    }
    save();
  }

  void purge(Iterable<String> ids) {
    final s = ids.toSet();
    items.removeWhere((r) => r['deleted'] == true && s.contains(r['id']));
    save();
  }
}

// ------------------------------------------------------------------ settings
class Settings {
  /// The settings the phone runtime reads (subset of engine/src/config.py DEFAULTS).
  static const defaults = <String, dynamic>{
    'agent_name': 'Snapy',
    'wake_words': ['snapy', 'snappy', 'hey snapy', 'snap'],
    'voice_language': 'en',
    'speak_typed_replies': false,
    'speak_confirmations': false,
    'continuation_wait_s': 1.5,
    'android_wake_word': false,
    'ai_provider': 'auto',
    'cloud_provider': 'gemini',
    'cloud_model': '',
    'cloud_base_url': '',
    'cloud_for_memory': false,
    'cloud_redact': true,
    'cloud_preview_ack': false,
    'memory_learning': true,
    'daily_greeting': true,
    'internet_tools': true,
    'follow_up_seconds': 8,
    'app_limits': <String, dynamic>{},
    'break_screen': false,
    'lan_brain': true,
  };

  final String file;
  final Map<String, dynamic> data = {};
  void Function(Map<String, dynamic> changes)? onChange;

  Settings(this.file) {
    final d = readJson(file);
    if (d is Map) data.addAll(Map<String, dynamic>.from(d));
  }

  dynamic get(String key) => data.containsKey(key) && data[key] != null ? data[key] : defaults[key];

  void update(Map<String, dynamic> changes) {
    data.addAll(changes);
    writeJson(file, data);
    onChange?.call(changes);
  }
}

// ------------------------------------------------------------------ tasks
class TaskStore {
  final Rules rules;
  final _RecordList _list;
  final Clock now;

  TaskStore(this.rules, String file, {required String device, Clock? clock})
      : now = clock ?? DateTime.now,
        _list = _RecordList(file, 'task', rules.core.schemaVersion('task'), device, clock ?? DateTime.now);

  List<Map<String, dynamic>> get items => _list.live.toList();

  Map<String, dynamic> add(String title, Object? remindAt, {String source = 'voice', DateTime? at}) {
    final created = isoSeconds(at ?? now());
    final item = <String, dynamic>{
      'id': randomHex(10),
      'title': title.trim(),
      'remind_at': remindAt is DateTime ? isoMinutes(remindAt) : remindAt,
      'done': false,
      'fired': false,
      'created': created,
      'source': source,
    };
    _list.stamp(item);
    _list.items.add(item);
    _list.save();
    return item;
  }

  Map<String, dynamic> addFromText(String text, {String source = 'voice', DateTime? at}) {
    final (at2, rest) = rules.parseWhen(text, at ?? now());
    return add(rules.cleanTitle(rest), at2, source: source, at: at);
  }

  Map<String, dynamic>? get(String id) => _list.get(id);

  Map<String, dynamic>? update(String id, Map<String, dynamic> changes) {
    final t = _list.get(id);
    if (t == null) return null;
    for (final k in ['title', 'remind_at', 'done']) {
      if (changes.containsKey(k)) t[k] = changes[k];
    }
    if (changes.containsKey('remind_at')) t['fired'] = false;
    if (changes['done'] == true) t['done_at'] = isoSeconds(now());
    _list.stamp(t);
    _list.save();
    return t;
  }

  Map<String, dynamic>? complete(String id) => update(id, {'done': true});

  void delete(String id) => _list.tombstone(id);

  Map<String, dynamic>? snooze(String id, {int minutes = 10}) =>
      update(id, {'remind_at': isoMinutes(now().add(Duration(minutes: minutes)))});

  Map<String, dynamic>? find(String query) {
    final q = query.toLowerCase().trim();
    final open = items.where((t) => t['done'] != true).toList();
    for (final t in open) {
      if ((t['title'] as String).toLowerCase().contains(q)) return t;
    }
    final words = RegExp(r'\w+').allMatches(q).map((m) => m[0]!).where((w) => w.length > 2).toList();
    final scored = stableSorted(
        [for (final t in open) (words.where((w) => (t['title'] as String).toLowerCase().contains(w)).length, t)],
        (a, b) => b.$1 - a.$1);
    return scored.isNotEmpty && scored.first.$1 > 0 ? scored.first.$2 : null;
  }

  List<Map<String, dynamic>> openTasks() => stableSorted(items.where((t) => t['done'] != true).toList(), (a, b) {
        final an = a['remind_at'] == null ? 1 : 0, bn = b['remind_at'] == null ? 1 : 0;
        if (an != bn) return an - bn;
        final c = ((a['remind_at'] ?? '') as String).compareTo((b['remind_at'] ?? '') as String);
        if (c != 0) return c;
        return ((a['created'] ?? '') as String).compareTo((b['created'] ?? '') as String);
      });

  List<Map<String, dynamic>> doneOn(String day) =>
      items.where((t) => t['done'] == true && ((t['done_at'] ?? '') as String).startsWith(day)).toList();

  /// Tasks whose reminder time has come and that haven't fired (marks them fired).
  List<Map<String, dynamic>> dueReminders([DateTime? at]) {
    final n = at ?? now();
    final due = <Map<String, dynamic>>[];
    for (final t in items) {
      if (t['done'] == true || t['fired'] == true || t['remind_at'] == null) continue;
      final w = parseIsoLocal(t['remind_at'] as String?);
      if (w == null) continue;
      if (!w.isAfter(n)) {
        t['fired'] = true;
        _list.stamp(t);
        due.add(t);
      }
    }
    if (due.isNotEmpty) _list.save();
    return due;
  }

  // sync (lib/core_runtime/sync_stores.dart)
  Map<String, Map<String, dynamic>> syncRecords() => _list.records();
  void syncApply(List<Map<String, dynamic>> recs) => _list.apply(recs);
  void syncPurge(Iterable<String> ids) => _list.purge(ids);
}

// ------------------------------------------------------------------ notes
class NoteStore {
  final _RecordList _list;
  final Clock now;

  NoteStore(CoreData core, String file, {required String device, Clock? clock})
      : now = clock ?? DateTime.now,
        _list = _RecordList(file, 'note', core.schemaVersion('note'), device, clock ?? DateTime.now) {
    var fixed = false;
    for (final n in _list.items) {
      if (!n.containsKey('kind')) {
        n['kind'] = 'note';
        fixed = true;
      }
    }
    if (fixed) _list.save();
  }

  /// Newest first (like Python's insert(0)).
  List<Map<String, dynamic>> get items => _list.live.toList();

  Map<String, dynamic> add(String text, {String kind = 'note', Map<String, dynamic> extra = const {}}) {
    final note = <String, dynamic>{'id': randomHex(10), 'text': text.trim(), 'ts': epochSeconds(now()), 'kind': kind, ...extra};
    _list.stamp(note);
    _list.items.insert(0, note);
    _list.save();
    return note;
  }

  Map<String, dynamic>? update(String id, Map<String, dynamic> changes) {
    final n = _list.get(id);
    if (n == null) return null;
    changes.forEach((k, v) {
      if (k != 'id') n[k] = v;
    });
    _list.stamp(n);
    _list.save();
    return n;
  }

  void delete(String id) => _list.tombstone(id);

  List<Map<String, dynamic>> onDay(String day) => items.where((n) {
        final ts = (n['ts'] as num?)?.toDouble() ?? 0;
        return isoDate(DateTime.fromMicrosecondsSinceEpoch((ts * 1e6).round())) == day;
      }).toList();

  List<Map<String, dynamic>> search(String query, {int limit = 8}) {
    final words = RegExp(r'\w+').allMatches(query.toLowerCase()).map((m) => m[0]!).where((w) => w.length > 2).toList();
    if (words.isEmpty) return items.take(limit).toList();
    final scored = <(int, Map<String, dynamic>)>[];
    for (final n in items) {
      var summary = n['summary'] ?? '';
      if (summary is List) summary = summary.join(' ');
      final hay = '${n['title'] ?? ''} ${n['text'] ?? ''} $summary'.toLowerCase();
      final s = words.fold<int>(0, (a, w) => a + w.allMatches(hay).length);
      if (s > 0) scored.add((s, n));
    }
    return stableSorted(scored, (a, b) => b.$1 - a.$1).take(limit).map((e) => e.$2).toList();
  }

  // sync (lib/core_runtime/sync_stores.dart)
  Map<String, Map<String, dynamic>> syncRecords() => _list.records();
  void syncApply(List<Map<String, dynamic>> recs) => _list.apply(recs, insertFront: true);
  void syncPurge(Iterable<String> ids) => _list.purge(ids);
}

// ------------------------------------------------------------------ memory
const profileDefaults = <String, dynamic>{
  'name': '', 'preferred_name': '', 'role': '', 'about': '', 'languages': ['English'], 'work_start': '09:00',
  'work_end': '18:00', 'city': '', 'editor': '', 'browser': '', 'projects': [], 'routine': {}, 'onboarded': false,
};

const _stop = 'the a an and or but to of in on at for with is are was were be been it this that these those '
    'i you he she they we my your his her their our me him them us do does did have has had not no '
    'so as by from about into over than then there here what when where which who whom why how '
    'can could would should will shall may might must just also very really please snap';
final Set<String> _stopWords = _stop.split(' ').toSet();

/// Keyword tokens for relevance (brain/memory.py _tokens).
Set<String> memoryTokens(String text) {
  final out = <String>{};
  for (final m in RegExp('[a-z0-9ऀ-ॿ]+').allMatches(text.toLowerCase())) {
    var w = m[0]!;
    if (_stopWords.contains(w) || w.runes.length < 2) continue;
    for (final suf in ['ing', 'ed', 'es', 's']) {
      if (w.runes.length > 4 && w.endsWith(suf)) {
        w = w.substring(0, w.length - suf.length);
        break;
      }
    }
    out.add(w);
  }
  return out;
}

class MemoryHit {
  final Map<String, dynamic> memory;
  final double score, relevance;
  MemoryHit(this.memory, this.score, this.relevance);
}

class MemoryStore {
  final Rules rules;
  final String folder;
  final Settings? settings;
  final Clock now;
  late final _RecordList _list;
  late Map<String, dynamic> profile;
  late final List<String> categories;
  void Function()? onChange;

  MemoryStore(this.rules, this.folder, {required String device, this.settings, Clock? clock})
      : now = clock ?? DateTime.now {
    Directory('$folder/journal').createSync(recursive: true);
    Directory('$folder/conversations').createSync(recursive: true);
    _list = _RecordList('$folder/memories.json', 'memory_fact', rules.core.schemaVersion('memory_fact'), device, now);
    categories = List<String>.from(
        ((rules.core.schema('memory_fact')['properties'] as Map)['category'] as Map)['enum'] as List);
    profile = {...profileDefaults, ...Map<String, dynamic>.from((readJson('$folder/profile.json') as Map?) ?? const {})};
  }

  List<Map<String, dynamic>> get memories => _list.live.toList();

  bool get learningEnabled => settings == null || settings!.get('memory_learning') != false;

  String _iso() => isoSeconds(now());

  void _save() {
    _list.save();
    onChange?.call();
  }

  void saveProfile() {
    profile['updated'] = _iso();
    writeJson('$folder/profile.json', profile);
    onChange?.call();
  }

  Map<String, dynamic> updateProfile(Map<String, dynamic> changes) {
    changes.forEach((k, v) {
      if (profileDefaults.containsKey(k) || k == 'updated') profile[k] = v;
    });
    saveProfile();
    return profile;
  }

  Map<String, dynamic>? get(String id) => _list.get(id);

  Map<String, dynamic>? add(String text, {String category = 'fact', int importance = 3, String source = 'conversation',
      bool pinned = false, bool dedupe = true, String? key}) {
    text = pyRstrip(text.trim(), '.');
    if (text.isEmpty || rules.isSecret(text)) return null;
    if (dedupe) {
      final dup = _nearDuplicate(text);
      if (dup != null) {
        dup['importance'] = math.max((dup['importance'] as num).toInt(), importance);
        dup['uses'] = ((dup['uses'] as num?) ?? 0).toInt() + 1;
        _list.stamp(dup);
        _save();
        return dup;
      }
    }
    final m = <String, dynamic>{
      'id': randomHex(10),
      'text': text,
      'category': categories.contains(category) ? category : 'fact',
      'importance': importance.clamp(1, 5),
      'created': _iso(),
      'last_used': null,
      'uses': 0,
      'source': source,
      'pinned': pinned,
      'history': <dynamic>[],
      'key': ?key,
    };
    _list.stamp(m);
    _list.items.add(m);
    _save();
    journalAdd('memory', 'Learned: $text');
    return m;
  }

  Map<String, dynamic>? update(String id, Map<String, dynamic> changes) {
    final m = _list.get(id);
    if (m == null) return null;
    final nt = (changes['text'] as String?)?.trim();
    if (nt != null && nt.isNotEmpty && nt != m['text']) {
      final hist = List<dynamic>.from((m['history'] as List?) ?? const [])..add({'text': m['text'], 'at': _iso()});
      m['history'] = hist.length > 5 ? hist.sublist(hist.length - 5) : hist;
      m['text'] = pyRstrip(nt, '.');
    }
    for (final k in ['category', 'importance', 'pinned']) {
      if (changes.containsKey(k)) m[k] = changes[k];
    }
    _list.stamp(m);
    _save();
    return m;
  }

  bool delete(String id) {
    final had = _list.get(id) != null;
    _list.tombstone(id);
    onChange?.call();
    return had;
  }

  Map<String, dynamic>? forget(String query) {
    final hits = retrieve(query, k: 1, minRelevance: 0.35, touch: false);
    if (hits.isEmpty) return null;
    final m = hits.first.memory;
    delete(m['id'] as String);
    return m;
  }

  void forgetAll() {
    for (final m in memories) {
      _list.tombstone(m['id'] as String);
    }
    profile = {...profileDefaults, 'onboarded': profile['onboarded'] ?? false};
    saveProfile();
  }

  Map<String, dynamic>? _nearDuplicate(String text) {
    final tt = memoryTokens(text);
    for (final m in memories) {
      final mt = memoryTokens(m['text'] as String);
      if (tt.isEmpty || mt.isEmpty) continue;
      final inter = tt.intersection(mt).length;
      final jacc = inter / tt.union(mt).length;
      final contained = inter / math.min(tt.length, mt.length);
      if (jacc >= 0.8 || contained >= 0.85 || (m['text'] as String).toLowerCase() == text.toLowerCase()) return m;
    }
    return null;
  }

  /// Retrieval: 0.5·relevance + 0.25·importance/5 + 0.25·recency (+0.3 pinned),
  /// recency = 0.995^hours since last access. Relevance = keyword overlap (no embeddings on the phone).
  List<MemoryHit> retrieve(String query, {int k = 6, double minRelevance = 0.2, bool touch = true, DateTime? at}) {
    final all = memories;
    if (all.isEmpty) return [];
    final qt = memoryTokens(query);
    final nowS = epochSeconds(at ?? now());
    final scored = <MemoryHit>[];
    for (final m in all) {
      final mt = memoryTokens(m['text'] as String);
      final rel = qt.isNotEmpty && mt.isNotEmpty ? qt.intersection(mt).length / math.max(1, math.min(qt.length, mt.length)) : 0.0;
      final ts = (m['last_used'] ?? m['updated'] ?? m['created']) as String?;
      final t = parseIsoLocal(ts);
      final ageDays = t == null ? 30.0 : (nowS - epochSeconds(t)) / 86400;
      final recency = math.pow(0.995, ageDays * 24).toDouble();
      final score = 0.5 * rel + 0.25 * (((m['importance'] as num?) ?? 3) / 5) + 0.25 * recency + (m['pinned'] == true ? 0.3 : 0);
      scored.add(MemoryHit(m, _round3(score), _round3(rel)));
    }
    final sorted = stableSorted(scored, (a, b) => b.score.compareTo(a.score));
    final hits = sorted.where((s) => s.relevance >= minRelevance).take(k).toList();
    if (touch && hits.isNotEmpty) {
      for (final h in hits) {
        h.memory['last_used'] = _iso();
        h.memory['uses'] = ((h.memory['uses'] as num?) ?? 0).toInt() + 1;
      }
      _list.save();
    }
    return hits;
  }

  static double _round3(double x) => pyRound(x * 1000) / 1000;

  List<Map<String, dynamic>> coreMemories() => memories
      .where((m) => m['pinned'] == true || m['category'] == 'instruction' || ((m['importance'] as num?) ?? 0) >= 5)
      .take(8)
      .toList();

  String profileText() {
    final p = profile;
    final bits = <String>[];
    final name = _s(p['preferred_name']).isNotEmpty ? _s(p['preferred_name']) : _s(p['name']);
    if (name.isNotEmpty) bits.add('Name: $name');
    if (_s(p['role']).isNotEmpty) bits.add('Role: ${p['role']}');
    if (_s(p['about']).isNotEmpty) bits.add('About: ${p['about']}');
    if (p['languages'] is List && (p['languages'] as List).isNotEmpty) bits.add('Languages: ${(p['languages'] as List).join(', ')}');
    if (_s(p['work_start']).isNotEmpty) bits.add('Work hours: ${p['work_start']}–${p['work_end'] ?? ''}');
    if (_s(p['city']).isNotEmpty) bits.add('City: ${p['city']}');
    if (_s(p['editor']).isNotEmpty) bits.add('Editor/IDE: ${p['editor']}');
    return bits.join('\n');
  }

  static String _s(dynamic v) => v is String ? v : '';

  (String, String) contextBlock(String query, {int k = 6}) {
    final core = coreMemories();
    final ids = core.map((m) => m['id']).toSet();
    final hits = retrieve(query, k: k).map((h) => h.memory).where((m) => !ids.contains(m['id']));
    return (profileText(), [...core, ...hits].map((m) => '- ${m['text']}').join('\n'));
  }

  // ------------------------------------------------------------ write policy
  /// "remember that my manager is Arun" -> "User's manager is Arun"
  Map<String, dynamic>? explicitRemember(String text) {
    var fact = pyRstrip((rules.explicitFact(text) ?? text).trim(), '.');
    fact = fact.replaceFirst(RegExp(r'^(that\s+)', caseSensitive: false), '');
    fact = fact.replaceAll(RegExp(r'\bmy\b', caseSensitive: false), "User's");
    fact = fact.replaceAll(RegExp(r"\bI am\b|\bI'm\b", caseSensitive: false), 'User is');
    fact = fact.replaceAll(RegExp(r'\bI\b'), 'User');
    fact = fact.replaceAll(RegExp(r'\bme\b', caseSensitive: false), 'the user');
    if (fact.isNotEmpty) fact = fact[0].toUpperCase() + fact.substring(1);
    return add(fact, category: 'fact', importance: 5, source: 'explicit');
  }

  /// Deterministic extraction (no LLM). Keyed facts are replaced, not duplicated.
  List<Map<String, dynamic>> extractRules(String userText, {String source = 'chat'}) {
    if (!learningEnabled || rules.isSecret(userText)) return [];
    final out = <Map<String, dynamic>>[];
    for (final e in rules.extractRules(userText)) {
      final key = e['key'] as String?;
      final groups = e['groups'] as List<String>;
      if (key == 'name') {
        final n = pyTitle(groups[0]);
        updateProfile({'name': n, 'preferred_name': _s(profile['preferred_name']).isNotEmpty ? profile['preferred_name'] : n});
      } else if (key == 'call_me') {
        updateProfile({'preferred_name': groups[0]});
      } else if (key == 'role') {
        updateProfile({'role': groups[0]});
      } else if (key == 'editor') {
        updateProfile({'editor': pyTitle(groups[0])});
      }
      final text = e['text'] as String, cat = e['category'] as String, imp = (e['importance'] as num).toInt();
      final mem = key != null ? upsert(key, text, category: cat, importance: imp, source: source) : add(text, category: cat, importance: imp, source: source);
      if (mem != null) out.add(mem);
    }
    return out;
  }

  Map<String, dynamic>? upsert(String key, String text, {String category = 'routine', int importance = 3, String source = 'observed'}) {
    for (final m in memories) {
      if (m['key'] == key) {
        if (m['text'] != text) return update(m['id'] as String, {'text': text, 'importance': math.max((m['importance'] as num).toInt(), importance)});
        return m;
      }
    }
    return add(text, category: category, importance: importance, source: source, key: key, dedupe: false);
  }

  String aboutMe() {
    final p = profile;
    final bits = <String>[];
    final name = _s(p['preferred_name']).isNotEmpty ? _s(p['preferred_name']) : _s(p['name']);
    if (name.isNotEmpty) bits.add("you're $name");
    if (_s(p['role']).isNotEmpty) bits.add('you work as ${p['role']}');
    if (_s(p['editor']).isNotEmpty) bits.add('you code in ${p['editor']}');
    const skip = ['name is', 'works as', 'prefers to be called', 'uses '];
    final top = stableSorted(memories, (a, b) {
      final pa = a['pinned'] == true ? 0 : 1, pb = b['pinned'] == true ? 0 : 1;
      if (pa != pb) return pa - pb;
      return ((b['importance'] as num?) ?? 0).compareTo((a['importance'] as num?) ?? 0);
    }).where((m) => !skip.any((s) => (m['text'] as String).toLowerCase().startsWith(s))).take(3).toList();
    if (bits.isEmpty && top.isEmpty) {
      return 'I don’t know much about you yet. Tell me things like “remember that I start work at 9”.'
          .replaceAll('’', "'");
    }
    var out = bits.isNotEmpty ? 'I know ${bits.join(', ')}' : 'I know a few things';
    if (top.isNotEmpty) out += '. I also remember: ${top.map((m) => m['text']).join('; ')}';
    return "$out. That's ${memories.length} things in total — you can see, edit or delete all of them in the Memory tab.";
  }

  bool worthExtracting(String userText) =>
      learningEnabled && userText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length >= 4 && rules.memorySelf(userText);

  /// Background learning with the AI (prompts/extract_memory.*). [chatJson] runs the model.
  Future<List<(String, Map<String, dynamic>?)>> extractAndConsolidate(String userText, String assistantText,
      Future<Map<String, dynamic>> Function(List<Map<String, String>> messages, Map<String, dynamic> schema) chatJson) async {
    if (!worthExtracting(userText)) return [];
    final similar = retrieve(userText, k: 6, minRelevance: 0.15, touch: false).map((h) => h.memory);
    final existing = similar.map((m) => '[${m['id']}] ${m['text']}').join('\n');
    final prompt = 'EXISTING MEMORIES:\n${existing.isEmpty ? '(none)' : existing}\n\nLATEST EXCHANGE:\nUser: $userText\n'
        'Assistant: ${assistantText.length > 300 ? assistantText.substring(0, 300) : assistantText}';
    final schema = deepCopy(rules.core.promptJson['extract_memory.schema']) as Map<String, dynamic>;
    final cat = (((schema['properties'] as Map)['memories'] as Map)['items'] as Map)['properties']['category'] as Map;
    cat.remove('description');
    cat['enum'] = categories;
    final out = await chatJson([
      {'role': 'system', 'content': rules.core.prompt('extract_memory')},
      {'role': 'user', 'content': prompt},
    ], schema);
    final applied = <(String, Map<String, dynamic>?)>[];
    for (final item in ((out['memories'] as List?) ?? const []).take(4)) {
      final it = Map<String, dynamic>.from(item as Map);
      final text = ((it['text'] ?? '') as String).trim();
      final id = it['id'] as String?;
      if (it['op'] == 'delete' && id != null && get(id) != null) {
        final gone = get(id);
        delete(id);
        applied.add(('delete', gone));
        continue;
      }
      if (text.length < 4 || rules.isSecret(text)) continue;
      if (it['op'] == 'update' && id != null && get(id) != null) {
        applied.add(('update', update(id, {'text': text, 'importance': it['importance'] ?? 3})));
      } else {
        applied.add(('add', add(text, category: (it['category'] ?? 'fact') as String, importance: ((it['importance'] ?? 3) as num).toInt())));
      }
    }
    return applied;
  }

  // ------------------------------------------------------------ episodic
  String _today() => isoDate(now());

  void journalAdd(String kind, String text, [String? day]) {
    final p = '$folder/journal/${day ?? _today()}.json';
    final j = Map<String, dynamic>.from((readJson(p) as Map?) ?? {'events': [], 'summary': ''});
    final events = List<dynamic>.from((j['events'] as List?) ?? const [])
      ..add({'ts': epochSeconds(now()), 'type': kind, 'text': text.length > 400 ? text.substring(0, 400) : text});
    j['events'] = events.length > 300 ? events.sublist(events.length - 300) : events;
    writeJson(p, j);
  }

  Map<String, dynamic> journal([String? day]) =>
      Map<String, dynamic>.from((readJson('$folder/journal/${day ?? _today()}.json') as Map?) ?? {'events': [], 'summary': ''});

  void recordTurn(String role, String text, [String? lang]) =>
      appendJsonl('$folder/conversations/${_today()}.jsonl', {'ts': epochSeconds(now()), 'role': role, 'text': text, 'lang': lang});

  // sync (lib/core_runtime/sync_stores.dart): usage counters stay on this device
  static const localOnly = {'last_used', 'uses'};
  Map<String, Map<String, dynamic>> syncRecords() => _list.records(localOnly: localOnly);
  void syncApply(List<Map<String, dynamic>> recs) {
    _list.apply(recs, localOnly: localOnly);
    onChange?.call();
  }

  void syncPurge(Iterable<String> ids) => _list.purge(ids);
}
