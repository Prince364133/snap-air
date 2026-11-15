import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/privacy.dart';

/// Monthly privacy receipts: what Snapy stored on this phone and what it sent, one-tap delete.
class PrivacyReceiptsPage extends StatefulWidget {
  const PrivacyReceiptsPage({super.key});
  @override
  State<PrivacyReceiptsPage> createState() => _PrivacyReceiptsPageState();
}

class _PrivacyReceiptsPageState extends State<PrivacyReceiptsPage> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<StoredItem> _stored = const [];
  List<SentItem> _sent = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = await Receipts.stored(year: _month.year, month: _month.month).catchError((_) => <StoredItem>[]);
    final se = await Receipts.sent(year: _month.year, month: _month.month).catchError((_) => <SentItem>[]);
    if (mounted) setState(() { _stored = st; _sent = se; });
  }

  void _shift(int months) {
    setState(() => _month = DateTime(_month.year, _month.month + months));
    _load();
  }

  Future<void> _delete(StoredItem it) async {
    final what = tr('privacy.kind.${it.kind}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('privacy.delete_confirm', {'what': what.toLowerCase()})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.delete'))),
        ],
      ),
    );
    if (ok != true) return;
    final done = await Receipts.delete(it);
    if (!mounted) return;
    if (done) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('privacy.deleted'))));
    _load();
  }

  static String _size(int b) => b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : (b >= 1024 ? '${b ~/ 1024} KB' : '$b B');

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final loc = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    return Scaffold(
      appBar: AppBar(title: Text(tr('privacy.title')), backgroundColor: c.bg),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('privacy.note'), style: Theme.of(context).textTheme.bodySmall),
        Row(children: [
          IconButton(tooltip: tr('privacy.prev'), onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
          Expanded(child: Text(loc.formatMonthYear(_month), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
          IconButton(tooltip: tr('privacy.next'), onPressed: isCurrent ? null : () => _shift(1), icon: const Icon(Icons.chevron_right)),
        ]),
        Text(tr('privacy.sent'), style: Theme.of(context).textTheme.titleMedium),
        if (_sent.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr('privacy.none_sent'))),
        for (final s in _sent)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.north_east),
            title: Text(I18n.current.has('privacy.sent_kind.${s.what}') ? tr('privacy.sent_kind.${s.what}') : s.what),
            subtitle: Text('${s.to} · ${loc.formatShortDate(s.at)} ${TimeOfDay.fromDateTime(s.at).format(context)}'),
          ),
        const SizedBox(height: 16),
        Text(tr('privacy.stored'), style: Theme.of(context).textTheme.titleMedium),
        if (_stored.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr('privacy.none_stored'))),
        for (final it in _stored)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('privacy.kind.${it.kind}')),
            subtitle: Text('${it.relative} · ${_size(it.bytes)} · ${loc.formatShortDate(it.modified)}'),
            trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: tr('common.delete'), onPressed: () => _delete(it)),
          ),
      ]),
    );
  }
}
