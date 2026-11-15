import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/chip_logic.dart' show formatDuration;
import '../realcount/habits.dart';
import '../realcount/realcount_data.dart';

/// The weekly attention report card (ready on Sundays) plus the streak. Compares only to you.
class ReportPage extends StatefulWidget {
  const ReportPage({super.key});
  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  WeeklyReport? _r;
  StreakResult _streak = const StreakResult(0, 0);
  Map<String, String> _labels = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final now = DateTime.now();
      final rules = await RealCountRepo.rules();
      final days = await RealCountRepo.history(14, now);
      final prefs = await RealCountRepo.prefs();
      final lim = await RealCountRepo.limits();
      final good = await RealCountRepo.goodDays(60, now, rules, appLimits: lim.limits, reelLimit: prefs.i('reel_limit'));
      Map<String, String> labels = const {};
      try {
        final apps = await SnapyCore.config('android.social_apps');
        if (apps is List) labels = {for (final a in apps) if (a is Map) '${a['package']}': '${a['label']}'};
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _r = WeeklyReport.build(days, now);
        _streak = streak(good, now, forgivePerWeek: rules.i('habits.streak_forgive_per_week'));
        _labels = labels;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: Text(tr('report.title')), backgroundColor: c.bg),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (r != null) WeeklyCard(report: r, labels: _labels),
        const SizedBox(height: 16),
        StreakCard(streak: _streak),
      ]),
    );
  }
}

class WeeklyCard extends StatelessWidget {
  final WeeklyReport report;
  final Map<String, String> labels;
  const WeeklyCard({super.key, required this.report, this.labels = const {}});

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final r = report;
    final line = switch (r.trend) {
      Trend.first => tr('report.first'),
      Trend.same => tr('report.same'),
      Trend.less => tr('report.less', {'pct': '${r.changePct.abs()}'}),
      Trend.more => tr('report.more', {'pct': '${r.changePct.abs()}'}),
    };
    Widget stat(String label, String value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ]),
        );
    return Material(
      color: c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [stat(tr('report.screen'), formatDuration(r.screenMs)), stat(tr('report.reels'), '${r.reels}')]),
          const SizedBox(height: 12),
          Text(line),
          if (r.topApp != null) ...[
            const SizedBox(height: 6),
            Text(tr('report.top_app', {'app': labels[r.topApp] ?? r.topApp!}), style: Theme.of(context).textTheme.bodySmall),
          ],
          if (r.calmestDay != null)
            Text(tr('report.calmest', {'day': MaterialLocalizations.of(context).formatMediumDate(r.calmestDay!)}),
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(tr('report.only_you'), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text3)),
        ]),
      ),
    );
  }
}

class StreakCard extends StatelessWidget {
  final StreakResult streak;
  const StreakCard({super.key, required this.streak});

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Material(
      color: c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('streak.title'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(streak.days > 0 ? tr('streak.days', {'n': '${streak.days}'}) : tr('streak.none'),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          if (streak.forgivenThisWeek > 0) Text(tr('streak.forgiven'), style: TextStyle(color: c.text2)),
          const SizedBox(height: 6),
          Text(tr('streak.rule'), style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}
