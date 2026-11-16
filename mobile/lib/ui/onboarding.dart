import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/oem.dart' show oemOf;
import 'main_scaffold.dart';
import 'orb.dart';
import 'profile_store.dart';
import 'profile_tab.dart' show VolumeShortcutGuide;

/// One permission card: why we ask, how to grant it, and what to tap in Settings.
class PermCard {
  final String id;          // i18n: onb.<id>.title / why / steps
  final String statusKey;   // key in SnapyCore.status()
  final IconData icon;
  const PermCard(this.id, this.statusKey, this.icon);
}

/// The plan's order (docs/ANDROID_NEXT_PLAN.md §2): Reel counter (prominent disclosure) →
/// Chip by the camera → Screen time → "Hey {assistant}" & buttons → Notifications.
const permCards = <PermCard>[
  PermCard('counter', 'realcount', Icons.play_circle_outline),
  PermCard('overlay', 'overlay', Icons.camera_outlined),
  PermCard('usage', 'usage', Icons.timer_outlined),
  PermCard('mic', 'microphone', Icons.mic_none),
  PermCard('notifications', 'notifications', Icons.notifications_none),
];

/// Phone families whose Settings screens differ (Nothing isn't in realcount/oem.dart's list).
String onboardingOem(Map<String, dynamic> device) {
  final m = '${device['manufacturer'] ?? ''} ${device['brand'] ?? ''}'.toLowerCase();
  if (m.contains('nothing')) return 'nothing';
  return oemOf('${device['manufacturer'] ?? ''}', '${device['brand'] ?? ''}');
}

/// The OEM note for a card, or null. Android 13+ gets the generic "restricted setting" hint.
String? oemNoteKey(String card, String oem, int sdk) {
  if (card == 'overlay') return oem == 'xiaomi' ? 'onb.oem.xiaomi_overlay' : null;
  if (card != 'counter') return null;
  switch (oem) {
    case 'xiaomi':
      return 'onb.oem.xiaomi_counter';
    case 'samsung':
      return 'onb.oem.samsung_counter';
    case 'oppo':
      return 'onb.oem.oppo_counter';
    case 'oneplus':
      return 'onb.oem.oneplus_counter';
    case 'nothing':
      return 'onb.oem.nothing_counter';
  }
  return sdk >= 33 ? 'onb.oem.generic_counter' : null;
}

