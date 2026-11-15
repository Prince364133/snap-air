import 'dart:async';

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../sync/pair_screen.dart';
import 'common.dart';

/// Tools Tab:
///  1. App & Reel Limits (Reels limit, Daily hours limit, Hard lock vs Soft nudge).
///  2. Focus Mode (Fullscreen distraction blocker with countdown & camera ring sync).
///  3. Phone Auto-Unlock PIN (securely stored for hands-free automation).
///  4. Pair Laptop.
class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
              child: Text(
                'Tools & Habits',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                    ),
              ),
            ),
            const AppLimitsCard(),
            const SizedBox(height: 16),
            const FocusModeCard(),
            const SizedBox(height: 16),
            const AutoUnlockPinCard(),
            const SizedBox(height: 16),
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
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------- 1. App Limits
class AppLimitsCard extends StatefulWidget {
  const AppLimitsCard({super.key});
  @override
  State<AppLimitsCard> createState() => _AppLimitsCardState();
}

class _AppLimitsCardState extends State<AppLimitsCard> {
  List<Map<String, dynamic>> _apps = [];
  Map<String, int> _usedReels = {};
  Map<String, int> _usedTime = {};
  bool _loading = true;

  final List<Map<String, dynamic>> _catalog = [
    {'package': 'com.instagram.android', 'label': 'Instagram', 'kind': 'Reels', 'icon': Icons.camera_alt_outlined, 'color': Color(0xFFDD2A7B)},
    {'package': 'com.google.android.youtube', 'label': 'YouTube', 'kind': 'Shorts', 'icon': Icons.play_arrow_rounded, 'color': Color(0xFFFF0000)},
    {'package': 'com.whatsapp', 'label': 'WhatsApp', 'kind': 'Chat & Status', 'icon': Icons.chat_bubble_outline, 'color': Color(0xFF25D366)},
    {'package': 'com.facebook.katana', 'label': 'Facebook', 'kind': 'Reels & Feed', 'icon': Icons.facebook, 'color': Color(0xFF1877F2)},
    {'package': 'com.snapchat.android', 'label': 'Snapchat', 'kind': 'Spotlight', 'icon': Icons.photo_camera_outlined, 'color': Color(0xFFFFFC00)},
    {'package': 'com.zhiliaoapp.musically', 'label': 'TikTok', 'kind': 'Videos', 'icon': Icons.music_note_outlined, 'color': Color(0xFF00F2FE)},
    {'package': 'com.twitter.android', 'label': 'X (Twitter)', 'kind': 'Feed & Videos', 'icon': Icons.tag, 'color': Color(0xFF1DA1F2)},
    {'package': 'com.reddit.frontpage', 'label': 'Reddit', 'kind': 'Feed & Watch', 'icon': Icons.forum_outlined, 'color': Color(0xFFFF4500)},
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SnapyCore.rcPrefs();
      final today = await SnapyCore.today();

      final list = <Map<String, dynamic>>[];
      for (final item in _catalog) {
        final pkg = item['package'] as String;
        final reelLimit = prefs['limit_$pkg'] as int? ?? 100;
        final timeLimitMin = prefs['time_limit_$pkg'] as int? ?? 0;
        final lock = prefs['lock_$pkg'] as bool? ?? true;
        list.add({
          ...item,
          'reelLimit': reelLimit,
          'timeLimitMin': timeLimitMin,
          'lock': lock,
        });
      }

      final reels = {for (final e in today.reels.entries) e.key: e.value.reels};
      final time = {for (final e in today.perAppMs.entries) e.key: e.value ~/ 60000};

      if (mounted) {
        setState(() {
          _apps = list;
          _usedReels = reels;
          _usedTime = time;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _configureApp(Map<String, dynamic> app) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: SnapyColors.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _AppLimitConfigSheet(
        app: app,
        onSave: (reelLimit, timeLimitMin, lock) async {
          final pkg = app['package'] as String;
          await SnapyCore.setRcPrefs({
            'limit_$pkg': reelLimit,
            'time_limit_$pkg': timeLimitMin,
            'lock_$pkg': lock,
          });
          _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return SnapyCard(
      title: 'App & Reel Limits',
      subtitle: 'Set daily reel count and usage hour limits to prevent doomscrolling',
      icon: Icons.shield_outlined,
      children: [
        if (_loading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else ...[
          for (final a in _apps) ...[
            ListTile(
              onTap: () => _configureApp(a),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (a['color'] as Color).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(a['icon'] as IconData, color: a['color'] as Color, size: 22),
              ),
              title: Text(a['label'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              subtitle: Text(
                '${a['reelLimit'] > 0 ? "Reels: ${a['reelLimit']}" : "No reel limit"} · ${a['timeLimitMin'] > 0 ? "${a['timeLimitMin']}m time" : "No time limit"}${_usedTime[a['package']] != null && _usedTime[a['package']]! > 0 ? " · ${_usedTime[a['package']]}m today" : ""} · ${a['lock'] == true ? "Hard lock" : "Soft nudge"}',
                style: TextStyle(color: c.text2, fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_usedReels[a['package']] != null && _usedReels[a['package']]! > 0)
                    Text(
                      '${_usedReels[a['package']]} viewed',
                      style: TextStyle(color: c.accent, fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
            if (a != _apps.last) Divider(height: 1, indent: 64, color: c.hair),
          ],
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

class _AppLimitConfigSheet extends StatefulWidget {
  final Map<String, dynamic> app;
  final Function(int reelLimit, int timeLimitMin, bool lock) onSave;

  const _AppLimitConfigSheet({required this.app, required this.onSave});

  @override
  State<_AppLimitConfigSheet> createState() => _AppLimitConfigSheetState();
}

class _AppLimitConfigSheetState extends State<_AppLimitConfigSheet> {
  late int _reelLimit;
  late int _timeLimitMin;
  late bool _lock;

  @override
  void initState() {
    super.initState();
    _reelLimit = widget.app['reelLimit'] as int? ?? 100;
    _timeLimitMin = widget.app['timeLimitMin'] as int? ?? 0;
    _lock = widget.app['lock'] as bool? ?? true;
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final label = widget.app['label'] as String;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(width: 36, height: 4, decoration: BoxDecoration(color: c.hairStrong, borderRadius: BorderRadius.circular(2))),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(widget.app['icon'] as IconData, color: widget.app['color'] as Color, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Configure $label', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                    Text('Customize daily usage boundaries', style: TextStyle(color: c.text2, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 1. Reel Limit Stepper & Slider
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Reel Limit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              Text(_reelLimit > 0 ? '$_reelLimit reels' : 'Disabled (off)', style: TextStyle(color: c.accent, fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            value: _reelLimit.toDouble(),
            min: 0,
            max: 300,
            divisions: 30,
            activeColor: c.accent,
            onChanged: (v) => setState(() => _reelLimit = v.toInt()),
          ),

          const SizedBox(height: 12),

          // 2. Daily Time Limit
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Daily Time Limit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              Text(_timeLimitMin > 0 ? '${_timeLimitMin}m (${_timeLimitMin ~/ 60}h ${_timeLimitMin % 60}m)' : 'No limit', style: TextStyle(color: c.accent, fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            value: _timeLimitMin.toDouble(),
            min: 0,
            max: 240,
            divisions: 16,
            activeColor: c.green,
            onChanged: (v) => setState(() => _timeLimitMin = v.toInt()),
          ),

          const SizedBox(height: 12),

          // 3. Hard Lock vs Soft Nudge
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enforce Hard Feed Lock', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              _lock ? 'Automatically exits reels or app when limit is hit' : 'Displays a gentle pill notification without blocking',
              style: TextStyle(color: c.text2, fontSize: 12),
            ),
            value: _lock,
            onChanged: (v) => setState(() => _lock = v),
          ),

          const SizedBox(height: 20),

          FilledButton(
            onPressed: () {
              widget.onSave(_reelLimit, _timeLimitMin, _lock);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Save Limit Settings', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------- 2. Focus Mode
class FocusModeCard extends StatefulWidget {
  const FocusModeCard({super.key});
  @override
  State<FocusModeCard> createState() => _FocusModeCardState();
}

class _FocusModeCardState extends State<FocusModeCard> {
  int _selectedMinutes = 25;
  bool _isFocusing = false;
  int _remainingSeconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _checkFocusState();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkFocusState() async {
    try {
      final s = await SnapyCore.rcState();
      final focusUntil = s['focus_until'] as int? ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (focusUntil > now) {
        final remaining = (focusUntil - now) ~/ 1000;
        setState(() {
          _isFocusing = true;
          _remainingSeconds = remaining;
        });
        _startTimer();
      }
    } catch (_) {}
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_remainingSeconds <= 1) {
        t.cancel();
        setState(() {
          _isFocusing = false;
          _remainingSeconds = 0;
        });
      } else {
        setState(() => _remainingSeconds--);
      }
    });
  }

  Future<void> _startFocus() async {
    await SnapyCore.startFocus(_selectedMinutes);
    setState(() {
      _isFocusing = true;
      _remainingSeconds = _selectedMinutes * 60;
    });
    _startTimer();
    if (mounted) {
      _showFullscreenFocusDialog();
    }
  }

  Future<void> _stopFocus() async {
    _timer?.cancel();
    await SnapyCore.stopFocus();
    if (mounted) {
      setState(() {
        _isFocusing = false;
        _remainingSeconds = 0;
      });
    }
  }

  void _showFullscreenFocusDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _FullscreenFocusDialog(
        remainingSeconds: _remainingSeconds,
        onEnd: () {
          _stopFocus();
          Navigator.pop(ctx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final mins = _remainingSeconds ~/ 60;
    final secs = _remainingSeconds % 60;
    final timeStr = '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

    return SnapyCard(
      title: 'Distraction-Free Focus Mode',
      subtitle: 'Blocks social feeds and distraction apps with countdown timer HUD',
      icon: Icons.timer_outlined,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isFocusing) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: c.accent.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'FOCUS SESSION ACTIVE',
                        style: TextStyle(color: c.accent, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 1),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        timeStr,
                        style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 36,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Timer is active below front camera ring',
                        style: TextStyle(color: c.text2, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _showFullscreenFocusDialog,
                        child: const Text('View Blocker'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _stopFocus,
                        style: FilledButton.styleFrom(foregroundColor: c.red),
                        child: const Text('End Focus'),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [15, 25, 45, 60].map((m) {
                    final isSel = _selectedMinutes == m;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedMinutes = m),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSel ? c.accent : c.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isSel ? c.accent : c.hair),
                        ),
                        child: Text(
                          '${m}m',
                          style: TextStyle(
                            color: isSel ? Colors.white : c.text,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _startFocus,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text('Start $_selectedMinutes Min Focus Session'),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FullscreenFocusDialog extends StatefulWidget {
  final int remainingSeconds;
  final VoidCallback onEnd;

  const _FullscreenFocusDialog({required this.remainingSeconds, required this.onEnd});

  @override
  State<_FullscreenFocusDialog> createState() => _FullscreenFocusDialogState();
}

class _FullscreenFocusDialogState extends State<_FullscreenFocusDialog> {
  late int _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remaining = widget.remainingSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_remaining <= 1) {
        t.cancel();
        widget.onEnd();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mins = _remaining ~/ 60;
    final secs = _remaining % 60;
    final timeStr = '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0F1117),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF28C8FF).withValues(alpha: 0.15),
                  border: Border.all(color: const Color(0xFF28C8FF), width: 2),
                ),
                child: const Icon(Icons.spa_rounded, color: Color(0xFF28C8FF), size: 44),
              ),
              const SizedBox(height: 32),
              Text(
                timeStr,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 64,
                  letterSpacing: -2,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Deep Focus in Progress',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 20),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Distraction feeds are blocked. Maintain your flow state.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
              const Spacer(),
              FilledButton.tonal(
                onPressed: widget.onEnd,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('End Focus Session', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------- 3. Auto-Unlock PIN
class AutoUnlockPinCard extends StatefulWidget {
  const AutoUnlockPinCard({super.key});
  @override
  State<AutoUnlockPinCard> createState() => _AutoUnlockPinCardState();
}

class _AutoUnlockPinCardState extends State<AutoUnlockPinCard> {
  final _pinController = TextEditingController();
  bool _saving = false;
  bool _hasPin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await SnapyCore.rcPrefs();
      final pin = p['screen_unlock_pin'] as String? ?? '';
      if (mounted) {
        setState(() {
          _hasPin = pin.isNotEmpty;
          if (pin.isNotEmpty) _pinController.text = pin;
        });
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final pin = _pinController.text.trim();
    setState(() => _saving = true);
    try {
      await SnapyCore.setRcPrefs({'screen_unlock_pin': pin});
      if (mounted) {
        setState(() => _hasPin = pin.isNotEmpty);
        toast(context, pin.isEmpty ? 'PIN cleared' : 'Unlock PIN saved securely');
      }
    } catch (_) {
      if (mounted) toast(context, 'Failed to save PIN');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return SnapyCard(
      title: 'Phone Auto-Unlock PIN',
      subtitle: 'Configures your lockscreen PIN so Snapy can automate hands-free phone actions',
      icon: Icons.lock_open_rounded,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: 'Device Lockscreen PIN',
                  hintText: '4 to 6 digit numerical PIN',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.key_rounded),
                  suffixIcon: _hasPin ? const Icon(Icons.check_circle, color: Color(0xFF30D158)) : null,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Stored strictly on-device in encrypted hardware storage. Used only when you request autonomous voice actions while the screen is locked.',
                style: TextStyle(color: c.text2, fontSize: 12),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(_saving ? 'Saving...' : 'Save Unlock PIN'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
