import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/realcount_data.dart';
import 'orb.dart';

/// Phase of the guided reset at [elapsed] of [total] seconds:
/// first half breathing (in 4 · hold 4 · out 6), then stand, then water.
String resetPhase(int elapsed, int total) {
  if (elapsed >= total) return 'done';
  if (elapsed < total ~/ 2) {
    final c = elapsed % 14;
    return c < 4 ? 'breathe_in' : (c < 8 ? 'hold' : 'breathe_out');
  }
  return elapsed < total * 3 ~/ 4 ? 'stand' : 'water';
}

/// The 2-minute guided Reset: breathe, stand, water — then back to whatever you were doing.
/// Soft friction: "Skip" is always there.
class ResetPage extends StatefulWidget {
  final String? app;
  final bool overlay;          // opened over another app (SheetActivity)
  final int? seconds;          // tests; otherwise rules nudges.reset_s
  const ResetPage({super.key, this.app, this.overlay = false, this.seconds});
  @override
  State<ResetPage> createState() => _ResetPageState();
}

class _ResetPageState extends State<ResetPage> {
  int _total = 120, _t = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _total = widget.seconds ?? 120;
    if (widget.seconds == null) {
      RealCountRepo.rules().then((r) {
        if (mounted) setState(() => _total = r.i('nudges.reset_s'));
      }).catchError((_) {});
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _t++);
      if (_t >= _total) _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _leave() {
    if (widget.overlay) {
      SnapyCore.closeSheet().catchError((_) {});
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final phase = resetPhase(_t, _total);
    final done = phase == 'done';
    final left = math.max(0, _total - _t);
    // breathing circle: grows on "in", holds, shrinks on "out"
    final c14 = _t % 14;
    final scale = phase == 'breathe_in' ? 0.7 + 0.3 * (c14 / 4) : (phase == 'hold' ? 1.0 : (phase == 'breathe_out' ? 1.0 - 0.3 * ((c14 - 8) / 6) : 0.85));
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Row(children: [
              Text(tr('reset.title'), style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (!done) Text('${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: TextStyle(color: c.text2, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
            const Spacer(),
            AnimatedScale(
              scale: scale,
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeInOut,
              child: const Orb(size: 180),
            ),
            const SizedBox(height: 40),
            Text(tr('reset.$phase'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
            const Spacer(),
            if (done)
              FilledButton(
                onPressed: _leave,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: Text(tr('reset.back')),
              )
            else
              TextButton(onPressed: _leave, child: Text(tr('reset.skip'))),
          ]),
        ),
      ),
    );
  }
}

/// The opt-in 10-second pause before a social app opens again after its soft limit.
/// Never a hard block: after the countdown the app is one tap away.
class BreakPage extends StatefulWidget {
  final String app;
  final int seconds;
  const BreakPage({super.key, required this.app, this.seconds = 10});
  @override
  State<BreakPage> createState() => _BreakPageState();
}

class _BreakPageState extends State<BreakPage> {
  late int _left = widget.seconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = math.max(0, _left - 1));
      if (_left == 0) _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final p = {'app': widget.app};
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Spacer(),
            SizedBox(
              width: 160,
              height: 160,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: widget.seconds == 0 ? 1 : 1 - _left / widget.seconds,
                    strokeWidth: 6,
                    color: c.orange,
                    backgroundColor: c.fill,
                  ),
                ),
                Text('$_left', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ),
            const SizedBox(height: 32),
            Text(tr('break.title'), style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(tr('break.sub', p), style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
            const Spacer(),
            FilledButton(
              onPressed: _left > 0 ? null : () => SnapyCore.closeSheet().catchError((_) {}),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(tr('break.open', p)),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await SnapyCore.goHome().catchError((_) {});
                await SnapyCore.closeSheet().catchError((_) {});
              },
              child: Text(tr('break.not_now')),
            ),
          ]),
        ),
      ),
    );
  }
}
