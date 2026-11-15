import 'dart:async';

import 'package:flutter/material.dart';

import '../core/files.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/counter_report.dart';
import '../realcount/habits.dart' show isReportDay;
import '../realcount/nudges.dart' show clock;
import '../realcount/realcount_data.dart';
import '../realcount/rules.dart';
import '../realcount/signed_rules.dart' show RulesUpdate;
import 'chip_settings.dart';
import 'onboarding.dart';
import 'report_page.dart';
import 'reset_page.dart';

/// Real Count on the home screen: setup (step-by-step permission flow) until usage access is
/// on, then today's numbers, focus, the reset, the weekly report and the chip settings.
class RealCountSection extends StatefulWidget {
  const RealCountSection({super.key});
  @override
  State<RealCountSection> createState() => _RealCountSectionState();
}

class _RealCountSectionState extends State<RealCountSection> with WidgetsBindingObserver {
  Map<String, bool> _status = const {};
  Today? _today;
  Map<String, String> _labels = const {};
  Map<String, String> _shortVideo = const {};
  Map<String, dynamic> _state = const {};
  RealCountRules _rules = RealCountRules.fallback;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    SnapyCore.config('android.social_apps').then((apps) {
      if (apps is List && mounted) {
        setState(() {
          _labels = {for (final a in apps) a['package'] as String: a['label'] as String};
          _shortVideo = {for (final a in apps) if (a['short_video'] != null) a['package'] as String: a['label'] as String};
        });
      }
    }).catchError((_) {});
    RealCountRepo.rules().then((r) { if (mounted) setState(() => _rules = r); }).catchError((_) {});
    RealCountRepo.checkRules().catchError((_) => RulesUpdate.failed);    // weekly, no-op until configured
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();      // back from Settings
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final st = await SnapyCore.status();
      final t = (st['usage'] ?? false) ? await SnapyCore.today() : null;
      final rs = await SnapyCore.rcState().catchError((_) => <String, dynamic>{});
      if (mounted) setState(() { _status = st; _today = t; _state = rs; });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final usage = _status['usage'] ?? false;
    if (!usage) return _Setup(usage: usage, realcount: _status['realcount'] ?? false, onDone: _refresh);
    return _Dashboard(
      today: _today,
      labels: _labels,
      shortVideo: _shortVideo,
      counterOn: _status['realcount'] ?? false,
      state: _state,
      rules: _rules,
      onChanged: _refresh,
    );
  }
}

class _Setup extends StatelessWidget {
  final bool usage, realcount;
  final VoidCallback onDone;
  const _Setup({required this.usage, required this.realcount, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    Widget step(int n, String title, String sub, bool done) => ListTile(
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: done ? c.green : c.accent,
            child: done ? const Icon(Icons.check, size: 16, color: Colors.white) : Text('$n', style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(sub),
        );
    return _Card(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(tr('rc.setup_title'), style: Theme.of(context).textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(tr('rc.setup_sub'), style: Theme.of(context).textTheme.bodySmall),
      ),
      const SizedBox(height: 8),
      step(1, tr('rc.step_usage'), tr('rc.step_usage_sub'), usage),
      step(2, tr('rc.step_counter'), tr('rc.step_counter_sub'), realcount),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: FilledButton(
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PermissionFlow()));
            onDone();
          },
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: Text(tr('rc.start_setup')),
        ),
      ),
    ]);
  }
}

