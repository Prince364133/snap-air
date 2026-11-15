import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import 'reset_page.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  List<Map<String, dynamic>> _socialApps = [];
  bool _loading = true;
  bool _torchOn = false;
  Map<String, dynamic> _rcState = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final apps = await SnapyCore.getInstalledSocialApps();
      final rs = await SnapyCore.rcState().catchError((_) => <String, dynamic>{});
      if (mounted) {
        setState(() {
          _socialApps = apps;
          _rcState = rs;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updateLimit(String pkg, int newLimit, bool lock) async {
    await SnapyCore.setAppReelLimit(pkg, newLimit, lock);
    _load();
  }

  Future<void> _showLimitDialog(Map<String, dynamic> app) async {
    final pkg = app['package'] as String;
    final label = app['label'] as String;
    int limit = (app['limit'] as num?)?.toInt() ?? 100;
    bool lock = app['lock'] as bool? ?? true;

    final controller = TextEditingController(text: '$limit');

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Reels Limit · $label'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Set the maximum reels allowed per day. When you hit this limit, reels will be locked.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Daily Reels Limit',
                  hintText: 'e.g. 50 or 100',
                  suffixText: 'reels',
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null) limit = n;
                },
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lock Reels When Reached', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: const Text('Bounces out of the reels feed to home/messages so you cannot doomscroll', style: TextStyle(fontSize: 12)),
                value: lock,
                onChanged: (v) => setDialogState(() => lock = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(controller.text.trim()) ?? limit;
                _updateLimit(pkg, n, lock);
                Navigator.pop(ctx);
              },
              child: const Text('Save Limit'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final focusUntil = (_rcState['focus_until'] as num?)?.toInt() ?? 0;
    final focusOn = focusUntil > DateTime.now().millisecondsSinceEpoch;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tools & Governance'),
        backgroundColor: c.bg,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // 1. Reel Scrolling Limits Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
            color: c.card,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.shield_outlined, color: c.accent, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Reel Scrolling Limits', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            Text('Locks short video feeds when you hit your target', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                  else if (_socialApps.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12)),
                      child: const Text('No supported short-form video apps detected on this device.', style: TextStyle(fontSize: 13)),
                    )
                  else
                    ..._socialApps.map((app) {
                      final label = app['label'] as String;
                      final pkg = app['package'] as String;
                      final limit = (app['limit'] as num?)?.toInt() ?? 100;
                      final lock = app['lock'] as bool? ?? true;
                      final isInstalled = app['installed'] as bool? ?? false;

                      Color badgeColor = c.accent;
                      if (pkg.contains('instagram')) {
                        badgeColor = const Color(0xFFDD2A7B);
                      } else if (pkg.contains('youtube')) {
                        badgeColor = const Color(0xFFFF0000);
                      } else if (pkg.contains('snapchat')) {
                        badgeColor = const Color(0xFFFFD600);
                      } else if (pkg.contains('facebook')) {
                        badgeColor = const Color(0xFF1877F2);
                      } else if (pkg.contains('tiktok')) {
                        badgeColor = const Color(0xFF00F2FE);
                      } else if (pkg.contains('reddit')) {
                        badgeColor = const Color(0xFFFF4500);
                      }

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: badgeColor.withValues(alpha: 0.18),
                          child: Text(
                            label.isNotEmpty ? label[0] : 'S',
                            style: TextStyle(color: badgeColor, fontWeight: FontWeight.bold),
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isInstalled ? c.green.withValues(alpha: 0.15) : c.hair,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isInstalled ? 'Installed' : 'Ready',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: isInstalled ? c.green : c.text2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(
                          lock ? 'Limit: $limit reels/day · Lock active' : 'Limit: $limit reels/day · Soft nudge',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: OutlinedButton(
                          onPressed: () => _showLimitDialog(app),
                          child: const Text('Edit'),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. Focus Mode Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
            color: c.card,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: c.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.center_focus_strong, color: c.green, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Focus Session', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            Text('Pause distracting apps and notifications', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (focusOn)
                    FilledButton.icon(
                      onPressed: () async {
                        await SnapyCore.stopFocus();
                        _load();
                      },
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop Focus Session'),
                      style: FilledButton.styleFrom(
                        backgroundColor: c.red,
                        minimumSize: const Size.fromHeight(44),
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: () async {
                              await SnapyCore.startFocus(25);
                              _load();
                            },
                            child: const Text('25 min Pomodoro'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: () async {
                              await SnapyCore.startFocus(50);
                              _load();
                            },
                            child: const Text('50 min Deep Work'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 3. Meeting Assistant Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
            color: c.card,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.mic, color: Colors.purpleAccent, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Meeting Assistant', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            Text('Keeps notes even when phone is locked', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Say "Hey Snapy, I am in a meeting" or tap mic to start recording notes.')),
                      );
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Meeting Notes'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 4. Quick Device Automations
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
            color: c.card,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Device Automations', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final newState = !_torchOn;
                            final ok = await SnapyCore.toggleTorch(newState);
                            if (ok) setState(() => _torchOn = newState);
                          },
                          icon: Icon(_torchOn ? Icons.flashlight_off : Icons.flashlight_on),
                          label: Text(_torchOn ? 'Torch Off' : 'Torch On'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ResetPage()));
                          },
                          icon: const Icon(Icons.self_improvement),
                          label: const Text('Reset Mind'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
