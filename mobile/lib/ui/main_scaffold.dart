import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'home_tab.dart';
import 'onboarding.dart';
import 'profile_tab.dart';
import 'tools_tab.dart';

/// Home · Tools · Profile in a Material 3 NavigationBar. An IndexedStack keeps each tab's
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
    // a tab is built the first time it's opened, then kept alive by the IndexedStack
    Widget lazy(int i, Widget w) => _visited.contains(i) ? w : const SizedBox.shrink();
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        lazy(0, const HomeTab()),
        lazy(1, const ToolsTab()),
        lazy(2, const ProfileTab()),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() {
          _tab = i;
          _visited.add(i);
        }),
        backgroundColor: c.surface,
        indicatorColor: c.accentSoft,
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home, color: c.accent), label: tr('nav.home')),
          NavigationDestination(icon: const Icon(Icons.handyman_outlined), selectedIcon: Icon(Icons.handyman, color: c.accent), label: tr('nav.tools')),
          NavigationDestination(icon: const Icon(Icons.person_outline), selectedIcon: Icon(Icons.person, color: c.accent), label: tr('nav.profile')),
        ],
      ),
    );
  }
}
