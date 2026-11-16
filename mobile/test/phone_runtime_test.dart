// The core runtime's phone-service handlers (docs/ANDROID_NEXT_PLAN.md §3–§9): reel limits,
// activation modes, device intents -> ops, meeting audio ops + Markdown vault + meeting -> tasks,
// vault list/clear, SOS info, wake greeting.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapy/core_runtime/brain.dart';
import 'package:snapy/core_runtime/core_data.dart';
import 'package:snapy/core_runtime/runtime.dart';

import 'runtime_helpers.dart';

class _Hooks implements PlatformHooks {
  @override
  final SecretVault vault = MemoryVault();
  @override
  NanoBridge? get nano => null;
  @override
  Future<String?> findContacts(String name) async => '[]';
  @override
  Future<String?> httpGet(Uri url) async => null;
}

void main() {
  late CoreData core;
  late Directory dir;
  late SnapyRuntime rt;
  late List<Map<String, dynamic>> events;
  final now = DateTime(2026, 11, 16, 10, 30);

  setUpAll(() async => core = await loadRepoCore());
  setUp(() {
    dir = Directory.systemTemp.createTempSync('snapy_phone_');
    rt = SnapyRuntime(core, dir.path, _Hooks(), clock: () => now, device: 'android-t');
    events = [];
    rt.events.listen(events.add);
  });
  tearDown(() async {
    await rt.close();
    dir.deleteSync(recursive: true);
  });

  Iterable<Map<String, dynamic>> ops(String op) => events.where((e) => e['type'] == 'op' && e['op'] == op);

  test('reel limits: device-only settings, opt-in, soft by default', () async {
    expect(jsonDecode(await rt.call('reel_limits_config', [])), isEmpty);
    final m = jsonDecode(await rt.call('set_reel_limit', ['com.instagram.android', '20', 'hard'])) as Map;
    expect(m['com.instagram.android'], {'limit': 20, 'mode': 'hard'});
    await rt.call('set_reel_limit', ['com.google.android.youtube', '10', 'whatever']);
    expect((rt.reelLimitsConfig()['com.google.android.youtube'] as Map)['mode'], 'soft');
    await rt.call('set_reel_limit', ['com.instagram.android', '0', 'hard']);
    expect(rt.reelLimitsConfig().containsKey('com.instagram.android'), isFalse, reason: '0 = off');
    final schema = core.schema('settings_profile')['properties'] as Map;
    expect(schema.containsKey('reel_limits'), isFalse, reason: 'never synced to the laptop');
  });

  test('activation modes: defaults, wake mirrors android_wake_word, event', () async {
    final m = jsonDecode(await rt.call('activation_modes', [])) as Map;
    expect(m, {'wake': false, 'volume': true, 'power': true});
    final m2 = jsonDecode(await rt.call('set_activation_mode', ['wake', 'true'])) as Map;
    expect(m2['wake'], true);
    expect(rt.settings.get('android_wake_word'), true);
    await rt.call('set_activation_mode', ['volume', 'false']);
    expect(rt.activationModes()['volume'], false);
    expect(events.where((e) => e['type'] == 'activation_modes'), isNotEmpty);
  });

  test('wake greeting uses the profile name', () async {
    expect(await rt.call('wake_greeting', []), 'Yes, tell me!');
    rt.setProfile({'name': 'Asha', 'ice_notes': 'Blood group O+', 'avatar': 'cat'});
    expect(await rt.call('wake_greeting', []), 'Yes Asha, tell me!');
    final p = rt.profileJson();
    expect(p['ice_notes'], 'Blood group O+');
    expect(p['avatar'], 'cat');
    final sos = jsonDecode(await rt.call('sos_info', [])) as Map;
    expect(sos['number'], isNotEmpty);
    expect(sos['ice_notes'], 'Blood group O+');
  });

  test('camera intents -> capture ops; "stop recording" only stops a capture', () async {
    await rt.send('take a video with the front camera', source: 'voice');
    expect(ops('capture').single['kwargs'], {'mode': 'video', 'camera': 'front', 'auto': true});
    await rt.send('stop recording');
    expect(ops('capture_stop'), hasLength(1));
    await rt.send('take a photo');
    expect(ops('capture').last['kwargs']['mode'], 'photo');
    await rt.call('capture_ended', []);
    expect(rt.captureActive, isFalse);
  });

  test('SOS: start, call needs a yes, stop', () async {
    await rt.send('emergency');
    expect(ops('sos_start'), hasLength(1));
    await rt.send('call emergency');
    expect(ops('sos_call'), isEmpty, reason: 'asks first');
    await rt.send('yes');
    expect(ops('sos_call').single['kwargs']['number'], rt.emergencyNumber);
    await rt.send('stop sos');
    expect(ops('sos_stop'), hasLength(1));
  });

  test('meeting: audio op on start/stop, Markdown vault, my action items become tasks', () async {
    rt.memory.updateProfile({'name': 'Asha'});
    await rt.send("I'm in a meeting, take notes", source: 'voice');
    expect(rt.meeting.recording, isTrue);
    final on = ops('meeting_audio').single['kwargs'] as Map;
    expect(on['on'], true);
    expect(on['path'], endsWith('/meetings/${on['id']}.m4a'));
    rt.meeting.addText('mic', "I'll send the deck by friday.");
    rt.meeting.addText('Room', 'We decided to launch in March.');
    await rt.send('meeting is over, save the notes', source: 'voice');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(rt.meeting.recording, isFalse);
    expect(ops('meeting_audio').last['kwargs']['on'], false);
    final note = rt.notes.items.firstWhere((n) => n['kind'] == 'meeting');
    final mdPath = note['markdown_path'] as String;
    expect(File(mdPath).existsSync(), isTrue);
    expect(mdPath, contains('/vault/meetings/2026-11-16_'));
    expect(File(mdPath).readAsStringSync(), contains('## Decisions'));
    expect(events.where((e) => e['type'] == 'vault_file' && e['path'] == mdPath), hasLength(1));
    final mine = (note['actions'] as List).where((a) => (a as Map)['mine'] == true).toList();
    if (mine.isNotEmpty) {
      expect((mine.first as Map)['task_id'], isNotNull);
      expect(rt.tasks.items.where((t) => t['source'] == 'meeting'), isNotEmpty);
    }
    // the audio arrives after the note: attached to it
    final audio = File('${dir.path}/meetings/${on['id']}.m4a')..createSync(recursive: true)..writeAsBytesSync([1, 2, 3]);
    final r = jsonDecode(await rt.call('meeting_audio_saved', [on['id'] as String, audio.path, '3'])) as Map;
    expect(r['ok'], true);
    expect(rt.notes.items.firstWhere((n) => n['kind'] == 'meeting')['audio'], audio.path);
  });

  test('audio but no transcript still saves a note to summarise later', () async {
    await rt.call('meeting_start', []);
    final id = (ops('meeting_audio').single['kwargs'] as Map)['id'] as String;
    await rt.call('meeting_stop', []);
    expect(rt.notes.items.where((n) => n['kind'] == 'meeting'), isEmpty);
    final f = File('${dir.path}/meetings/$id.m4a')..createSync(recursive: true)..writeAsBytesSync(List.filled(10, 0));
    await rt.call('meeting_audio_saved', [id, f.path, '10']);
    final n = rt.notes.items.firstWhere((n) => n['kind'] == 'meeting');
    expect(n['summary_pending'], true);
    expect(n['audio'], f.path);
  });

  test('vault list and clear', () async {
    rt.memory.add('Likes chai', dedupe: false);
    rt.notes.add('Buy milk');
    Directory('${dir.path}/vault/meetings').createSync(recursive: true);
    File('${dir.path}/vault/meetings/2026-11-15_standup.md').writeAsStringSync('# Standup\n\n- a');
    File('${dir.path}/vault/meetings/2026-11-14_secret.md.enc').writeAsBytesSync([1, 2]);
    final all = (jsonDecode(await rt.call('vault_list', ['all'])) as List).cast<Map>();
    expect(all.where((i) => i['kind'] == 'facts').single['title'], 'Likes chai');
    expect(all.where((i) => i['kind'] == 'notes').single['markdown'], 'Buy milk');
    final meetings = all.where((i) => i['kind'] == 'meetings').toList();
    expect(meetings.first['title'], 'Standup');
    expect(meetings[1]['encrypted'], true, reason: 'Ghost-mode files: Kotlin decrypts after the biometric prompt');
    final r = jsonDecode(await rt.call('vault_clear', ['meetings'])) as Map;
    expect(r['ok'], true);
    expect(Directory('${dir.path}/vault/meetings').listSync(), isEmpty);
    expect(rt.notes.items.where((n) => n['kind'] != 'meeting'), isNotEmpty, reason: 'plain notes kept');
    await rt.call('vault_clear', ['facts']);
    expect(rt.memory.memories, isEmpty);
  });
}
