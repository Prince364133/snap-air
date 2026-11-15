import 'dart:async';

import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';

/// Tasks and what Snapy remembers — the same data the shared brain uses.
class LifeSection extends StatefulWidget {
  const LifeSection({super.key});
  @override
  State<LifeSection> createState() => _LifeSectionState();
}

class _LifeSectionState extends State<LifeSection> {
  List<Map<String, dynamic>> _tasks = const [];
  List<Map<String, dynamic>> _memories = const [];
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    // refresh when the brain finishes a reply (it may have added a task or a memory)
    _sub = SnapyCore.events.listen((e) {
      if ((e['type'] == 'chat_message' && e['final'] != false) || e['type'] == 'reminders') _load();
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await SnapyCore.snapshot();
      if (!mounted) return;
      setState(() {
        _tasks = List<Map<String, dynamic>>.from((s['tasks'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        _memories = List<Map<String, dynamic>>.from((s['memories'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
      });
    } catch (_) {}
  }

  String _when(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final now = DateTime.now();
    final t = TimeOfDay.fromDateTime(d).format(context);
    return (d.year == now.year && d.month == now.month && d.day == now.day) ? t : '${d.day}/${d.month} $t';
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    Widget card(String title, List<Widget> rows, String empty) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Material(
            color: c.card,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: c.hair)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              if (rows.isEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: Text(empty, style: Theme.of(context).textTheme.bodySmall)),
              ...rows,
              if (rows.isNotEmpty) const SizedBox(height: 6),
            ]),
          ),
        );
    return Column(children: [
      card(
        'Tasks',
        _tasks.take(8).map((t) => CheckboxListTile(
              value: false,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text((t['title'] ?? '').toString()),
              subtitle: t['remind_at'] != null ? Text(_when(t['remind_at'] as String?)) : null,
              onChanged: (_) async { await SnapyCore.completeTask(t['id'] as String); _load(); },
            )).toList(),
        'Nothing pending. Try “remind me at 5 to call mom”.',
      ),
      card(
        'What Snapy remembers',
        _memories.reversed.take(6).map((m) => ListTile(dense: true, title: Text((m['text'] ?? '').toString()))).toList(),
        'Nothing yet. Say “remember that I prefer Slack” — or just talk; Snapy learns lasting facts.',
      ),
    ]);
  }
}
