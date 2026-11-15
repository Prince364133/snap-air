import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'home_tab.dart';
import 'onboarding.dart';
import 'profile_tab.dart';
import 'tools_tab.dart';

/// Home · Tools · Profile in a floating dynamic capsule dock. An IndexedStack keeps each tab's
/// state (scroll position, edits) while switching. First launch shows the onboarding.
class MainScaffold extends StatefulWidget {
  /// Tests start on a tab, or skip the first-launch check.
  final int initialTab;
  final bool checkOnboarding;
  const MainScaffold({super.key, this.initialTab = 0, this.checkOnboarding = true});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  late int _tab = widget.initialTab;
  final _visited = <int>{};

  @override
  void initState() {
    super.initState();
    _visited.add(_tab);
    if (widget.checkOnboarding) _checkFirstLaunch();
  }

  Future<void> _checkFirstLaunch() async {
    try {
      final p = await SnapyCore.rcPrefs();
      if (p['onboarding_done'] == true || !mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OnboardingFlow()));
      });
    } catch (_) {
      // no platform (tests) or prefs unavailable: go straight to Home
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // a tab is built the first time it's opened, then kept alive by the IndexedStack
    Widget lazy(int i, Widget w) => _visited.contains(i) ? w : const SizedBox.shrink();

    Widget dockItem(int index, IconData icon, IconData activeIcon, String label) {
      final selected = _tab == index;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            _tab = index;
            _visited.add(index);
          }),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: selected ? c.accent.withValues(alpha: 0.16) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  selected ? activeIcon : icon,
                  color: selected ? c.accent : c.text3,
                  size: 24,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? c.accent : c.text3,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: _tab, children: [
        lazy(0, const HomeTab()),
        lazy(1, const ToolsTab()),
        lazy(2, const ProfileTab()),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: (isDark ? const Color(0xFF14161F) : Colors.white).withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: c.hair),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    dockItem(0, Icons.home_outlined, Icons.home_rounded, tr('nav.home')),
                    dockItem(1, Icons.handyman_outlined, Icons.handyman_rounded, tr('nav.tools')),
                    dockItem(2, Icons.person_outline_rounded, Icons.person_rounded, tr('nav.profile')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
