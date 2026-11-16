// Shared-core conformance: every golden case in ../core/conformance/*.json (except sync/)
// against the Dart runtime, with the per-suite rules of core/README.md §9 — the same
// semantics as engine/tests/test_conformance.py. Failures list the case ids.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core_runtime/core_data.dart';
import 'package:snapy/core_runtime/local_intents.dart';
import 'package:snapy/core_runtime/realcount.dart';
import 'package:snapy/core_runtime/rules.dart';

import 'runtime_helpers.dart';

const defaultSettings = {
  'agent_name': 'Snapy',
  'wake_words': ['snapy', 'snappy', 'hey snapy', 'snap'],
};

typedef Runner = Object? Function(Map<String, dynamic> c);

/// JSON deep equality: booleans are not numbers; 1 == 1.0 (as in Python); key order ignored.
bool jsonEq(Object? a, Object? b) {
  if (a is bool || b is bool) return a == b;
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !jsonEq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

void main() {
  late CoreData core;
  late Rules rules;

  setUpAll(() async {
    core = await loadRepoCore();
    rules = Rules(core);
  });

  Map<String, Runner> runners() => {
        'phone_intents': (c) => {'action': rules.parsePhone(c['input'] as String, DateTime.parse(c['now'] as String))},
        'yes_no': (c) => {'match': core.anyMatch(c['domain'] as String, (c['input'] as String).trim())},
        'hinglish': (c) => {
              'command': rules.normalizeCommand(c['input'] as String),
              'question_or_creative': rules.isQuestionOrCreative(c['input'] as String),
              'lang': rules.detectLang(c['input'] as String),
            },
        'polite': (c) => {
              'plain': rules.plain(Rules.normalizeText(c['input'] as String)),
              'plain_original': rules.plainOriginal(c['input'] as String),
            },
        'ordinal': (c) {
          final (rest, n) = rules.ordinal(Rules.normalizeText(c['input'] as String));
          return {'rest': rest, 'n': n};
        },
        'play': (c) {
          final p = rules.playPipeline(c['input'] as String);
          return {'q': p.q, 'n': p.n};
        },
        'time_parse': (c) {
          final (at, rest) = rules.parseWhen(c['input'] as String, DateTime.parse(c['now'] as String));
          return {'when': at == null ? null : isoMinutesOf(at), 'rest': rest};
        },
        'realcount': (c) => RealCount(core, tempDir('rc_classify')).classify(c['input'] as String),
        'realcount_answer': (c) {
          final dir = Directory.systemTemp.createTempSync('snapy_rc_');
          try {
            ((c['files'] as Map?) ?? const {}).forEach((name, data) {
              File('${dir.path}/$name').writeAsStringSync(jsonEncode(data));
            });
            final today = DateTime.parse(c['today'] as String);
            final rc = RealCount(core, dir.path, today: () => today);
            final lang = (c['lang'] as String?) ?? 'en';
            if (c['weekly'] == true) return {'answer': rc.weeklySummary(lang: lang)};
            return {'answer': rc.answer(c['input'] as String, lang: lang)};
          } finally {
            dir.deleteSync(recursive: true);
          }
        },
        'wake': (c) {
          final s = {...defaultSettings, ...((c['settings'] as Map?)?.cast<String, Object>() ?? const {})};
          final (heard, rest) = rules.stripWake(c['input'] as String,
              agentName: s['agent_name'] as String, wakeWords: List<String>.from(s['wake_words'] as List));
          return {'heard': heard, 'rest': rest};
        },
        'unfinished': (c) => {'unfinished': rules.soundsUnfinished(c['input'] as String)},
        'memory': (c) {
          final text = c['input'] as String;
          final out = [
            for (final e in rules.extractRules(text))
              {'key': e['key'], 'text': e['text'], 'category': e['category'], 'importance': e['importance']},
          ];
          return {'secret': rules.isSecret(text), 'extract': out, 'explicit': rules.explicitFact(text)};
        },
        'task_title': (c) => {'title': rules.cleanTitle(c['input'] as String)},
        'phone_device': (c) {
          final d = LocalIntents.parse(c['input'] as String, core: core);
          return {'intent': d?.intent, 'camera': d?.camera};
        },
      };

  final suites = loadConformanceSuites();

  test('conformance files exist', () => expect(suites, isNotEmpty));

  for (final entry in suites.entries) {
    test('conformance ${entry.key}', () {
      final suite = entry.value;
      final run = runners()[suite['suite']];
      expect(run, isNotNull, reason: 'no runner for suite ${suite['suite']}');
      final failures = <String>[];
      var total = 0;
      for (final c in (suite['cases'] as List).cast<Map<String, dynamic>>()) {
        total++;
        Object? got;
        try {
          got = jsonDecode(jsonEncode(run!(c)));
        } catch (e) {
          got = 'EXCEPTION $e';
        }
        if (!jsonEq(got, c['expect'])) {
          failures.add('${c['id']}: ${jsonEncode(c['input'])}\n    expected ${jsonEncode(c['expect'])}\n    got      ${jsonEncode(got)}');
        }
      }
      // ignore: avoid_print
      print('[conformance] ${entry.key}: ${total - failures.length}/$total passed');
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  }

  test('case ids are unique', () {
    final ids = [for (final s in suites.values) for (final c in s['cases'] as List) (c as Map)['id']];
    expect(ids.length, ids.toSet().length);
  });

  test('every core pattern is portable and compiles in Dart', () {
    final pats = core.allPatterns();
    expect(pats.length, greaterThan(50));
    for (final (_, _, _, src) in pats) {
      CoreData.checkPortable(src);
      RegExp(src);
    }
  });

  test('prompts and tools', () {
    final system = core.prompt('system', {'agent_name': 'Meera'});
    expect(system, contains('You are Meera,'));
    expect(system, isNot(contains('{{')));
    final names = [for (final t in core.tools['tools'] as List) (t as Map)['name']];
    expect(core.actionSchema()['properties']['tool']['enum'], ['none', ...names]);
  });
}
