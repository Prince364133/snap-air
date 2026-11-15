/// Where the Real Count screens get their data: rules (config + signed update), the user's
/// chip/counter preferences (shared with the Kotlin overlay), day history files and the
/// daily three.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../core/files.dart';
import '../core/snapy_core.dart';
import 'habits.dart';
import 'nudges.dart' show dayKey;
import 'rules.dart';
import 'signed_rules.dart';

/// User preferences (Kotlin SharedPreferences "snapy_rc"; same keys in RcPrefs.kt).
class RcPrefs {
  static const defaults = <String, dynamic>{
    'chip_enabled': true,
    'chip_size': 'normal',          // small | normal | large
    'chip_x': -1,                   // -1 = automatic (centred on the camera)
    'chip_y': -1,
    'hidden_day': '',               // "hide for today"
    'creator_mode': false,
    'intention_prompt': true,
    'nudges': true,
    'speak_nudges': false,
    'reel_limit': 0,                // daily soft limit for reels (0 = none)
    'bedtime': '',                  // '' = rules default
    'simple_mode': false,
    'ui_lang': 'auto',
    'overlay_fallback': true,       // show the chip with "Display over other apps" when the counter is off
    'counter_reports': false,       // opt-in "counter looks wrong" reports
  };

  final Map<String, dynamic> v;
  RcPrefs(Map<String, dynamic> raw) : v = {...defaults, ...raw};

  bool b(String k) => v[k] == true;
  int i(String k) => (v[k] as num?)?.toInt() ?? (defaults[k] as num? ?? 0).toInt();
  String s(String k) => (v[k] ?? defaults[k] ?? '').toString();
}

class RealCountRepo {
  static Future<RealCountRules>? _rules;

  static Future<RealCountRules> rules({bool reload = false}) {
    if (reload) _rules = null;
    return _rules ??= () async {
      dynamic bundled, cfg;
      Map<String, dynamic>? signed;
      try {
        bundled = jsonDecode(await rootBundle.loadString('assets/rules/realcount.json'));
      } catch (_) {}
      try {
        cfg = await SnapyCore.config('android.realcount');
      } catch (_) {}
      try {
        signed = await RulesUpdater.cached();
      } catch (_) {}
      // safety-net defaults < bundled file < shared config < signed weekly update
      return RealCountRules.from(deepMerge(bundled is Map ? bundled : const {}, cfg is Map ? cfg : const {}), override: signed);
    }();
  }

  static Future<RcPrefs> prefs() async {
    try {
      return RcPrefs(await SnapyCore.rcPrefs());
    } catch (_) {
      return RcPrefs(const {});
    }
  }

  static Future<void> setPrefs(Map<String, dynamic> changes) async {
    try {
      await SnapyCore.setRcPrefs(changes);
    } catch (_) {}
  }

  /// The weekly check for a signed rules file (no-op until the URL and key are configured).
  static Future<RulesUpdate> checkRules({bool force = false}) async {
    final r = await RulesUpdater().maybeUpdate(await rules(), DateTime.now(), force: force);
    if (r == RulesUpdate.updated) await rules(reload: true);
    return r;
  }

  // ------------------------------------------------------------ day files (shared with the brain)
  static Future<DayStat> day(DateTime d) async {
    final k = dayKey(d);
    final rc = await SnapyFiles.readJson('realcount/$k.json');
    final usage = await SnapyFiles.readJson('realcount/usage-$k.json');
    final apps = (rc is Map ? rc['apps'] : null) as Map? ?? const {};
    final reels = apps.values.fold<int>(0, (a, v) => a + (((v as Map)['reels'] as num?)?.toInt() ?? 0));
    final per = (usage is Map ? usage['per_app_ms'] : null) as Map? ?? const {};
    return DayStat(d,
        screenMs: ((usage is Map ? usage['screen_ms'] : null) as num?)?.toInt() ?? 0,
        reels: reels,
        perAppMs: per.map((k, v) => MapEntry(k.toString(), (v as num).toInt())));
  }

  static Future<List<DayStat>> history(int days, DateTime today) async => [
        for (var i = 0; i < days; i++) await day(DateTime(today.year, today.month, today.day - i)),
      ];

  // ------------------------------------------------------------ daily three
  static String _threePath(String day) => 'daily_three/$day.json';

  static Future<DailyThree> three(DateTime now) async {
    final k = dayKey(now);
    final j = await SnapyFiles.readJson(_threePath(k));
    return DailyThree.fromJson(j is Map ? j : null, k);
  }

  static Future<void> saveThree(DailyThree t) => SnapyFiles.writeJson(_threePath(t.date), t.toJson());

  /// Good days for the streak, over the last [days] days.
  static Future<Map<String, bool>> goodDays(int days, DateTime today, RealCountRules rules,
      {Map<String, int> appLimits = const {}, int reelLimit = 0}) async {
    final out = <String, bool>{};
    for (var i = 0; i < days; i++) {
      final d = DateTime(today.year, today.month, today.day - i);
      final k = dayKey(d);
      final t = await SnapyFiles.readJson(_threePath(k));
      final stat = await day(d);
      if (t == null && !stat.hasData) continue;                   // nothing recorded that day
      final three = DailyThree.fromJson(t is Map ? t : null, k);
      final limitsSet = appLimits.isNotEmpty || reelLimit > 0;
      final within = appLimits.entries.every((e) => (stat.perAppMs[e.key] ?? 0) <= e.value * 60000) &&
          (reelLimit <= 0 || stat.reels <= reelLimit);
      out[k] = goodDay(threeDone: three.done, minDone: rules.i('habits.streak_min_done'), limitsSet: limitsSet, withinLimits: within);
    }
    return out;
  }

  /// {package: minutes} from the brain's settings (app_limits).
  static Future<({Map<String, int> limits, bool breakScreen})> limits() async {
    try {
      final m = _decode(await SnapyCore.coreCall('limits_json'));
      final l = (m['limits'] as Map?) ?? const {};
      return (limits: l.map((k, v) => MapEntry(k.toString(), (v as num).toInt())), breakScreen: m['break'] == true);
    } catch (_) {
      return (limits: const <String, int>{}, breakScreen: false);
    }
  }

  static Future<void> setLimit(String pkg, int minutes) async {
    try {
      await SnapyCore.coreCall('set_limit', [pkg, '$minutes']);
    } catch (_) {}
  }

  static Future<void> setBreakScreen(bool on) async {
    try {
      await SnapyCore.updateSettings({'break_screen': on});
    } catch (_) {}
  }

  static Map<String, dynamic> _decode(String j) {
    try {
      final v = jsonDecode(j);
      return v is Map ? Map<String, dynamic>.from(v) : const {};
    } catch (_) {
      return const {};
    }
  }
}
