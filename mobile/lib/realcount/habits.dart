/// Weekly attention report, daily three and streaks — pure logic (tested in habits_test.dart).
/// Everything compares you only with yourself.
library;

import 'nudges.dart' show dayKey;

class DayStat {
  final DateTime date;
  final int screenMs;
  final int reels;
  final Map<String, int> perAppMs;
  const DayStat(this.date, {this.screenMs = 0, this.reels = 0, this.perAppMs = const {}});
  bool get hasData => screenMs > 0 || reels > 0;
}

enum Trend { first, less, same, more }

class WeeklyReport {
  final int screenMs, reels, prevScreenMs, prevReels, daysWithData;
  final String? topApp;
  final DateTime? calmestDay;
  final Trend trend;
  final int changePct;      // screen time vs last week (negative = less)
  const WeeklyReport({
    required this.screenMs,
    required this.reels,
    required this.prevScreenMs,
    required this.prevReels,
    required this.daysWithData,
    required this.topApp,
    required this.calmestDay,
    required this.trend,
    required this.changePct,
  });

  /// [days] = the last 14 days, any order. This week = the 7 days ending [today].
  static WeeklyReport build(List<DayStat> days, DateTime today, {int samePct = 5}) {
    final t = DateTime(today.year, today.month, today.day);
    bool inRange(DayStat d, int from, int to) {
      final ago = t.difference(DateTime(d.date.year, d.date.month, d.date.day)).inDays;
      return ago >= from && ago <= to;
    }

    final week = days.where((d) => inRange(d, 0, 6)).toList();
    final prev = days.where((d) => inRange(d, 7, 13)).toList();
    int sum(List<DayStat> l, int Function(DayStat) f) => l.fold(0, (a, d) => a + f(d));
    final screen = sum(week, (d) => d.screenMs), reels = sum(week, (d) => d.reels);
    final pScreen = sum(prev, (d) => d.screenMs), pReels = sum(prev, (d) => d.reels);
    final perApp = <String, int>{};
    for (final d in week) {
      d.perAppMs.forEach((k, v) => perApp[k] = (perApp[k] ?? 0) + v);
    }
    final top = perApp.isEmpty ? null : (perApp.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    final withData = week.where((d) => d.hasData).toList()..sort((a, b) => a.screenMs.compareTo(b.screenMs));
    final pct = pScreen == 0 ? 0 : (((screen - pScreen) * 100) / pScreen).round();
    final trend = pScreen == 0
        ? Trend.first
        : (pct.abs() < samePct ? Trend.same : (pct < 0 ? Trend.less : Trend.more));
    return WeeklyReport(
      screenMs: screen,
      reels: reels,
      prevScreenMs: pScreen,
      prevReels: pReels,
      daysWithData: withData.length,
      topApp: top,
      calmestDay: withData.isEmpty ? null : withData.first.date,
      trend: trend,
      changePct: pct,
    );
  }
}

bool isReportDay(DateTime now, int isoWeekday) => now.weekday == isoWeekday;

// ------------------------------------------------------------------ daily three
class ThreeItem {
  final String text;
  final bool done;
  const ThreeItem(this.text, {this.done = false});
  ThreeItem toggled() => ThreeItem(text, done: !done);
  Map<String, dynamic> toJson() => {'text': text, 'done': done};
  static ThreeItem fromJson(Map j) => ThreeItem((j['text'] ?? '').toString(), done: j['done'] == true);
}

enum ThreePhase { ask, pinned, recap, none }

class DailyThree {
  final String date;
  final List<ThreeItem> items;
  const DailyThree(this.date, this.items);

  int get done => items.where((i) => i.done).length;

  /// Morning: ask (until [askUntilMin]). Day: pinned. Evening (after [recapAfterMin]): recap and score.
  ThreePhase phase(DateTime now, {required int askUntilMin, required int recapAfterMin}) {
    final m = now.hour * 60 + now.minute;
    if (items.isEmpty) return m < askUntilMin ? ThreePhase.ask : ThreePhase.none;
    return m >= recapAfterMin ? ThreePhase.recap : ThreePhase.pinned;
  }

  Map<String, dynamic> toJson() => {'date': date, 'items': items.map((e) => e.toJson()).toList()};
  static DailyThree fromJson(Map? j, String date) => DailyThree(
      date, j == null || j['date'] != date ? const [] : [for (final i in (j['items'] as List? ?? const [])) ThreeItem.fromJson(i as Map)]);
}

// ------------------------------------------------------------------ streaks with forgiveness
class StreakResult {
  final int days;              // good days in the current streak
  final int forgivenThisWeek;  // misses forgiven in the last 7 days
  const StreakResult(this.days, this.forgivenThisWeek);
  @override
  String toString() => 'StreakResult($days, forgiven $forgivenThisWeek)';
}

/// [good] maps 'YYYY-MM-DD' -> whether that day counted. Today only adds when already good
/// (the day isn't over). A miss is forgiven when fewer than [forgivePerWeek] misses were
/// already forgiven in the 7 days after it — so a streak survives one miss a week.
StreakResult streak(Map<String, bool> good, DateTime today, {int forgivePerWeek = 1}) {
  if (good.isEmpty) return const StreakResult(0, 0);
  final first = good.keys.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
  var d = DateTime(today.year, today.month, today.day);
  if (good[dayKey(d)] != true) d = DateTime(d.year, d.month, d.day - 1);
  var count = 0;
  final forgiven = <DateTime>[];
  while (dayKey(d).compareTo(first) >= 0) {
    if (good[dayKey(d)] == true) {
      count++;
    } else {
      final recent = forgiven.where((f) => f.difference(d).inDays < 7).length;
      if (recent >= forgivePerWeek) break;
      forgiven.add(d);
    }
    d = DateTime(d.year, d.month, d.day - 1);
  }
  final t = DateTime(today.year, today.month, today.day);
  return StreakResult(count, forgiven.where((f) => t.difference(f).inDays < 7).length);
}

/// A day counts when at least [minDone] of the daily three were done, or the user stayed
/// within every soft limit they set (when they set any).
bool goodDay({required int threeDone, required int minDone, bool limitsSet = false, bool withinLimits = false}) =>
    threeDone >= minDone || (limitsSet && withinLimits);
