// Real Count answers, weekly summary and limit state (core/README.md §4.10, §2 "Limit state").
// Python reference: engine/src/life/realcount.py. Day files live in <data>/realcount/.
import 'dart:convert';
import 'dart:io';

import 'core_data.dart';
import 'py.dart';

class RealCount {
  final CoreData core;
  final String folder;
  final Map<String, String> labels = {}; // package/id -> label (insertion order matters)
  final DateTime Function()? today;

  RealCount(this.core, this.folder, {Map<String, String>? appLabels, this.today}) {
    Directory(folder).createSync(recursive: true);
    labels.addAll(appLabels ?? const {});
    for (final a in (core.config('android.social_apps') as List?) ?? const []) {
      labels.putIfAbsent((a as Map)['package'] as String, () => a['label'] as String);
    }
    for (final e in ((core.config('realcount.web_labels') as Map?) ?? const {}).entries) {
      if (e.key != '_comment') labels.putIfAbsent(e.key as String, () => e.value as String);
    }
  }

  DateTime _today() {
    final d = today != null ? today!() : DateTime.now();
    return DateTime(d.year, d.month, d.day);
  }

  static DateTime _minusDays(DateTime d, int n) => DateTime(d.year, d.month, d.day - n);

  String fmt(num ms, [String lang = 'en']) {
    final m = (ms / 60000).floor();
    return m >= 60 ? core.t('time.hours_minutes', lang, {'h': m ~/ 60, 'm': m % 60}) : core.t('time.minutes', lang, {'m': m});
  }

  Map<String, dynamic> classify(String text) {
    final low = text.toLowerCase().trim();
    final pm = core.firstMatch('realcount_period', low);
    final word = pm == null ? null : CoreData.group(pm.$2, 'period');
    final periods = core.slotValues('realcount.period') as Map;
    final period = (periods[word] ?? core.slotValues('realcount.period_default')) as String;
    String? app;
    final am = core.firstMatch('realcount_app', low);
    if (am != null) {
      app = (CoreData.group(am.$2, 'app') ?? CoreData.group(am.$2, 'app2') ?? '').trim();
      if (app.isEmpty) app = (CoreData.group(am.$2, 'app2') ?? '').trim();
      if (am.$1['last_word'] == true && app.isNotEmpty) app = app.split(RegExp(r'\s+')).last;
    }
    return {
      'period': period,
      'app': (app == null || app.isEmpty) ? null : app,
      'reels': core.anyMatch('realcount_reels', low),
      'videos': core.anyMatch('realcount_videos', low),
      'screen': core.anyMatch('realcount_screen', low),
    };
  }