/// Cute, guided first run: your name → what to call Snapy → five permission cards (each
/// skippable, refreshed when you come back from Settings) → confetti → Home. No API key here:
/// that lives in Profile → Settings only.
///
/// With [isInitialSetup] false (Settings → "Set up step by step") it opens straight on the
/// permission cards and returns to where it was opened from.
class OnboardingFlow extends StatefulWidget {
  final bool isInitialSetup;
  const OnboardingFlow({super.key, this.isInitialSetup = true});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> with WidgetsBindingObserver {
  final _pages = PageController();
  final _name = TextEditingController();
  final _assistant = TextEditingController(text: 'Snapy');
  int _i = 0;
  Map<String, bool> _status = const {};
  String _oem = 'other';
  int _sdk = 0;
  final Map<String, bool> _modes = {'wake': false, 'volume': false, 'power': false};
  ActivationModes? _act;        // shortcut / shortcutTarget for the volume-key setup steps
  bool _saving = false;

  bool get _intro => widget.isInitialSetup;
  int get _first => _intro ? 2 : 0;                  // index of the first permission card
  int get _count => _first + permCards.length + 1;   // + the celebration
  int get _doneIndex => _count - 1;
  String get _who => _name.text.trim();
  String get _assistantName => _assistant.text.trim().isEmpty ? 'Snapy' : _assistant.text.trim();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _loadDevice();
    _loadProfile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pages.dispose();
    _name.dispose();
    _assistant.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _refresh(); // back from Android Settings
      NextApi.activationModes().then((m) {
        if (mounted && m != null) setState(() => _act = m);
      });
    }
  }

  Future<void> _refresh() async {
    try {
      final st = await SnapyCore.status();
      if (mounted) setState(() => _status = st);
    } catch (_) {}
  }

  Future<void> _loadDevice() async {
    try {
      final d = await SnapyCore.device();
      if (mounted) setState(() { _oem = onboardingOem(d); _sdk = (d['sdk'] as num?)?.toInt() ?? 0; });
    } catch (_) {}
  }

  Future<void> _loadProfile() async {
    final p = await ProfileStore.load();
    final m = await NextApi.activationModes();
    if (!mounted) return;
    setState(() {
      if (_name.text.isEmpty && p.name.isNotEmpty) _name.text = p.name;
      if (p.assistantName.isNotEmpty) _assistant.text = p.assistantName;
      _act = m;
      if (m != null) {
        for (final k in _modes.keys.toList()) {
          _modes[k] = m.of(k);
        }
      }
    });
  }

  bool _reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _go(int i) {
    FocusScope.of(context).unfocus();
    if (_reduced(context)) {
      _pages.jumpToPage(i);
    } else {
      _pages.animateToPage(i, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  void _next() => _go(math.min(_i + 1, _doneIndex));

  void _back() {
    if (_i > 0) {
      _go(_i - 1);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _grant(PermCard card) async {
    try {
      switch (card.id) {
        case 'counter':
          var restricted = false;
          try {
            restricted = await SnapyCore.isRestrictedSettings();
          } catch (_) {}
          if (restricted) {
            if (mounted) _showRestrictedHelp();
            return;
          }
          await SnapyCore.openRealCountSettings();
        case 'overlay':
          await SnapyCore.openOverlaySettings();
        case 'usage':
          await SnapyCore.openUsageAccess();
        case 'mic':
          await SnapyCore.requestPermission('microphone');
        case 'notifications':
          await SnapyCore.requestNotifications();
      }
    } catch (_) {}
    await _refresh();
  }

  /// Sideloaded APKs on Android 13+ need "Allow restricted settings" before Accessibility.
  void _showRestrictedHelp() {
    final c = SnapyColors.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: c.bg,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.security_rounded, color: c.accent),
              const SizedBox(width: 10),
              Expanded(child: Text(tr('onb.restricted_title'), style: Theme.of(ctx).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 10),
            Text(tr('onb.restricted_body'), style: TextStyle(color: c.text2, height: 1.45)),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    SnapyCore.openRealCountSettings().catchError((_) {});
                  },
                  child: Text(tr('onb.go_settings')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    SnapyCore.openAppDetails().catchError((_) {});
                  },
                  child: Text(tr('onb.open_app_info')),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _setMode(String mode, bool on) async {
    setState(() => _modes[mode] = on);
    if (mode == 'power' && on) await NextApi.requestAssistantRole();
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    if (_intro) await ProfileStore.save(name: _who, assistantName: _assistantName);
    for (final e in _modes.entries) {
      await NextApi.setActivationMode(e.key, e.value);
    }
    try {
      await SnapyCore.setRcPrefs({'onboarding_done': true, 'wake_enabled': _modes['wake'] == true});
    } catch (_) {}
    // the microphone service starts here, while the app is visible (as Android requires)
    if (_modes['wake'] == true && (_status['microphone'] ?? false)) {
      try {
        await SnapyCore.setWakeWord(true);
      } catch (_) {}
    }
    if ((_status['overlay'] ?? false) && !(_status['realcount'] ?? false)) {
      try {
        await SnapyCore.startChip();
      } catch (_) {}
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (_intro) {
      nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const MainScaffold(checkOnboarding: false)), (_) => false);
    } else if (nav.canPop()) {
      nav.pop();
    } else {
      nav.pushReplacement(MaterialPageRoute(builder: (_) => const MainScaffold(checkOnboarding: false)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final showProgress = _i < _doneIndex;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: _i == 0 && _intro
            ? null
            : IconButton(tooltip: tr('onb.back'), icon: const Icon(Icons.arrow_back), onPressed: _back),
        automaticallyImplyLeading: !_intro,
        centerTitle: true,
        title: showProgress
            ? Semantics(
                label: tr('onb.progress', {'n': '${_i + 1}', 'total': '${_count - 1}'}),
                child: ExcludeSemantics(child: _Dots(count: _count - 1, index: _i)),
              )
            : null,
      ),
      body: SafeArea(
        child: PageView(
          controller: _pages,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (i) => setState(() => _i = i),
          children: [
            if (_intro) _namePage(c),
            if (_intro) _assistantPage(c),
            for (final card in permCards) _permPage(c, card),
            _donePage(c),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ steps 1–2

  Widget _ask({required Widget art, required String title, String? sub, required Widget field, required Widget actions}) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), children: [
      const SizedBox(height: 16),
      Center(child: art),
      const SizedBox(height: 28),
      Semantics(header: true, child: Text(title, textAlign: TextAlign.center, style: t.headlineMedium)),
      if (sub != null) ...[
        const SizedBox(height: 8),
        Text(sub, textAlign: TextAlign.center, style: t.bodySmall),
      ],
      const SizedBox(height: 28),
      field,
      const SizedBox(height: 20),
      actions,
    ]);
  }

  InputDecoration _field(SnapyColors c, String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: c.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(rLg), borderSide: BorderSide(color: c.hair)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(rLg), borderSide: BorderSide(color: c.hair)),
      );

  Widget _namePage(SnapyColors c) => _ask(
        art: _Hello(reduced: _reduced(context)),
        title: tr('onb.name_title'),
        sub: tr('onb.name_sub'),
        field: TextField(
          key: const ValueKey('onb-name'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 18),
          decoration: _field(c, tr('onb.name_hint')),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _who.isEmpty ? null : _next(),
        ),
        actions: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FilledButton(
            onPressed: _who.isEmpty ? null : _next,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: Text(tr('onb.next')),
          ),
          TextButton(
            onPressed: () {
              _name.clear();
              _next();
            },
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(tr('onb.skip')),
          ),
        ]),
      );

  Widget _assistantPage(SnapyColors c) => _ask(
        art: _Hello(reduced: _reduced(context), wave: false),
        title: _who.isEmpty ? tr('onb.assistant_title_anon') : tr('onb.assistant_title', {'name': _who}),
        sub: tr('onb.assistant_sub', {'assistant': _assistantName}),
        field: TextField(
          key: const ValueKey('onb-assistant'),
          controller: _assistant,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(fontSize: 18),
          decoration: _field(c, 'Snapy'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _next(),
        ),
        actions: FilledButton(
          onPressed: _next,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(tr('onb.next')),
        ),
      );

  // ------------------------------------------------------------------ step 3: permission cards

  Widget _permPage(SnapyColors c, PermCard card) {
    final t = Theme.of(context).textTheme;
    final a = {'assistant': _assistantName};
    final on = _status[card.statusKey] ?? false;
    final note = oemNoteKey(card.id, _oem, _sdk);
    final steps = tr('onb.${card.id}.steps', a).split('\n');
    final allow = card.id == 'counter' ? tr('perm.agree') : tr('onb.allow');
    return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
      _Illustration(kind: card.id, reduced: _reduced(context), label: tr('onb.illustration', {'what': tr('onb.${card.id}.title', a)})),
      const SizedBox(height: 20),
      Semantics(header: true, child: Text(tr('onb.${card.id}.title', a), style: t.headlineMedium)),
      const SizedBox(height: 6),
      Text(tr('onb.${card.id}.why', a), style: t.bodyMedium?.copyWith(color: c.text2)),
      const SizedBox(height: 12),
      _PrivacyBadge(text: tr('onb.privacy_badge')),
      if (card.id == 'counter') ...[
        // Play's prominent disclosure: shown in full before the user agrees
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(r)),
          child: Text(tr('perm.counter.disclosure'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        ),
        const SizedBox(height: 10),
        Text(tr('perm.counter.detail'), style: t.bodySmall),
      ],
      if (card.id == 'mic') ...[
        const SizedBox(height: 16),
        Text(tr('onb.mic.modes', a), style: t.titleMedium),
        for (final m in ['wake', 'volume', 'power'])
          CheckboxListTile(
            key: ValueKey('mode-$m'),
            contentPadding: EdgeInsets.zero,
            value: _modes[m],
            onChanged: (v) => _setMode(m, v ?? false),
            title: Text(tr('onb.mode.$m', a)),
          ),
        // the volume keys reach Snapy only once it is Android's accessibility-shortcut target
        if (_modes['volume'] == true && (_act == null || _act!.shortcutTarget != true))
          VolumeShortcutGuide(
            modes: ActivationModes(volume: true, shortcut: _act?.shortcut ?? (_status['realcount'] ?? false), shortcutTarget: _act?.shortcutTarget),
            assistant: _assistantName,
          ),
      ],
      const SizedBox(height: 16),
      _HowTo(steps: steps, note: note == null ? null : tr(note), reduced: _reduced(context),
          onAppInfo: note == null || card.id != 'counter' ? null : () => SnapyCore.openAppDetails().catchError((_) {})),
      const SizedBox(height: 20),
      if (on)
        Semantics(
          liveRegion: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(color: c.green.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(rLg)),
            child: Row(children: [
              Icon(Icons.check_circle, color: c.green),
              const SizedBox(width: 10),
              Text(tr('onb.granted'), style: TextStyle(color: c.green, fontWeight: FontWeight.w700)),
            ]),
          ),
        )
      else
        FilledButton(
          key: ValueKey('allow-${card.id}'),
          onPressed: () => _grant(card),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56), textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          child: Text(allow),
        ),
      const SizedBox(height: 8),
      if (on)
        FilledButton.tonal(
          onPressed: _next,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(tr('onb.continue')),
        )
      else
        TextButton(
          key: ValueKey('skip-${card.id}'),
          onPressed: _next,
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(tr('onb.skip_card')),
        ),
    ]);
  }

  // ------------------------------------------------------------------ step 4: celebration

  Widget _donePage(SnapyColors c) {
    final t = Theme.of(context).textTheme;
    return Stack(children: [
      Positioned.fill(child: IgnorePointer(child: _Confetti(play: _i == _doneIndex, reduced: _reduced(context)))),
      ListView(padding: const EdgeInsets.fromLTRB(24, 40, 24, 24), children: [
        Center(child: _Hello(reduced: _reduced(context), wave: false)),
        const SizedBox(height: 28),
        Semantics(
          header: true,
          child: Text(_who.isEmpty ? tr('onb.done_title_anon') : tr('onb.done_title', {'name': _who}), textAlign: TextAlign.center, style: t.headlineMedium),
        ),
        const SizedBox(height: 8),
        Text(tr('onb.done_sub', {'assistant': _assistantName}), textAlign: TextAlign.center, style: t.bodySmall),
        const SizedBox(height: 32),
        FilledButton(
          key: const ValueKey('onb-go'),
          onPressed: _saving ? null : _finish,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56), textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          child: Text(tr('onb.go')),
        ),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------------------- pieces

class _Dots extends StatelessWidget {
  final int count, index;
  const _Dots({required this.count, required this.index});
  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: i == index ? 18 : 7,
          height: 7,
          decoration: BoxDecoration(color: i <= index ? c.accent : c.hairStrong, borderRadius: BorderRadius.circular(4)),
        ),
    ]);
  }
}

class _PrivacyBadge extends StatelessWidget {
  final String text;
  const _PrivacyBadge({required this.text});
  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: c.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, size: 16, color: c.green),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: TextStyle(color: c.green, fontWeight: FontWeight.w600, fontSize: 13))),
        ]),
      ),
    );
  }
}

