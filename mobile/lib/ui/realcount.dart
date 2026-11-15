import 'dart:async';

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';

/// Real Count on the home screen: the setup steps (with the disclosure Google Play requires)
/// until permissions are on, then today's numbers.
class RealCountSection extends StatefulWidget {
  const RealCountSection({super.key});
  @override
  State<RealCountSection> createState() => _RealCountSectionState();
}

class _RealCountSectionState extends State<RealCountSection> with WidgetsBindingObserver {
  Map<String, bool> _status = const {};
  Today? _today;
  Map<String, String> _labels = const {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    SnapyCore.config('android.social_apps').then((apps) {
      if (apps is List && mounted) {
        setState(() => _labels = {for (final a in apps) a['package'] as String: a['label'] as String});
      }
    }).catchError((_) {});
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
      if (mounted) setState(() { _status = st; _today = t; });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final usage = _status['usage'] ?? false;
    final rc = _status['realcount'] ?? false;
    if (!usage || !rc) return _Setup(usage: usage, realcount: rc);
    return _Dashboard(today: _today, labels: _labels);
  }
}

class _Setup extends StatelessWidget {
  final bool usage, realcount;
  const _Setup({required this.usage, required this.realcount});

  Future<void> _disclose(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow Real Count?'),
        content: const SingleChildScrollView(
          child: Text(
            'Snapy uses Android’s Accessibility permission to:\n\n'
            '• see which app is open, to show your screen time in the pill at the top\n'
            '• count swipes in short-video feeds (Instagram Reels, YouTube Shorts, Facebook, Snapchat, Moj, Josh and more)\n'
            '• go Back, Home or open Recents when you ask by voice\n\n'
            'Everything is counted on your phone. Snapy never reads, stores or sends your messages, posts, '
            'passwords or anything else on your screen, and nothing is uploaded.\n\n'
            'On the next screen, tap “Snapy Real Count” and turn it on.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Agree and continue')),
        ],
      ),
    );
    if (ok == true) await SnapyCore.openRealCountSettings();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    Widget step(int n, String title, String sub, bool done, VoidCallback onTap) => ListTile(
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: done ? c.green : c.accent,
            child: done ? const Icon(Icons.check, size: 16, color: Colors.white) : Text('$n', style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(sub),
          trailing: done ? null : const Icon(Icons.chevron_right),
          onTap: done ? null : onTap,
        );
    return _Card(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('Turn on Real Count', style: Theme.of(context).textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('See your screen time and how many reels you’ve watched, right beside your camera.',
            style: Theme.of(context).textTheme.bodySmall),
      ),
      const SizedBox(height: 8),
      step(1, 'Usage access', 'Screen time per app, the same data as Digital Wellbeing', usage, SnapyCore.openUsageAccess),
      step(2, 'Snapy Real Count', 'Counts reels and shows the pill over other apps', realcount, () => _disclose(context)),
      const SizedBox(height: 8),
    ]);
  }
}

class _Dashboard extends StatelessWidget {
  final Today? today;
  final Map<String, String> labels;
  const _Dashboard({required this.today, required this.labels});

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final t = today;
    final social = t == null
        ? <MapEntry<String, int>>[]
        : (t.perAppMs.entries.where((e) => labels.containsKey(e.key) || t.reels.containsKey(e.key)).toList()
          ..sort((a, b) => b.value.compareTo(a.value)));
    return _Card(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: _Stat(label: 'Screen time today', value: t == null ? '—' : formatMs(t.screenMs))),
          Expanded(child: _Stat(label: 'Reels & shorts', value: t == null ? '—' : '${t.totalReels}')),
        ]),
      ),
      if (social.isNotEmpty) Divider(color: c.hair, height: 24),
      ...social.take(6).map((e) {
        final reels = t!.reels[e.key]?.reels ?? 0;
        return ListTile(
          dense: true,
          title: Text(labels[e.key] ?? e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('${t.opens[e.key] ?? 0} opens'),
          trailing: Text(reels > 0 ? '$reels · ${formatMs(e.value)}' : formatMs(e.value),
              style: TextStyle(color: c.text2, fontFeatures: const [FontFeature.tabularFigures()])),
        );
      }),
      const SizedBox(height: 8),
    ]);
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
