import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Dart side of Snapy's brain. The brain is the same Python the Windows engine runs
/// (engine/src via Chaquopy); Kotlin executes the phone actions it decides on.
class SnapyCore {
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

  static Future<Map<String, dynamic>> _json(String method, [Map<String, dynamic>? args]) async =>
      Map<String, dynamic>.from(jsonDecode((await _ch.invokeMethod<String>(method, args)) ?? '{}') as Map);

  static Future<Map<String, dynamic>> brainStatus() => _json('brainStatus');
  static Future<Map<String, dynamic>> setApiKey(String provider, String key) =>
      _json('setApiKey', {'provider': provider, 'key': key});
  static Future<void> updateSettings(Map<String, dynamic> changes) =>
      _ch.invokeMethod('updateSettings', {'json': jsonEncode(changes)});
  static Future<Map<String, dynamic>> snapshot() => _json('snapshot');
  static Future<void> completeTask(String id) => _ch.invokeMethod('completeTask', {'id': id});

  /// Which permissions are on: {usage, realcount, pill, notifications}.
  static Future<Map<String, bool>> status() async => Map<String, bool>.from(await _ch.invokeMethod('status') as Map);
  static Future<void> requestNotifications() => _ch.invokeMethod('requestNotifications');
  static Future<void> openUsageAccess() => _ch.invokeMethod('openUsageAccess');
  static Future<void> openRealCountSettings() => _ch.invokeMethod('openRealCountSettings');
  static Future<void> closeSheet() => _ch.invokeMethod('closeSheet');

  /// Today's screen time, per-app time, opens and reels/shorts counts.
  static Future<Today> today() async =>
      Today.fromJson(jsonDecode((await _ch.invokeMethod<String>('today')) ?? '{}') as Map<String, dynamic>);

  /// Central product data (src/data/app.json), e.g. config('android.social_apps').
  static Future<dynamic> config(String path) async =>
      jsonDecode((await _ch.invokeMethod<String>('config', {'path': path})) ?? 'null');
}

/// One day of Real Count.
class Today {
  final int screenMs;
  final Map<String, int> perAppMs;
  final Map<String, int> opens;
  final Map<String, ({int reels, int reelMs})> reels;
  Today(this.screenMs, this.perAppMs, this.opens, this.reels);

  int get totalReels => reels.values.fold(0, (a, b) => a + b.reels);

  factory Today.fromJson(Map<String, dynamic> j) {
    Map<String, int> ints(dynamic m) =>
        m is Map ? m.map((k, v) => MapEntry(k.toString(), (v as num).toInt())) : <String, int>{};
    final apps = ((j['realcount'] as Map?)?['apps'] as Map?) ?? const {};
    return Today(
      (j['screen_ms'] as num?)?.toInt() ?? 0,
      ints(j['per_app_ms']),
      ints(j['opens']),
      apps.map((k, v) => MapEntry(k.toString(),
          (reels: ((v as Map)['reels'] as num?)?.toInt() ?? 0, reelMs: (v['reel_ms'] as num?)?.toInt() ?? 0))),
    );
  }
}

String formatMs(int ms) {
  final m = ms ~/ 60000;
  return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
}
