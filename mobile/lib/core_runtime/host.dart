// The core engine: a headless FlutterEngine that Kotlin starts once per process
// (CoreBridge.kt, cached in FlutterEngineCache as "snapy_core") with the entrypoint
// [snapyCoreMain]. It owns the ONE SnapyRuntime — the single source of truth for every store
// (memory, tasks, notes, settings, Real Count answers). The UI engines (MainActivity,
// SheetActivity) never open the stores themselves: they call "snapy/core", Kotlin forwards to
// this engine over "snapy/runtime", and this engine's events go back to every UI's
// "snapy/events" stream.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../sync/pair_screen.dart';
import '../sync/pairing.dart';
import 'core_data.dart';
import 'platform_channels.dart';
import 'runtime.dart';
import 'sync_runner.dart';

SnapyRuntime? _runtime;
SyncRunner? _sync;

/// The core engine's main (called by the `snapyCoreMain` entrypoint in lib/main.dart).
Future<void> runSnapyCore() async {
  WidgetsFlutterBinding.ensureInitialized();
  final hooks = RuntimeChannel();
  const keys = KeystoreKeyStore();
  SyncHost.keyStore = keys;
  Completer<void>? starting;
  final pending = <Map<String, dynamic>>[];
  var flushQueued = false;

  void flush() {
    flushQueued = false;
    if (pending.isEmpty) return;
    final batch = [...pending];
    pending.clear();
    hooks.sendEvents(batch);
  }

  Future<void> start(String dataDir) async {
    if (_runtime != null) return;
    if (starting != null) return starting!.future;
    starting = Completer<void>();
    try {
      final core = await CoreData.load(AssetCoreSource(rootBundle.loadString));
      String? device;
      try {
        device = (await PairingRepository(keys).identity()).deviceId; // the same id the sync stamps with
      } catch (_) {}
      final rt = SnapyRuntime(core, dataDir, hooks, device: device);
      rt.events.listen((e) {
        pending.add(e);
        if (!flushQueued) {
          flushQueued = true;
          scheduleMicrotask(flush); // one batch per burst, in order
        }
      });
      rt.syncReminders();
      _runtime = rt;
      _sync = SyncRunner(rt, keys, onWifi: hooks.onWifi, multicastLock: hooks.multicastLock)..start();
      rt.onSyncKick = () => _sync?.kick();
      starting!.complete();
    } catch (e) {
      starting!.completeError(e);
      starting = null;
      rethrow;
    }
  }

  RuntimeChannel.channel.setMethodCallHandler((call) async {
    if (hooks.handleNano(call)) return null;
    final args = Map<String, dynamic>.from((call.arguments as Map?) ?? const {});
    switch (call.method) {
      case 'init':
        await start(args['dataDir'] as String);
        return 'ok';
      case 'call':
        final rt = _runtime;
        if (rt == null) {
          if (starting != null) await starting!.future;
        }
        if (_runtime == null) throw PlatformException(code: 'not_ready', message: 'Snapy core is starting');
        final r = await _runtime!.call(args['method'] as String, List<String>.from((args['args'] as List?) ?? const []));
        return r;
      case 'syncKick':
        _sync?.kick();
        return 'ok';
    }
    throw MissingPluginException(call.method);
  });
  // Kotlin waits for this before sending "init"
  await RuntimeChannel.channel.invokeMethod('ready');
}