/// The friendly face on the name steps: Snapy's orb (static under reduced motion).
class _Hello extends StatelessWidget {
  final bool reduced, wave;
  const _Hello({required this.reduced, this.wave = true});
  @override
  Widget build(BuildContext context) {
    if (!reduced) return ExcludeSemantics(child: Orb(size: 96, active: wave, interactive: false));
    return ExcludeSemantics(
      child: Container(
        width: 96,
        height: 96,
        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: SweepGradient(colors: [...orbPalette, Color(0xFF5E81FF)])),
      ),
    );
  }
}

/// A looping (or, with reduced motion, still) picture for each permission, on a pastel
/// gradient made from the theme tokens. No network images.
class _Illustration extends StatefulWidget {
  final String kind, label;
  final bool reduced;
  const _Illustration({required this.kind, required this.reduced, required this.label});
  @override
  State<_Illustration> createState() => _IllustrationState();
}

class _IllustrationState extends State<_Illustration> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    if (!widget.reduced) _a.repeat();
  }

  @override
  void didUpdateWidget(_Illustration old) {
    super.didUpdateWidget(old);
    if (widget.reduced && _a.isAnimating) _a.stop();
    if (!widget.reduced && !_a.isAnimating) _a.repeat();
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final tint = switch (widget.kind) {
      'counter' => orbPalette[0],
      'overlay' => orbPalette[1],
      'usage' => c.orange,
      'mic' => c.green,
      _ => orbPalette[2],
    };
    return Semantics(
      image: true,
      label: widget.label,
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tint.withValues(alpha: 0.26), orbPalette[2].withValues(alpha: 0.12), c.card],
          ),
          border: Border.all(color: c.hair),
        ),
        child: AnimatedBuilder(
          animation: _a,
          builder: (_, _) => CustomPaint(painter: _IllustrationPainter(widget.kind, widget.reduced ? 0.35 : _a.value, tint, c)),
        ),
      ),
    );
  }
}

