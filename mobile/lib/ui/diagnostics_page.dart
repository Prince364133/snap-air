import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/next_api.dart';
import '../core/theme.dart';
import '../i18n/i18n.dart';
import 'common.dart';

/// Settings → Diagnostics: the crash reports Snapy keeps on the phone (files/diag, SnapyApp.kt
/// CrashLog) and the Reel counter's health, so a problem can be reported and fixed. Nothing is
/// sent anywhere; Copy puts one report on the clipboard for the user to share.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  List<CrashReport> _reports = const [];
  String _reelLog = '';
  A11yHealth? _health;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await NextApi.crashReports();
    final h = await NextApi.a11yHealth();
    final log = await NextApi.reelDebug();
    if (!mounted) return;
    setState(() {
      _reports = r;
      _reelLog = log;
      _health = h;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    await NextApi.clearCrashReports();
    if (mounted) toast(context, tr('diag.cleared'));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = SnapyColors.of(context);
    final h = _health;
    return Scaffold(
      appBar: AppBar(title: Text(tr('diag.title')), backgroundColor: c.bg, actions: [
        if (_reports.isNotEmpty)
          TextButton(key: const ValueKey('diag-clear'), onPressed: _clear, child: Text(tr('diag.clear'))),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.monitor_heart_outlined, color: c.accent),
                title: Text(tr('diag.counter')),
                subtitle: Text(h == null ? tr('diag.unknown') : tr('diag.state.${h.state}')),
              ),
              // what the counter saw while you scrolled (open a reels feed, swipe a few, come back)
              Card(
                child: ExpansionTile(
                  key: const ValueKey('diag-reels'),
                  leading: Icon(Icons.slow_motion_video, color: c.accent),
                  title: Text(tr('diag.reel_events'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(tr('diag.reel_events_sub')),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: SelectableText(_reelLog.isEmpty ? tr('diag.reel_events_none') : _reelLog,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5)),
                    ),
                    if (_reelLog.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: _reelLog));
                            if (context.mounted) toast(context, tr('diag.copied'));
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: Text(tr('diag.copy')),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(),
              if (_reports.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(tr('diag.none'), textAlign: TextAlign.center, style: TextStyle(color: c.text2)),
                )
              else
                for (final r in _reports)
                  Card(
                    child: ExpansionTile(
                      title: Text(r.file, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: Text(r.text.split('\n').firstWhere((l) => l.startsWith('where='), orElse: () => '').replaceFirst('where=', ''),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: SelectableText(r.text, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: r.text));
                              if (context.mounted) toast(context, tr('diag.copied'));
                            },
                            icon: const Icon(Icons.copy, size: 16),
                            label: Text(tr('diag.copy')),
                          ),
                        ),
                      ],
                    ),
                  ),
            ]),
    );
  }
}
