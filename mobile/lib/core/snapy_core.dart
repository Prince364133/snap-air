import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core_runtime/platform_channels.dart';
import '../sync/pair_screen.dart';

/// The UI's door to Snapy's brain. The brain is the Dart core runtime (lib/core_runtime) running
/// in its own headless engine started by Kotlin — one instance per process, the only owner of
/// the stores — and implementing core/ exactly like the Windows Python engine. Calls go
/// "snapy/core" -> Kotlin -> that engine; its events arrive on "snapy/events".
class SnapyCore {
  /// Once per UI engine (main): platform services this isolate needs (the Keystore-backed
  /// SecureKeyStore that lib/sync pairing uses).
  static void install() {
    SyncHost.keyStore ??= const KeystoreKeyStore();
  }

  static const _ch = MethodChannel('snapy/core');
  static const _ev = EventChannel('snapy/events');
  static Stream<Map<String, dynamic>>? _events;

  /// Everything the brain emits: chat_message, assistant_state, toast, op, ui_action, reminders…
  static Stream<Map<String, dynamic>> get events => _events ??= _ev
      .receiveBroadcastStream()
      .expand((batch) => (jsonDecode(batch as String) as List).map((e) => Map<String, dynamic>.from(e as Map)))
      .asBroadcastStream();

  static Future<bool> ready() async => (await _ch.invokeMethod<bool>('ready')) ?? false;

  /// A user message (typed now; spoken in Phase 3). Replies arrive on [events].
  static Future<void> send(String text, {String source = 'typed'}) =>
      _ch.invokeMethod('send', {'text': text, 'source': source});

  static Future<void> interrupt() => _ch.invokeMethod('interrupt');

  /// Push-to-talk (asks for the microphone the first time; returns false until granted).
  static Future<bool> startListening() async => (await _ch.invokeMethod<bool>('startListening')) ?? false;
  static Future<void> stopListening() => _ch.invokeMethod('stopListening');

  /// "Hey Snapy" in the background (opt-in).
  static Future<bool> setWakeWord(bool on) async => (await _ch.invokeMethod<bool>('setWakeWord', {'on': on})) ?? false;

  static Future<Map<String, dynamic>> _json(String method, [Map<String, dynamic>? args]) async {
    try {
      final raw = await _ch.invokeMethod<String>(method, args);
      if (raw == null || raw.trim().isEmpty || raw.trim() == 'null') return <String, dynamic>{};
      final dec = jsonDecode(raw);
      if (dec is Map) return Map<String, dynamic>.from(dec);
    } catch (_) {}
    return <String, dynamic>{};
  }

  static Future<Map<String, dynamic>> brainStatus() => _json('brainStatus');
  static Future<Map<String, dynamic>> setApiKey(String provider, String key) =>
      _json('setApiKey', {'provider': provider, 'key': key});
  static Future<void> updateSettings(Map<String, dynamic> changes) =>
      _ch.invokeMethod('updateSettings', {'json': jsonEncode(changes)});
  static Future<Map<String, dynamic>> snapshot() => _json('snapshot');
  static Future<void> completeTask(String id) => _ch.invokeMethod('completeTask', {'id': id});

  /// Which permissions are on: {usage, realcount, pill, overlay, notifications, microphone, contacts, calls, wake, battery}.
  static Future<Map<String, bool>> status() async => Map<String, bool>.from(await _ch.invokeMethod('status') as Map);
  static Future<void> requestNotifications() => _ch.invokeMethod('requestNotifications');

  /// contacts | calls | microphone
  static Future<void> requestPermission(String which) => _ch.invokeMethod('requestPermission', {'which': which});
  static Future<void> openUsageAccess() => _ch.invokeMethod('openUsageAccess');
  static Future<void> openRealCountSettings() => _ch.invokeMethod('openRealCountSettings');
  static Future<void> closeSheet() => _ch.invokeMethod('closeSheet');

  /// Today's screen time, per-app time, opens and reels/shorts counts.
  static Future<Today> today() async {
    try {
      final raw = await _ch.invokeMethod<String>('today');
      if (raw != null && raw.trim().isNotEmpty && raw.trim() != 'null') {
        final dec = jsonDecode(raw);
        if (dec is Map<String, dynamic>) return Today.fromJson(dec);
        if (dec is Map) return Today.fromJson(Map<String, dynamic>.from(dec));
      }
    } catch (_) {}
    return Today(0, const {}, const {}, const {});
  }

  /// Shared product data (core/rules, merged), e.g. config('android.social_apps').
  static Future<dynamic> config(String path) async =>
      jsonDecode((await _ch.invokeMethod<String>('config', {'path': path})) ?? 'null');

  // ---------------------------------------------------------------- Real Count (Phase 5)
  /// The app's private files folder (…/files); Snapy's data lives in its "snapy" subfolder.
  static Future<String> filesDir() async => (await _ch.invokeMethod<String>('filesDir')) ?? '';

  /// Chip and counter preferences kept on the phone (also read by the Kotlin overlay).
  static Future<Map<String, dynamic>> rcPrefs() => _json('rcPrefs');
  static Future<void> setRcPrefs(Map<String, dynamic> changes) =>
      _ch.invokeMethod('setRcPrefs', {'json': jsonEncode(changes)});

  /// Live counter state: focus_until, paused_until, hidden_day, intention, paused_apps, mode.
  static Future<Map<String, dynamic>> rcState() => _json('rcState');
  static Future<void> startFocus(int minutes) => _ch.invokeMethod('startFocus', {'minutes': minutes});
  static Future<void> stopFocus() => _ch.invokeMethod('stopFocus');
  static Future<void> pauseCounting(int minutes) => _ch.invokeMethod('pauseCounting', {'minutes': minutes});

