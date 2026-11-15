import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'snapy_core.dart';

/// Typed, defensive client for the "next generation" Dart <-> Kotlin contract
/// (docs/ANDROID_NEXT_PLAN.md §9) on the `snapy/core` MethodChannel.
///
/// Every call is safe: a missing method (MissingPluginException / notImplemented, because the
/// Kotlin side is still being built), a PlatformException or a bad payload never throws — it
/// falls back to the older method where one exists, else returns an empty value the UI shows
/// as an empty state. Results may arrive as JSON strings or as platform maps/lists; both work.
class NextApi {
  NextApi._();

  static const channel = MethodChannel('snapy/core');

  /// null = the method isn't there (or failed); the caller picks its fallback.
  static Future<dynamic> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      return _decode(await channel.invokeMethod<dynamic>(method, args));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static dynamic _decode(dynamic v) {
    if (v is String) {
      final s = v.trim();
      if (s.startsWith('{') || s.startsWith('[')) {
        try {
          return jsonDecode(s);
        } catch (_) {}
      }
    }
    return v;
  }

  /// The core runtime's text API (SnapyCore.coreCall), for methods it already implements.
  static Future<dynamic> _core(String method, [List<String> args = const []]) =>
      _invoke('coreCall', {'method': method, 'args': args});

  static Map<String, dynamic> _map(dynamic v) {
    if (v is Map) return v.map((k, e) => MapEntry('$k', e));
    return <String, dynamic>{};
  }

  static List<Map<String, dynamic>> _list(dynamic v) =>
      v is List ? [for (final e in v) if (e is Map) _map(e)] : <Map<String, dynamic>>[];

  static int _int(dynamic v, [int d = 0]) => v is num ? v.toInt() : int.tryParse('$v') ?? d;
  static bool _bool(dynamic v, [bool d = false]) => v is bool ? v : (v == null ? d : '$v' == 'true');

  // ------------------------------------------------------------------ short-video apps
  /// Installed short-video apps (installed ∩ core/rules/social.json catalogue).
  static Future<List<ShortVideoApp>> shortVideoApps() async {
    var raw = _list(await _invoke('shortVideoApps'));
    if (raw.isEmpty) {
      // older Kotlin: getInstalledSocialApps (installed flag + limit/lock per app)
      raw = _list(await _invoke('getInstalledSocialApps')).where((a) => a['installed'] != false).toList();
    }
    return [for (final a in raw) if ('${a['package'] ?? ''}'.isNotEmpty) ShortVideoApp.fromJson(a)];
  }

  static final Map<String, Uint8List?> _icons = {};

  /// The app's launcher icon as PNG bytes (cached here and on the Kotlin side); null = placeholder.
  static Future<Uint8List?> appIcon(String package, {int size = 96}) async {
    final key = '$package@$size';
    if (_icons.containsKey(key)) return _icons[key];
    final v = await _invoke('appIcon', {'package': package, 'size': size});
    Uint8List? bytes;
    if (v is Uint8List && v.isNotEmpty) {
      bytes = v;
    } else if (v is List<int> && v.isNotEmpty) {
      bytes = Uint8List.fromList(v);
    } else if (v is String && v.isNotEmpty) {
      try {
        bytes = base64Decode(v);
      } catch (_) {}
    }
    _icons[key] = bytes;
    return bytes;
  }

  /// Tests: forget cached icons.
  static void clearIconCache() => _icons.clear();

  // ------------------------------------------------------------------ reel limits
  /// {package: ReelLimit} — today's limit, mode, reels used and state.
  static Future<Map<String, ReelLimit>> reelLimits() async {
    final v = await _invoke('reelLimits');
    if (v is Map) {
      return {for (final e in _map(v).entries) if (e.value is Map) e.key: ReelLimit.fromJson(_map(e.value))};
    }
    // older Kotlin: limits live on getInstalledSocialApps rows
    final legacy = _list(await _invoke('getInstalledSocialApps'));
    return {
      for (final a in legacy)
        if (a['limit'] != null)
          '${a['package']}': ReelLimit(limit: _int(a['limit']), mode: a['lock'] == true ? 'hard' : 'soft', used: _int(a['used']), state: '${a['state'] ?? 'ok'}'),
    };
  }

  /// limit 0 = off. mode: soft | hard. Returns false when nothing could store it.
  static Future<bool> setReelLimit(String package, int limit, String mode) async {
    final v = await _invoke('setReelLimit', {'package': package, 'limit': limit, 'mode': mode});
    if (v != null) return v != false;
    final legacy = await _invoke('setAppReelLimit', {'package': package, 'limit': limit, 'lock': mode == 'hard'});
    return legacy == true;
  }