  // ------------------------------------------------------------ files
  Map<String, dynamic> _read(String name) {
    try {
      final v = jsonDecode(File('$folder/$name').readAsStringSync());
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (_) {
      return {};
    }
  }

  void saveUsage(Map<String, dynamic> usage, [DateTime? day]) {
    final d = day ?? DateTime.now();
    File('$folder/usage-${isoDate(d)}.json').writeAsStringSync(jsonEncode(usage));
  }

  static int _int(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

  Map<String, dynamic> day(DateTime d) {
    final u = _read('usage-${isoDate(d)}.json');
    final f = _read('${isoDate(d)}.json');
    final r = Map<String, dynamic>.from((f['apps'] as Map?) ?? const {});
    return {
      'screen_ms': _int(u['screen_ms']),
      'per_app_ms': {for (final e in ((u['per_app_ms'] as Map?) ?? const {}).entries) e.key as String: _int(e.value)},
      'reels': {for (final e in r.entries) e.key: _int((e.value as Map)['reels'])},
      'videos': {
        for (final e in ((f['videos'] as Map?) ?? const {}).entries)
          e.key as String: {'count': _int((e.value as Map)['count']), 'ms': _int(e.value['ms'])},
      },
      'has_usage': u.isNotEmpty,
    };
  }

  Map<String, dynamic> range(int days, [DateTime? end]) {
    end ??= _today();
    final perApp = <String, int>{}, reels = <String, int>{};
    var screen = 0, vCount = 0, vMs = 0, active = 0, usageDays = 0;
    for (var i = 0; i < days; i++) {
      final d = day(_minusDays(end, i));
      final dReels = d['reels'] as Map<String, int>;
      if ((d['screen_ms'] as int) != 0 || dReels.isNotEmpty) active++;
      if (d['has_usage'] as bool) usageDays++;
      for (final v in (d['videos'] as Map).values) {
        vCount += (v as Map)['count'] as int;
        vMs += v['ms'] as int;
      }
      screen += d['screen_ms'] as int;
      (d['per_app_ms'] as Map<String, int>).forEach((k, v) => perApp[k] = (perApp[k] ?? 0) + v);
      dReels.forEach((k, v) => reels[k] = (reels[k] ?? 0) + v);
    }
    return {
      'screen_ms': screen,
      'per_app_ms': perApp,
      'reels': reels,
      'videos': {'count': vCount, 'ms': vMs},
      'days': active,
      'usage_days': usageDays,
    };
  }

  String label(String pkg) => labels[pkg] ?? pyTitle(pkg.split('.').last);

  String? findApp(String name) {
    final n = name.toLowerCase().trim();
    for (final e in labels.entries) {
      final l = e.value.toLowerCase();
      if (l == n || l.split(RegExp(r'\s+')).contains(n) || n == e.key) return e.key;
    }
    return null;
  }

  /// Sorted by value descending, stable (Python sorted on -value).
  static List<MapEntry<String, int>> _top(Map<String, int> m, int n) =>
      stableSorted(m.entries.toList(), (a, b) => b.value.compareTo(a.value)).take(n).toList();

  // ------------------------------------------------------------ answers
  String? answer(String text, {String lang = 'en', DateTime? todayOverride}) {
    final q = classify(text);
    final period = q['period'] as String;
    final days = ((core.slotValues('realcount.period_days') as Map)[period] as num).toInt();
    final back = ((core.slotValues('realcount.period_end_offset_days') as Map)[period] as num).toInt();
    final base = todayOverride != null ? DateTime(todayOverride.year, todayOverride.month, todayOverride.day) : _today();
    final end = _minusDays(base, back);
    final when = core.t('realcount.period.$period', lang);
    if (q['app'] != null) {
      final pkg = findApp(q['app'] as String);
      if (pkg != null) {
        final t = range(days, end);
        final ms = (t['per_app_ms'] as Map<String, int>)[pkg] ?? 0;
        final reels = (t['reels'] as Map<String, int>)[pkg] ?? 0;
        final extra = reels != 0 ? core.t('realcount.app_time_reels', lang, {'reels': reels}) : '';
        return core.t('realcount.app_time', lang, {'time': fmt(ms, lang), 'app': label(pkg), 'when': when, 'extra': extra});
      }
    }
    if (q['reels'] == true) {
      final t = range(days, end);
      final reels = t['reels'] as Map<String, int>;
      final total = reels.values.fold<int>(0, (a, b) => a + b);
      if (total == 0) {
        final msg = core.t('realcount.no_reels', lang, {'when': when});
        return (t['days'] as int) != 0 ? msg : '$msg ${core.t('realcount.turn_on', lang)}';
      }
      final parts = _top(reels, 3)
          .where((e) => e.value != 0)
          .map((e) => core.t('realcount.reels_part', lang, {'n': e.value, 'app': label(e.key)}))
          .join(', ');
      return core.t('realcount.reels_total', lang, {'total': total, 'when': when, 'parts': parts});
    }
    if (q['videos'] == true) {
      final v = range(days, end)['videos'] as Map;
      return (v['count'] as int) != 0
          ? core.t('realcount.videos_total', lang, {'n': v['count'], 'when': when, 'time': fmt(v['ms'] as int, lang)})
          : core.t('realcount.no_videos', lang, {'when': when});
    }
    if (q['screen'] == true) {
      final t = range(days, end);
      final screen = t['screen_ms'] as int;
      if (screen == 0) return core.t('realcount.no_screen_time', lang, {'when': when});
      final parts = _top(t['per_app_ms'] as Map<String, int>, 3)
          .map((e) => core.t('realcount.screen_part', lang, {'app': label(e.key), 'time': fmt(e.value, lang)}))
          .join(', ');
      final activeDays = (t['days'] as int) < 1 ? 1 : t['days'] as int;
      final avg = days > 1 ? core.t('realcount.screen_avg', lang, {'time': fmt(screen / activeDays, lang)}) : '';
      return core.t('realcount.screen_time', lang, {'when': when, 'time': fmt(screen, lang), 'avg': avg, 'parts': parts});
    }
    return null;
  }

  String weeklySummary({DateTime? end, String lang = 'en'}) {
    end ??= _today();
    final thisW = range(7, end), lastW = range(7, _minusDays(end, 7));
    final reels = (thisW['reels'] as Map<String, int>).values.fold<int>(0, (a, b) => a + b);
    final prev = (lastW['reels'] as Map<String, int>).values.fold<int>(0, (a, b) => a + b);
    var social = 0;
    (thisW['per_app_ms'] as Map<String, int>).forEach((p, ms) {
      if (labels.containsKey(p)) social += ms;
    });
    String line;
    if ((thisW['usage_days'] as int) != 0) {
      line = core.t('realcount.weekly', lang,
          {'reels': reels, 'social': fmt(social, lang), 'screen': fmt(thisW['screen_ms'] as int, lang)});
    } else {
      line = core.t('realcount.weekly_no_screen', lang, {'reels': reels, 'social': fmt(social, lang)});
    }
    if (prev != 0) {
      final change = pyRound((reels - prev) * 100 / prev);
      if (change == 0) {
        line += core.t('realcount.weekly_same', lang);
      } else {
        line += core.t(change > 0 ? 'realcount.weekly_more' : 'realcount.weekly_less', lang, {'pct': change.abs()});
      }
    }
    return line;
  }

  /// 'ok' | 'near' | 'over' for a daily limit in minutes (core/rules/limits.json).
  String limitState(int usedMs, int? limitMin) {
    if (limitMin == null || limitMin == 0) return 'ok';
    final lim = (core.config('android.realcount.limits') as Map?) ?? const {};
    final f = usedMs / (limitMin * 60000);
    if (f >= ((lim['over_fraction'] as num?) ?? 1.0)) return 'over';
    if (f >= ((lim['near_fraction'] as num?) ?? 0.8)) return 'near';
    return 'ok';
  }
}
