import 'dart:math' as math;

import 'package:flutter/material.dart';

/// "Show some emojis": the same floating burst as the Windows HUD (never blocks taps).
class EmojiBurst {
  static void show(BuildContext context, List<String> emojis) {
    if (emojis.isEmpty) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (_) => IgnorePointer(child: _Burst(emojis, onDone: () => entry.remove())));
    overlay.insert(entry);
  }
}

class _Burst extends StatefulWidget {
  final List<String> emojis;
  final VoidCallback onDone;
  const _Burst(this.emojis, {required this.onDone});
  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200))
    ..forward().whenComplete(widget.onDone);
  final _rnd = math.Random();
  late final _parts = List.generate(24, (i) => (
        x: 0.04 + _rnd.nextDouble() * 0.92,
        size: 26.0 + _rnd.nextDouble() * 30,
        delay: _rnd.nextDouble() * 0.3,
        drift: (_rnd.nextDouble() - 0.5) * 80,
        e: widget.emojis[i % widget.emojis.length],
      ));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final reduce = MediaQuery.of(context).disableAnimations;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Stack(
        children: _parts.map((p) {
          final t = ((_c.value - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
          final rise = reduce ? 0.4 : Curves.easeOutCubic.transform(t);
          final opacity = t < 0.15 ? t / 0.15 : (t > 0.8 ? (1 - t) / 0.2 : 1.0);
          return Positioned(
            left: p.x * size.width + p.drift * t,
            top: size.height - rise * size.height * 0.85,
            child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: Text(p.e, style: TextStyle(fontSize: p.size))),
          );
        }).toList(),
      ),
    );
  }
}
