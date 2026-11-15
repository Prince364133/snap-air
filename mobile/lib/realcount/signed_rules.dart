/// Self-healing counters: a signed rules file (selectors, thresholds) fetched weekly.
///
/// Envelope served at `rules_update.url`:
///   `{"payload": "<base64 of the rules JSON bytes>", "sig": "<base64 Ed25519 signature of those bytes>"}`
/// The payload is a JSON object with an integer "version" plus any `android.realcount` keys.
/// Verified with `rules_update.public_key` (base64, from config). A bad signature, bad JSON
/// or an older version is rejected and the last good file stays in use. Verified payloads
/// are cached at snapy/rules/realcount.json, where the Kotlin counter also reads them.
library;

import 'dart:convert';
import 'dart:io';

import '../core/files.dart';
import 'ed25519.dart';
import 'privacy.dart';
import 'rules.dart';

/// Returns the payload when the envelope is validly signed, else null.
Map<String, dynamic>? openSignedRules(String envelope, String publicKeyB64) {
  try {
    final key = base64.decode(publicKeyB64.trim());
    final env = jsonDecode(envelope) as Map;
    final payload = base64.decode(env['payload'] as String);
    final sig = base64.decode(env['sig'] as String);
    if (!ed25519Verify(key, payload, sig)) return null;
    final rules = jsonDecode(utf8.decode(payload));
    if (rules is! Map || rules['version'] is! num) return null;
    return Map<String, dynamic>.from(rules);
  } catch (_) {
    return null;
  }
}

enum RulesUpdate { off, notDue, updated, unchanged, rejected, failed }

class RulesUpdater {
  static const cachePath = 'rules/realcount.json';
  static const metaPath = 'rules/realcount.meta.json';

  /// Injected for tests; the default uses dart:io HttpClient.
  final Future<String> Function(Uri url) fetch;
  RulesUpdater({Future<String> Function(Uri url)? fetch}) : fetch = fetch ?? _get;

  static Future<Map<String, dynamic>?> cached() async {
    final c = await SnapyFiles.readJson(cachePath);
    return c is Map ? Map<String, dynamic>.from(c) : null;
  }

  Future<RulesUpdate> maybeUpdate(RealCountRules rules, DateTime now, {bool force = false}) async {
    final url = rules.s('rules_update.url'), key = rules.s('rules_update.public_key');
    if (url.isEmpty || key.isEmpty) return RulesUpdate.off;
    final meta = (await SnapyFiles.readJson(metaPath) as Map?) ?? const {};
    final last = (meta['checked_ms'] as num?)?.toInt() ?? 0;
    if (!force && now.millisecondsSinceEpoch - last < rules.i('rules_update.interval_days') * 86400000) {
      return RulesUpdate.notDue;
    }
    String body;
    final uri = Uri.parse(url);
    try {
      body = await fetch(uri);
      await Receipts.logSent('rules_check', uri.host, 0);       // a plain GET: nothing about you is sent
    } catch (_) {
      return RulesUpdate.failed;               // offline: try again next time, keep the cache
    }
    final old = await cached();
    final payload = openSignedRules(body, key);
    final result = payload == null
        ? RulesUpdate.rejected
        : ((payload['version'] as num) <= ((old?['version'] as num?) ?? -1) ? RulesUpdate.unchanged : RulesUpdate.updated);
    if (result == RulesUpdate.updated) await SnapyFiles.writeJson(cachePath, payload);
    await SnapyFiles.writeJson(metaPath, {
      'checked_ms': now.millisecondsSinceEpoch,
      'result': result.name,
      'version': result == RulesUpdate.updated ? payload!['version'] : old?['version'],
    });
    return result;
  }

  static Future<String> _get(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(url);
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: url);
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }
}