class _IllustrationPainter extends CustomPainter {
  final String kind;
  final double t;     // 0..1 loop
  final Color tint;
  final SnapyColors c;
  _IllustrationPainter(this.kind, this.t, this.tint, this.c);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final fill = Paint()..color = c.card;
    final line = Paint()
      ..color = c.hairStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final accent = Paint()..color = tint;
    final soft = Paint()..color = tint.withValues(alpha: 0.35);
    final wave = math.sin(t * 2 * math.pi);

    RRect phone() => RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, cy + 8), width: 86, height: 150), const Radius.circular(16));

    switch (kind) {
      case 'counter':
        final p = phone();
        canvas.drawRRect(p, fill);
        canvas.save();
        canvas.clipRRect(p.deflate(6));
        // reels sliding up
        final h = p.height - 12;
        final off = (t * h) % h;
        for (var i = -1; i < 2; i++) {
          final top = p.top + 6 - off + i * h;
          canvas.drawRRect(RRect.fromLTRBR(p.left + 6, top + 4, p.right - 6, top + h - 4, const Radius.circular(10)),
              Paint()..color = (i.isEven ? tint : orbPalette[2]).withValues(alpha: 0.30));
          canvas.drawCircle(Offset(cx, top + h / 2), 12, Paint()..color = c.card.withValues(alpha: 0.9));
          final path = Path()
            ..moveTo(cx - 4, top + h / 2 - 6)
            ..lineTo(cx + 7, top + h / 2)
            ..lineTo(cx - 4, top + h / 2 + 6)
            ..close();
          canvas.drawPath(path, accent);
        }
        canvas.restore();
        canvas.drawRRect(p, line);
        // the count badge
        final badge = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(p.right + 18, p.top + 26 - wave * 3), width: 48, height: 26), const Radius.circular(13));
        canvas.drawRRect(badge, accent);
        _text(canvas, '▶ 12', badge.center, Colors.white, 12);
      case 'overlay':
        final p = phone();
        canvas.drawRRect(p, fill);
        canvas.drawRRect(p, line);
        final cam = Offset(cx, p.top + 14);
        // the chip hugging the camera, gently breathing
        final w = 60 + wave * 4;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: cam, width: w, height: 18), const Radius.circular(9)), soft);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: cam, width: w, height: 18), const Radius.circular(9)), Paint()
          ..color = tint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
        canvas.drawCircle(cam, 5, Paint()..color = c.text);
        for (var i = 0; i < 3; i++) {
          canvas.drawRRect(RRect.fromLTRBR(p.left + 12, p.top + 44 + i * 26.0, p.right - 12, p.top + 60 + i * 26.0, const Radius.circular(6)), Paint()..color = c.fill);
        }
      case 'usage':
        const bars = [0.45, 0.8, 0.6, 0.95, 0.5];
        const bw = 22.0;
        final base = cy + 50;
        for (var i = 0; i < bars.length; i++) {
          final grow = ((t * 1.4 - i * 0.12).clamp(0.0, 1.0));
          final h = 100 * bars[i] * (0.35 + 0.65 * grow);
          final x = cx - (bars.length * (bw + 10)) / 2 + i * (bw + 10);
          canvas.drawRRect(RRect.fromLTRBR(x, base - h, x + bw, base, const Radius.circular(6)), i == 3 ? accent : soft);
        }
        canvas.drawLine(Offset(cx - 90, base + 2), Offset(cx + 90, base + 2), line);
      case 'mic':
        for (var i = 0; i < 3; i++) {
          final f = (t + i / 3) % 1.0;
          canvas.drawCircle(Offset(cx, cy), 30 + f * 50, Paint()
            ..color = tint.withValues(alpha: (1 - f) * 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
        }
        canvas.drawCircle(Offset(cx, cy), 30, accent);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, cy - 4), width: 14, height: 24), const Radius.circular(7)), Paint()..color = Colors.white);
        canvas.drawLine(Offset(cx, cy + 10), Offset(cx, cy + 16), Paint()
          ..color = Colors.white
          ..strokeWidth = 3);
      default: // notifications: a swinging bell
        canvas.save();
        canvas.translate(cx, cy - 40);
        canvas.rotate(wave * 0.25);
        final bell = Path()
          ..moveTo(-32, 56)
          ..quadraticBezierTo(-30, 8, 0, 6)
          ..quadraticBezierTo(30, 8, 32, 56)
          ..close();
        canvas.drawPath(bell, accent);
        canvas.drawCircle(const Offset(0, 4), 6, accent);
        canvas.drawCircle(const Offset(0, 64), 8, accent);
        canvas.restore();
        canvas.drawCircle(Offset(cx + 34, cy - 30), 10 + wave.abs() * 2, Paint()..color = c.red);
    }
  }

  void _text(Canvas canvas, String s, Offset center, Color color, double size) {
    final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w700)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_IllustrationPainter old) => old.t != t || old.kind != kind || old.tint != tint;
}

