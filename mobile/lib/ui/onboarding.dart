import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'main_scaffold.dart';
import 'orb.dart';

/// One permission step: why we ask, what happens without it, how to grant it.
class PermStep {
  final String id; // i18n: perm.<id>.title / why / without
  final String? statusKey; // key in SnapyCore.status(); null = nothing to grant now
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
    if (s == AppLifecycleState.resumed) _refresh(); // back from Android Settings
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

/// Friendly, delightful onboarding flow that introduces the user to their
/// on-device AI guardian, sets up personalized names, guides through permissions
/// with clear visual step-by-step instructions, and launches into the main app.
class OnboardingFlow extends StatefulWidget {
  final bool isInitialSetup;
  const OnboardingFlow({super.key, this.isInitialSetup = true});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final TextEditingController _userCtrl = TextEditingController(text: 'Boss');
  final TextEditingController _aiCtrl = TextEditingController(text: 'Snapy');

  Map<String, bool> _permStatus = const {};
  bool _wakeWordOptIn = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialPrefs();
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _userCtrl.dispose();
    _aiCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions();
    }
  }

  Future<void> _loadInitialPrefs() async {
    try {
      final p = await SnapyCore.rcPrefs();
      if ((p['user_name'] as String?)?.isNotEmpty == true) {
        _userCtrl.text = p['user_name'] as String;
      }
      if ((p['ai_name'] as String?)?.isNotEmpty == true) {
        _aiCtrl.text = p['ai_name'] as String;
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _refreshPermissions() async {
    try {
      final s = await SnapyCore.status();
      if (mounted) {
        setState(() => _permStatus = s);
      }
    } catch (_) {}
  }

  void _nextPage() {
    if (_currentPage < 5) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finishOnboarding();
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOutCubic,
      );
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _finishOnboarding() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final uName = _userCtrl.text.trim().isEmpty ? 'Boss' : _userCtrl.text.trim();
      final aName = _aiCtrl.text.trim().isEmpty ? 'Snapy' : _aiCtrl.text.trim();
      await SnapyCore.setRcPrefs({
        'onboarding_done': true,
        'user_name': uName,
        'ai_name': aName,
        'wake_enabled': _wakeWordOptIn,
      });

      if (_wakeWordOptIn) {
        await SnapyCore.setWakeWord(true).catchError((_) => false);
      }

      if (_permStatus['overlay'] == true) {
        await SnapyCore.startChip().catchError((_) => false);
      }
    } catch (_) {}

    if (mounted) {
      if (widget.isInitialSetup) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainScaffold(checkOnboarding: false)),
          (route) => false,
        );
      } else {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const MainScaffold(checkOnboarding: false)),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _prevPage,
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Orb(size: 20, active: false, interactive: false),
            const SizedBox(width: 8),
            Text(
              'Step ${_currentPage + 1} of 6',
              style: TextStyle(fontSize: 14, color: c.text2, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_currentPage + 1) / 6.0,
                  backgroundColor: c.hair,
                  valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                  minHeight: 4,
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const BouncingScrollPhysics(),
                onPageChanged: (idx) => setState(() => _currentPage = idx),
                children: [
                  _buildWelcomePage(c),
                  _buildReelGuardianPage(c),
                  _buildOverlayPage(c),
                  _buildUsageAccessPage(c),
                  _buildMicPage(c),
                  _buildCelebrationPage(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Page 1: Welcome & Personalization
  Widget _buildWelcomePage(SnapyColors c) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        const SizedBox(height: 12),
        const Center(
          child: Orb(size: 80, active: true, interactive: true),
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text(
            'Meet Your AI Guardian ✨',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'A private on-device companion that tracks your phone use, breaks doomscrolling loops, and assists you hands-free.',
            style: TextStyle(fontSize: 14, color: c.text2, height: 1.4),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 32),
        _buildSectionCard(
          c,
          title: 'Personalize Your Experience',
          icon: Icons.person_outline,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What should I call you?', style: TextStyle(color: c.text2, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              TextField(
                controller: _userCtrl,
                decoration: InputDecoration(
                  hintText: 'e.g. Boss, Alex',
                  filled: true,
                  fillColor: c.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: c.hair),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: c.hair),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text('What do you want to name me?', style: TextStyle(color: c.text2, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              TextField(
                controller: _aiCtrl,
                decoration: InputDecoration(
                  hintText: 'e.g. Snapy, Jarvis',
                  filled: true,
                  fillColor: c.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: c.hair),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: c.hair),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: _nextPage,
          style: FilledButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: const Text("Let's Get Started ✨", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  /// Page 2: Short-Form Reel Guardian (Accessibility)
  Widget _buildReelGuardianPage(SnapyColors c) {
    final granted = _permStatus['realcount'] == true;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        _buildHeaderIcon(Icons.play_circle_filled, c.accent),
        const SizedBox(height: 16),
        const Text(
          'Reels & Shorts Guardian',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Automatically counts reels you watch on Instagram, YouTube Shorts, Snapchat, etc., right beside your front camera.',
          style: TextStyle(fontSize: 14, color: c.text2, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          c,
          title: 'Feed Lock Defense',
          icon: Icons.shield_outlined,
          child: Text(
            'When you reach your daily reel limit, it smoothly bounces out of the addictive short-video feed while keeping direct messages and home feeds completely accessible!',
            style: TextStyle(fontSize: 13, color: c.text2, height: 1.4),
          ),
        ),
        const SizedBox(height: 16),
        _buildStepsGuide(
          c,
          steps: [
            '1. Tap "Turn On Guardian" below to open Accessibility',
            '2. Tap "Installed apps" (or "Downloaded apps")',
            '3. Tap "Snapy" and toggle the switch ON',
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.hair),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: c.accent),
                  const SizedBox(width: 6),
                  Text('Android 13+ Security Note', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: c.text)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'If Android says "Restricted setting unavailable": Open App Info, tap the 3 dots in the top right corner, and select "Allow restricted settings".',
                style: TextStyle(fontSize: 11, color: c.text2, height: 1.3),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => SnapyCore.openAppDetails(),
                  icon: const Icon(Icons.settings_applications, size: 14),
                  label: const Text('Open App Info', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (granted)
          _buildGrantedBanner(c, 'Guardian Service Active & Ready')
        else
          FilledButton.icon(
            onPressed: () async {
              final isRestricted = await SnapyCore.isRestrictedSettings();
              if (!mounted) return;
              if (isRestricted) {
                _showRestrictedHelp(context);
                return;
              }
              SnapyCore.openRealCountSettings();
            },
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Turn On Guardian', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _nextPage,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(granted ? 'Continue' : 'Skip for now'),
        ),
      ],
    );
  }

  void _showRestrictedHelp(BuildContext context) {
    final c = SnapyColors.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: c.bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                  Icon(Icons.security_rounded, color: c.accent, size: 24),
                  const SizedBox(width: 10),
                  Text('Android Sideload Verification', style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 17)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Because Snapy was installed as an APK, Android requires a 1-time security unlock before enabling accessibility:\n\n'
                '1. Tap "Open App Info" below.\n'
                '2. Tap the ⋮ (three dots) at top-right corner.\n'
                '3. Select "Allow restricted permissions".\n'
                '4. Return here and tap "Turn On Guardian".',
                style: TextStyle(color: c.text2, fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        SnapyCore.openRealCountSettings();
                      },
                      child: const Text('Go to Settings'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        SnapyCore.openAppDetails();
                      },
                      child: const Text('Open App Info'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Page 3: Display Over Other Apps (Camera Punch-Hole Halo)
  Widget _buildOverlayPage(SnapyColors c) {
    final granted = _permStatus['overlay'] == true;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        _buildHeaderIcon(Icons.lens_blur, c.accent),
        const SizedBox(height: 16),
        const Text(
          'Camera Punch-Hole Halo',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Snapy hugs your front camera with an interactive living halo ring. The camera lens stays completely clear while the glowing aura indicates active status.',
          style: TextStyle(fontSize: 14, color: c.text2, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          c,
          title: 'Interactive Dropped Strip',
          icon: Icons.unfold_more,
          child: Text(
            'Touch the camera halo anytime to drop a sleek status strip displaying your screen time and reel count. Tap left to open the AI assistant, or tap right to launch your active social feed.',
            style: TextStyle(fontSize: 13, color: c.text2, height: 1.4),
          ),
        ),
        const SizedBox(height: 16),
        _buildStepsGuide(
          c,
          steps: [
            '1. Tap "Allow Camera Overlay" below',
            '2. Find "Snapy" in the list of applications',
            '3. Switch "Allow display over other apps" to ON',
          ],
        ),
        const SizedBox(height: 24),
        if (granted)
          _buildGrantedBanner(c, 'Camera Punch-Hole Halo Active')
        else
          FilledButton.icon(
            onPressed: () => SnapyCore.openOverlaySettings(),
            icon: const Icon(Icons.layers_outlined),
            label: const Text('Allow Camera Overlay', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _nextPage,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(granted ? 'Continue' : 'Skip for now'),
        ),
      ],
    );
  }

  /// Page 4: Usage Access (Screen Time & Stats)
  Widget _buildUsageAccessPage(SnapyColors c) {
    final granted = _permStatus['usage'] == true;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        _buildHeaderIcon(Icons.timer_outlined, c.orange),
        const SizedBox(height: 16),
        const Text(
          'Screen Time & Wellness',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Provides accurate screen time statistics and per-app usage so you can understand your daily phone habits.',
          style: TextStyle(fontSize: 14, color: c.text2, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          c,
          title: '100% On-Device Privacy',
          icon: Icons.lock_outline,
          child: Text(
            'Your app usage data never leaves this phone. No telemetry, no external ad tracking, and zero cloud uploads of your personal activity.',
            style: TextStyle(fontSize: 13, color: c.text2, height: 1.4),
          ),
        ),
        const SizedBox(height: 16),
        _buildStepsGuide(
          c,
          steps: [
            '1. Tap "Allow Usage Access" below',
            '2. Find "Snapy" in the list',
            '3. Turn "Permit usage access" ON',
          ],
        ),
        const SizedBox(height: 24),
        if (granted)
          _buildGrantedBanner(c, 'Usage Access Granted')
        else
          FilledButton.icon(
            onPressed: () => SnapyCore.openUsageAccess(),
            icon: const Icon(Icons.analytics_outlined),
            label: const Text('Allow Usage Access', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _nextPage,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(granted ? 'Continue' : 'Skip for now'),
        ),
      ],
    );
  }

  /// Page 5: Smart Hands-Free Activation (Microphone & Wake Word)
  Widget _buildMicPage(SnapyColors c) {
    final granted = _permStatus['microphone'] == true;
    final userName = _userCtrl.text.trim().isEmpty ? 'Boss' : _userCtrl.text.trim();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        _buildHeaderIcon(Icons.mic_none, c.green),
        const SizedBox(height: 16),
        const Text(
          'Smart Activation',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Wake your AI hands-free or with a single hardware button hold, even when your screen is locked.',
          style: TextStyle(fontSize: 14, color: c.text2, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          c,
          title: 'Hardware & Voice Shortcuts',
          icon: Icons.bolt,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.volume_up, size: 16, color: c.accent),
                  const SizedBox(width: 6),
                  const Text('Hardware Shortcut:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Hold Volume Up + Down together for 3 seconds anywhere to summon your AI with gentle haptic confirmation.',
                style: TextStyle(fontSize: 12, color: c.text2, height: 1.3),
              ),
              const Divider(height: 20),
              Row(
                children: [
                  Icon(Icons.record_voice_over, size: 16, color: c.accent),
                  const SizedBox(width: 6),
                  const Text('Voice Wake Word:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Say "Hey Snapy" to activate. Snapy replies: "Yes $userName, tell me!"',
                style: TextStyle(fontSize: 12, color: c.text2, height: 1.3),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.hair),
          ),
          child: SwitchListTile(
            value: _wakeWordOptIn,
            onChanged: (v) => setState(() => _wakeWordOptIn = v),
            title: const Text('Enable Voice Wake Word', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            subtitle: Text('Listens locally on device for the wake phrase', style: TextStyle(fontSize: 12, color: c.text2)),
            activeTrackColor: c.accent,
          ),
        ),
        const SizedBox(height: 24),
        if (granted)
          _buildGrantedBanner(c, 'Microphone Permission Granted')
        else
          FilledButton.icon(
            onPressed: () async {
              await SnapyCore.requestPermission('microphone');
              await _refreshPermissions();
            },
            icon: const Icon(Icons.mic),
            label: const Text('Enable Microphone', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _nextPage,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(granted ? 'Continue' : 'Skip for now'),
        ),
      ],
    );
  }

  /// Page 6: Celebration & Final Step
  Widget _buildCelebrationPage(SnapyColors c) {
    final userName = _userCtrl.text.trim().isEmpty ? 'Boss' : _userCtrl.text.trim();
    final aiName = _aiCtrl.text.trim().isEmpty ? 'Snapy' : _aiCtrl.text.trim();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        const SizedBox(height: 16),
        const Center(
          child: Orb(size: 88, active: true, interactive: true),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            "You're All Set, $userName! 🎉",
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            "$aiName is fully armed and guarding your digital wellness.",
            style: TextStyle(fontSize: 14, color: c.text2, height: 1.4),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 28),
        _buildSectionCard(
          c,
          title: 'Active Features Overview',
          icon: Icons.stars,
          child: Column(
            children: [
              _buildFeatureRow(Icons.shield_outlined, 'Reel Counter & Feed Limiter', 'Controls Instagram, YouTube Shorts, etc.', c),
              const Divider(height: 18),
              _buildFeatureRow(Icons.camera_alt_outlined, 'Camera Punch-Hole Halo', 'Dynamic halo & tap-to-drop status strip', c),
              const Divider(height: 18),
              _buildFeatureRow(Icons.tune_outlined, 'Tools & App Limits Tab', 'Set custom limits in the dedicated Tools tab', c),
              const Divider(height: 18),
              _buildFeatureRow(Icons.lock_outline, '100% On-Device Privacy', 'Zero external telemetry or data tracking', c),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.hair),
          ),
          child: Row(
            children: [
              Icon(Icons.key_outlined, size: 20, color: c.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Want your own Gemini API key? You can paste and test it anytime in Profile → Settings.',
                  style: TextStyle(fontSize: 12, color: c.text2, height: 1.3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: _finishOnboarding,
          style: FilledButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: _saving
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Enter Snapy 🚀', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _buildHeaderIcon(IconData icon, Color color) {
    return Center(
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 36, color: color),
      ),
    );
  }

  Widget _buildSectionCard(SnapyColors c, {required String title, required IconData icon, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.hair),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: c.accent),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildStepsGuide(SnapyColors c, {required List<String> steps}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.hair),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Easy 3-Step Setup:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: c.accent)),
          const SizedBox(height: 8),
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(step, style: TextStyle(fontSize: 12, color: c.text2, height: 1.3)),
            ),
        ],
      ),
    );
  }

  Widget _buildGrantedBanner(SnapyColors c, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.green.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.green.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: c.green, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: c.green, fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureRow(IconData icon, String title, String subtitle, SnapyColors c) {
    return Row(
      children: [
        Icon(icon, size: 20, color: c.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 11, color: c.text2)),
            ],
          ),
        ),
      ],
    );
  }
}
