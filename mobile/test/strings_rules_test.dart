import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core/files.dart';
import 'package:snapy/i18n/i18n.dart';
import 'package:snapy/realcount/counter_report.dart';
import 'package:snapy/realcount/oem.dart';
import 'package:snapy/realcount/privacy.dart';
import 'package:snapy/realcount/rules.dart';

import 'helpers.dart';

void main() {
  setUpAll(useEnglish);

  test('every nudge the engine can produce has English text, soft variant and action labels', () {
    final keys = <String>[
      for (final k in ['session_reels', 'frequent_opens', 'soft_limit', 'bedtime', 'bedtime_task', 'focus_open',
        for (final o in intentionOptionsIds) 'intention_done_$o'])
        for (final v in ['', '_soft']) 'nudge.$k$v',
      for (final a in ['keep_going', 'reset', 'focus', 'dismiss', 'open_anyway', 'back_to_focus', 'wrap_up', 'wind_down']) 'action.$a',
      for (final o in intentionOptionsIds) 'intent.$o',
      for (final s in ['small', 'normal', 'large']) 'size.$s',
      for (final o in oemIds) ...['oem.$o.name', 'oem.$o.steps'],
      for (final p in ['usage', 'overlay', 'counter', 'notifications', 'mic', 'contacts']) 'perm.$p.title',
      for (final k in ['realcount', 'memory', 'tasks', 'notes', 'keys', 'models', 'rules', 'daily_three', 'receipts', 'reports', 'settings', 'chat', 'other'])
        'privacy.kind.$k',
      'chip.text', 'chip.paused', 'reset.breathe_in', 'reset.hold', 'reset.breathe_out', 'reset.stand', 'reset.water', 'reset.done',
    ];
    final missing = keys.where((k) => !I18n.current.has(k)).toList();
    expect(missing, isEmpty);
  });

  test('the Reel counter disclosure says exactly what the plan requires', () {
    expect(tr('perm.counter.disclosure'), 'Count Reels and Shorts. Never reads messages or what you type.');
  });

  test('no shame language in any string', () {
    final all = allEnglishText();
    for (final w in ['addict', 'shame', 'wasted', 'waste of', 'guilty', 'lazy', 'bad habit', 'too much']) {
      expect(all.contains(w), isFalse, reason: w);
    }
  });

  test('i18n: nested and flat keys, params, fallback to English then the key', () {
    final hi = I18n.fromJson('hi', '{"chip": {"text": "{time} · ▶ {reels} (hi)"}}', enJson: '{"a.b": "A", "chip.text": "x"}');
    expect(hi.t('chip.text', {'time': '1m', 'reels': '2'}), '1m · ▶ 2 (hi)');
    expect(hi.t('a.b'), 'A');
    expect(hi.t('missing.key'), 'missing.key');
    expect(I18n.resolve('auto', 'ta'), 'ta');
    expect(I18n.resolve('auto', 'fr'), 'en');
    expect(I18n.resolve('hi', 'en'), 'hi');
  });

  test('bundled rules file matches the safety-net defaults (and the Kotlin mirror)', () {
    final asset = jsonDecode(File('assets/rules/realcount.json').readAsStringSync()) as Map;
    final copy = Map.of(asset)..remove('_comment')..remove('version');
    expect(jsonEncode(copy), jsonEncode(RealCountRules.defaults));
  });

  test('the nudge defaults are the product spec', () {
    const r = RealCountRules.fallback;
    expect(r.i('nudges.min_gap_min'), 20);
    expect(r.i('nudges.session_reels'), 30);
    expect(r.i('nudges.opens_per_hour'), 10);
    expect(r.s('nudges.bedtime'), '23:00');
    expect(r.i('nudges.focus_min'), 25);
    expect(r.i('nudges.reset_s'), 120);
    expect(r.i('nudges.break_s'), 10);
    expect(r.i('nudges.soften_after_dismissals'), 2);
    expect(parseHm('23:00'), 1380);
  });

  test('OEM detection and deep-link order', () {
    expect(oemOf('Xiaomi', 'Redmi'), 'xiaomi');
    expect(oemOf('realme'), 'oppo');
    expect(oemOf('vivo'), 'vivo');
    expect(oemOf('samsung'), 'samsung');
    expect(oemOf('OnePlus'), 'oneplus');
    expect(oemOf('Google', 'google'), 'other');
    final t = targetsFor('xiaomi', null);
    expect(t.first.pkg, 'com.miui.securitycenter');
    expect(t.last.action, 'android.settings.APPLICATION_DETAILS_SETTINGS');
    expect(targetsFor('samsung', {'samsung': [{'pkg': 'a', 'cls': 'b'}]}).first.cls, 'b');
  });

  test('counter report is anonymous: versions only', () {
    final r = buildCounterReport(
      device: {'snapy_version': '1.0.0', 'sdk': 34, 'manufacturer': 'Xiaomi', 'model': 'X', 'android_id': 'secret'},
      appVersions: {'com.instagram.android': '300.0'},
      app: 'com.instagram.android',
    );
    expect(r.keys, isNot(contains('model')));
    expect(jsonEncode(r), isNot(contains('secret')));
    expect(r['app_versions'], {'com.instagram.android': '300.0'});
  });

  group('privacy receipts', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('snapy_priv_');
      SnapyFiles.overrideRoot = tmp;
    });
    tearDown(() {
      SnapyFiles.overrideRoot = null;
      tmp.deleteSync(recursive: true);
    });

    test('lists what was stored and sent this month, deletes one item', () async {
      File('${tmp.path}/realcount/2026-11-15.json')..createSync(recursive: true)..writeAsStringSync('{}');
      File('${tmp.path}/models/vosk/am/final.mdl')..createSync(recursive: true)..writeAsStringSync('x' * 2000);
      File('${tmp.path}/models/vosk/conf/model.conf')..createSync(recursive: true)..writeAsStringSync('y');
      await Receipts.logSent('rules_check', 'rules.example', 0);
      final n = DateTime.now();
      final stored = await Receipts.stored(year: n.year, month: n.month);
      expect(stored.map((s) => s.kind), containsAll(['realcount', 'models', 'receipts']));
      expect(stored.where((s) => s.kind == 'models').single.relative, 'models/vosk');   // one item per model
      expect((await Receipts.sent(year: n.year, month: n.month)).single.to, 'rules.example');
      final day = stored.firstWhere((s) => s.kind == 'realcount');
      expect(await Receipts.delete(day), isTrue);
      expect(File('${tmp.path}/realcount/2026-11-15.json').existsSync(), isFalse);
      expect(await Receipts.delete(StoredItem('../outside', 'other', 0, n)), isFalse);
    });

    test('kinds', () {
      expect(kindOf('realcount/usage-2026-11-15.json'), 'realcount');
      expect(kindOf('rules/realcount.json'), 'rules');
      expect(kindOf('weird/thing.bin'), 'other');
    });
  });
}

const intentionOptionsIds = ['dms', 'post', 'browse'];
