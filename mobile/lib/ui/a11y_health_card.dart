import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/oem.dart';
import 'battery_guide.dart';

/// Home card for a Reel counter that is switched on in Settings but not running
/// (A11yHealth state "stopped": the phone's battery manager or a crash stopped Snapy), with the
/// brand's steps to keep it alive and a button back to Accessibility settings. When it is
/// "off" and Android's restricted-settings block applies (sideloaded APK, Android 13+), it
/// offers the existing sideload guide instead ([onSideloadGuide]).
class A11yHealthCard extends StatelessWidget {
  final A11yHealth health;
  final bool restricted;
  final VoidCallback onSideloadGuide;
  const A11yHealthCard({super.key, required this.health, required this.restricted, required this.onSideloadGuide});

  /// Show nothing when it's on, or off for an ordinary reason (the setup banner covers that).
  static bool wanted(A11yHealth? h, bool restricted) => h != null && (h.stopped || (h.off && restricted));

  @override
  Widget build(BuildContext context) {
    if (!wanted(health, restricted)) return const SizedBox.shrink();
    final c = SnapyColors.of(context);
    final oem = oemOf(health.manufacturer);
    final stopped = health.stopped;
    return Container(
      key: const ValueKey('a11y-health-card'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.orange.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.report_gmailerrorred_rounded, color: c.orange, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(tr(stopped ? 'home.a11y_stopped_title' : 'home.a11y_restricted_title'),
                style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(tr(stopped ? 'home.a11y_stopped_body' : 'home.a11y_restricted_body'), style: TextStyle(color: c.text2, fontSize: 13)),
        if (stopped) ...[
          const SizedBox(height: 8),
          Text(tr('home.a11y_steps.$oem'), style: TextStyle(color: c.text, fontSize: 13, height: 1.4)),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: stopped ? () => SnapyCore.openRealCountSettings().catchError((_) {}) : onSideloadGuide,
            icon: Icon(stopped ? Icons.accessibility_new : Icons.security_rounded, size: 18),
            label: Text(tr(stopped ? 'home.a11y_turn_on' : 'home.a11y_sideload')),
          ),
          if (stopped)
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BatteryGuidePage())),
              child: Text(tr('home.a11y_battery_guide')),
            ),
        ]),
      ]),
    );
  }
}
