import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import 'assistant_panel.dart';
import 'orb.dart';

/// Opened by tapping the pill at the top of any app: a bottom sheet over that app.
/// Tap outside or swipe down to go back to what you were doing.
class SheetPage extends StatefulWidget {
  const SheetPage({super.key});
  @override
  State<SheetPage> createState() => _SheetPageState();
}

class _SheetPageState extends State<SheetPage> {
  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        Positioned.fill(child: GestureDetector(onTap: SnapyCore.closeSheet, behavior: HitTestBehavior.opaque)),
        NotificationListener<DraggableScrollableNotification>(
          onNotification: (n) {
            if (n.extent <= 0.12) SnapyCore.closeSheet();     // swiped down
            return false;
          },
          child: DraggableScrollableSheet(
            initialChildSize: 0.62,
            minChildSize: 0.1,
            maxChildSize: 0.95,
            builder: (ctx, scroll) => Container(
              decoration: BoxDecoration(
                color: c.bg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 30)],
              ),
              child: Column(children: [
                const SizedBox(height: 8),
                Container(width: 36, height: 5, decoration: BoxDecoration(color: c.hairStrong, borderRadius: BorderRadius.circular(3))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    const Orb(size: 32),
                    const SizedBox(width: 10),
                    Text('Snapy', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close_rounded, size: 20, color: c.text2),
                      tooltip: 'Close',
                      onPressed: SnapyCore.closeSheet,
                    ),
                  ]),
                ),
                Expanded(child: AssistantPanel(scrollController: scroll)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