/// "What to tap": a mini Settings list where each step lights up in turn and the last row's
/// switch flips on. Under reduced motion every step is simply listed.
class _HowTo extends StatefulWidget {
  final List<String> steps;
  final String? note;
  final bool reduced;
  final VoidCallback? onAppInfo;
  const _HowTo({required this.steps, this.note, required this.reduced, this.onAppInfo});
  @override
  State<_HowTo> createState() => _HowToState();
}

class _HowToState extends State<_HowTo> {
  int _step = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_HowTo old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.reduced) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(milliseconds: 1600), (_) {
        if (mounted) setState(() => _step = (_step + 1) % (widget.steps.length + 1));
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    final n = widget.steps.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(rLg), border: Border.all(color: c.hair)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('onb.howto'), style: TextStyle(fontWeight: FontWeight.w700, color: c.accent, fontSize: 13)),
        const SizedBox(height: 8),
        for (var i = 0; i < n; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: !widget.reduced && i == _step ? c.accentSoft : c.fill.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(rSm),
            ),
            child: Row(children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: (widget.reduced || i <= _step) ? c.accent : c.hairStrong,
                child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.steps[i], style: const TextStyle(fontSize: 13.5))),
              if (i == n - 1)
                ExcludeSemantics(
                  child: IgnorePointer(
                    child: Transform.scale(
                      scale: 0.75,
                      child: Switch(value: widget.reduced || _step >= n - 1, onChanged: (_) {}),
                    ),
                  ),
                ),
            ]),
          ),
        if (widget.note != null) ...[
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 16, color: c.orange),
            const SizedBox(width: 6),
            Expanded(child: Text(widget.note!, style: small)),
          ]),
          if (widget.onAppInfo != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.onAppInfo,
                icon: const Icon(Icons.settings_applications, size: 18),
                label: Text(tr('onb.open_app_info')),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              ),
            ),
        ],
      ]),
    );
  }
}

