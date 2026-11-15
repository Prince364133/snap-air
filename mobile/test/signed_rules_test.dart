import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core/files.dart';
import 'package:snapy/realcount/ed25519.dart';
import 'package:snapy/realcount/privacy.dart';
import 'package:snapy/realcount/rules.dart';
import 'package:snapy/realcount/signed_rules.dart';

List<int> hex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

// RFC 8032 §7.1, TEST 1 (empty message)
const rfcPk = 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
const rfcSig = 'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b';

// Same RFC key signing {"version":2,"nudges":{"session_reels":25}} (made with the RFC reference code)
const pkB64 = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=';
const payloadB64 = 'eyJ2ZXJzaW9uIjoyLCJudWRnZXMiOnsic2Vzc2lvbl9yZWVscyI6MjV9fQ==';
const sigB64 = 'oP+S8B6HV/+e/l+F9/+hS6ZDAKjDMR1kkG1VDp9QRRPBlJaB89EmNkUS4CcbQWT8D2Cgtlkr5vi/eCJjOlmACQ==';

String envelope({String payload = payloadB64, String sig = sigB64}) => jsonEncode({'payload': payload, 'sig': sig});

void main() {
  group('ed25519', () {
    test('RFC 8032 test 1 verifies', () {
      expect(ed25519Verify(hex(rfcPk), const [], hex(rfcSig)), isTrue);
    });
    test('a changed message, signature or key fails', () {
      expect(ed25519Verify(hex(rfcPk), const [0x72], hex(rfcSig)), isFalse);
      final bad = hex(rfcSig)..[10] ^= 1;
      expect(ed25519Verify(hex(rfcPk), const [], bad), isFalse);
      final badKey = hex(rfcPk)..[0] ^= 1;
      expect(ed25519Verify(badKey, const [], hex(rfcSig)), isFalse);
      expect(ed25519Verify(hex(rfcPk), const [], hex(rfcSig).sublist(0, 63)), isFalse);
    });
  });

  test('signed envelope opens only with the right key', () {
    expect(openSignedRules(envelope(), pkB64)!['version'], 2);
    final tampered = base64.encode(utf8.encode('{"version":3,"nudges":{"session_reels":1}}'));
    expect(openSignedRules(envelope(payload: tampered), pkB64), isNull);
    expect(openSignedRules('not json', pkB64), isNull);
    expect(openSignedRules(envelope(), base64.encode(List.filled(32, 7))), isNull);
  });

  group('weekly updater', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('snapy_rules_');
      SnapyFiles.overrideRoot = tmp;
    });
    tearDown(() {
      SnapyFiles.overrideRoot = null;
      tmp.deleteSync(recursive: true);
    });

    final rules = RealCountRules.from({'rules_update': {'url': 'https://rules.example/realcount.json', 'public_key': pkB64}});
    final now = DateTime(2026, 11, 15);

    test('off until a URL and key are configured', () async {
      expect(await RulesUpdater(fetch: (_) async => envelope()).maybeUpdate(RealCountRules.fallback, now), RulesUpdate.off);
    });

    test('caches a good file, then waits a week', () async {
      var calls = 0;
      final u = RulesUpdater(fetch: (_) async { calls++; return envelope(); });
      expect(await u.maybeUpdate(rules, now), RulesUpdate.updated);
      expect((await RulesUpdater.cached())!['nudges'], {'session_reels': 25});
      expect(await u.maybeUpdate(rules, now.add(const Duration(days: 3))), RulesUpdate.notDue);
      expect(calls, 1);
      expect(await u.maybeUpdate(rules, now.add(const Duration(days: 8))), RulesUpdate.unchanged);   // same version
      // the cached rules override config
      final merged = RealCountRules.from(const {}, override: await RulesUpdater.cached());
      expect(merged.i('nudges.session_reels'), 25);
      expect(merged.i('nudges.opens_per_hour'), 10);
      // the check shows on the privacy receipt
      final n = DateTime.now();
      final sent = await Receipts.sent(year: n.year, month: n.month);
      expect(sent.map((s) => '${s.what}@${s.to}'), contains('rules_check@rules.example'));
    });

    test('a bad signature is rejected and the last good file stays', () async {
      await RulesUpdater(fetch: (_) async => envelope()).maybeUpdate(rules, now);
      final evil = base64.encode(utf8.encode('{"version":9,"nudges":{"session_reels":1}}'));
      expect(await RulesUpdater(fetch: (_) async => envelope(payload: evil)).maybeUpdate(rules, now, force: true), RulesUpdate.rejected);
      expect((await RulesUpdater.cached())!['version'], 2);
    });

    test('offline: failed, cache kept, retried next time', () async {
      expect(await RulesUpdater(fetch: (_) async => throw const SocketException('offline')).maybeUpdate(rules, now), RulesUpdate.failed);
      expect(await RulesUpdater(fetch: (_) async => envelope()).maybeUpdate(rules, now), RulesUpdate.updated);
    });
  });
}
