import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Snapy's presence: the same soft, slowly turning gradient orb as the Windows HUD.
class Orb extends StatefulWidget {
  final double size;
  final bool active;           // listening / thinking: spins faster
  const Orb({super.key, this.size = 28, this.active = false});

  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat();

  @override
  void didUpdateWidget(Orb old) {
    super.didUpdateWidget(old);
    _c.duration = Duration(milliseconds: widget.active ? 2200 : 9000);
    if (!_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(painter: _OrbPainter(reduce ? 0 : _c.value * 2 * math.pi)),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double t;
  _OrbPainter(this.t);

  @override
  void paint(Canvas canvas, Size s) {
    final r = s.width / 2;
    final center = Offset(r, r);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    canvas.drawCircle(center, r, Paint()
      ..shader = RadialGradient(center: const Alignment(-0.3, -0.4), colors: [Colors.white, orbPalette[0]])
          .createShader(Rect.fromCircle(center: center, radius: r)));
    for (var i = 0; i < 3; i++) {
      final a = t + i * 2.1;
      final p = center + Offset(math.cos(a), math.sin(a)) * r * 0.45;
      canvas.drawCircle(p, r * 0.75, Paint()
        ..blendMode = BlendMode.screen
        ..shader = RadialGradient(colors: [orbPalette[i].withValues(alpha: 0.95), orbPalette[i].withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: p, radius: r * 0.75)));
    }
    canvas.drawCircle(center + Offset(-r * 0.3, -r * 0.35), r * 0.45, Paint()
      ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)])
          .createShader(Rect.fromCircle(center: center + Offset(-r * 0.3, -r * 0.35), radius: r * 0.45)));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t;
}
