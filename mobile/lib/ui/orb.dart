import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Snapy's living AI orb: smoothly turns, breaths, and transitions through radiant
/// spectral color palettes. Tapping the orb triggers an energetic bloom, haptic feedback,
/// and cycles the color palette, matching the desktop floating pill orb.
class Orb extends StatefulWidget {
  final double size;
  final bool active;          // listening / thinking: spins faster
  final bool interactive;     // tap to cycle colors & pulse
  final bool autoShift;       // automatically morph between colors periodically
  final VoidCallback? onTap;

  const Orb({
    super.key,
    this.size = 28,
    this.active = false,
    this.interactive = true,
    this.autoShift = true,
    this.onTap,
  });

  /// Spectral palettes matching & expanding on desktop HUD (app/orb.js)
  static const List<List<Color>> palettes = [
    // 0: Cyan Electric (desktop HUD listening / primary AI presence)
    [Color(0xFF28C8FF), Color(0xFF3CFFC8), Color(0xFF78A0FF)],
    // 1: Snapy Classic (Indigo / Violet / Cyan)
    [Color(0xFF5E81FF), Color(0xFF966EFF), Color(0xFF46C8FF)],
    // 2: Thinking (Ultraviolet / Neon Magenta / Violet)
    [Color(0xFFAA5AFF), Color(0xFFFF5AC8), Color(0xFF5A78FF)],
    // 3: Speaking (Radiant Sky Blue / Ice / Periwinkle)
    [Color(0xFF5AAAFF), Color(0xFFBEDCFF), Color(0xFF826EFF)],
    // 4: Sunset Aura (Amber Gold / Coral Rose / Purple)
    [Color(0xFFFF9F0A), Color(0xFFFF375F), Color(0xFFBF5AF2)],
    // 5: Emerald Aurora (Neon Green / Mint / Aqua)
    [Color(0xFF30D158), Color(0xFF00F2FE), Color(0xFF66FF99)],
  ];

  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with TickerProviderStateMixin {
  late final AnimationController _turnAnim =
      AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat();
  late final AnimationController _pulseAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
  late final AnimationController _colorAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  late Animation<double> _scale;

  int _paletteIndex = 0;
  List<Color> _fromPalette = Orb.palettes[0];
  List<Color> _toPalette = Orb.palettes[0];
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.88).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
      TweenSequenceItem(tween: Tween(begin: 0.88, end: 1.10).chain(CurveTween(curve: Curves.easeOutBack)), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.10, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 25),
    ]).animate(_pulseAnim);

    if (widget.autoShift) {
      _startAutoShift();
    }
  }

  void _startAutoShift() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      _nextPalette(userInitiated: false);
    });
  }

  void _nextPalette({bool userInitiated = true}) {
    if (userInitiated) {
      HapticFeedback.lightImpact();
      _pulseAnim.forward(from: 0.0);
    }
    setState(() {
      _fromPalette = _interpolatedPalette(_colorAnim.value);
      _paletteIndex = (_paletteIndex + 1) % Orb.palettes.length;
      _toPalette = Orb.palettes[_paletteIndex];
      _colorAnim.forward(from: 0.0);
    });
  }

  List<Color> _interpolatedPalette(double t) {
    return List.generate(3, (i) {
      return Color.lerp(_fromPalette[i], _toPalette[i], t) ?? _toPalette[i];
    });
  }

  @override
  void didUpdateWidget(Orb old) {
    super.didUpdateWidget(old);
    _turnAnim.duration = Duration(milliseconds: widget.active ? 2200 : 9000);
    if (!_turnAnim.isAnimating) _turnAnim.repeat();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _turnAnim.dispose();
    _pulseAnim.dispose();
    _colorAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;

    Widget child = SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_turnAnim, _pulseAnim, _colorAnim]),
        builder: (_, _) {
          final t = reduce ? 0.0 : _turnAnim.value * 2 * math.pi;
          final currentColors = _interpolatedPalette(_colorAnim.value);
          final scale = reduce ? 1.0 : _scale.value;

          return Transform.scale(
            scale: scale,
            child: CustomPaint(
              painter: _OrbPainter(
                t: t,
                colors: currentColors,
                glow: widget.active || _pulseAnim.isAnimating,
              ),
            ),
          );
        },
      ),
    );

    if (widget.interactive) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _nextPalette(userInitiated: true);
          widget.onTap?.call();
        },
        child: child,
      );
    }

    return child;
  }
}

class _OrbPainter extends CustomPainter {
  final double t;
  final List<Color> colors;
  final bool glow;

  _OrbPainter({required this.t, required this.colors, this.glow = false});

  @override
  void paint(Canvas canvas, Size s) {
    final r = s.width / 2;
    final center = Offset(r, r);

    // 1. Soft atmospheric halo around the orb
    final haloPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          colors[0].withValues(alpha: glow ? 0.45 : 0.22),
          colors[1].withValues(alpha: glow ? 0.20 : 0.08),
          Colors.transparent,
        ],
        stops: const [0.4, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: r * 1.15));
    canvas.drawCircle(center, r * 1.15, haloPaint);

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r * 0.96)));

    // 2. Base spherical gradient (pure luminous white center falloff to primary color)
    canvas.drawCircle(
      center,
      r * 0.96,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.35),
          colors: [Colors.white, colors[0]],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: r * 0.96)),
    );

    // 3. Multi-harmonic spectral light blobs (moving inside the sphere)
    for (var i = 0; i < 3; i++) {
      final a = t + i * 2.1;
      final rr = r * (0.38 + 0.10 * math.sin(t * 0.8 + i));
      final p = center + Offset(math.cos(a), math.sin(a * 1.12)) * rr;
      canvas.drawCircle(
        p,
        r * 0.80,
        Paint()
          ..blendMode = BlendMode.screen
          ..shader = RadialGradient(
            colors: [
              colors[i].withValues(alpha: 0.95),
              colors[i].withValues(alpha: 0.0),
            ],
            stops: const [0.0, 1.0],
          ).createShader(Rect.fromCircle(center: p, radius: r * 0.80)),
      );
    }

    // 4. Glassy specular reflection (top-left highlight)
    final highlightPos = center + Offset(-r * 0.32, -r * 0.38);
    canvas.drawCircle(
      highlightPos,
      r * 0.50,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.65),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: highlightPos, radius: r * 0.50)),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.t != t || old.colors != colors || old.glow != glow;
}
