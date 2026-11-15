import 'package:flutter/material.dart';

import '../core/snapy_core.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import '../realcount/oem.dart';
import '../realcount/realcount_data.dart';

/// "Keep the counter running": per-brand steps (Xiaomi/MIUI-HyperOS, Oppo/Realme ColorOS,
/// Vivo Funtouch, Samsung One UI, OnePlus) with a button that tries the brand's own screen,
/// then Android's battery-optimisation list, then Snapy's app info page.
class BatteryGuidePage extends StatefulWidget {
  const BatteryGuidePage({super.key});
  @override
  State<BatteryGuidePage> createState() => _BatteryGuidePageState();
}

class _BatteryGuidePageState extends State<BatteryGuidePage> with WidgetsBindingObserver {
  String _oem = 'other';
  bool? _batteryOk;
  dynamic _override;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final d = await SnapyCore.device();
      final st = await SnapyCore.status();
      final rules = await RealCountRepo.rules();
      if (!mounted) return;
      setState(() {
        _oem = oemOf('${d['manufacturer'] ?? ''}', '${d['brand'] ?? ''}');
        _batteryOk = st['battery'];
        _override = rules.get('oem');
      });
    } catch (_) {}
  }

  Future<void> _open(String oem) async {
    for (final t in targetsFor(oem, _override)) {
      if (await SnapyCore.openTarget(t.toArgs()).catchError((_) => false)) return;
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('battery.not_found'))));
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    Widget guide(String oem, {bool mine = false}) {
      final steps = tr('oem.$oem.steps').split('\n');
      return Card(
        elevation: 0,
        color: c.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg), side: BorderSide(color: mine ? c.accent : c.hair)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('oem.$oem.name'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (var i = 0; i < steps.length; i++)
              Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('${i + 1}. ${steps[i]}')),
            if (mine) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: () => _open(oem), child: Text(tr('battery.open'))),
            ],
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('battery.title')), backgroundColor: c.bg),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr('battery.sub')),
        if (_batteryOk != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Icon(_batteryOk! ? Icons.check_circle : Icons.info_outline, color: _batteryOk! ? c.green : c.orange, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(_batteryOk! ? tr('battery.ok') : tr('battery.on'))),
          ]),
        ],
        const SizedBox(height: 16),
        Text(tr('battery.your_phone'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        guide(_oem, mine: true),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => _open('other'), child: Text(tr('battery.generic'))),
        const SizedBox(height: 24),
        Text(tr('battery.other_phones'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        for (final o in oemIds.where((o) => o != _oem && o != 'other')) Padding(padding: const EdgeInsets.only(bottom: 8), child: guide(o)),
      ]),
    );
  }
}
