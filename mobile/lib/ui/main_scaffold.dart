import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import 'home_page.dart';
import 'onboarding.dart';
import 'profile_page.dart';
import 'tools_page.dart';

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    HomePage(),
    ToolsPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    _checkFirstLaunch();
  }

  Future<void> _checkFirstLaunch() async {
    try {
      final p = await SnapyCore.rcPrefs();
      final done = p['onboarding_done'] as bool? ?? false;
      if (!done && mounted) {
        // Automatically welcome new users with the cute guided onboarding
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OnboardingFlow(isInitialSetup: true)),
            );
          }
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        backgroundColor: c.surface,
        indicatorColor: c.accent.withValues(alpha: 0.2),
        elevation: 2,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home, color: c.accent),
            label: 'Home',
          ),
          NavigationDestination(
            icon: const Icon(Icons.handyman_outlined),
            selectedIcon: Icon(Icons.handyman, color: c.accent),
            label: 'Tools',
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person, color: c.accent),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