  // ------------------------------------------------------------------ activation
  static Future<ActivationModes?> activationModes() async {
    final v = await _invoke('activationModes');
    return v is Map ? ActivationModes.fromJson(_map(v)) : null;
  }

  /// mode: wake | volume | power.
  static Future<ActivationModes?> setActivationMode(String mode, bool on) async {
    final v = await _invoke('setActivationMode', {'mode': mode, 'on': on});
    if (v is Map) return ActivationModes.fromJson(_map(v));
    if (mode == 'wake') {
      // the wake word already has its own switch on older builds
      try {
        await SnapyCore.setWakeWord(on);
      } catch (_) {}
    }
    return null;
  }

  /// Asks Android to make Snapy the digital assistant (power / home long-press).
  static Future<bool> requestAssistantRole() async => (await _invoke('requestAssistantRole')) == true;

  // ------------------------------------------------------------------ AI key
  static Future<KeyTestResult> testApiKey(String provider, String key) async {
    var v = await _invoke('testApiKey', {'provider': provider, 'key': key});
    v ??= await _core('test_api_key', [provider, key]);
    if (v is Map) return KeyTestResult.fromJson(_map(v));
    final legacy = await _invoke('testGeminiKey', {'key': key});
    if (legacy is Map) {
      final m = _map(legacy);
      return KeyTestResult(ok: m['ok'] == true, code: m['ok'] == true ? 'ok' : '${m['code'] ?? m['error'] ?? 'error'}', message: '${m['error'] ?? ''}');
    }
    return const KeyTestResult(ok: false, code: 'unavailable', message: '');
  }

  // ------------------------------------------------------------------ meetings
  static Future<MeetingState> meetingStart([String title = '']) async =>
      MeetingState.fromJson(_map(await _invoke('meetingStart', {'title': title}) ?? await _core('meeting_start', [title])));
  static Future<MeetingState> meetingStop() async =>
      MeetingState.fromJson(_map(await _invoke('meetingStop') ?? await _core('meeting_stop')));
  static Future<MeetingState> meetingState() async =>
      MeetingState.fromJson(_map(await _invoke('meetingState') ?? await _core('meeting_state')));

  // ------------------------------------------------------------------ memory vault
  /// kind: facts | notes | meetings | all. Newest first.
  static Future<List<VaultItem>> vaultList(String kind) async {
    final v = await _invoke('vaultList', {'kind': kind});
    if (v is List) return [for (final e in _list(v)) VaultItem.fromJson(e, kind)];
    if (v is Map && v['items'] is List) return [for (final e in _list(v['items'])) VaultItem.fromJson(e, kind)];
    if (kind == 'meetings') return const [];
    // older builds: facts and notes from the brain's snapshot
    final s = _map(await _core('snapshot'));
    final out = <VaultItem>[];
    if (kind == 'facts' || kind == 'all') {
      for (final m in _list(s['memories']).reversed) {
        out.add(VaultItem(kind: 'facts', id: '${m['id'] ?? ''}', title: '${m['text'] ?? ''}', markdown: '${m['text'] ?? ''}', date: null));
      }
    }
    if (kind == 'notes' || kind == 'all') {
      for (final n in _list(s['notes']).reversed) {
        final text = '${n['text'] ?? n['content'] ?? n['title'] ?? ''}';
        out.add(VaultItem(kind: 'notes', id: '${n['id'] ?? ''}', title: '${n['title'] ?? text}', markdown: text, date: DateTime.tryParse('${n['created'] ?? n['at'] ?? ''}')));
      }
    }
    return out;
  }

  /// Writes a Markdown/JSON export on the phone; returns its path (null = couldn't).
  static Future<String?> vaultExport(String kind) async {
    final v = await _invoke('vaultExport', {'kind': kind});
    if (v is String && v.isNotEmpty) return v;
    if (v is Map && v['path'] is String) return v['path'] as String;
    return null;
  }

  static Future<bool> vaultClear(String kind) async {
    final v = await _invoke('vaultClear', {'kind': kind});
    return v == true || (v is Map && v['ok'] == true);
  }

  // ------------------------------------------------------------------ device actions
  /// Opens Snapy's camera screen and starts recording. camera: front | back.
  static Future<bool> captureVideo(String camera) async => (await _invoke('captureVideo', {'camera': camera})) == true;
  static Future<bool> sosStart() async => (await _invoke('sosStart')) == true;
  static Future<bool> sosStop() async => (await _invoke('sosStop')) == true;

