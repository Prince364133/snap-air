// SnapyRuntime: Snapy's brain on Android in Dart — the same API surface and event shapes as
// engine/src/platform/android.py (the Chaquopy brain it replaces).
//
// Kotlin and the Flutter UIs call methods by name (send, snapshot, limits_json, set_limit,
// brain_status_json, set_api_key, update_settings, complete_task, reminder_fired,
// sounds_unfinished, voice_config, find_on_screen, update_usage, weekly_summary,
// morning_brief, add_meeting_text, set_apps, set_clipboard, interrupt, config…).
// Every side effect is an event:
//   {"type":"op",…} -> OpExecutor.kt · {"type":"speak"|"speak_stop"} -> Android TTS
//   {"type":"reminders","items":[…]} -> AlarmManager · everything -> the Flutter UIs
import 'dart:async';
import 'dart:convert';

import 'assistant.dart';
import 'brain.dart';
import 'commands.dart';
import 'core_data.dart';
import 'life.dart';
import 'py.dart';
import 'realcount.dart';
import 'rules.dart';
import 'stores.dart';

/// What the runtime needs from the platform (Kotlin), injectable for tests.
abstract class PlatformHooks {
  /// Contacts.kt find(name) -> JSON [{name, number}] or {"error":"permission"}; null = unavailable.
  Future<String?> findContacts(String name);
  SecretVault get vault;
  NanoBridge? get nano;
  Future<String?> httpGet(Uri url);
}

class SnapyRuntime {
  final CoreData core;
  final Rules rules;
  final String dataDir;
  final PlatformHooks hooks;
  final Clock now;
  late final String device;
  late final Settings settings;
  late final TaskStore tasks;
  late final NoteStore notes;
  late final MemoryStore memory;
  late final RealCount realcount;
  late final AndroidApps apps;
  late final PhoneCommands agent;
  late final BrainRouter brain;
  late final CloudBackend cloud;
  late final MeetingRecorder meeting;
  late final Briefing briefing;
  late final Assistant assistant;
  PairedBrain? pairedBrain; // set by lib/sync once a laptop is paired
  String clipboard = '';
  Map<String, dynamic>? pendingPhone; // an action waiting for "yes"
  int _seq = 0;

  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// Every event, in order.
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// "sync now" (set by the host's SyncRunner).
  void Function()? onSyncKick;

  SnapyRuntime(this.core, this.dataDir, this.hooks, {Clock? clock, String? device})
      : rules = Rules(core),
        now = clock ?? DateTime.now {
    this.device = device ?? deviceId(dataDir);
    settings = Settings('$dataDir/settings.json');
    tasks = TaskStore(rules, '$dataDir/tasks.json', device: this.device, clock: now);
    notes = NoteStore(core, '$dataDir/notes.json', device: this.device, clock: now);
    memory = MemoryStore(rules, '$dataDir/memory', device: this.device, settings: settings, clock: now);
    realcount = RealCount(core, '$dataDir/realcount');
    apps = AndroidApps();
    agent = PhoneCommands(core, rules, apps, _op, emit, () => _agentName, () => _wakeWords, fetch: hooks.httpGet);
    cloud = CloudBackend(core, settings, hooks.vault);
    brain = BrainRouter(settings, NanoBackend(hooks.nano), OnDeviceBackend(), cloud, PairedBackend(() => pairedBrain));
    meeting = MeetingRecorder(core, notes, tasks, memory, brain, onUpdate: (st) => emit({'type': 'meeting', ...st}), clock: now);
    briefing = Briefing(memory, tasks, notes, settings, '$dataDir/greeting_state.json', rules.humanTime, clock: now);
    assistant = Assistant(core, rules, settings, agent, memory, tasks, notes, briefing, meeting, brain, _assistantEmit,
        (text, lang) => emit({'type': 'speak', 'text': text, 'lang': lang.isEmpty ? 'en' : lang}),
        () => emit({'type': 'speak_stop'}),
        clock: now);
    syncReminders();
  }

  String get _agentName {
    final n = ((settings.get('agent_name') as String?) ?? 'Snapy').trim();
    return n.isEmpty ? 'Snapy' : n;
  }

  List<String> get _wakeWords => List<String>.from((settings.get('wake_words') as List?) ?? const ['snapy', 'snap']);

