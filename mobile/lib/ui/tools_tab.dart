import 'dart:async';

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../sync/pair_screen.dart';
import 'app_limits_page.dart';
import 'tools_cards.dart';

/// Tools Tab:
///  1. App & Reel Limits (Dedicated page fetching real device apps with real icons).
///  2. Distraction-Free Focus Mode (Deep work timer with DND and fullscreen blocker).
///  3. Pair with Laptop (Local desktop pairing).
class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 16),
              child: Text(
                'Tools & Habits',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                    ),
              ),
            ),

            // 1. App & Reel Limits Card
            _buildToolCard(
              context,
              icon: Icons.shield_outlined,
              iconColor: const Color(0xFF3CFFC8),
              title: 'App & Reel Limits',
              subtitle: 'Control doomscrolling and set daily reel and screen time limits for all your installed apps.',
              badge: 'Real-time',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppLimitsPage()),
              ),
            ),

            const SizedBox(height: 14),

            // 2. Distraction-Free Focus Mode Card
            const FocusModeCard(),

            const SizedBox(height: 7),
            const MeetingCard(),
            const QuickActionsCard(),

            const SizedBox(height: 14),

            // 3. Pair with Laptop Card
            _buildToolCard(
              context,
              icon: Icons.laptop_mac_rounded,
              iconColor: const Color(0xFF78A0FF),
              title: tr('tools.pair_title'),
              subtitle: tr('tools.pair_sub'),
              badge: 'Desktop Sync',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PairLaptopPage()),
              ),
            ),

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  Widget _buildToolCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String badge,
    required VoidCallback onTap,
  }) {
    final c = SnapyColors.of(context);

    return Material(
      color: c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: iconColor.withValues(alpha: 0.3)),
                ),
                child: Icon(icon, color: iconColor, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: iconColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            badge,
                            style: TextStyle(color: iconColor, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: TextStyle(color: c.text2, fontSize: 13, height: 1.35),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: c.text3, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------- Focus Mode Card
class FocusModeCard extends StatefulWidget {
  const FocusModeCard({super.key});

  @override
  State<FocusModeCard> createState() => _FocusModeCardState();
}

class _FocusModeCardState extends State<FocusModeCard> {
  bool _isFocusing = false;
  int _remainingSeconds = 0;
  int _selectedMinutes = 25;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _checkState();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkState() async {
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
    if (mounted) _showFullscreenFocusDialog();
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

    return Material(
      color: c.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: c.hair)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF28C8FF).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF28C8FF).withValues(alpha: 0.3)),
                  ),
                  child: const Icon(Icons.spa_rounded, color: Color(0xFF28C8FF), size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Distraction-Free Focus',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: (_isFocusing ? const Color(0xFF3CFFC8) : const Color(0xFF28C8FF)).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _isFocusing ? 'ACTIVE' : 'Deep Work',
                              style: TextStyle(
                                color: _isFocusing ? const Color(0xFF3CFFC8) : const Color(0xFF28C8FF),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isFocusing
                            ? 'Focus session in progress. Distraction feeds are blocked.'
                            : 'Mute all notifications, alarms and distractions for a pure flow state.',
                        style: TextStyle(color: c.text2, fontSize: 13, height: 1.35),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_isFocusing) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.accent.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
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
                    Text(tr('tools.focus_ambient'), style: TextStyle(color: c.text2, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _showFullscreenFocusDialog,
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                      child: Text(tr('tools.focus_view_blocker')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _stopFocus,
                      style: FilledButton.styleFrom(foregroundColor: c.red, minimumSize: const Size.fromHeight(44)),
                      child: Text(tr('tools.focus_end')),
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
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: isSel ? c.accent : c.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isSel ? c.accent : c.hair),
                      ),
                      child: Text(
                        '${m}m',
                        style: TextStyle(
                          color: isSel ? Colors.white : c.text,
                          fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _startFocus,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(tr('tools.focus_start_n', {'min': '$_selectedMinutes'})),
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ],
        ),
      ),
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
              Text(
                tr('tools.focus_in_progress'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 20),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  tr('tools.focus_blocker_line'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
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
                child: Text(tr('tools.focus_end_session'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