class _Dashboard extends StatelessWidget {
  final Today? today;
  final Map<String, String> labels, shortVideo;
  final bool counterOn;
  final Map<String, dynamic> state;
  final RealCountRules rules;
  final VoidCallback onChanged;
  const _Dashboard({required this.today, required this.labels, required this.shortVideo, required this.counterOn,
      required this.state, required this.rules, required this.onChanged});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)).then((_) => onChanged());

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final t = today;
    final allPkgs = <String>{
      if (t != null) ...t.perAppMs.keys,
      if (t != null) ...t.reels.keys,
    }.where((k) => labels.containsKey(k) || (t?.reels.containsKey(k) ?? false) || (t?.perAppMs[k] ?? 0) >= 60000).toList();
    allPkgs.sort((a, b) {
      final reelsA = t?.reels[a]?.reels ?? 0;
      final reelsB = t?.reels[b]?.reels ?? 0;
      final msA = t?.perAppMs[a] ?? 0;
      final msB = t?.perAppMs[b] ?? 0;
      return (reelsB * 1000000 + msB).compareTo(reelsA * 1000000 + msA);
    });
    final focusUntil = (state['focus_until'] as num?)?.toInt() ?? 0;
    final focusOn = focusUntil > DateTime.now().millisecondsSinceEpoch;
    final focusMin = rules.i('nudges.focus_min');
    return _Card(children: [
      if (isReportDay(DateTime.now(), rules.i('habits.report_weekday')))
        ListTile(
          leading: Icon(Icons.insights_outlined, color: c.accent),
          title: Text(tr('report.sunday')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _push(context, const ReportPage()),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: _Stat(label: tr('rc.screen_today'), value: t == null ? '—' : formatMs(t.screenMs))),
          Expanded(child: _Stat(label: tr('rc.reels_today'), value: t == null || !counterOn ? '—' : '${t.totalReels}')),
        ]),
      ),
      if (!counterOn)
        ListTile(
          dense: true,
          leading: Icon(Icons.play_circle_outline, color: c.accent),
          title: Text(tr('rc.counter_off')),
          onTap: () => _push(context, const PermissionFlow()),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (focusOn)
            ActionChip(
              avatar: const Icon(Icons.center_focus_strong, size: 18),
              label: Text('${tr('rc.focus_running', {'until': clock(DateTime.fromMillisecondsSinceEpoch(focusUntil))})} · ${tr('rc.focus_stop')}'),
              onPressed: () async { await SnapyCore.stopFocus().catchError((_) {}); onChanged(); },
            )
          else
            ActionChip(
              avatar: const Icon(Icons.center_focus_weak, size: 18),
              label: Text(tr('rc.focus', {'min': '$focusMin'})),
              onPressed: () async { await SnapyCore.startFocus(focusMin).catchError((_) {}); onChanged(); },
            ),
          ActionChip(avatar: const Icon(Icons.self_improvement, size: 18), label: Text(tr('rc.reset')), onPressed: () => _push(context, const ResetPage())),
          ActionChip(avatar: const Icon(Icons.insights_outlined, size: 18), label: Text(tr('rc.report')), onPressed: () => _push(context, const ReportPage())),
          ActionChip(avatar: const Icon(Icons.tune, size: 18), label: Text(tr('rc.chip_settings')), onPressed: () => _push(context, const ChipSettingsPage())),
        ]),
      ),
      if (allPkgs.isNotEmpty) Divider(color: c.hair, height: 24),
      ...allPkgs.map((pkg) {
        final reels = t!.reels[pkg]?.reels ?? 0;
        final ms = t.perAppMs[pkg] ?? 0;
        final name = labels[pkg] ?? pkg.split('.').last;
        Color badgeColor = c.accent;
        if (pkg.contains('instagram')) {
          badgeColor = const Color(0xFFDD2A7B);
        } else if (pkg.contains('youtube')) {
          badgeColor = const Color(0xFFFF0000);
        } else if (pkg.contains('snapchat')) {
          badgeColor = const Color(0xFFFFD600);
        } else if (pkg.contains('facebook')) {
          badgeColor = const Color(0xFF1877F2);
        } else if (pkg.contains('twitter') || pkg.contains('x')) {
          badgeColor = Colors.white70;
        } else if (pkg.contains('whatsapp')) {
          badgeColor = const Color(0xFF25D366);
        } else if (pkg.contains('reddit')) {
          badgeColor = const Color(0xFFFF4500);
        }

        return ListTile(
          dense: true,
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: badgeColor.withValues(alpha: 0.35), width: 1),
            ),
            alignment: Alignment.center,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : 'A',
              style: TextStyle(color: badgeColor == const Color(0xFFFFD600) ? Colors.amber : badgeColor, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(tr('rc.opens', {'n': '${t.opens[pkg] ?? 0}'}) + (ms >= 60000 ? ' · ${formatMs(ms)}' : '')),
          trailing: reels > 0
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: c.accent.withValues(alpha: 0.3), width: 1),
                  ),
                  child: Text(
                    '▶ $reels reels',
                    style: TextStyle(color: c.accent, fontWeight: FontWeight.bold, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                )
              : Text(
                  formatMs(ms),
                  style: TextStyle(color: c.text2, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
        );
      }),
      if (counterOn)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => showDialog(context: context, builder: (_) => CounterWrongDialog(shortVideo: shortVideo, paused: state['paused_apps'])),
            child: Text(tr('rc.looks_wrong')),
          ),
        ),
      const SizedBox(height: 8),
    ]);
  }
}