/// A light, one-shot confetti burst (custom painter, ~40 pieces). Still under reduced motion.
class _Confetti extends StatefulWidget {
  final bool play, reduced;
  const _Confetti({required this.play, required this.reduced});
  @override
  State<_Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<_Confetti> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  final _rnd = math.Random(7);
  late final List<(double, double, double, int)> _bits =
      List.generate(40, (i) => (_rnd.nextDouble(), _rnd.nextDouble() * 0.5 + 0.5, _rnd.nextDouble() * 6.28, i % 5));

  @override
  void didUpdateWidget(_Confetti old) {
    super.didUpdateWidget(old);
    if (widget.play && !old.play && !widget.reduced) _a.forward(from: 0);
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final colors = [...orbPalette, c.orange, c.green];
    return AnimatedBuilder(
      animation: _a,
      builder: (_, _) => CustomPaint(
        painter: _ConfettiPainter(_bits, widget.reduced ? (widget.play ? 0.55 : 0) : _a.value, colors),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final List<(double, double, double, int)> bits;
  final double t;
  final List<Color> colors;
  _ConfettiPainter(this.bits, this.t, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    for (final (x, speed, spin, ci) in bits) {
      final y = -20 + t * speed * (size.height + 40);
      final dx = math.sin(t * 6 + spin) * 18;
      canvas.save();
      canvas.translate(x * size.width + dx, y);
      canvas.rotate(spin + t * 8);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-4, -7, 8, 14), const Radius.circular(2)),
          Paint()..color = colors[ci % colors.length].withValues(alpha: 1 - t * 0.6));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
