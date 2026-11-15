import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';

/// One permission step: why we ask, what happens without it, how to grant it.
class PermStep {
  final String id;            // i18n: perm.<id>.title / why / without
  final String? statusKey;    // key in SnapyCore.status(); null = nothing to grant now
  final IconData icon;
  final Future<void> Function()? grant;
  const PermStep(this.id, this.statusKey, this.icon, this.grant);
}

/// The plan's order: Usage access → Display over other apps → Reel counter (prominent
/// disclosure) → Notifications → (opt-in) Microphone + wake word → Contacts/Phone on first use.
final permSteps = <PermStep>[
  PermStep('usage', 'usage', Icons.timer_outlined, SnapyCore.openUsageAccess),
  PermStep('overlay', 'overlay', Icons.picture_in_picture_alt_outlined, SnapyCore.openOverlaySettings),
  PermStep('counter', 'realcount', Icons.play_circle_outline, SnapyCore.openRealCountSettings),
  PermStep('notifications', 'notifications', Icons.notifications_none, SnapyCore.requestNotifications),
  PermStep('mic', 'microphone', Icons.mic_none, () => SnapyCore.requestPermission('microphone')),
  const PermStep('contacts', null, Icons.contacts_outlined, null),
];

/// Every step can be declined; the app keeps working with less.
class PermissionFlow extends StatefulWidget {
  const PermissionFlow({super.key});
  @override
  State<PermissionFlow> createState() => _PermissionFlowState();
}

class _PermissionFlowState extends State<PermissionFlow> with WidgetsBindingObserver {
  final _pages = PageController();
  int _i = 0;
  Map<String, bool> _status = const {};
  bool _wake = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pages.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();       // back from Android Settings
  }

  Future<void> _refresh() async {
    try {
      final st = await SnapyCore.status();
      if (mounted) setState(() => _status = st);
    } catch (_) {}
  }

  void _next() {
    if (_i >= permSteps.length - 1) {
      _finish();
      return;
    }
    _pages.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Future<void> _finish() async {
    // chip without the counter: "Display over other apps" was allowed, the Reel counter wasn't
    if ((_status['overlay'] ?? false) && !(_status['realcount'] ?? false)) {
      await SnapyCore.startChip().catchError((_) => false);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _grant(PermStep s) async {
    if (s.id == 'counter') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('perm.counter.disclosure')),
          content: SingleChildScrollView(child: Text(tr('perm.counter.detail'))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('perm.not_now'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('perm.agree'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await s.grant?.call();
      if (s.id == 'mic' && _wake) await SnapyCore.setWakeWord(true);
    } catch (_) {}
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('perm.title')), backgroundColor: c.bg),
      body: PageView.builder(
        controller: _pages,
        itemCount: permSteps.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (context, i) {
          final s = permSteps[i];
          final on = s.statusKey != null && (_status[s.statusKey] ?? false);
          final without = tr('perm.${s.id}.without');
          return ListView(padding: const EdgeInsets.all(24), children: [
            Text(tr('perm.step', {'n': '${i + 1}', 'total': '${permSteps.length}'}), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            Icon(s.icon, size: 48, color: c.accent),
            const SizedBox(height: 16),
            Text(tr('perm.${s.id}.title'), style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            if (s.id == 'counter') ...[
              // Google Play prominent disclosure: shown before the system screen
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(r)),
                child: Text(tr('perm.counter.disclosure'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
              const SizedBox(height: 12),
              Text(tr('perm.counter.detail')),
            ] else
              Text(tr('perm.${s.id}.why')),
            if (without.isNotEmpty && !without.startsWith('perm.')) ...[
              const SizedBox(height: 12),
              Text(without, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (s.id == 'mic')
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _wake,
                onChanged: (v) => setState(() => _wake = v ?? false),
                title: Text(tr('perm.mic.wake')),
              ),
            const SizedBox(height: 24),
            if (on)
              ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.check_circle, color: c.green), title: Text(tr('perm.granted')))
            else if (s.grant != null)
              FilledButton(
                onPressed: () => _grant(s),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: Text(s.id == 'counter' ? tr('perm.agree') : tr('perm.allow')),
              ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _next,
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(i == permSteps.length - 1 ? tr('perm.finish') : (on ? tr('common.continue') : tr('perm.not_now'))),
            ),
          ]);
        },
      ),
    );
  }
}
