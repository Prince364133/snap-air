import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/realcount/habits.dart';
import 'package:snapy/realcount/nudges.dart' show dayKey;

void main() {
  final today = DateTime(2026, 11, 15); // a Sunday
  DateTime ago(int n) => DateTime(today.year, today.month, today.day - n);

  group('weekly report', () {
    test('compares only with your own last week', () {
      final days = [
        for (var i = 0; i < 7; i++) DayStat(ago(i), screenMs: 3 * 3600000, reels: 40, perAppMs: {'ig': 3600000, 'yt': 1800000}),
        for (var i = 7; i < 14; i++) DayStat(ago(i), screenMs: 4 * 3600000, reels: 60),
      ];
      final r = WeeklyReport.build(days, today);
      expect(r.screenMs, 21 * 3600000);
      expect(r.reels, 280);
      expect(r.prevReels, 420);
      expect(r.trend, Trend.less);
      expect(r.changePct, -25);
      expect(r.topApp, 'ig');
      expect(r.daysWithData, 7);
    });

    test('first week, same week, more', () {
      expect(WeeklyReport.build([DayStat(today, screenMs: 1000)], today).trend, Trend.first);
      expect(WeeklyReport.build([DayStat(today, screenMs: 1000), DayStat(ago(8), screenMs: 1020)], today).trend, Trend.same);
      final more = WeeklyReport.build([DayStat(today, screenMs: 2000), DayStat(ago(8), screenMs: 1000)], today);
      expect(more.trend, Trend.more);
      expect(more.changePct, 100);
    });

    test('calmest day is the lowest day with data', () {
      final r = WeeklyReport.build([DayStat(ago(1), screenMs: 500), DayStat(ago(2), screenMs: 100), DayStat(ago(3))], today);
      expect(r.calmestDay, ago(2));
    });

    test('report day is Sunday by default', () {
      expect(isReportDay(today, 7), isTrue);
      expect(isReportDay(ago(1), 7), isFalse);
    });
  });

  group('daily three', () {
    final t = DailyThree('2026-11-15', const [ThreeItem('Deck'), ThreeItem('Gym', done: true), ThreeItem('Call Ma')]);
    int m(int h, [int min = 0]) => h * 60 + min;

    test('ask in the morning, pinned by day, recap in the evening', () {
      const empty = DailyThree('2026-11-15', []);
      expect(empty.phase(DateTime(2026, 11, 15, 8), askUntilMin: m(12), recapAfterMin: m(20)), ThreePhase.ask);
      expect(empty.phase(DateTime(2026, 11, 15, 13), askUntilMin: m(12), recapAfterMin: m(20)), ThreePhase.none);
      expect(t.phase(DateTime(2026, 11, 15, 13), askUntilMin: m(12), recapAfterMin: m(20)), ThreePhase.pinned);
      expect(t.phase(DateTime(2026, 11, 15, 21), askUntilMin: m(12), recapAfterMin: m(20)), ThreePhase.recap);
      expect(t.done, 1);
    });

    test('saved and loaded; yesterday\'s list doesn\'t carry over', () {
      expect(DailyThree.fromJson(t.toJson(), '2026-11-15').items.length, 3);
      expect(DailyThree.fromJson(t.toJson(), '2026-11-16').items, isEmpty);
      expect(t.items.first.toggled().done, isTrue);
    });
  });

  group('streaks with forgiveness', () {
    Map<String, bool> days(List<bool> newestFirst) => {for (var i = 0; i < newestFirst.length; i++) dayKey(ago(i)): newestFirst[i]};

    test('counts good days back from today', () {
      expect(streak(days([true, true, true]), today).days, 3);
    });

    test('today not done yet doesn\'t break it', () {
      expect(streak(days([false, true, true]), today).days, 2);
    });

    test('survives one miss a week', () {
      final r = streak(days([true, true, false, true, true, true]), today);
      expect(r.days, 5);
      expect(r.forgivenThisWeek, 1);
    });

    test('two misses in a week end it', () {
      expect(streak(days([true, false, true, false, true, true]), today).days, 2);
    });

    test('misses more than a week apart are each forgiven', () {
      final d = days([true, false, true, true, true, true, true, true, false, true]);
      expect(streak(d, today).days, 8);
    });

    test('empty history', () {
      expect(streak(const {}, today).days, 0);
    });

    test('a good day: one of three done, or within the limits you set', () {
      expect(goodDay(threeDone: 1, minDone: 1), isTrue);
      expect(goodDay(threeDone: 0, minDone: 1), isFalse);
      expect(goodDay(threeDone: 0, minDone: 1, limitsSet: true, withinLimits: true), isTrue);
      expect(goodDay(threeDone: 0, minDone: 1, limitsSet: false, withinLimits: true), isFalse);
    });
  });
}
