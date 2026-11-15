/// "Counter looks wrong" — an opt-in, anonymous fingerprint that helps fix selectors when a
/// social app updates. It holds only versions and which counters look paused: no account,
/// no device ID, no counts, no screen content. The user sees the exact JSON before anything.
library;

import 'dart:convert';

Map<String, dynamic> buildCounterReport({
  required Map<String, dynamic> device,          // {snapy_version, sdk, manufacturer, model?}
  required Map<String, String> appVersions,      // supported social apps installed -> versionName
  required String app,                           // the app the user says is wrong ('' = not sure)
  List<String> pausedApps = const [],
  Object? rulesVersion,
  bool creatorMode = false,
}) =>
    {
      'kind': 'counter_wrong',
      'snapy_version': device['snapy_version'],
      'android_sdk': device['sdk'],
      'manufacturer': device['manufacturer'],    // brand only: OEM layouts differ
      'app': app,
      'app_versions': Map.fromEntries(appVersions.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      'paused': pausedApps,
      'rules_version': rulesVersion,
      'creator_mode': creatorMode,
    };

String prettyReport(Map<String, dynamic> r) => const JsonEncoder.withIndent('  ').convert(r);

/// TODO(endpoint): no report endpoint exists yet. When one does, send [report] here (HTTPS POST),
/// then log it with Receipts.logSent('counter_report', host, bytes). Until then it's kept locally.
Future<bool> sendCounterReport(Map<String, dynamic> report) async => false;
