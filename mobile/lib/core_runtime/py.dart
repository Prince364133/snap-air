// Small Python semantics the shared rules depend on, implemented exactly:
// difflib.SequenceMatcher.ratio (Ratcliff/Obershelp), str.strip(chars), str.title(),
// round() (half to even), stable sort, ISO local time formatting.
import 'dart:math' as math;

/// difflib.SequenceMatcher(None, a, b) — isjunk=None, autojunk=True (only matters for len(b) >= 200).
class SequenceMatcher {
  final List<int> a, b;
  final Map<int, List<int>> _b2j = {};
  final Set<int> _bpopular = {};

  SequenceMatcher(String a, String b)
      : a = a.runes.toList(),
        b = b.runes.toList() {
    for (var i = 0; i < this.b.length; i++) {
      _b2j.putIfAbsent(this.b[i], () => []).add(i);
    }
    final n = this.b.length;
    if (n >= 200) {
      final ntest = n ~/ 100 + 1;
      for (final e in _b2j.entries.toList()) {
        if (e.value.length > ntest) _bpopular.add(e.key);
      }
      for (final k in _bpopular) {
        _b2j.remove(k);
      }
    }
  }

  (int, int, int) findLongestMatch(int alo, int ahi, int blo, int bhi) {
    var besti = alo, bestj = blo, bestsize = 0;
    var j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final newj2len = <int, int>{};
      for (final j in _b2j[a[i]] ?? const <int>[]) {
        if (j < blo) continue;
        if (j >= bhi) break;
        final k = (j2len[j - 1] ?? 0) + 1;
        newj2len[j] = k;
        if (k > bestsize) {
          besti = i - k + 1;
          bestj = j - k + 1;
          bestsize = k;
        }
      }
      j2len = newj2len;
    }
    // no junk: only the "popular" elements (autojunk) can extend a match
    while (besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1]) {
      besti--;
      bestj--;
      bestsize++;
    }
    while (besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize]) {
      bestsize++;
    }
    return (besti, bestj, bestsize);
  }

  List<(int, int, int)> matchingBlocks() {
    final la = a.length, lb = b.length;
    final queue = <(int, int, int, int)>[(0, la, 0, lb)];
    final blocks = <(int, int, int)>[];
    while (queue.isNotEmpty) {
      final (alo, ahi, blo, bhi) = queue.removeLast();
      final (i, j, k) = findLongestMatch(alo, ahi, blo, bhi);
      if (k > 0) {
        blocks.add((i, j, k));
        if (alo < i && blo < j) queue.add((alo, i, blo, j));
        if (i + k < ahi && j + k < bhi) queue.add((i + k, ahi, j + k, bhi));
      }
    }
    blocks.sort((x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : (x.$2 != y.$2 ? x.$2 - y.$2 : x.$3 - y.$3));
    final out = <(int, int, int)>[];
    var i1 = 0, j1 = 0, k1 = 0;
    for (final (i2, j2, k2) in blocks) {
      if (i1 + k1 == i2 && j1 + k1 == j2) {
        k1 += k2;
      } else {
        if (k1 > 0) out.add((i1, j1, k1));
        i1 = i2;
        j1 = j2;
        k1 = k2;
      }
    }
    if (k1 > 0) out.add((i1, j1, k1));
    out.add((la, lb, 0));
    return out;
  }

  double ratio() {
    final m = matchingBlocks().fold<int>(0, (s, t) => s + t.$3);
    final t = a.length + b.length;
    return t == 0 ? 1.0 : 2.0 * m / t;
  }
}

double seqRatio(String a, String b) => SequenceMatcher(a, b).ratio();

/// difflib.get_close_matches(word, possibilities, n=1, cutoff) -> best or null.
String? closeMatch(String word, Iterable<String> possibilities, {double cutoff = 0.6}) {
  String? best;
  double bestScore = -1;
  for (final x in possibilities) {
    final r = seqRatio(x, word);
    if (r < cutoff) continue;
    // heapq.nlargest over (score, x): higher score, then the greater string
    if (r > bestScore || (r == bestScore && best != null && x.compareTo(best) > 0)) {
      best = x;
      bestScore = r;
    }
  }
  return best;
}

String pyStrip(String s, [String? chars]) => pyRstrip(pyLstrip(s, chars), chars);

String pyLstrip(String s, [String? chars]) {
  if (chars == null) return s.trimLeft();
  var i = 0;
  while (i < s.length && chars.contains(s[i])) {
    i++;
  }
  return s.substring(i);
}

String pyRstrip(String s, [String? chars]) {
  if (chars == null) return s.trimRight();
  var j = s.length;
  while (j > 0 && chars.contains(s[j - 1])) {
    j--;
  }
  return s.substring(0, j);
}

bool _cased(String c) => c.toUpperCase() != c.toLowerCase();

/// str.title(): first cased letter of each run upper, the rest lower.
String pyTitle(String s) {
  final out = StringBuffer();
  var prevCased = false;
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (_cased(c)) {
      out.write(prevCased ? c.toLowerCase() : c.toUpperCase());
      prevCased = true;
    } else {
      out.write(c);
      prevCased = false;
    }
  }
  return out.toString();
}

/// Python round(x) for floats: half to even.
int pyRound(num x) {
  final f = x.floorToDouble();
  final diff = x - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// collapse runs of whitespace to one space and trim
String collapseWs(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// List.sort is not stable in Dart: sort with the original index as a tie-breaker.
List<T> stableSorted<T>(List<T> items, int Function(T a, T b) cmp) {
  final idx = List<int>.generate(items.length, (i) => i);
  idx.sort((x, y) {
    final c = cmp(items[x], items[y]);
    return c != 0 ? c : x - y;
  });
  return [for (final i in idx) items[i]];
}

dynamic deepCopy(dynamic v) {
  if (v is Map) return <String, dynamic>{for (final e in v.entries) e.key as String: deepCopy(e.value)};
  if (v is List) return [for (final e in v) deepCopy(e)];
  return v;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// datetime.isoformat(timespec="minutes") for a local time.
String isoMinutes(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}';

/// datetime.isoformat(timespec="seconds") for a local time.
String isoSeconds(DateTime d) => '${isoMinutes(d)}:${_two(d.second)}';

String isoDate(DateTime d) => isoMinutes(d).substring(0, 10);

/// Parses Python fromisoformat-style local times ("2026-11-16T10:00", "...:00", "... 10:00").
DateTime? parseIsoLocal(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    final d = DateTime.parse(s.replaceFirst(' ', 'T'));
    return d.isUtc ? d.toLocal() : d;
  } catch (_) {
    return null;
  }
}

/// Seconds since the epoch as a double (Python time.time()).
double epochSeconds([DateTime? d]) => (d ?? DateTime.now()).microsecondsSinceEpoch / 1e6;

String randomHex(int n) {
  final r = math.Random.secure();
  const hex = '0123456789abcdef';
  return List.generate(n, (_) => hex[r.nextInt(16)]).join();
}

/// strftime("%I:%M %p").lstrip("0")
String clock12(DateTime w) {
  final h = w.hour % 12 == 0 ? 12 : w.hour % 12;
  final s = '${_two(h)}:${_two(w.minute)} ${w.hour < 12 ? 'AM' : 'PM'}';
  return pyLstrip(s, '0');
}

const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const weekdayLong = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const monthLong = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
