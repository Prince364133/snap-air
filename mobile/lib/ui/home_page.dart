import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import 'assistant_panel.dart';
import 'life_section.dart';
import 'orb.dart';
import 'realcount.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _openAssistant(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: SnapyColors.of(context).bg,
      builder: (_) => SizedBox(height: MediaQuery.of(context).size.height * 0.75, child: const AssistantPanel()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const SizedBox(height: 8),
          Center(child: GestureDetector(onTap: () => _openAssistant(context), child: const HeaderPill())),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 8, 4),
            child: Row(children: [
              Text('Snapy', style: Theme.of(context).textTheme.headlineMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Tap the pill — here or at the top of any app — to talk to Snapy.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          const RealCountSection(),
          const LifeSection(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: () => _openAssistant(context),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Ask Snapy'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The Real Count chip (in-app copy of the system pill beside the camera).
class HeaderPill extends StatefulWidget {
  const HeaderPill({super.key});
  @override
  State<HeaderPill> createState() => _HeaderPillState();
}

class _HeaderPillState extends State<HeaderPill> {
  String _value = '—';

  @override
  void initState() {
    super.initState();
    SnapyCore.status().then((s) async {
      if (s['usage'] ?? false) {
        final t = await SnapyCore.today();
        if (mounted) setState(() => _value = formatMs(t.screenMs));
      }
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.fromLTRB(6, 0, 14, 0),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.hair),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Orb(size: 28),
        const SizedBox(width: 10),
        const Text('Real Count', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(width: 10),
        Container(width: 1, height: 16, color: c.hair),
        const SizedBox(width: 10),
        Icon(Icons.timer_outlined, size: 16, color: c.text2),
        const SizedBox(width: 4),
        Text(_value, style: TextStyle(color: c.text2, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}
