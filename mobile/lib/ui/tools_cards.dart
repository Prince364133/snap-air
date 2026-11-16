import 'dart:async';

import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'common.dart';
import 'vault_page.dart';

/// Tools cards from docs/ANDROID_NEXT_PLAN.md §1: the meeting assistant (start/stop, timer,
/// live line, recent notes) and the quick actions test panel (torch, front/back video,
/// screenshot, lock screen).

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
      padding: const EdgeInsets.symmetric(vertical: 7),
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
      padding: const EdgeInsets.symmetric(vertical: 7),
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
