/// Privacy receipts: what Snapy stored on this phone and what it sent, month by month,
/// with one-tap delete. Stored = the files in Snapy's private folder (grouped by kind).
/// Sent = a local ledger (snapy/receipts/sent.jsonl) that every outgoing request appends to.
///
/// TODO(brain): the Python/Dart brain should call [Receipts.logSent] for cloud AI requests
/// and web lookups; today the rules-file check, counter reports and the wake-word model
/// download are logged from the app side.
library;

import 'dart:convert';
import 'dart:io';

import '../core/files.dart';

class StoredItem {
  final String relative;   // path under snapy/
  final String kind;       // i18n key suffix: privacy.kind.<kind>
  final int bytes;
  final DateTime modified;
  const StoredItem(this.relative, this.kind, this.bytes, this.modified);
}

class SentItem {
  final DateTime at;
  final String what;       // i18n key suffix: privacy.sent.<what>
  final String to;         // host
  final int bytes;
  const SentItem(this.at, this.what, this.to, this.bytes);
  Map<String, dynamic> toJson() => {'at': at.toIso8601String(), 'what': what, 'to': to, 'bytes': bytes};
  static SentItem? fromJson(dynamic j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    return at == null ? null : SentItem(at, '${j['what']}', '${j['to']}', (j['bytes'] as num?)?.toInt() ?? 0);
  }
}

/// Folder -> kind. Unknown folders show as "other" (never hidden).
String kindOf(String relative) {
  final top = relative.split(RegExp(r'[\\/]')).first;
  if (relative.startsWith('realcount')) return 'realcount';
  const map = {
    'memory': 'memory', 'memories': 'memory', 'tasks': 'tasks', 'notes': 'notes', 'reminders': 'tasks',
    'secrets': 'keys', 'keys': 'keys', 'models': 'models', 'rules': 'rules', 'daily_three': 'daily_three',
    'receipts': 'receipts', 'reports': 'reports', 'settings.json': 'settings', 'chat': 'chat', 'history': 'chat',
  };
  return map[top] ?? 'other';
}

class Receipts {
  static const ledger = 'receipts/sent.jsonl';

  static Future<void> logSent(String what, String to, int bytes, {DateTime? at}) async {
    try {
      final f = await SnapyFiles.file(ledger);
      await f.writeAsString('${jsonEncode(SentItem(at ?? DateTime.now(), what, to, bytes).toJson())}\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<List<SentItem>> sent({required int year, required int month}) async {
    try {
      final f = await SnapyFiles.file(ledger);
      if (!f.existsSync()) return const [];
      return (await f.readAsLines())
          .map((l) {
            try {
              return SentItem.fromJson(jsonDecode(l));
            } catch (_) {
              return null;
            }
          })
          .whereType<SentItem>()
          .where((s) => s.at.year == year && s.at.month == month)
          .toList()
        ..sort((a, b) => b.at.compareTo(a.at));
    } catch (_) {
      return const [];
    }
  }

  /// Files changed in [year]/[month]; large model folders are one item each.
  static Future<List<StoredItem>> stored({required int year, required int month}) async {
    final root = await SnapyFiles.root();
    if (!root.existsSync()) return const [];
    final out = <StoredItem>[];
    final models = <String, (int, DateTime)>{};
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(root.path.length + 1).replaceAll('\\', '/');
      final st = e.statSync();
      final kind = kindOf(rel);
      if (kind == 'models') {
        final parts = rel.split('/');
        final key = parts.length > 1 ? '${parts[0]}/${parts[1]}' : rel;
        final prev = models[key];
        models[key] = (
          (prev?.$1 ?? 0) + st.size,
          prev == null || st.modified.isAfter(prev.$2) ? st.modified : prev.$2,
        );
        continue;
      }
      if (st.modified.year == year && st.modified.month == month) out.add(StoredItem(rel, kind, st.size, st.modified));
    }
    models.forEach((k, v) {
      if (v.$2.year == year && v.$2.month == month) out.add(StoredItem(k, 'models', v.$1, v.$2));
    });
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  static Future<bool> delete(StoredItem item) async {
    try {
      if (item.relative.isEmpty || item.relative.split('/').contains('..')) return false;   // stay inside snapy/
      final root = await SnapyFiles.root();
      final path = '${root.path}/${item.relative}';
      final t = FileSystemEntity.typeSync(path);
      if (t == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else if (t == FileSystemEntityType.file) {
        File(path).deleteSync();
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
