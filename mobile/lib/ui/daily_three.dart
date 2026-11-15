import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/habits.dart';
import '../realcount/realcount_data.dart';
import '../realcount/rules.dart';

/// Daily three: in the morning Snapy asks for 3 things that matter today, pins them on the
/// home screen, and in the evening the recap scores them (feeds the streak).
class DailyThreeCard extends StatefulWidget {
  final DateTime Function() clock;
  const DailyThreeCard({super.key, this.clock = DateTime.now});
  @override
  State<DailyThreeCard> createState() => _DailyThreeCardState();
}

class _DailyThreeCardState extends State<DailyThreeCard> {
  DailyThree? _three;
  RealCountRules _rules = RealCountRules.fallback;
  final _fields = List.generate(3, (_) => TextEditingController());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rules = await RealCountRepo.rules();
      final t = await RealCountRepo.three(widget.clock());
      if (mounted) setState(() { _rules = rules; _three = t; });
    } catch (_) {
      // no storage (tests, very first start): nothing to pin to, so no card
    }
  }

  Future<void> _save(DailyThree t) async {
    setState(() => _three = t);
    try {
      await RealCountRepo.saveThree(t);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = _three;
    if (t == null) return const SizedBox.shrink();
    final c = SnapyColors.of(context);
    final phase = t.phase(widget.clock(),
        askUntilMin: _rules.minutesOfDay('habits.three_ask_until'), recapAfterMin: _rules.minutesOfDay('habits.three_recap_after'));
    if (phase == ThreePhase.none) return const SizedBox.shrink();
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Row(children: [
          Expanded(child: Text(tr('three.title'), style: Theme.of(context).textTheme.titleMedium)),
          if (phase != ThreePhase.ask) Text(tr('three.score', {'done': '${t.done}'}), style: TextStyle(color: c.text2)),
        ]),
      ),
    ];
    if (phase == ThreePhase.ask) {
      children.addAll([
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(tr('three.ask'), style: Theme.of(context).textTheme.bodySmall)),
        for (final f in _fields)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: TextField(controller: f, decoration: InputDecoration(hintText: tr('three.hint'), isDense: true)),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () {
                final items = [for (final f in _fields) if (f.text.trim().isNotEmpty) ThreeItem(f.text.trim())];
                if (items.isNotEmpty) _save(DailyThree(t.date, items));
              },
              child: Text(tr('three.pin')),
            ),
          ),
        ),
      ]);
    } else {
      if (phase == ThreePhase.recap) {
        children.add(Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(tr('three.recap'), style: Theme.of(context).textTheme.bodySmall)));
      }
      for (var i = 0; i < t.items.length; i++) {
        children.add(CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: t.items[i].done,
          title: Text(t.items[i].text),
          onChanged: (_) => _save(DailyThree(t.date, [for (var j = 0; j < t.items.length; j++) j == i ? t.items[j].toggled() : t.items[j]])),
        ));
      }
      children.add(const SizedBox(height: 6));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: c.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}
