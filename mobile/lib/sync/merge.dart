/// Last-writer-wins merge, a line-for-line port of engine/src/sync/merge.py.
/// Both are checked against core/conformance/sync/merge.json.
library;

typedef Rec = Map<String, dynamic>;

const syncFields = {'id', 'updated', 'device', 'deleted', 'schema_version'};

// Same grammar as merge.py: YYYY-MM-DD[T ]HH:MM[:SS[.frac]][Z|+HH:MM|+HHMM], no offset = UTC.
final _rx = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?'
    r'(Z|z|[+-]\d{2}:?\d{2})?$');

int _daysIn(int y, int m) {
  const d = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  return m == 2 && leap ? 29 : d[m - 1];
}

/// ISO-8601 -> epoch milliseconds. Throws [FormatException] on anything else.
int parseTs(Object? text) {
  if (text is! String) throw const FormatException('timestamp must be a string');
  final m = _rx.firstMatch(text.trim());
  if (m == null) throw const FormatException('not an ISO-8601 date-time');
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
  final h = int.parse(m.group(4)!), mi = int.parse(m.group(5)!);
  final sec = int.parse(m.group(6) ?? '0');
  var frac = m.group(7) ?? '0';
  frac = (frac.length > 3 ? frac.substring(0, 3) : frac).padRight(3, '0');
  final ms = int.parse(frac);
  if (y < 1 || mo < 1 || mo > 12 || d < 1 || d > _daysIn(y, mo) || h > 23 || mi > 59 || sec > 59) {
    throw const FormatException('date-time out of range');
  }
  var off = 0;
  final tz = m.group(8);
  if (tz != null && tz != 'Z' && tz != 'z') {
    final oh = int.parse(tz.substring(1, 3)), om = int.parse(tz.substring(tz.length - 2));
    if (oh > 23 || om > 59) throw const FormatException('offset out of range');
    off = (oh * 60 + om) * (tz[0] == '+' ? 1 : -1);
  }
  return DateTime.utc(y, mo, d, h, mi, sec).millisecondsSinceEpoch - off * 60000 + ms;
}

/// epoch ms -> 'YYYY-MM-DDTHH:MM:SS.mmmZ'.
String fmtTs(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(d.year, 4)}-${p(d.month)}-${p(d.day)}T${p(d.hour)}:${p(d.minute)}:${p(d.second)}'
      '.${p(d.millisecond, 3)}Z';
}

/// True when [a] should replace [b].
bool wins(Rec a, Rec b) {
  final ta = parseTs(a['updated']), tb = parseTs(b['updated']);
  final da = (a['device'] ?? '').toString(), db = (b['device'] ?? '').toString();
  return ta > tb || (ta == tb && da.compareTo(db) > 0);
}

bool valid(Object? rec, {int? nowMs, int? maxSkewMs}) {
  if (rec is! Map) return false;
  final id = rec['id'];
  if (id is! String || id.isEmpty || id.length > 200) return false;
  final dev = rec['device'];
  if (dev is! String || dev.isEmpty) return false;
  if (rec.containsKey('deleted') && rec['deleted'] is! bool) return false;
  int t;
  try {
    t = parseTs(rec['updated']);
  } on FormatException {
    return false;
  }
  if (nowMs != null && maxSkewMs != null && t > nowMs + maxSkewMs) return false;
  return true;
}

Map<String, List<String>> manifest(Map<String, Rec> local) =>
    {for (final e in local.entries) e.key: [e.value['updated'] as String, e.value['device'] as String]};

/// Local records the peer lacks or holds an older version of, sorted by id.
List<Rec> toSend(Map<String, Rec> local, Map<String, dynamic> peerManifest) {
  final ids = local.keys.toList()..sort();
  final out = <Rec>[];
  for (final i in ids) {
    final r = local[i]!;
    final theirs = peerManifest[i];
    if (theirs == null) {
      out.add(r);
      continue;
    }
    try {
      final l = theirs as List;
      if (wins(r, {'updated': l[0], 'device': l[1]})) out.add(r);
    } catch (_) {
      out.add(r); // unreadable entry: ours is the good copy
    }
  }
  return out;
}

class MergeResult {
  final Map<String, Rec> merged;
  final List<String> applied;
  final int rejected;
  MergeResult(this.merged, this.applied, this.rejected);
}

MergeResult merge(Map<String, Rec> local, Iterable<dynamic> incoming, {int? nowMs, int? maxSkewMs}) {
  final merged = Map<String, Rec>.of(local);
  final applied = <String>{};
  var rejected = 0;
  for (final raw in incoming) {
    if (!valid(raw, nowMs: nowMs, maxSkewMs: maxSkewMs)) {
      rejected++;
      continue;
    }
    final r = Map<String, dynamic>.from(raw as Map);
    final cur = merged[r['id']];
    if (cur == null || wins(r, cur)) {
      merged[r['id'] as String] = r;
      applied.add(r['id'] as String);
    }
  }
  return MergeResult(merged, applied.toList()..sort(), rejected);
}

List<String> purgeTombstones(Map<String, Rec> local, int nowMs, int retentionDays) {
  final cutoff = nowMs - retentionDays * 86400 * 1000;
  final out = <String>[];
  for (final e in local.entries) {
    if (e.value['deleted'] == true) {
      try {
        if (parseTs(e.value['updated']) < cutoff) out.add(e.key);
      } on FormatException {
        out.add(e.key);
      }
    }
  }
  return out..sort();
}
