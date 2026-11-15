// Unit tests for the Dart core runtime beyond the golden cases: stores (schema fields,
// tombstones, legacy migration), retrieval scoring, router order, the phone confirmation
// flow, events, the command grammar, the screen matcher, sync stores and Python helpers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core_runtime/brain.dart';
import 'package:snapy/core_runtime/commands.dart';
import 'package:snapy/core_runtime/core_data.dart';
import 'package:snapy/core_runtime/py.dart';
import 'package:snapy/core_runtime/rules.dart';
import 'package:snapy/core_runtime/runtime.dart';
import 'package:snapy/core_runtime/stores.dart';
import 'package:snapy/core_runtime/sync_stores.dart';
import 'package:snapy/sync/merge.dart';

import 'runtime_helpers.dart';

class FakeHooks implements PlatformHooks {
  final Map<String, String> contacts;
  @override
  final SecretVault vault = MemoryVault();
  @override
  NanoBridge? nano;
  FakeHooks({this.contacts = const {}, this.nano});

  @override
  Future<String?> findContacts(String name) async => contacts[name.toLowerCase()] ?? '[]';
  @override
  Future<String?> httpGet(Uri url) async => null;
}

class FakeNano implements NanoBridge {
  String state;
  final List<String> chunks;
  final List<String> prompts = [];
  FakeNano(this.state, this.chunks);
  @override
  Future<String> status() async => state;
  @override
  Stream<String> generate(String prompt) {
    prompts.add(prompt);
    return Stream.fromIterable(chunks);
  }
}

class FakeBackend extends LlmBackend {
  @override
  final String name;
  bool isReady;
  final List<String> reply;
  bool fail;
  int calls = 0;
  FakeBackend(this.name, {this.isReady = true, this.reply = const ['{"say": "hi"}'], this.fail = false});
  @override
  Future<bool> ready() async => isReady;
  @override
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300, double temperature = 0.4, Cancel? cancel}) async* {
    calls++;
    if (fail) throw StateError('$name failed');
    yield* Stream.fromIterable(reply);
  }

  @override
  Future<String> chatText(List<Msg> messages, {int maxTokens = 300, double temperature = 0.4}) async {
    calls++;
    if (fail) throw StateError('$name failed');
    return reply.join();
  }
}

