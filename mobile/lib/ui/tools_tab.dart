import 'dart:async';

import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/nudges.dart' show clock;
import '../sync/pair_screen.dart';
import 'common.dart';
import 'vault_page.dart';

/// Tools: reel limits per app (soft nudge or hard lock), focus, the meeting assistant, a quick
/// actions test panel and laptop pairing.
class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Semantics(header: true, child: Text(tr('tools.title'), style: Theme.of(context).textTheme.headlineMedium)),
          ),
          const ReelLimitsCard(),
          const FocusCard(),
          const MeetingCard(),
          const QuickActionsCard(),
          SnapyCard(
            children: [
              ListTile(
                minTileHeight: 56,
                leading: const Icon(Icons.laptop),
                title: Text(tr('tools.pair_title')),
                subtitle: Text(tr('tools.pair_sub')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PairLaptopPage())),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------- reels

class ReelLimitsCard extends StatefulWidget {
  const ReelLimitsCard({super.key});
  @override
  State<ReelLimitsCard> createState() => _ReelLimitsCardState();
}

class _ReelLimitsCardState extends State<ReelLimitsCard> {
  List<ShortVideoApp> _apps = const [];
  Map<String, ReelLimit> _limits = const {};
  Map<String, int> _usedToday = const {};
  bool _loading = true;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = NextApi.events(types: const {'reel_lock'}).listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final apps = await NextApi.shortVideoApps();
    final limits = await NextApi.reelLimits();
    var used = <String, int>{};
    try {
      final t = await SnapyCore.today();
      used = {for (final e in t.reels.entries) e.key: e.value.reels};
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _limits = limits;
      _usedToday = used;
      _loading = false;
    });
  }

  Future<void> _set(String pkg, ReelLimit l) async {
    setState(() => _limits = {..._limits, pkg: l});
    final ok = await NextApi.setReelLimit(pkg, l.limit, l.mode);
    if (!ok && mounted) toast(context, tr('tools.save_failed'));
  }

  @override
  Widget build(BuildContext context) {
    return SnapyCard(
      title: tr('tools.reels_title'),
      subtitle: tr('tools.reels_sub'),
      icon: Icons.shield_outlined,
      children: [
        if (_loading)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        else if (_apps.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(tr('tools.reels_empty'), style: Theme.of(context).textTheme.bodySmall),
          )
        else
          for (final a in _apps)
            ReelLimitRow(
              key: ValueKey('reel-${a.package}'),
              app: a,
              limit: _limits[a.package] ?? const ReelLimit(),
              usedToday: _usedToday[a.package],
              onChanged: (l) => _set(a.package, l),
            ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// One app: icon, today's progress, a 0–200 stepper/slider (0 = off) and Soft nudge | Hard lock.
class ReelLimitRow extends StatelessWidget {
  static const step = 5, max = 200;
  final ShortVideoApp app;
  final ReelLimit limit;
  final int? usedToday;
  final ValueChanged<ReelLimit> onChanged;
  const ReelLimitRow({super.key, required this.app, required this.limit, this.usedToday, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final used = limit.used > 0 ? limit.used : (usedToday ?? 0);
    final n = limit.limit;
    final progress = n <= 0 ? 0.0 : used / n;
    final p = {'app': app.label, 'kind': app.kind};
    String? state;
    if (n > 0 && (limit.state == 'locked' || (limit.hard && used >= n))) {
      state = tr('tools.state_locked');
    } else if (n > 0 && (limit.state == 'near' || progress >= 0.8)) {
      state = tr('tools.state_near');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          AppIconView(package: app.package, label: app.label, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${app.label} · ${app.kind}', style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                n > 0 ? tr('tools.used', {'used': '$used', 'limit': '$n'}) : tr('tools.used_nolimit', {'used': '$used'}),
                style: small,
              ),
            ]),
          ),
          IconButton(
            tooltip: tr('tools.decrease', p),
            onPressed: n <= 0 ? null : () => onChanged(limit.copyWith(limit: (n - step).clamp(0, max))),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 64,
            child: Text(
              n <= 0 ? tr('tools.limit_off') : '$n',
              key: ValueKey('limit-${app.package}'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          IconButton(
            tooltip: tr('tools.increase', p),
            onPressed: n >= max ? null : () => onChanged(limit.copyWith(limit: (n + step).clamp(0, max))),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ]),
        if (n > 0) ...[
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.only(right: 8), child: LimitBar(value: progress)),
          if (state != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(state, style: small?.copyWith(color: progress >= 1 ? c.red : c.orange))),
        ],
        Slider(
          value: n.clamp(0, max).toDouble(),
          min: 0,
          max: max.toDouble(),
          divisions: max ~/ step,
          label: n <= 0 ? tr('tools.limit_off') : tr('tools.limit_n', {'n': '$n'}),
          semanticFormatterCallback: (v) => v <= 0 ? tr('tools.limit_off') : tr('tools.limit_n', {'n': '${v.round()}'}),
          onChanged: (v) => onChanged(limit.copyWith(limit: v.round())),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'soft', label: Text(tr('tools.mode_soft')), icon: const Icon(Icons.notifications_none)),
              ButtonSegment(value: 'hard', label: Text(tr('tools.mode_hard')), icon: const Icon(Icons.lock_outline)),
            ],
            selected: {limit.hard ? 'hard' : 'soft'},
            onSelectionChanged: n <= 0 ? null : (s) => onChanged(limit.copyWith(mode: s.first)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 8, 4),
          child: Text(limit.hard ? tr('tools.hard_explain', p) : tr('tools.soft_explain'), style: small),
        ),
        Divider(color: c.hair, height: 16),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------------------- focus

class FocusCard extends StatefulWidget {
  const FocusCard({super.key});
  @override
  State<FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<FocusCard> {
  int _until = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await SnapyCore.rcState();
      if (mounted) setState(() => _until = (s['focus_until'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final on = _until > DateTime.now().millisecondsSinceEpoch;
    return SnapyCard(
      title: tr('tools.focus_title'),
      subtitle: on ? tr('tools.focus_running', {'until': clock(DateTime.fromMillisecondsSinceEpoch(_until))}) : tr('tools.focus_sub'),
      icon: Icons.center_focus_strong,
      iconColor: c.green,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
          child: on
              ? OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await SnapyCore.stopFocus();
                    } catch (_) {}
                    setState(() => _until = 0);
                    _load();
                  },
                  icon: const Icon(Icons.stop),
                  label: Text(tr('tools.focus_stop')),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                )
              : FilledButton.tonalIcon(
                  onPressed: () async {
                    try {
                      await SnapyCore.startFocus(25);
                      setState(() => _until = DateTime.now().add(const Duration(minutes: 25)).millisecondsSinceEpoch);
                    } catch (_) {
                      if (context.mounted) toast(context, tr('profile.unavailable'));
                    }
                    _load();
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('tools.focus_start')),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------- meeting

class MeetingCard extends StatefulWidget {
  const MeetingCard({super.key});
  @override
  State<MeetingCard> createState() => _MeetingCardState();
}

class _MeetingCardState extends State<MeetingCard> {
  MeetingState _m = const MeetingState();
  int _elapsed = 0;
  List<VaultItem> _recent = const [];
  Timer? _tick;
  StreamSubscription? _sub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = NextApi.events(types: const {'meeting'}).listen((e) => _apply(MeetingState.fromJson(e)));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await NextApi.meetingState();
    final notes = await NextApi.vaultList('meetings');
    if (!mounted) return;
    setState(() => _recent = notes.take(3).toList());
    _apply(s);
  }

  void _apply(MeetingState s) {
    if (!mounted) return;
    final wasRecording = _m.recording;
    setState(() {
      _m = s;
      _elapsed = s.elapsed;
    });
    _tick?.cancel();
    if (s.recording) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed++);
      });
    } else if (wasRecording) {
      NextApi.vaultList('meetings').then((n) {
        if (mounted) setState(() => _recent = n.take(3).toList());
      });
    }
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final s = _m.recording ? await NextApi.meetingStop() : await NextApi.meetingStart();
    if (!mounted) return;
    setState(() => _busy = false);
    _apply(s);
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    return SnapyCard(
      title: tr('tools.meeting_title'),
      subtitle: tr('tools.meeting_sub'),
      icon: Icons.mic_none,
      iconColor: orbPalette[1],
      children: [
        if (_m.recording)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Semantics(
              liveRegion: true,
              child: Row(children: [
                Icon(Icons.fiber_manual_record, color: c.red, size: 14),
                const SizedBox(width: 6),
                Text(tr('tools.meeting_recording', {'time': clockOf(_elapsed)}),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ),
          ),
        if (_m.recording)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Text(_m.live.isEmpty ? tr('tools.meeting_live_wait') : _m.live, maxLines: 2, overflow: TextOverflow.ellipsis, style: small),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: _m.recording
              ? FilledButton.icon(
                  onPressed: _busy ? null : _toggle,
                  icon: const Icon(Icons.stop),
                  label: Text(tr('tools.meeting_stop')),
                  style: FilledButton.styleFrom(backgroundColor: c.red, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
                )
              : FilledButton.icon(
                  onPressed: _busy ? null : _toggle,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: Text(tr('tools.meeting_start')),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Text(tr('tools.meeting_recent'), style: small)),
        if (_recent.isEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 2, 16, 14), child: Text(tr('tools.meeting_none'), style: small)),
        for (final n in _recent)
          ListTile(
            dense: true,
            title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VaultItemPage(item: n))),
          ),
        if (_recent.isNotEmpty) const SizedBox(height: 6),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------- quick actions

class QuickActionsCard extends StatefulWidget {
  const QuickActionsCard({super.key});
  @override
  State<QuickActionsCard> createState() => _QuickActionsCardState();
}

class _QuickActionsCardState extends State<QuickActionsCard> {
  bool _torch = false;

  Future<void> _run(Future<bool> Function() action) async {
    var ok = false;
    try {
      ok = await action();
    } catch (_) {}
    if (mounted) toast(context, ok ? tr('tools.quick_done') : tr('tools.quick_failed'));
  }

  /// The brain's own phone commands (same as saying them).
  static Future<bool> _say(String command) async {
    await SnapyCore.send(command, source: 'quick_action');
    return true;
  }

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, Future<bool> Function() run) => SizedBox(
          width: 148,
          child: OutlinedButton.icon(
            onPressed: () => _run(run),
            icon: Icon(icon),
            label: Text(label, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
        );
    return SnapyCard(
      title: tr('tools.quick_title'),
      subtitle: tr('tools.quick_sub'),
      icon: Icons.bolt,
      iconColor: SnapyColors.of(context).orange,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            action(_torch ? Icons.flashlight_off : Icons.flashlight_on, tr('tools.torch'), () async {
              final on = !_torch;
              var ok = false;
              try {
                ok = await SnapyCore.toggleTorch(on);
              } catch (_) {
                ok = await _say(on ? 'turn on the torch' : 'turn off the torch');
              }
              if (ok && mounted) setState(() => _torch = on);
              return ok;
            }),
            action(Icons.videocam_outlined, tr('tools.video_front'), () => NextApi.captureVideo('front')),
            action(Icons.video_camera_back_outlined, tr('tools.video_back'), () => NextApi.captureVideo('back')),
            action(Icons.screenshot_outlined, tr('tools.screenshot'), () => _say('take a screenshot')),
            action(Icons.lock_outline, tr('tools.lock'), () => _say('lock the phone')),
          ]),
        ),
      ],
    );
  }
}