  String T(String key, [Map<String, Object?> values = const {}]) => core.t(key, 'en', values);

  /// Stores changed underneath (sync applied peer records): refresh the UIs and the alarms.
  void storesChanged() {
    emit({'type': 'tasks', 'tasks': tasks.openTasks()});
    emit({'type': 'notes', 'notes': notes.items});
    emit({'type': 'memory', 'profile': memory.profile, 'memories': memory.memories});
    syncReminders();
  }

  // ------------------------------------------------------------ events
  void emit(Map<String, dynamic> e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _assistantEmit(Map<String, dynamic> e) {
    emit(e);
    if ((e['type'] == 'chat_message' || e['type'] == 'tasks') && e['final'] != false) syncReminders();
  }

  void _op(String op, {List<Object?> args = const [], Map<String, Object?> kwargs = const {}}) =>
      emit({'type': 'op', 'op': op, 'args': args, 'kwargs': kwargs});

  /// All upcoming reminders, so Android schedules real alarms (they fire even if Snapy is closed).
  void syncReminders() {
    final items = <Map<String, dynamic>>[];
    for (final t in tasks.openTasks()) {
      if (t['remind_at'] == null || t['fired'] == true) continue;
      final at = parseIsoLocal(t['remind_at'] as String?);
      if (at == null) continue;
      items.add({'id': t['id'], 'title': t['title'], 'at_ms': at.millisecondsSinceEpoch});
    }
    emit({'type': 'reminders', 'items': items});
  }

  // ------------------------------------------------------------ messages
  (bool, String) _wake(String text) => rules.stripWake(text, agentName: _agentName, wakeWords: _wakeWords);

  String _clean(String text) =>
      _wake(text).$1 ? rules.stripWakeOriginal(text, agentName: _agentName, wakeWords: _wakeWords) : text;

  /// A user message (typed or spoken). Real Count answers and phone actions are handled here;
  /// everything else goes to the Assistant. Completes when the turn is done.
  Future<String> send(String text, {String source = 'typed'}) async {
    text = text.trim();
    if (text.isEmpty) return 'ok';
    final speak = source == 'voice';
    final clean = _clean(text);
    final answer = realcount.answer(clean);
    if (answer != null) {
      emit({'type': 'chat_message', 'id': 'rc${_seq++}', 'role': 'assistant', 'text': answer, 'final': true, 'ts': 0});
      if (speak) emit({'type': 'speak', 'text': answer, 'lang': 'en'});
      return 'ok';
    }
    if (await _phone(clean, speak)) return 'ok';
    await assistant.handle(text, source: source);
    return 'ok';
  }

  void _say(String text, bool speak, {bool error = false}) {
    emit({'type': 'chat_message', 'id': 'p${_seq++}', 'role': 'assistant', 'text': text, 'final': true, 'error': error, 'ts': 0});
    if (speak) emit({'type': 'speak', 'text': text, 'lang': 'en'});
  }

  Future<(Map<String, dynamic>?, String?)> _lookup(String name) async {
    final aliases = (core.config('android.contact_aliases') as Map?) ?? const {};
    final tries = List<String>.from((aliases[name.toLowerCase()] as List?) ?? [name]);
    List<dynamic> found = const [];
    for (final n in tries) {
      String? raw;
      try {
        raw = await hooks.findContacts(n);
      } catch (e) {
        return (null, T('phone.contacts_error', {'error': e}));
      }
      if (raw == null) return (null, T('phone.contacts_unavailable'));
      final v = jsonDecode(raw);
      if (v is Map && v['error'] == 'permission') return (null, T('phone.contacts_permission'));
      found = v is List ? v : const [];
      if (found.isNotEmpty) break;
    }
    if (found.isEmpty) return (null, T('phone.contact_not_found', {'name': name}));
    return (Map<String, dynamic>.from(found.first as Map), null);
  }

  /// True if the message was a phone action (or a yes/no to one).
  Future<bool> _phone(String clean, bool speak) async {
    if (pendingPhone != null) {
      final act = pendingPhone!;
      pendingPhone = null;
      if (rules.isPhoneYes(clean)) {
        _runPhone(act, speak);
        return true;
      }
      if (rules.isPhoneNo(clean)) {
        _say(T('phone.cancelled'), speak);
        return true;
      }
      // anything else: forget the pending action and treat this as a new request
    }
    final intent = rules.parsePhone(clean, now());
    if (intent == null) return false;
    final k = intent['kind'] as String;
    if (k == 'whatsapp' || k == 'sms' || k == 'call') {
      final (who, err) = await _lookup(intent['contact'] as String);
      if (err != null) {
        _say(err, speak, error: true);
        return true;
      }
      intent['name'] = who!['name'];
      intent['number'] = who['number'];
      final q = k == 'call'
          ? T('phone.confirm_call', {'name': who['name']})
          : T(k == 'whatsapp' ? 'phone.confirm_send_whatsapp' : 'phone.confirm_send', {'name': who['name'], 'text': intent['text']});
      pendingPhone = intent;
      _say(k != 'call' ? '$q ${T('phone.say_yes_to_send')}' : q, speak);
      return true;
    }
    _runPhone(intent, speak);
    return true;
  }

  void _runPhone(Map<String, dynamic> a, bool speak) {
    switch (a['kind']) {
      case 'whatsapp':
        _op('whatsapp_send', kwargs: {'number': a['number'], 'text': a['text']});
        _say(T('phone.sending_whatsapp', {'name': a['name']}), speak);
      case 'sms':
        _op('sms', kwargs: {'number': a['number'], 'text': a['text']});
        _say(T('phone.sms_ready', {'name': a['name']}), speak);
      case 'call':
        _op('call', kwargs: {'number': a['number'], 'video': a['video'] == true});
        _say(T('phone.calling', {'name': a['name']}), speak);
      case 'alarm':
        final h = a['hour'] as int, m = a['minute'] as int;
        _op('alarm', kwargs: {'hour': h, 'minute': m, 'label': a['label']});
        _say(T('phone.alarm_set', {'hour': h % 12 == 0 ? 12 : h % 12, 'minute': m.toString().padLeft(2, '0'), 'ampm': h < 12 ? T('time.am') : T('time.pm')}), speak);
      case 'timer':
        final s = a['seconds'] as int;
        _op('timer', kwargs: {'seconds': s});
        final mins = s ~/ 60;
        _say(mins != 0 ? T(mins == 1 ? 'phone.timer_set_minute' : 'phone.timer_set_minutes', {'n': mins}) : T('phone.timer_set_seconds', {'n': s}), speak);
      case 'navigate':
        _op('navigate', kwargs: {'place': a['place']});
        _say(T('phone.directions', {'place': a['place']}), speak);
      case 'torch':
        _op('torch', kwargs: {'on': a['on']});
        _say(a['on'] == true ? T('phone.torch_on') : T('phone.torch_off'), speak);
      case 'panel':
        _op('panel', kwargs: {'panel': a['panel']});
        _say(T('phone.panel', {'panel': pyTitle(a['panel'] as String)}), speak);
      case 'type':
        _op('type_text', kwargs: {'text': a['text']});
      case 'tap':
        _op('screen_tap', kwargs: {'query': a['target']});
    }
  }

  // ------------------------------------------------------------ API for Kotlin / Dart
  int setApps(String appsJson) {
    final items = jsonDecode(appsJson) as List;
    apps.set(items);
    for (final i in items) {
      final m = i as Map;
      if (m['package'] != null && m['label'] != null) realcount.labels.putIfAbsent('${m['package']}', () => '${m['label']}');
    }
    return apps.apps.length;
  }

  String updateUsage(String usageJson) {
    realcount.saveUsage(Map<String, dynamic>.from(jsonDecode(usageJson) as Map));
    return 'ok';
  }

  String limitsJson() => jsonEncode({'limits': settings.get('app_limits') ?? {}, 'break': settings.get('break_screen') == true});

  String setLimit(String package, String minutes) {
    final limits = Map<String, dynamic>.from((settings.get('app_limits') as Map?) ?? const {});
    final m = int.tryParse(minutes) ?? 0;
    if (m > 0) {
      limits[package] = m;
    } else {
      limits.remove(package);
    }
    settings.update({'app_limits': limits});
    return limitsJson();
  }

  String voiceConfig() {
    final lang = ((settings.get('voice_language') as String?) ?? 'auto').toLowerCase();
    final locales = (core.config('android.speech_locales') as Map?) ?? const {};
    final name = _agentName.toLowerCase();
    var phrases = List<String>.from((core.config('android.wake_phrases') as List?) ?? const []);
    if (name.isNotEmpty && name != 'snapy' && name != 'snappy') phrases = [name, 'hey $name', 'hi $name', 'okay $name', ...phrases];
    return jsonEncode({
      'locale': locales[lang] ?? locales['auto'] ?? 'en-IN',
      'wake_phrases': phrases,
      'continuation_wait_ms': (((settings.get('continuation_wait_s') as num?) ?? 1.5) * 1000).toInt(),
      'wake_enabled': settings.get('android_wake_word') == true,
      'wake_model': core.config('android.wake_model'),
    });
  }

  Future<Map<String, dynamic>> brainStatus() async {
    final nanoStatus = hooks.nano == null ? 'unavailable' : await hooks.nano!.status().catchError((_) => 'error');
    return {
      'mode': settings.get('ai_provider'),
      'voice_language': settings.get('voice_language') ?? 'auto',
      'local_ready': nanoStatus == 'available',
      'nano': nanoStatus,
      'laptop': pairedBrain != null,
      'cloud_configured': await cloud.configured(),
      'provider': cloud.provider,
      'model': cloud.model,
      'providers': {for (final e in cloud.providers.entries) e.key: (e.value as Map)['label']},
      'error': cloud.lastError,
    };
  }

  Future<String> setApiKey(String provider, String key) async {
    await hooks.vault.setKey('cloud_$provider', key);
    settings.update({'cloud_provider': provider});
    cloud.lastError = null;
    return jsonEncode(await brainStatus());
  }

  /// Checks a key with the provider ("Reply with exactly: OK").
  /// -> {ok, code, message, help_url} (docs/ANDROID_NEXT_PLAN.md §9); code: ok | invalid_key |
  /// quota | permission | model | network | error.
  Future<String> testApiKey(String provider, String key) async {
    final probeVault = MemoryVault()..keys['cloud_$provider'] = key.trim();
    final probeSettings = Settings('$dataDir/.probe_settings.json')..data.addAll({...settings.data, 'cloud_provider': provider});
    final probe = CloudBackend(core, probeSettings, probeVault);
    final info = (cloud.providers[provider] as Map?) ?? const {};
    final help = info['key_url'] is String ? 'https://${info['key_url']}' : null;
    if (key.trim().isEmpty) return jsonEncode({'ok': false, 'code': 'invalid_key', 'message': 'Paste your API key first.', 'help_url': help});
    try {
      await probe.test();
      return jsonEncode({'ok': true, 'code': 'ok', 'message': 'Key works.', 'help_url': help});
    } catch (e) {
      final (code, message) = mapKeyError('$e');
      return jsonEncode({'ok': false, 'code': code, 'message': message, 'help_url': help, 'detail': '$e'});
    }
  }

  static (String, String) mapKeyError(String detail) {
    final d = detail.toLowerCase();
    if (RegExp(r'api[ _-]?key.{0,30}(not valid|invalid|incorrect)|(invalid|incorrect).{0,20}api[ _-]?key|unauthori[sz]ed|401|api_key_invalid|authentication').hasMatch(d)) {
      return ('invalid_key', 'That key was not accepted. Copy it again from your provider.');
    }
    if (RegExp(r'quota|resource_exhausted|rate limit|429|insufficient|billing|credit').hasMatch(d)) {
      return ('quota', 'This key has no quota left. Check billing or try later.');
    }
    if (RegExp(r'permission|403|forbidden|not enabled').hasMatch(d)) {
      return ('permission', 'This key is not allowed to use the API. Enable it in your provider console.');
    }
    if (RegExp(r'model.{0,40}(not found|not supported|unavailable)|does not exist|decommission').hasMatch(d)) {
      return ('model', 'The model is not available for this key.');
    }
    if (RegExp(r'socket|host lookup|network|timed? ?out|connection|handshake').hasMatch(d)) {
      return ('network', 'Could not reach the provider. Check your internet connection.');
    }
    return ('error', 'The key check failed.');
  }

  String snapshot() {
    final ns = notes.items;
    final ms = memory.memories;
    return jsonEncode({
      'tasks': tasks.openTasks(),
      'notes': ns.length > 50 ? ns.sublist(ns.length - 50) : ns,
      'memories': [for (final m in (ms.length > 100 ? ms.sublist(ms.length - 100) : ms)) {'id': m['id'], 'text': m['text'], 'category': m['category']}],
    });
  }

  String completeTask(String id) {
    tasks.complete(id);
    syncReminders();
    return 'ok';
  }

  String reminderFired(String id) {
    tasks.dueReminders();
    syncReminders();
    return 'ok';
  }

  /// §9 profile: {name, assistant_name, ice_notes} over memory profile + settings.agent_name.
  Map<String, dynamic> profileJson() => {
        'name': (memory.profile['preferred_name'] as String?)?.isNotEmpty == true ? memory.profile['preferred_name'] : memory.profile['name'],
        'assistant_name': _agentName,
        'ice_notes': memory.profile['ice_notes'] ?? '',
        ...memory.profile,
      };

  Map<String, dynamic> setProfile(Map<String, dynamic> p) {
    if (p['name'] is String) memory.updateProfile({'name': p['name'], 'preferred_name': p['name']});
    if (p['ice_notes'] is String) {
      memory.profile['ice_notes'] = p['ice_notes'];
      memory.saveProfile();
    }
    if (p['assistant_name'] is String && (p['assistant_name'] as String).trim().isNotEmpty) {
      settings.update({'agent_name': (p['assistant_name'] as String).trim()});
    }
    return profileJson();
  }

  String addMeetingText(String text) => meeting.addText('Room', text) ? 'ok' : 'ignored';

  /// Dispatch by name (the MethodChannel surface). Results are strings (JSON where structured).
  Future<String> call(String method, List<String> args) async {
    String a(int i) => i < args.length ? args[i] : '';
    switch (method) {
      case 'send':
        return send(a(0), source: args.length > 1 && a(1).isNotEmpty ? a(1) : 'typed');
      case 'interrupt':
        assistant.interrupt();
        return 'ok';
      case 'set_apps':
        return '${setApps(a(0))}';
      case 'set_clipboard':
        clipboard = a(0);
        return 'ok';
      case 'set_api_key':
        return setApiKey(a(0), a(1));
      case 'test_api_key':
        return testApiKey(a(0), a(1));
      case 'brain_status_json':
        return jsonEncode(await brainStatus());
      case 'update_settings':
        settings.update(Map<String, dynamic>.from(jsonDecode(a(0)) as Map));
        return 'ok';
      case 'snapshot':
        return snapshot();
      case 'complete_task':
        return completeTask(a(0));
      case 'reminder_fired':
        return reminderFired(a(0));
      case 'sounds_unfinished':
        return jsonEncode(rules.soundsUnfinished(a(0)));
      case 'voice_config':
        return voiceConfig();
      case 'find_on_screen':
        return jsonEncode(ScreenMatcher.findJson(a(0), a(1)));
      case 'update_usage':
        return updateUsage(a(0));
      case 'limits_json':
        return limitsJson();
      case 'set_limit':
        return setLimit(a(0), a(1));
      case 'weekly_summary':
        return realcount.weeklySummary();
      case 'morning_brief':
        return briefing.morningBriefJson();
      case 'add_meeting_text':
        return addMeetingText(a(0));
      case 'config':
        return jsonEncode(core.config(a(0)));
      case 'profile':
        return jsonEncode(profileJson());
      case 'update_profile':
        return jsonEncode(memory.updateProfile(Map<String, dynamic>.from(jsonDecode(a(0)) as Map)));
      case 'meeting_state':
        return jsonEncode(meeting.state());
      case 'meeting_start':
        if (!meeting.recording) meeting.start(title: a(0).isEmpty ? null : a(0));
        return jsonEncode(meeting.state());
      case 'meeting_stop':
        if (meeting.recording) await assistant.finishMeeting('en', false);
        return jsonEncode(meeting.state());
      case 'set_profile':
        return jsonEncode(setProfile(Map<String, dynamic>.from(jsonDecode(a(0)) as Map)));
      case 'sync_kick':
        onSyncKick?.call();
        return 'ok';
      default:
        throw ArgumentError('unknown core method $method');
    }
  }

  Future<void> close() async {
    assistant.dispose();
    await _events.close();
  }
}