void main() {
  late CoreData core;
  late Rules rules;
  setUpAll(() async {
    core = await loadRepoCore();
    rules = Rules(core);
  });

  group('python helpers', () {
    test('SequenceMatcher.ratio equals difflib', () {
      expect(seqRatio('abcd', 'bcde'), 0.75);
      expect(seqRatio('mira', 'meera'), closeTo(0.6666666666666666, 1e-12));
      expect(seqRatio('snapi', 'snapy'), 0.8);
      expect(seqRatio('instagarm', 'instagram'), closeTo(0.8888888888888888, 1e-12));
      expect(seqRatio('private key', 'privat ky'), closeTo(0.9, 1e-12));
      expect(seqRatio('', ''), 1.0);
      expect(closeMatch('youtub', ['youtube', 'you tube music', 'yt'], cutoff: 0.75), 'youtube');
    });
    test('round half to even, title, strip', () {
      expect([pyRound(0.5), pyRound(1.5), pyRound(2.5), pyRound(-0.5), pyRound(2.6)], [0, 2, 2, 0, 3]);
      expect(pyTitle('instagram.android'), 'Instagram.Android');
      expect(pyTitle("it's"), "It'S");
      expect(pyStrip(' ,.hi., ', ' ,.'), 'hi');
    });
  });

  group('stores', () {
    test('tasks carry the schema fields and keep tombstones', () {
      final dir = tempDir('tasks');
      final now = DateTime(2026, 11, 16, 10);
      final store = TaskStore(rules, '$dir/tasks.json', device: 'android-test', clock: () => now);
      final t = store.addFromText('remind me to call mom in 10 minutes');
      expect(t['title'], 'call mom');
      expect(t['remind_at'], '2026-11-16T10:10');
      for (final k in ['schema_version', 'id', 'updated', 'device', 'deleted', 'title', 'remind_at', 'done', 'fired', 'created']) {
        expect(t.containsKey(k), isTrue, reason: k);
      }
      expect(t['device'], 'android-test');
      expect(() => parseTs(t['updated']), returnsNormally);
      store.delete(t['id'] as String);
      expect(store.openTasks(), isEmpty);
      final recs = store.syncRecords();
      expect(recs[t['id']]!['deleted'], isTrue);
      final again = TaskStore(rules, '$dir/tasks.json', device: 'android-test');
      expect(again.openTasks(), isEmpty, reason: 'tombstone persisted');
    });

    test('legacy Python records get sync fields once (local times -> UTC stamps)', () {
      final dir = tempDir('legacy');
      File('$dir/tasks.json').writeAsStringSync(jsonEncode([
        {'id': 'abc', 'title': 'old', 'remind_at': null, 'done': false, 'fired': false, 'created': '2026-01-02T03:04:05', 'source': 'voice', 'extra_field': 7},
      ]));
      final store = TaskStore(rules, '$dir/tasks.json', device: 'android-x');
      final t = store.get('abc')!;
      expect(t['schema_version'], 1);
      expect(t['deleted'], false);
      expect(t['extra_field'], 7, reason: 'unknown fields preserved');
      expect(parseTs(t['updated']), DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch);
    });

    test('due reminders fire once', () {
      final dir = tempDir('due');
      var now = DateTime(2026, 11, 16, 10);
      final store = TaskStore(rules, '$dir/tasks.json', device: 'd', clock: () => now);
      store.add('stretch', DateTime(2026, 11, 16, 10, 5));
      expect(store.dueReminders(), isEmpty);
      now = DateTime(2026, 11, 16, 10, 6);
      expect(store.dueReminders().length, 1);
      expect(store.dueReminders(), isEmpty);
    });

    test('notes newest first, search, onDay', () {
      final dir = tempDir('notes');
      final now = DateTime(2026, 11, 16, 12);
      final notes = NoteStore(core, '$dir/notes.json', device: 'd', clock: () => now);
      notes.add('buy milk and eggs');
      notes.add('call the plumber');
      expect(notes.items.first['text'], 'call the plumber');
      expect(notes.search('milk').single['text'], 'buy milk and eggs');
      expect(notes.onDay('2026-11-16').length, 2);
    });
  });

  group('memory', () {
    test('rule extraction, keyed upsert, secrets never stored', () {
      final dir = tempDir('mem');
      final m = MemoryStore(rules, '$dir/memory', device: 'd');
      expect(m.extractRules('my name is arjun').single['text'], 'Name is arjun');
      expect(m.profile['name'], 'Arjun');
      m.extractRules('I start work at 9am');
      m.extractRules('I start work at 10am');
      expect(m.memories.where((x) => x['key'] == 'start_time').single['text'], 'Usually starts work at 10am');
      expect(m.memories.where((x) => x['key'] == 'start_time').single['history'], isNotEmpty);
      expect(m.add('my password is hunter2'), isNull);
      expect(m.extractRules('my otp is 1234, I love pizza'), isEmpty);
      // unknown categories ("work" in core memory_extract) are stored as "fact"
      m.extractRules('I work at Zoho.');
      expect(m.memories.firstWhere((x) => x['key'] == 'company')['category'], 'fact');
    });

    test('explicit remember rewrites first person; forget deletes the best match', () {
      final m = MemoryStore(rules, '${tempDir('mem2')}/memory', device: 'd');
      final r = m.explicitRemember('remember that my manager is Arun');
      expect(r!['text'], "User's manager is Arun");
      expect(r['importance'], 5);
      expect(m.forget('manager'), isNotNull);
      expect(m.memories, isEmpty);
      expect(m.syncRecords().values.single['deleted'], isTrue);
    });

    test('retrieval score = 0.5 rel + 0.25 imp/5 + 0.25 * 0.995^hours (+0.3 pinned)', () {
      var now = DateTime(2026, 11, 16, 12);
      final m = MemoryStore(rules, '${tempDir('mem3')}/memory', device: 'd', clock: () => now);
      m.add('Likes filter coffee in the morning', importance: 3, dedupe: false);
      now = now.add(const Duration(hours: 10));
      final hits = m.retrieve('coffee', touch: false);
      expect(hits.length, 1);
      final expected = 0.5 * 1.0 + 0.25 * (3 / 5) + 0.25 * math.pow(0.995, 10);
      expect(hits.single.score, closeTo(expected, 0.001));
      expect(hits.single.relevance, 1.0);
      expect(m.retrieve('weather', touch: false), isEmpty, reason: 'below min relevance');
    });
  });

  group('brain router', () {
    Settings settings(Map<String, dynamic> d) => Settings('${tempDir('settings')}/s.json')..data.addAll(d);

    test('auto: Nano, on-device, cloud, then the laptop', () async {
      final s = settings({});
      final nano = NanoBackend(FakeNano('unavailable', const []));
      final cloud = CloudBackend(core, s, MemoryVault());
      final router = BrainRouter(s, nano, OnDeviceBackend(), cloud, PairedBackend(() => null));
      expect(router.order().map((b) => b.name), ['nano', 'on_device', 'cloud', 'laptop']);
      expect(await router.ready(), isFalse);
      s.data['ai_provider'] = 'cloud';
      expect(router.order().first.name, 'cloud');
      s.data['ai_provider'] = 'local';
      expect(router.order().map((b) => b.name), isNot(contains('cloud')));
      s.data['ai_provider'] = 'auto';
      expect(router.forPurpose('memory').order().map((b) => b.name), isNot(contains('cloud')), reason: 'cloud_for_memory off');
    });

    test('uses Nano when available, flattening the conversation into one prompt', () async {
      final s = settings({});
      final fake = FakeNano('available', ['{"say": "Hel', 'lo"}']);
      final router = BrainRouter(s, NanoBackend(fake), OnDeviceBackend(), CloudBackend(core, s, MemoryVault()), PairedBackend(() => null));
      final out = await router.stream([
        {'role': 'system', 'content': 'SYS'},
        {'role': 'user', 'content': 'hey'},
      ], schema: const {}).join();
      expect(out, '{"say": "Hello"}');
      expect(router.lastUsed, 'nano');
      expect(fake.prompts.single, startsWith('SYS'));
      expect(fake.prompts.single, contains('User: hey'));
    });

    test('falls back to the next ready backend when one fails before output', () async {
      final s = settings({});
      final a = FakeBackend('a', fail: true), b = FakeBackend('b', reply: ['ok']);
      final router = _Router(core, s, [a, b]);
      expect(await router.stream(const []).join(), 'ok');
      expect(a.calls, 1);
      expect(router.lastUsed, 'b');
    });
  });

  group('cloud', () {
    test('request formats per provider', () async {
      final s = Settings('${tempDir('c')}/s.json');
      final v = MemoryVault()..keys.addAll({'cloud_gemini': 'g-key', 'cloud_openai': 'o-key', 'cloud_anthropic': 'a-key'});
      final c = CloudBackend(core, s, v);
      final msgs = <Msg>[
        {'role': 'system', 'content': 'S'},
        {'role': 'user', 'content': 'U'},
      ];
      s.data['cloud_provider'] = 'gemini';
      var (uri, headers, body) = await c.buildRequest(msgs, jsonMode: true, stream: true);
      expect(uri.toString(), contains(':streamGenerateContent?alt=sse'));
      expect(headers['x-goog-api-key'], 'g-key');
      expect(body['systemInstruction'], {'parts': [{'text': 'S'}]});
      expect((body['generationConfig'] as Map)['responseMimeType'], 'application/json');
      s.data['cloud_provider'] = 'openai';
      (uri, headers, body) = await c.buildRequest(msgs, jsonMode: true, stream: false);
      expect(uri.path, endsWith('/chat/completions'));
      expect(headers['Authorization'], 'Bearer o-key');
      expect(body['response_format'], {'type': 'json_object'});
      expect(body.containsKey('temperature'), isFalse, reason: 'first OpenAI model has sampling: false');
      s.data['cloud_provider'] = 'anthropic';
      (uri, headers, body) = await c.buildRequest(msgs, jsonMode: false, stream: true, maxTokens: 100);
      expect(uri.path, endsWith('/messages'));
      expect(body['system'], 'S');
      expect(body['max_tokens'], 1024, reason: 'min_max_tokens');
    });

    test('SSE parsing and redaction', () {
      expect(CloudBackend.sseTexts('gemini', {'candidates': [{'content': {'parts': [{'text': 'a'}, {'text': 'b'}]}}]}).toList(), ['a', 'b']);
      expect(CloudBackend.sseTexts('openai', {'choices': [{'delta': {'content': 'x'}}]}).toList(), ['x']);
      expect(CloudBackend.sseTexts('anthropic', {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'y'}}).toList(), ['y']);
      final r = redact('mail me at a.b@example.com or +91 98765 43210, key sk-abcdefghijklmnopqrstuvwx, card 4111 1111 1111 1111');
      expect(r, contains('[email]'));
      expect(r, contains('[phone]'));
      expect(r, contains('[key]'));
      expect(r, contains('[card]'));
      expect(redact('meeting on 2026-11-15 10'), 'meeting on 2026-11-15 10');
    });

    test('streaming helpers', () {
      final s = JsonFieldStreamer('say');
      expect(s.feed('{"sa'), '');
      expect(s.feed('y": "Hi\\n th'), 'Hi\n th');
      expect(s.feed('ere", "tool": "none"}'), 'ere');
      final t = ThinkFilter();
      expect(t.feed('a<thi') + t.feed('nk>secret</think>b'), 'ab');
      expect(parseJsonObject('noise {"say": "x", "tool": "none"} tail')['say'], 'x');
    });
  });

  group('runtime', () {
    late Directory dir;
    late SnapyRuntime rt;
    late List<Map<String, dynamic>> events;
    var now = DateTime(2026, 11, 16, 10);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('snapy_rt_');
      now = DateTime(2026, 11, 16, 10);
      rt = SnapyRuntime(core, dir.path,
          FakeHooks(contacts: {'mom': jsonEncode([{'name': 'Mummy', 'number': '+919876543210'}])}),
          clock: () => now, device: 'android-t');
      events = [];
      rt.events.listen(events.add);
    });
    tearDown(() async {
      await rt.close();
      dir.deleteSync(recursive: true);
    });

    Iterable<Map<String, dynamic>> ofType(String t) => events.where((e) => e['type'] == t);
    List<String> said() => [for (final e in ofType('chat_message')) if (e['role'] == 'assistant') e['text'] as String];

    test('call: contact lookup, confirmation, yes -> op', () async {
      await rt.send('call mom');
      expect(said().last, 'Call Mummy?');
      expect(ofType('op'), isEmpty);
      await rt.send('yes');
      final op = ofType('op').single;
      expect(op['op'], 'call');
      expect(op['kwargs'], {'number': '+919876543210', 'video': false});
      expect(said().last, 'Calling Mummy.');
    });

    test('WhatsApp: "no" cancels; unknown contact; anything else drops the pending action', () async {
      await rt.send('whatsapp mom I am on my way');
      expect(said().last, 'Send to Mummy on WhatsApp: “I am on my way”? Say yes to send.');
      await rt.send('no');
      expect(said().last, 'Okay, cancelled.');
      expect(ofType('op'), isEmpty);
      await rt.send('call ravi');
      expect(said().last, 'I couldn’t find “ravi” in your contacts.'.replaceAll('’', "'"));
    });

    test('alarm and timer run straight away (no confirmation)', () async {
      await rt.send('set an alarm for 6:30 am');
      expect(ofType('op').last['op'], 'alarm');
      expect(said().last, 'Alarm set for 6:30 am.');
      await rt.send('set a timer for 5 minutes');
      expect(ofType('op').last['kwargs'], {'seconds': 300});
    });

    test('Real Count answers come first', () async {
      await rt.send('how many reels did I watch today?');
      expect(said().single, startsWith('No reels or shorts counted today.'));
    });

    test('reminders: task store, tasks event, reminders event for AlarmManager', () async {
      await rt.send('remind me to drink water in 10 minutes');
      expect(said().last, "Okay, I'll remind you to drink water today at 10:10 AM.");
      final r = ofType('reminders').last['items'] as List;
      expect((r.single as Map)['title'], 'drink water');
      expect((r.single as Map)['at_ms'], DateTime(2026, 11, 16, 10, 10).millisecondsSinceEpoch);
      expect(ofType('tasks'), isNotEmpty);
      final snap = jsonDecode(rt.snapshot()) as Map;
      expect((snap['tasks'] as List).single['title'], 'drink water');
    });

    test('router order: memory rule, fast intent, then command grammar, then no-AI reply', () async {
      await rt.send('remember that my car is a red Swift');
      expect(said().last, "Got it — I'll remember that.");
      await rt.send('what do you know about me');
      expect(said().last, contains("User's car is a red Swift"));
      rt.setApps(jsonEncode([{'label': 'YouTube', 'package': 'com.google.android.youtube'}]));
      await rt.send('youtube kholo');
      expect(ofType('op').last['op'], 'launch_app');
      expect(ofType('op').last['args'], ['com.google.android.youtube']);
      await rt.send('volume up');
      expect(ofType('op').last['op'], 'media');
      expect(ofType('op').last['args'], ['volumeup', 5]);
      await rt.send('go back');
      expect(ofType('op').last['args'], ['alt', 'left']);
      // (core quirk, same as Python: "write me a poem…" matches phone intent type.text and is typed)
      await rt.send('tell me a joke about rain');
      expect(said().last, contains("my AI brain isn't set up"));
    });

    test('LLM turn streams {say, tool, args} and runs the tool', () async {
      rt.pairedBrain = _Paired(['{"say": "Added it', '.", "tool": "add_task", "args": {"title": "buy milk", "when": "tomorrow 9am"}}']);
      await rt.send('could you note down that I should buy milk tomorrow morning?');
      expect(said().last, 'Added it.');
      final last = ofType('chat_message').last;
      expect(last['final'], true);
      expect(last['brain'], 'laptop');
      expect(rt.tasks.openTasks().single['remind_at'], '2026-11-17T09:00');
    });

    test('play the nth video and emoji / quit specials', () async {
      await rt.send('play arijit singh songs, the 4th video');
      final op = ofType('op').last;
      expect(op['op'], 'open_url');
      expect((op['args'] as List).single, contains('arijit'));
      await rt.send('show me some party emojis');
      expect(ofType('ui_action').last['action'], 'emoji');
      expect(ofType('ui_action').last['emojis'], contains('🎉'));
    });

    test('call() surface used by Kotlin and the UI', () async {
      expect(await rt.call('sounds_unfinished', ['open youtube and']), 'true');
      final vc = jsonDecode(await rt.call('voice_config', [])) as Map;
      expect(vc['continuation_wait_ms'], 1500);
      expect(jsonDecode(await rt.call('set_limit', ['com.instagram.android', '30'])), {'limits': {'com.instagram.android': 30}, 'break': false});
      expect(jsonDecode(await rt.call('config', ['ordinals.fourth'])), 4);
      final idx = jsonDecode(await rt.call('find_on_screen', [
        'tap the second video',
        jsonEncode([
          {'name': 'Arijit Singh live concert full video', 'type': 'HyperlinkControl', 'rect': [0, 100, 500, 400]},
          {'name': 'Best of Arijit Singh songs jukebox', 'type': 'HyperlinkControl', 'rect': [0, 420, 500, 700]},
          {'name': 'Home', 'type': 'ButtonControl', 'rect': [0, 0, 50, 50]},
        ]),
      ])) as Map;
      expect(idx['index'], 1);
      final key = jsonDecode(await rt.call('test_api_key', ['gemini', ''])) as Map;
      expect(key['code'], 'invalid_key');
      expect(key['help_url'], 'https://aistudio.google.com');
      expect(SnapyRuntime.mapKeyError('Google Gemini: API key not valid. Please pass a valid API key.').$1, 'invalid_key');
      expect(SnapyRuntime.mapKeyError('RESOURCE_EXHAUSTED quota').$1, 'quota');
      final p = jsonDecode(await rt.call('set_profile', [jsonEncode({'name': 'Asha', 'assistant_name': 'Meera'})])) as Map;
      expect(p['name'], 'Asha');
      expect(p['assistant_name'], 'Meera');
    });

    test('meeting notes from text (no AI: heuristic notes)', () async {
      await rt.send('take meeting notes');
      expect(rt.meeting.recording, isTrue);
      expect(rt.addMeetingText("I'll send the deck by friday."), 'ok');
      expect(rt.addMeetingText('We decided to launch in March.'), 'ok');
      final st = jsonDecode(await rt.call('meeting_stop', [])) as Map;
      expect(st['recording'], false);
      final note = rt.notes.items.first;
      expect(note['kind'], 'meeting');
      expect(note['decisions'], ['We decided to launch in March.']);
      expect((note['transcript'] as List).length, 2);
    });

    test('sync stores: tombstones, local-only fields, settings profile', () async {
      final mem = rt.memory.add('Likes chai', dedupe: false)!;
      rt.memory.retrieve('chai'); // touches last_used / uses (local only)
      final ms = memorySyncStore(rt.memory);
      final recs = await ms.records();
      expect(recs[mem['id']]!.containsKey('uses'), isFalse);
      expect(recs[mem['id']]!['device'], 'android-t');
      await ms.apply([{...recs[mem['id']]!, 'text': 'Loves chai', 'updated': fmtTs(DateTime(2027).millisecondsSinceEpoch), 'device': 'windows-1'}]);
      expect(rt.memory.get(mem['id'] as String)!['text'], 'Loves chai');
      expect(rt.memory.get(mem['id'] as String)!['uses'], 1, reason: 'local counter kept');
      final ss = SettingsProfileSync(core, rt.settings, SyncMeta('${dir.path}/sync/meta.json'), 'android-t');
      final prof = (await ss.records())['profile']!;
      expect(prof['agent_name'], 'Snapy');
      await ss.apply([{...prof, 'agent_name': 'Meera', 'updated': fmtTs(DateTime(2027).millisecondsSinceEpoch), 'device': 'windows-1'}]);
      expect(rt.settings.get('agent_name'), 'Meera');
      File('${dir.path}/realcount/2026-11-16.json').writeAsStringSync(jsonEncode({'apps': {'com.instagram.android': {'reels': 3, 'reel_ms': 1000}}}));
      final days = attentionDays(rt.realcount, today: DateTime(2026, 11, 16));
      expect(days.single['apps'], {'com.instagram.android': {'reels': 3, 'reel_ms': 1000}});
    });
  });

  group('commands', () {
    test('open: installed app first, then known websites, then domains', () async {
      final ops = <(String, List<Object?>)>[];
      final apps = AndroidApps()..set([{'label': 'Instagram', 'package': 'com.instagram.android'}]);
      final c = PhoneCommands(core, rules, apps, (op, {args = const [], kwargs = const {}}) => ops.add((op, args)), (_) {},
          () => 'Snapy', () => ['snapy']);
      expect((await c.execute('open instagram')).action, 'launch');
      expect((await c.execute('open instagarm')).action, 'launch', reason: 'fuzzy app name');
      expect((await c.execute('open gmail')).action, 'web');
      expect((await c.execute('open github dot com')).message, 'Opened github.com');
      expect((await c.execute('hello there')).action, 'unknown');
      expect(ops.first.$1, 'launch_app');
      expect(ops.first.$2, ['com.instagram.android']);
    });
  });
}

class _Router extends BrainRouter {
  final List<LlmBackend> list;
  _Router(CoreData core, Settings s, this.list)
      : super(s, NanoBackend(null), OnDeviceBackend(), CloudBackend(core, s, MemoryVault()), PairedBackend(() => null));
  @override
  List<LlmBackend> order() => list;
}

class _Paired implements PairedBrain {
  final List<String> chunks;
  _Paired(this.chunks);
  @override
  Future<bool> available() async => true;
  @override
  Stream<String> stream(List<Msg> messages, {Map<String, dynamic>? schema, int maxTokens = 300}) => Stream.fromIterable(chunks);
}