/// "Counter looks wrong?" — opt-in; prepares an anonymous fingerprint locally (not sent: no endpoint yet).
class CounterWrongDialog extends StatefulWidget {
  final Map<String, String> shortVideo;
  final dynamic paused;
  const CounterWrongDialog({super.key, required this.shortVideo, this.paused});
  @override
  State<CounterWrongDialog> createState() => _CounterWrongDialogState();
}

class _CounterWrongDialogState extends State<CounterWrongDialog> {
  String _app = '';
  bool? _optIn;
  Map<String, dynamic>? _report;
  String? _msg;

  @override
  void initState() {
    super.initState();
    RealCountRepo.prefs().then((p) { if (mounted) setState(() => _optIn = p.b('counter_reports')); });
  }

  Future<void> _prepare() async {
    try {
      final device = await SnapyCore.device();
      final versions = await SnapyCore.appVersions(widget.shortVideo.keys.toList());
      final prefs = await RealCountRepo.prefs();
      final rules = await RealCountRepo.rules();
      final r = buildCounterReport(
        device: device,
        appVersions: versions,
        app: _app,
        pausedApps: [for (final p in (widget.paused as List? ?? const [])) '$p'],
        rulesVersion: rules.get('version'),
        creatorMode: prefs.b('creator_mode'),
      );
      await SnapyFiles.writeJson('reports/counter-${DateTime.now().millisecondsSinceEpoch}.json', r);
      final sent = await sendCounterReport(r);        // TODO hook: always false until an endpoint exists
      if (mounted) setState(() { _report = r; _msg = sent ? null : tr('wrong.prepared'); });
    } catch (e) {
      if (mounted) setState(() => _msg = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('wrong.title')),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(tr('wrong.body')),
          const SizedBox(height: 12),
          if (_optIn == false) Text(tr('wrong.opt_in'), style: const TextStyle(fontWeight: FontWeight.w600)),
          if (_optIn == true && _report == null)
            DropdownButton<String>(
              isExpanded: true,
              value: _app,
              items: [
                DropdownMenuItem(value: '', child: Text(tr('wrong.not_sure'))),
                for (final e in widget.shortVideo.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _app = v ?? ''),
            ),
          if (_report != null) ...[
            const SizedBox(height: 8),
            Text(prettyReport(_report!), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          ],
          if (_msg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_msg!)),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final r = await RealCountRepo.checkRules(force: true).catchError((_) => RulesUpdate.failed);
            if (mounted) setState(() => _msg = '${tr('wrong.check_now')}: ${r.name}');
          },
          child: Text(tr('wrong.check_now')),
        ),
        if (_optIn == true && _report == null) FilledButton(onPressed: _prepare, child: Text(tr('wrong.prepare'))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('common.close'))),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.8, fontFeatures: [FontFeature.tabularFigures()])),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});
  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(                         // a Material surface so list taps show their ripple
        color: c.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}