  /// Opens a web page in the browser. false = nothing could open it (the UI then copies the link).
  static Future<bool> openUrl(String url) async {
    final v = await _invoke('openUrl', {'url': url});
    if (v == true) return true;
    final t = await _invoke('openTarget', {'action': 'android.intent.action.VIEW', 'uri': url, 'data': url});
    return t == true;
  }

  // ------------------------------------------------------------------ profile
  static Future<SnapyProfile> profile() async {
    final v = await _invoke('profile') ?? await _core('profile');
    final map = _map(v);
    if (!map.containsKey('avatar') || '${map['avatar']}'.isEmpty) {
      try {
        final prefs = await SnapyCore.rcPrefs();
        if (prefs.containsKey('user_avatar') && '${prefs['user_avatar']}'.isNotEmpty) {
          map['avatar'] = prefs['user_avatar'];
        }
      } catch (_) {}
    }
    return SnapyProfile.fromJson(map);
  }

  /// Only the given fields change. Returns the stored profile (null = couldn't store).
  static Future<SnapyProfile?> setProfile({String? name, String? assistantName, String? iceNotes, String? avatar}) async {
    final p = <String, dynamic>{
      'name': ?name,
      'assistant_name': ?assistantName,
      'ice_notes': ?iceNotes,
      'avatar': ?avatar,
    };
    var v = await _invoke('setProfile', p);
    v ??= await _core('set_profile', [jsonEncode(p)]);
    // the Kotlin overlay and the wake-word reply read these prefs too
    try {
      await SnapyCore.setRcPrefs({
        'user_name': ?name,
        'ai_name': ?assistantName,
        'user_avatar': ?avatar,
      });
    } catch (_) {}
    return v is Map ? SnapyProfile.fromJson(_map(v)) : null;
  }

  // ------------------------------------------------------------------ events
  /// voice / speak / reel_lock / meeting / activation events from `snapy/events` (never errors).
  static Stream<Map<String, dynamic>> events({Set<String> types = const {'voice', 'speak', 'reel_lock', 'meeting', 'activation'}}) {
    Stream<Map<String, dynamic>> src;
    try {
      src = SnapyCore.events;
    } catch (_) {
      return const Stream.empty();
    }
    return src.handleError((_) {}).where((e) => types.contains(e['type']));
  }
}

class ShortVideoApp {
  final String package, label, kind;
  final bool installed;
  const ShortVideoApp({required this.package, required this.label, this.kind = 'Reels', this.installed = true});

  factory ShortVideoApp.fromJson(Map<String, dynamic> j) => ShortVideoApp(
        package: '${j['package']}',
        label: '${j['label'] ?? j['package']}',
        kind: '${j['kind'] ?? j['short_video'] ?? 'Reels'}',
        installed: j['installed'] != false,
      );
}

class ReelLimit {
  final int limit, used;
  final String mode, state; // mode: soft | hard · state: ok | near | locked | unlocked | off
  const ReelLimit({this.limit = 0, this.mode = 'soft', this.used = 0, this.state = 'ok'});

  bool get hard => mode == 'hard';
  bool get off => limit <= 0;
  double get progress => limit <= 0 ? 0 : (used / limit).clamp(0, 1).toDouble();

  factory ReelLimit.fromJson(Map<String, dynamic> j) => ReelLimit(
        limit: NextApi._int(j['limit']),
        mode: j['mode'] == 'hard' ? 'hard' : 'soft',
        used: NextApi._int(j['used']),
        state: '${j['state'] ?? 'ok'}',
      );

  ReelLimit copyWith({int? limit, String? mode, int? used}) =>
      ReelLimit(limit: limit ?? this.limit, mode: mode ?? this.mode, used: used ?? this.used, state: state);
}

class ActivationModes {
  final bool wake, volume, power, assistantRole;
  const ActivationModes({this.wake = false, this.volume = false, this.power = false, this.assistantRole = false});

  factory ActivationModes.fromJson(Map<String, dynamic> j) => ActivationModes(
        wake: NextApi._bool(j['wake']),
        volume: NextApi._bool(j['volume']),
        power: NextApi._bool(j['power']),
        assistantRole: NextApi._bool(j['assistantRole'] ?? j['assistant_role']),
      );