  /// A call into the core runtime that returns text (JSON where structured), e.g. coreCall('limits_json').
  static Future<String> coreCall(String method, [List<String> args = const []]) async =>
      (await _ch.invokeMethod<String>('coreCall', {'method': method, 'args': args})) ?? 'null';

  /// {manufacturer, brand, model, sdk, snapy_version}
  static Future<Map<String, dynamic>> device() async => Map<String, dynamic>.from(await _ch.invokeMethod('device') as Map);

  /// versionName of each installed package in [packages] (missing = not installed).
  static Future<Map<String, String>> appVersions(List<String> packages) async =>
      Map<String, String>.from(await _ch.invokeMethod('appVersions', {'packages': packages}) as Map);

  static Future<void> openOverlaySettings() => _ch.invokeMethod('openOverlaySettings');
  static Future<void> openAppDetails() => _ch.invokeMethod('openAppDetails');

  /// Opens a settings screen: an explicit component (pkg/cls) or an action. false if it isn't there.
  static Future<bool> openTarget(Map<String, String?> target) async =>
      (await _ch.invokeMethod<bool>('openTarget', target)) ?? false;

  /// Shows the chip with "Display over other apps" when the Reel counter is off.
  static Future<bool> startChip() async => (await _ch.invokeMethod<bool>('startChip')) ?? false;

  /// Leaves the current app for the home screen (the "Not now" on the pause screen).
  static Future<void> goHome() => _ch.invokeMethod('goHome');

  /// Fetches installed social apps that support short-form video feeds with current limits.
  static Future<List<Map<String, dynamic>>> getInstalledSocialApps() async {
    final res = await _ch.invokeMethod<List>('getInstalledSocialApps');
    return (res ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Sets daily reel limit and feed lock toggle for a specific app.
  static Future<bool> setAppReelLimit(String package, int limit, bool lock) async {
    return (await _ch.invokeMethod<bool>('setAppReelLimit', {
      'package': package,
      'limit': limit,
      'lock': lock,
    })) ?? false;
  }

  /// Checks any provider's key through the brain: {ok, code, message, help_url}
  /// (code: ok | invalid_key | quota | permission | model | network | error).
  static Future<Map<String, dynamic>> testApiKey(String provider, String key) async =>
      Map<String, dynamic>.from(jsonDecode(await coreCall('test_api_key', [provider, key])) as Map);

  /// Meeting notes from the phone's recognizer: {recording, elapsed, live, words, ...}.
  static Future<Map<String, dynamic>> meetingStart([String title = '']) async =>
      Map<String, dynamic>.from(jsonDecode(await coreCall('meeting_start', [title])) as Map);
  static Future<Map<String, dynamic>> meetingStop() async =>
      Map<String, dynamic>.from(jsonDecode(await coreCall('meeting_stop')) as Map);
  static Future<Map<String, dynamic>> meetingState() async =>
      Map<String, dynamic>.from(jsonDecode(await coreCall('meeting_state')) as Map);

  /// {name, assistant_name, ice_notes, ...profile}
  static Future<Map<String, dynamic>> profile() async =>
      Map<String, dynamic>.from(jsonDecode(await coreCall('profile')) as Map);
  static Future<Map<String, dynamic>> setProfile(Map<String, dynamic> p) async =>
      Map<String, dynamic>.from(jsonDecode(await coreCall('set_profile', [jsonEncode(p)])) as Map);

  /// Sync with the paired laptop now (e.g. right after pairing).
  static Future<void> syncNow() => coreCall('sync_kick');

  /// Tests Google Gemini API key live against Gemini API.
  static Future<Map<String, dynamic>> testGeminiKey(String key) async {
    final res = await _ch.invokeMethod<Map>('testGeminiKey', {'key': key});
    return Map<String, dynamic>.from(res ?? {'ok': false, 'error': 'Unknown error'});
  }

  /// Toggles device flashlight.
  static Future<bool> toggleTorch(bool on) async {
    return (await _ch.invokeMethod<bool>('toggleTorch', {'on': on})) ?? false;
  }
}

/// One day of Real Count.
class Today {
  final int screenMs;
  final Map<String, int> perAppMs;
  final Map<String, int> opens;
  final Map<String, ({int reels, int reelMs, int longVideos})> reels;
  Today(this.screenMs, this.perAppMs, this.opens, this.reels);

  int get totalReels => reels.values.fold(0, (a, b) => a + b.reels);
  int get totalLongVideos => reels.values.fold(0, (a, b) => a + b.longVideos);

  factory Today.fromJson(Map<String, dynamic> j) {
    Map<String, int> ints(dynamic m) =>
        m is Map ? m.map((k, v) => MapEntry(k.toString(), (v as num).toInt())) : <String, int>{};
    final apps = ((j['realcount'] as Map?)?['apps'] as Map?) ?? const {};
    return Today(
      (j['screen_ms'] as num?)?.toInt() ?? 0,
      ints(j['per_app_ms']),
      ints(j['opens']),
      apps.map((k, v) => MapEntry(
          k.toString(),
          (
            reels: ((v as Map)['reels'] as num?)?.toInt() ?? 0,
            reelMs: (v['reel_ms'] as num?)?.toInt() ?? 0,
            longVideos: (v['long_videos'] as num?)?.toInt() ?? 0,
          ))),
    );
  }
}

String formatMs(int ms) {
  final m = ms ~/ 60000;
  return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
}
