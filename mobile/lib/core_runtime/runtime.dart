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
import 'dart:io';

import 'assistant.dart';
import 'brain.dart';
import 'commands.dart';
import 'core_data.dart';
import 'life.dart';
import 'local_intents.dart';
import 'meeting_audio.dart';
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
  final HttpClient Function() httpClient;
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

  SnapyRuntime(this.core, this.dataDir, this.hooks, {Clock? clock, String? device, HttpClient Function()? httpClient})
      : rules = Rules(core),
        now = clock ?? DateTime.now,
        httpClient = httpClient ?? HttpClient.new {
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
    meeting = MeetingRecorder(core, notes, tasks, memory, brain, onUpdate: _onMeetingUpdate, clock: now);
    meeting.onSaved = _onMeetingSaved;
    meeting.audioSummarizer = _audioSummary;
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
    if (await _device(clean, speak)) return 'ok';
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
      case 'sos_call':
        _op('sos_call', kwargs: {'number': emergencyNumber});
        _say(_tx('phone.sos_dialing', 'Opening the dialer with {number} — press call.', {'number': emergencyNumber}), speak);
    }
  }

  // ------------------------------------------------------------ phone services (ANDROID_NEXT_PLAN §3–§8)
  /// A Snapy camera screen is open (set by capture ops, cleared by Kotlin's capture_ended).
  bool captureActive = false;
  bool sosActive = false;
  bool _meetingAudioOn = false;
  final Map<String, Completer<String?>> _audioReady = {};

  /// Copy from core/i18n when the key exists there, else the built-in English text.
  String _tx(String key, String fallback, [Map<String, Object?> values = const {}]) {
    final s = T(key, values);
    if (s != key) return s;
    return fallback.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => values.containsKey(m[1]) ? '${values[m[1]]}' : m[0]!);
  }

  String get emergencyNumber {
    final n = core.config('android.emergency_number') ?? core.config('android.sos.number');
    return n is String && n.trim().isNotEmpty ? n.trim() : '112';
  }

  String get _userName {
    final p = memory.profile;
    final n = (p['preferred_name'] as String?)?.isNotEmpty == true ? p['preferred_name'] as String : ((p['name'] as String?) ?? '');
    return n.trim();
  }

  /// Camera, SOS and "I'm in a meeting" (lib/core_runtime/local_intents.dart; core domain
  /// `phone_device` once it exists). True if handled.
  Future<bool> _device(String clean, bool speak) async {
    final d = LocalIntents.parse(clean, core: core);
    if (d == null) return false;
    switch (d.intent) {
      case 'capture_video':
      case 'capture_photo':
        final video = d.intent == 'capture_video';
        final cam = d.camera ?? ((settings.get('capture_default_camera') as String?) ?? 'back');
        captureActive = true;
        _op('capture', kwargs: {'mode': video ? 'video' : 'photo', 'camera': cam, 'auto': true});
        _say(video
            ? _tx('phone.capture_video', 'Recording with the {camera} camera. Say “stop recording” when you are done.', {'camera': cam})
            : _tx('phone.capture_photo', 'Taking a photo with the {camera} camera.', {'camera': cam}), speak);
        return true;
      case 'capture_stop':
        if (!captureActive) return false; // "stop recording" may mean the meeting
        captureActive = false;
        _op('capture_stop');
        _say(_tx('phone.capture_saved', 'Stopped — saved to your gallery.'), speak);
        return true;
      case 'sos':
        sosActive = true;
        _op('sos_start', kwargs: {'number': emergencyNumber});
        _say(_tx('phone.sos_on', 'Emergency mode is on. Say “call emergency” or tap Call {number} on the screen. Say “stop SOS” to end it.', {'number': emergencyNumber}), speak);
        return true;
      case 'sos_stop':
        if (!sosActive) return false;
        sosActive = false;
        _op('sos_stop');
        _say(_tx('phone.sos_off', 'Emergency mode is off.'), speak);
        return true;
      case 'sos_call':
        pendingPhone = {'kind': 'sos_call'};
        _say(_tx('phone.sos_confirm_call', 'Call {number}? Say yes to open the dialer.', {'number': emergencyNumber}), speak);
        return true;
      case 'meeting_start':
        if (meeting.recording) {
          _say(_tx('meeting.already', "I'm already taking notes."), speak);
          return true;
        }
        meeting.start();
        _say(_tx('meeting.started', 'Taking meeting notes now. Let everyone know. Say “meeting is over, save the notes” when it ends.'), speak);
        return true;
      case 'meeting_stop':
        if (!meeting.recording) return false;
        _say(_tx('meeting.stopping', 'Okay, wrapping up the notes — give me a moment.'), speak);
        unawaited(assistant.finishMeeting('en', speak));
        return true;
    }
    return false;
  }

  /// Start/stop the audio recording in the mic service with the meeting (any path: voice,
  /// UI, assistant). Kotlin: CoreBridge routes op "meeting_audio" -> WakeWordService.
  void _onMeetingUpdate(Map<String, dynamic> st) {
    final rec = st['recording'] == true;
    if (rec && !_meetingAudioOn && meeting.meetingId != null) {
      _meetingAudioOn = true;
      final id = meeting.meetingId!;
      meeting.audioPath = '$dataDir/meetings/$id.m4a';
      _audioReady[id] = Completer<String?>();
      _op('meeting_audio', kwargs: {'on': true, 'id': id, 'path': meeting.audioPath, 'title': meeting.title ?? ''});
    } else if (!rec && _meetingAudioOn) {
      _meetingAudioOn = false;
      _op('meeting_audio', kwargs: {'on': false, 'id': meeting.meetingId ?? ''});
    }
    emit({'type': 'meeting', ...st});
  }

  /// Kotlin finished the .m4a (or failed: path ""). Attaches the audio to its note; a meeting
  /// with audio but no transcript still gets a note ("summarise later").
  Map<String, dynamic> meetingAudioSaved(String id, String path, int bytes) {
    final c = _audioReady.remove(id);
    if (c != null && !c.isCompleted) c.complete(path.isEmpty ? null : path);
    if (path.isEmpty || bytes <= 0) {
      if (meeting.meetingId == id) meeting.audioPath = null;
      for (final n in notes.items) {
        if (n['meeting_id'] == id && n['audio'] != null) notes.update(n['id'] as String, {'audio': null});
      }
      return {'ok': false};
    }
    for (final n in notes.items) {
      if (n['meeting_id'] == id) {
        notes.update(n['id'] as String, {'audio': path, 'audio_bytes': bytes});
        return {'ok': true, 'note': n['id']};
      }
    }
    if (meeting.recording && meeting.meetingId == id) return {'ok': true};
    final hhmm = RegExp(r'_(\d{2})(\d{2})\d{2}$').firstMatch(id);
    final note = notes.add(_tx('meeting.audio_only', 'Meeting audio saved — no transcript yet.'), kind: 'meeting', extra: {
      'title': hhmm == null ? 'Meeting' : 'Meeting ${hhmm[1]}:${hhmm[2]}',
      'summary': <dynamic>[],
      'actions': <dynamic>[],
      'transcript': <dynamic>[],
      'meeting_id': id,
      'audio': path,
      'audio_bytes': bytes,
      'summary_pending': true,
      'ai_summary': false,
      'review_pending': false,
    });
    _onMeetingSaved(note);
    emit({'type': 'notes', 'notes': notes.items});
    return {'ok': true, 'note': note['id']};
  }

  /// Optional Gemini inline-audio summary (only with `meeting_audio_upload` on and the user's
  /// own Gemini key). Waits briefly for Kotlin to finish the file.
  Future<Map<String, dynamic>?> _audioSummary(String transcript) async {
    if (settings.get('meeting_audio_upload') != true || cloud.provider != 'gemini') return null;
    final id = meeting.meetingId, path = meeting.audioPath;
    if (id == null || path == null) return null;
    final key = await cloud.key();
    if (key.isEmpty) return null;
    String? ready = path;
    final c = _audioReady[id];
    if (c != null) ready = await c.future.timeout(const Duration(seconds: 6), onTimeout: () => null);
    if (ready == null) return null;
    return geminiAudioSummary(
        apiKey: key, model: cloud.model, audio: File(ready), systemPrompt: core.prompt('meeting_summary'), transcript: transcript, client: httpClient);
  }

  /// Saved meeting note -> the user's own action items become tasks with reminders, then the
  /// Markdown vault file (Kotlin seals it when Ghost mode is on: event "vault_file").
  void _onMeetingSaved(Map<String, dynamic> note) {
    final acts = [for (final a in (note['actions'] as List?) ?? const []) Map<String, dynamic>.from(a as Map)];
    var added = 0;
    for (final a in acts) {
      if (a['mine'] != true || a['status'] != 'pending') continue;
      final t = tasks.addFromText('${a['task']} ${a['due'] ?? ''}'.trim(), source: 'meeting');
      a['status'] = 'accepted';
      a['task_id'] = t['id'];
      added++;
    }
    final changes = <String, dynamic>{'actions': acts, 'review_pending': acts.any((a) => a['status'] == 'pending')};
    final path = _writeMeetingMarkdown({...note, ...changes});
    if (path != null) changes['markdown_path'] = path;
    notes.update(note['id'] as String, changes);
    note.addAll(changes);
    if (added > 0) {
      emit({'type': 'tasks', 'tasks': tasks.openTasks()});
      syncReminders();
    }
  }

  String get vaultDir => '$dataDir/vault';

  String? _writeMeetingMarkdown(Map<String, dynamic> note) {
    try {
      final st = parseIsoLocal(note['started'] as String?) ?? now();
      final dir = Directory('$vaultDir/meetings')..createSync(recursive: true);
      final old = note['markdown_path'] as String?;
      final base = '${dir.path}/${isoDate(st)}_${slugify('${note['title'] ?? 'meeting'}')}';
      var path = old ?? '$base.md';
      if (old == null) {
        var i = 2;
        while (File(path).existsSync() || File('$path.enc').existsSync()) {
          path = '$base-${i++}.md';
        }
      }
      File(path).writeAsStringSync(meetingMarkdown(note));
      emit({'type': 'vault_file', 'path': path, 'kind': 'meetings'});
      return path;
    } catch (_) {
      return null;
    }
  }

  /// §9 vaultList: facts | notes | meetings | all -> [{kind,id,title,markdown,date,path?,encrypted?}],
  /// newest first. Ghost-mode files (*.md.enc) come back with encrypted:true for Kotlin to open.
  List<Map<String, dynamic>> vaultList(String kind) {
    final out = <Map<String, dynamic>>[];
    String? dateOf(Object? ts) => ts is num ? isoMinutes(DateTime.fromMillisecondsSinceEpoch((ts * 1000).round())) : null;
    if (kind == 'facts' || kind == 'all') {
      for (final m in memory.memories.reversed) {
        out.add({'kind': 'facts', 'id': m['id'], 'title': m['text'], 'markdown': '- ${m['text']}', 'category': m['category'], 'date': dateOf(m['ts'] ?? m['created'])});
      }
    }
    if (kind == 'notes' || kind == 'all') {
      for (final n in notes.items.where((n) => n['kind'] != 'meeting')) {
        out.add({'kind': 'notes', 'id': n['id'], 'title': n['title'] ?? n['text'], 'markdown': n['text'], 'date': dateOf(n['ts'])});
      }
    }
    if (kind == 'meetings' || kind == 'all') {
      final seen = <String>{};
      final dir = Directory('$vaultDir/meetings');
      final files = dir.existsSync()
          ? dir.listSync().whereType<File>().where((f) => f.path.endsWith('.md') || f.path.endsWith('.md.enc')).toList()
          : <File>[];
      String nameOf(File f) => f.path.split(RegExp(r'[/\\]')).last;
      files.sort((a, b) => nameOf(b).compareTo(nameOf(a)));
      for (final f in files) {
        final name = nameOf(f);
        final enc = name.endsWith('.enc');
        final plainPath = enc ? f.path.substring(0, f.path.length - 4) : f.path;
        seen.add(plainPath.replaceAll('\\', '/'));
        final md = enc ? '' : f.readAsStringSync();
        final title = enc
            ? name.replaceAll(RegExp(r'\.md\.enc$'), '').replaceFirst(RegExp(r'^\d{4}-\d{2}-\d{2}_'), '').replaceAll('-', ' ')
            : (RegExp(r'^# (.+)$', multiLine: true).firstMatch(md)?[1] ?? name);
        out.add({
          'kind': 'meetings',
          'id': name,
          'title': title,
          'markdown': md,
          'date': name.length >= 10 ? name.substring(0, 10) : null,
          'path': f.path,
          'encrypted': enc,
        });
      }
      for (final n in notes.items.where((n) => n['kind'] == 'meeting')) {
        if (seen.contains('${n['markdown_path']}'.replaceAll('\\', '/'))) continue;
        out.add({'kind': 'meetings', 'id': n['id'], 'title': n['title'] ?? 'Meeting', 'markdown': meetingMarkdown(n), 'date': dateOf(n['ts'])});
      }
    }
    return out;
  }

  /// §9 vaultClear. Facts: every memory (the profile/name stays). Notes: plain notes.
  /// Meetings: meeting notes, their Markdown and audio.
  Map<String, dynamic> vaultClear(String kind) {
    var n = 0;
    if (kind == 'facts' || kind == 'all') {
      for (final m in memory.memories) {
        if (memory.delete(m['id'] as String)) n++;
      }
      emit({'type': 'memory', 'profile': memory.profile, 'memories': memory.memories});
    }
    if (kind == 'notes' || kind == 'all' || kind == 'meetings') {
      for (final note in notes.items) {
        final isMeeting = note['kind'] == 'meeting';
        if ((kind == 'notes' && isMeeting) || (kind == 'meetings' && !isMeeting)) continue;
        notes.delete(note['id'] as String);
        n++;
      }
      emit({'type': 'notes', 'notes': notes.items});
    }
    if (kind == 'meetings' || kind == 'all') {
      for (final d in ['$vaultDir/meetings', '$dataDir/meetings']) {
        final dir = Directory(d);
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    }
    return {'ok': true, 'removed': n};
  }

  // ---- reel limits (device-only: settings key `reel_limits`, not in the synced profile)
  Map<String, dynamic> reelLimitsConfig() => Map<String, dynamic>.from((settings.get('reel_limits') as Map?) ?? const {});

  Map<String, dynamic> setReelLimit(String package, int limit, String mode) {
    final all = reelLimitsConfig();
    if (limit <= 0) {
      all.remove(package);
    } else {
      all[package] = {'limit': limit, 'mode': mode == 'hard' ? 'hard' : 'soft'};
    }
    settings.update({'reel_limits': all});
    return all;
  }

  // ---- activation modes (device-only: settings `activation_modes`; wake mirrors android_wake_word)
  static const activationDefaults = {'wake': false, 'volume': true, 'power': true};

  Map<String, dynamic> activationModes() {
    final m = Map<String, dynamic>.from((settings.get('activation_modes') as Map?) ?? const {});
    return {
      for (final e in activationDefaults.entries) e.key: m[e.key] is bool ? m[e.key] : e.value,
      'wake': settings.get('android_wake_word') == true,
    };
  }

  Map<String, dynamic> setActivationMode(String mode, bool on) {
    if (!activationDefaults.containsKey(mode)) return activationModes();
    final m = Map<String, dynamic>.from((settings.get('activation_modes') as Map?) ?? const {})..[mode] = on;
    settings.update({'activation_modes': m, if (mode == 'wake') 'android_wake_word': on});
    emit({'type': 'activation_modes', ...activationModes()});
    return activationModes();
  }

  /// The wake reply (§4): "Yes {name}, tell me!".
  String wakeGreeting() {
    final name = _userName;
    return name.isEmpty
        ? _tx('voice.wake_greeting_noname', 'Yes, tell me!')
        : _tx('voice.wake_greeting', 'Yes {name}, tell me!', {'name': name});
  }

  Map<String, dynamic> sosInfo() => {
        'number': emergencyNumber,
        'name': _userName,
        'ice_notes': memory.profile['ice_notes'] ?? '',
        'title': _tx('sos.title', 'Emergency'),
        'call_label': _tx('sos.call', 'Call {number}', {'number': emergencyNumber}),
        'confirm': _tx('sos.confirm', 'Call {number} now?', {'number': emergencyNumber}),
        'stop_label': _tx('sos.stop', "I'm safe — stop"),
        'ice_title': _tx('sos.ice_title', 'Medical / ICE notes'),
      };

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
      // off unless the user switched it on in Settings (disclosed there): meeting audio -> Gemini
      'meeting_audio_upload': settings.get('meeting_audio_upload') == true,
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

  /// Checks a key with the provider. -> {ok, code, message, help_url, action}
  /// (docs/ANDROID_NEXT_PLAN.md §9; messages = the §1 copy table, exactly).
  /// code: ok | invalid_key | permission | quota | region | network | model | error ·
  /// action: get_key | help | retry | null.
  /// Gemini: GET /v1beta/models (no generation, no cost) so the HTTP status and the error
  /// status/reason are mapped precisely; other providers: a tiny generation via CloudBackend.
  Future<String> testApiKey(String provider, String key) async {
    final info = (cloud.providers[provider] as Map?) ?? const {};
    final label = '${info['label'] ?? 'Gemini'}'.replaceFirst(RegExp(r'^Google '), '');
    final help = provider == 'gemini' ? geminiKeyUrl : (info['key_url'] is String ? 'https://${info['key_url']}' : null);
    Map<String, dynamic> out(String code, {String? detail}) => {
          'ok': code == 'ok',
          'code': code,
          'message': keyMessage(code, label: provider == 'gemini' ? 'Gemini' : label),
          'help_url': code == 'network' || code == 'ok' ? help : (code == 'region' ? geminiRegionHelpUrl : help),
          'action': keyAction(code),
          'detail': ?detail,
        };
    if (key.trim().isEmpty) return jsonEncode(out('invalid_key'));
    if (provider == 'gemini') {
      try {
        final c = httpClient()..connectionTimeout = const Duration(seconds: 8);
        final req = await c.getUrl(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1'));
        req.headers.set('x-goog-api-key', key.trim());
        final r = await req.close().timeout(const Duration(seconds: 12));
        final body = await r.transform(utf8.decoder).join();
        c.close(force: true);
        return jsonEncode(out(mapGeminiStatus(r.statusCode, body)));
      } on SocketException {
        return jsonEncode(out('network'));
      } on HandshakeException {
        return jsonEncode(out('network'));
      } on TimeoutException {
        return jsonEncode(out('network'));
      } on HttpException {
        return jsonEncode(out('network'));
      } catch (e) {
        return jsonEncode(out(mapKeyError('$e').$1));
      }
    }
    final probeVault = MemoryVault()..keys['cloud_$provider'] = key.trim();
    final probeSettings = Settings('$dataDir/.probe_settings.json')..data.addAll({...settings.data, 'cloud_provider': provider});
    final probe = CloudBackend(core, probeSettings, probeVault, client: httpClient);
    try {
      await probe.test();
      return jsonEncode(out('ok'));
    } catch (e) {
      return jsonEncode(out(mapKeyError('$e').$1));
    }
  }

  static const geminiKeyUrl = 'https://aistudio.google.com/apikey';
  static const geminiRegionHelpUrl = 'https://ai.google.dev/gemini-api/docs/available-regions';

  /// The §1 copy table (exact). [label] replaces "Gemini" for other providers.
  static String keyMessage(String code, {String label = 'Gemini'}) => switch (code) {
        'ok' => 'Connected — Snapy\'s AI brain is ready.',
        'invalid_key' => "This key isn't valid. Copy it again, or create a new one.",
        'permission' => "This key can't use the $label API. Enable it or create a new key.",
        'quota' => "This key's free quota is used up. Wait, or use another key.",
        'region' => "$label isn't available for this key's region.",
        'network' => "No internet — try again when you're online.",
        'model' => "This key can't use Snapy's $label model. Create a new key or pick another model.",
        _ => "The key check didn't work. Try again in a moment.",
      };

  /// The table's Action column: get_key ("Get a new key"), help, retry.
  static String? keyAction(String code) => switch (code) {
        'invalid_key' || 'permission' || 'quota' || 'model' => 'get_key',
        'region' => 'help',
        'network' || 'error' => 'retry',
        _ => null,
      };

  /// Gemini HTTP status + error body -> code (the §1 rows, in their precedence order).
  static String mapGeminiStatus(int status, String body) {
    if (status >= 200 && status < 300) return 'ok';
    var st = '', msg = '', reasons = '';
    try {
      final err = (jsonDecode(body) as Map)['error'] as Map;
      st = '${err['status'] ?? ''}'.toUpperCase();
      msg = '${err['message'] ?? ''}';
      reasons = [for (final d in (err['details'] as List?) ?? const []) '${(d as Map)['reason'] ?? ''}'].join(' ').toUpperCase();
    } catch (_) {
      msg = body;
    }
    final all = '$st $reasons ${msg.toUpperCase()}';
    if (all.contains('API_KEY_INVALID') || RegExp(r'API KEY (NOT VALID|EXPIRED|INVALID)').hasMatch(all)) return 'invalid_key';
    if (status == 429 || st == 'RESOURCE_EXHAUSTED') return 'quota';
    if (st == 'FAILED_PRECONDITION' || all.contains('LOCATION IS NOT SUPPORTED') || all.contains('USER LOCATION')) return 'region';
    if (status == 403 && (st == 'PERMISSION_DENIED' || reasons.contains('SERVICE_DISABLED') || reasons.contains('API_KEY_SERVICE_BLOCKED') ||
        all.contains('HAS NOT BEEN USED') || all.contains('IS DISABLED') || all.contains('NOT BEEN ENABLED'))) {
      // 403 PERMISSION_DENIED (API not enabled / key restricted); a 403 that names the key itself is invalid
      return RegExp(r'API_KEY_INVALID|UNREGISTERED_CALLERS|API KEY NOT VALID').hasMatch(all) ? 'invalid_key' : 'permission';
    }
    if (status == 400 || status == 401 || status == 403) return 'invalid_key';
    if (status == 404) return 'model';
    if (status >= 500) return 'error';
    return 'error';
  }

  /// Free-text provider errors (non-Gemini providers, or exceptions) -> code.
  static (String, String) mapKeyError(String detail) {
    final d = detail.toLowerCase();
    String r(String code) => code;
    if (RegExp(r'failed_precondition|location is not supported|user location').hasMatch(d)) return (r('region'), keyMessage('region'));
    if (RegExp(r'quota|resource_exhausted|rate limit|429|insufficient|billing|credit').hasMatch(d)) {
      return ('quota', keyMessage('quota'));
    }
    if (RegExp(r'permission_denied|not enabled|has not been used|service_disabled|is disabled').hasMatch(d)) {
      return ('permission', keyMessage('permission'));
    }
    if (RegExp(r'api[ _-]?key.{0,30}(not valid|invalid|incorrect|expired)|(invalid|incorrect).{0,20}api[ _-]?key|unauthori[sz]ed|401|403|forbidden|api_key_invalid|authentication')
        .hasMatch(d)) {
      return ('invalid_key', keyMessage('invalid_key'));
    }
    if (RegExp(r'model.{0,40}(not found|not supported|unavailable)|does not exist|decommission').hasMatch(d)) {
      return ('model', keyMessage('model'));
    }
    if (RegExp(r'socket|host lookup|network|timed? ?out|connection|handshake').hasMatch(d)) {
      return ('network', keyMessage('network'));
    }
    return ('error', keyMessage('error'));
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
    if (p['avatar'] is String) {
      memory.profile['avatar'] = p['avatar'];
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
      // ---- docs/ANDROID_NEXT_PLAN.md §9 (Kotlin-side shapes are built in SnapyChannels.kt)
      case 'reel_limits_config':
        return jsonEncode(reelLimitsConfig());
      case 'set_reel_limit':
        return jsonEncode(setReelLimit(a(0), int.tryParse(a(1)) ?? 0, a(2)));
      case 'activation_modes':
        return jsonEncode(activationModes());
      case 'set_activation_mode':
        return jsonEncode(setActivationMode(a(0), a(1) == 'true'));
      case 'wake_greeting':
        return wakeGreeting();
      case 'vault_list':
        return jsonEncode(vaultList(a(0).isEmpty ? 'all' : a(0)));
      case 'vault_clear':
        return jsonEncode(vaultClear(a(0).isEmpty ? 'all' : a(0)));
      case 'meeting_audio_saved':
        return jsonEncode(meetingAudioSaved(a(0), a(1), int.tryParse(a(2)) ?? 0));
      case 'meeting_command':
        // a phrase heard by the recording service's recognizer that started with the wake word
        return send(a(0), source: 'voice');
      case 'capture_started':
        captureActive = true;
        return 'ok';
      case 'capture_ended':
        captureActive = false;
        return 'ok';
      case 'sos_state':
        sosActive = a(0) == 'true';
        return 'ok';
      case 'sos_info':
        return jsonEncode(sosInfo());
      default:
        throw ArgumentError('unknown core method $method');
    }
  }

  Future<void> close() async {
    assistant.dispose();
    await _events.close();
  }
}