  ActivationModes withMode(String mode, bool on) => ActivationModes(
        wake: mode == 'wake' ? on : wake,
        volume: mode == 'volume' ? on : volume,
        power: mode == 'power' ? on : power,
        assistantRole: assistantRole,
      );

  bool of(String mode) => switch (mode) { 'wake' => wake, 'volume' => volume, 'power' => power, _ => false };
}

/// What a key test means for the person: one of the rows of the plan's copy table.
enum KeyVerdict { ok, invalid, permission, quota, region, network, error }

class KeyTestResult {
  final bool ok;
  final String code, message;
  final String? helpUrl;
  const KeyTestResult({required this.ok, required this.code, this.message = '', this.helpUrl});

  factory KeyTestResult.fromJson(Map<String, dynamic> j) => KeyTestResult(
        ok: j['ok'] == true,
        code: '${j['code'] ?? (j['ok'] == true ? 'ok' : 'error')}',
        message: '${j['message'] ?? ''}',
        helpUrl: j['help_url'] is String ? j['help_url'] as String : null,
      );

  /// Maps the brain's codes (ok | invalid_key | quota | permission | model | network | error) and
  /// raw provider codes (API_KEY_INVALID, PERMISSION_DENIED, RESOURCE_EXHAUSTED,
  /// FAILED_PRECONDITION, 400/401/403/429) to the plan's table.
  KeyVerdict get verdict {
    if (ok) return KeyVerdict.ok;
    final c = code.toUpperCase();
    final m = message.toUpperCase();
    if (c == 'REGION' || c.contains('FAILED_PRECONDITION') || m.contains('FAILED_PRECONDITION') || m.contains('LOCATION IS NOT SUPPORTED')) {
      return KeyVerdict.region;
    }
    if (c == 'QUOTA' || c == '429' || c.contains('RESOURCE_EXHAUSTED')) return KeyVerdict.quota;
    if (c == 'PERMISSION' || c.contains('PERMISSION_DENIED')) return KeyVerdict.permission;
    if (c == 'INVALID_KEY' || c == 'INVALID' || c.contains('API_KEY_INVALID') || c == '400' || c == '401' || c == '403' ||
        c == 'UNAUTHENTICATED') {
      return KeyVerdict.invalid;
    }
    if (c == 'NETWORK' || c == 'OFFLINE' || c == 'TIMEOUT') return KeyVerdict.network;
    return KeyVerdict.error;
  }
}

class MeetingState {
  final bool recording;
  final int elapsed; // seconds
  final String live; // latest transcript line
  const MeetingState({this.recording = false, this.elapsed = 0, this.live = ''});

  factory MeetingState.fromJson(Map<String, dynamic> j) {
    var e = NextApi._int(j['elapsed'] ?? j['elapsed_s']);
    if (e > 100000) e ~/= 1000; // milliseconds from some builds
    return MeetingState(recording: j['recording'] == true, elapsed: e, live: '${j['live'] ?? ''}');
  }
}

class VaultItem {
  final String kind, id, title, markdown;
  final DateTime? date;
  const VaultItem({required this.kind, required this.id, required this.title, required this.markdown, this.date});

  factory VaultItem.fromJson(Map<String, dynamic> j, String kind) {
    final md = '${j['markdown'] ?? j['text'] ?? j['content'] ?? j['summary'] ?? ''}';
    var title = '${j['title'] ?? ''}';
    if (title.isEmpty) {
      title = md.split('\n').map((l) => l.replaceFirst(RegExp(r'^#+\s*'), '').trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    }
    return VaultItem(
      kind: '${j['kind'] ?? kind}',
      id: '${j['id'] ?? j['path'] ?? title}',
      title: title,
      markdown: md,
      date: DateTime.tryParse('${j['date'] ?? j['created'] ?? j['at'] ?? ''}'),
    );
  }
}

class SnapyProfile {
  final String name, assistantName, iceNotes, avatar;
  const SnapyProfile({this.name = '', this.assistantName = 'Snapy', this.iceNotes = '', this.avatar = 'halo'});

  factory SnapyProfile.fromJson(Map<String, dynamic> j) {
    final a = '${j['assistant_name'] ?? ''}'.trim();
    return SnapyProfile(
      name: '${j['name'] ?? j['preferred_name'] ?? ''}'.trim(),
      assistantName: a.isEmpty ? 'Snapy' : a,
      iceNotes: '${j['ice_notes'] ?? ''}',
      avatar: '${j['avatar'] ?? j['user_avatar'] ?? 'halo'}',
    );
  }
}
