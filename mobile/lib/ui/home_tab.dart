import 'package:flutter/material.dart';

import '../core/next_api.dart';
import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'assistant_panel.dart';
import 'daily_three.dart';
import 'life_section.dart';
import 'orb.dart';
import 'profile_store.dart';
import 'realcount.dart';

/// Opens the chat with Snapy as a bottom sheet (same panel as over other apps).
void openAssistant(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: SnapyColors.of(context).bg,
    builder: (ctx) => SizedBox(height: MediaQuery.of(ctx).size.height * 0.75, child: const AssistantPanel()),
  );
}

/// Home: the chip preview, today's numbers with per-app icons, today's three, what's coming
/// up, the latest meeting note, memory highlights and "Ask Snapy".
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});
  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  @override
  void initState() {
    super.initState();
    ProfileStore.load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(children: [
          const SizedBox(height: 8),
          Center(
            child: Semantics(
              button: true,
              label: tr('chip.talk_hint'),
              child: GestureDetector(onTap: () => openAssistant(context), child: const HeaderPill()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 2),
            child: ValueListenableBuilder<SnapyProfile>(
              valueListenable: ProfileStore.notifier,
              builder: (_, p, _) => Semantics(
                header: true,
                child: Text(p.name.isEmpty ? tr('home.greeting_anon') : tr('home.greeting', {'name': p.name}), style: text.headlineMedium),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(tr('home.tagline'), style: text.bodySmall),
          ),
          const RealCountSection(),
          const DailyThreeCard(),
          const LifeSection(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: FilledButton.icon(
              onPressed: () => openAssistant(context),
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(tr('home.ask')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The Real Count chip (in-app copy of the system chip beside the camera).
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
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await SnapyCore.status();
      if (!(s['usage'] ?? false)) return;
      final t = await SnapyCore.today();
      // same text as the chip over other apps: "5h 16m · ▶ 42"
      if (mounted) setState(() => _value = tr('chip.text', {'time': formatMs(t.screenMs), 'reels': '${t.totalReels}'}));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: c.hair),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Orb(size: 30, interactive: false),
        const SizedBox(width: 10),
        Text(tr('home.real_count'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
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
