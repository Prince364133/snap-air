// Background sync with the paired laptop (lib/sync does the protocol; this wires it to the
// phone's stores and actions). While on Wi-Fi and paired: connect, run the session (LWW sync
// of memory/tasks/notes/settings/day summaries, periodic resync inside runSession), reconnect
// with back-off. Laptop -> phone commands: link, note, text, start_my_day, focus, resume_context.
import 'dart:async';

import '../sync/pairing.dart';
import '../sync/sync_client.dart';
import '../sync/sync_store.dart';
import 'life.dart';
import 'runtime.dart';
import 'sync_stores.dart';

class SyncRunner {
  final SnapyRuntime rt;
  final SecureKeyStore keys;
  final Future<bool> Function() onWifi;
  final Future<void> Function(bool on) multicastLock;
  late final SyncEngine engine;
  SyncConnection? _conn;
  Timer? _timer;
  bool _connecting = false;
  bool _stopped = false;
  Duration _backoff = const Duration(seconds: 15);
  String state = 'idle'; // idle | searching | connected | unpaired | offline

  SyncRunner(this.rt, this.keys, {required this.onWifi, required this.multicastLock}) {
    final meta = SyncMeta('${rt.dataDir}/sync/meta.json');
    void changed() => rt.storesChanged();
    engine = SyncEngine([
      memorySyncStore(rt.memory, onApplied: changed),
      taskSyncStore(rt.tasks, onApplied: changed),
      noteSyncStore(rt.notes, onApplied: changed),
      SettingsProfileSync(rt.core, rt.settings, meta, rt.device),
      DaySummarySync(rt.core, 'activity_day', () => const [], meta, rt.device, '${rt.dataDir}/sync/remote_activity_day.json'),
      DaySummarySync(rt.core, 'attention_day', () => attentionDays(rt.realcount), meta, rt.device,
          '${rt.dataDir}/sync/remote_attention_day.json'),
    ]);
  }

  void start() {
    _stopped = false;
    _schedule(const Duration(seconds: 3));
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _conn?.close();
  }

  /// "sync now" (after pairing, app resumed, network back).
  void kick() => _schedule(Duration.zero);

  void _schedule(Duration d) {
    if (_stopped) return;
    _timer?.cancel();
    _timer = Timer(d, _tick);
  }

  void _setState(String s) {
    if (s == state) return;
    state = s;
    rt.emit({'type': 'sync', 'state': s});
  }

  Future<void> _tick() async {
    if (_stopped || _connecting || _conn != null) return;
    _connecting = true;
    try {
      final repo = PairingRepository(keys);
      final laptops = await repo.laptops();
      if (laptops.isEmpty) {
        _setState('unpaired');
        _schedule(const Duration(minutes: 5));
        return;
      }
      if (!await onWifi()) {
        _setState('offline');
        _schedule(const Duration(minutes: 2));
        return;
      }
      _setState('searching');
      await multicastLock(true);
      SyncConnection? conn;
      try {
        for (final l in laptops) {
          try {
            conn = await connectPaired(l, repo);
            break;
          } catch (_) {}
        }
      } finally {
        await multicastLock(false);
      }
      if (conn == null) {
        _setState('idle');
        _backoff = _backoff * 2 > const Duration(minutes: 10) ? const Duration(minutes: 10) : _backoff * 2;
        _schedule(_backoff);
        return;
      }
      _backoff = const Duration(seconds: 15);
      _conn = conn;
      _setState('connected');
      unawaited(runSession(conn, engine, onCommand: (peer, cmd) => handleCommand(cmd), onEvent: (kind, data) {
        rt.emit({'type': 'sync_$kind', ...data});
      }).whenComplete(() {
        _conn = null;
        _setState('idle');
        _schedule(const Duration(seconds: 20));
      }));
    } catch (_) {
      _schedule(const Duration(minutes: 1));
    } finally {
      _connecting = false;
    }
  }

  /// Phone-side command handlers (validated by lib/sync before they get here).
  void handleCommand(Map<String, dynamic> cmd) {
    switch (cmd['type']) {
      case 'link':
        rt.agent.openUrl(cmd['url'] as String);
        rt.emit({'type': 'toast', 'text': 'Opened a link from your laptop'});
      case 'note':
        final n = rt.notes.add(cmd['text'] as String, extra: const {'source': 'laptop'});
        rt.emit({'type': 'note_added', 'note': n});
        rt.emit({'type': 'toast', 'text': 'Note saved from your laptop'});
      case 'text':
        rt.emit({'type': 'op', 'op': 'copy_text', 'args': <dynamic>[], 'kwargs': {'text': cmd['text'], 'notify': true}});
      case 'start_my_day':
        final b = rt.briefing.build();
        rt.emit({'type': 'briefing', ...b});
        rt.emit({'type': 'op', 'op': 'notify', 'args': <dynamic>[], 'kwargs': {'title': b['title'], 'text': Briefing.spoken(b)}});
      case 'focus':
        rt.emit({'type': 'op', 'op': 'focus', 'args': <dynamic>[], 'kwargs': {'minutes': cmd['minutes'], 'dnd': true}});
      case 'resume_context':
        rt.emit({'type': 'toast', 'text': 'Resuming “${cmd['name']}” on your laptop'});
    }
  }
}
