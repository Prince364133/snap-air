/// Phone side of Snapy sync: discovery, pairing, the encrypted session and LWW sync.
/// Mirrors engine/src/sync/session.py + transport.py.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

import 'commands.dart';
import 'merge.dart';
import 'pairing.dart';
import 'protocol.dart';
import 'sync_config.dart';
import 'sync_store.dart';

// ------------------------------------------------------------------ sync engine
class SyncEngine {
  final Map<String, SyncStore> stores;
  final int Function() nowMs;
  final SyncConfig cfg;

  SyncEngine(List<SyncStore> list, {int Function()? nowMs, SyncConfig? cfg})
      : stores = {for (final s in list) s.kind: s},
        nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        cfg = cfg ?? SyncConfig();

  Future<Map<String, dynamic>> manifestMsg() async =>
      {'type': 'manifest', 'kinds': {for (final e in stores.entries) e.key: manifest(await e.value.records())}};

  Future<List<Map<String, dynamic>>> answer(Map<String, dynamic> msg) async {
    final kinds = msg['kinds'] is Map ? msg['kinds'] as Map : const {};
    final batch = cfg.i('batch_records');
    final out = <Map<String, dynamic>>[];
    var sent = 0;
    for (final e in stores.entries) {
      final theirs = kinds[e.key] is Map ? Map<String, dynamic>.from(kinds[e.key] as Map) : <String, dynamic>{};
      final recs = toSend(await e.value.records(), theirs);
      sent += recs.length;
      for (var i = 0; i < recs.length; i += batch) {
        out.add({'type': 'records', 'kind': e.key, 'records': recs.sublist(i, (i + batch).clamp(0, recs.length))});
      }
    }
    out.add({'type': 'sync_end', 'sent': sent});
    return out;
  }

  /// Returns (applied, rejected).
  Future<(int, int)> receive(Map<String, dynamic> msg) async {
    final s = stores[msg['kind']];
    final recs = msg['records'];
    if (s == null || recs is! List) return (0, recs is List ? recs.length : 0);
    final res = merge(await s.records(), recs, nowMs: nowMs(), maxSkewMs: cfg.i('max_clock_skew_s') * 1000);
    if (res.applied.isNotEmpty) await s.apply([for (final i in res.applied) res.merged[i]!]);
    return (res.applied.length, res.rejected);
  }

  Future<int> purge() async {
    var n = 0;
    for (final s in stores.values) {
      final ids = purgeTombstones(await s.records(), nowMs(), cfg.i('tombstone_days'));
      if (ids.isNotEmpty) {
        await s.purge(ids);
        n += ids.length;
      }
    }
    return n;
  }
}

// ------------------------------------------------------------------ framing over a socket
class _FrameReader {
  final _buf = BytesBuilder(copy: false);
  final _waiters = <Completer<void>>[];
  bool closed = false;
  Object? error;
  late final StreamSubscription<Uint8List> _sub;

  _FrameReader(Stream<Uint8List> s) {
    _sub = s.listen((d) {
      _buf.add(d);
      _wake();
    }, onError: (Object e) {
      error = e;
      closed = true;
      _wake();
    }, onDone: () {
      closed = true;
      _wake();
    });
  }

  void _wake() {
    for (final w in List.of(_waiters)) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<Uint8List> _take(int n) async {
    while (_buf.length < n) {
      if (closed) throw const SocketException('connection closed');
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    final all = _buf.takeBytes();
    if (all.length > n) _buf.add(all.sublist(n));
    return Uint8List.sublistView(all, 0, n);
  }

  Future<Uint8List> read(int maxBytes) async {
    final head = await _take(4);
    final n = ByteData.sublistView(head).getUint32(0);
    if (n == 0 || n > maxBytes) throw const FrameException('frame size out of range');
    return Uint8List.fromList(await _take(n));
  }

  Future<void> cancel() => _sub.cancel();
}

/// One authenticated session with the laptop.
class SyncConnection {
  final Socket socket;
  final _FrameReader _reader;
  final Channel channel;
  final String peerId, peerName;
  final SyncConfig cfg;
  bool closed = false;
  Future<void> _wq = Future.value();

  SyncConnection._(this.socket, this._reader, this.channel, this.peerId, this.peerName, this.cfg);

  Future<void> send(Map<String, dynamic> msg) {
    // serialise writes: the counter order must match the byte order on the wire
    final next = _wq.then((_) async {
      final body = await channel.sendJson(msg);
      socket.add(frame(body));
      await socket.flush();
    });
    _wq = next.catchError((_) {});
    return next;
  }

  Future<Map<String, dynamic>> recv() async => channel.openJson(await _reader.read(cfg.i('max_frame_bytes')));

  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _reader.cancel();
    socket.destroy();
  }
}

/// Open a TCP connection and run the handshake.
Future<SyncConnection> connectToLaptop({
  required String host,
  required int port,
  required DeviceIdentity me,
  required Uint8List laptopPublicKey,
  String? laptopId,
  List<int>? pairingSecret,
  SyncConfig? cfg,
}) async {
  final c = cfg ?? SyncConfig();
  final socket = await Socket.connect(host, port, timeout: Duration(seconds: c.i('connect_timeout_s')));
  final reader = _FrameReader(socket);
  try {
    final hs = await ClientHandshake.create(
        staticPriv: me.privateKey,
        deviceId: me.deviceId,
        name: me.name,
        serverStaticPub: laptopPublicKey,
        mode: pairingSecret != null ? 'pair' : 'session',
        psk: pairingSecret,
        expectServerId: laptopId);
    final maxb = c.i('max_frame_bytes');
    await () async {
      socket.add(frame(await hs.message1()));
      await socket.flush();
      await hs.readMessage2(await reader.read(maxb));
      await hs.readConfirm(await reader.read(maxb));
      socket.add(frame(await hs.message4()));
      await socket.flush();
    }()
        .timeout(Duration(seconds: c.i('handshake_timeout_s')));
    return SyncConnection._(socket, reader, hs.channel(), hs.serverId!, hs.serverName!, c);
  } catch (_) {
    await reader.cancel();
    socket.destroy();
    rethrow;
  }
}

typedef CommandHandler = void Function(String peerId, Map<String, dynamic> cmd);
typedef SyncEventHandler = void Function(String kind, Map<String, dynamic> data);

/// Run sync + commands + keepalive until the link closes. Never throws.
Future<void> runSession(SyncConnection conn, SyncEngine engine,
    {CommandHandler? onCommand, SyncEventHandler? onEvent, void Function(String id)? onAck}) async {
  final cfg = conn.cfg;
  final emit = onEvent ?? (String kind, Map<String, dynamic> data) {};
  var lastRx = DateTime.now(), lastManifest = DateTime.now();
  var appliedTotal = 0;
  try {
    await conn.send(await engine.manifestMsg());
    while (!conn.closed) {
      Map<String, dynamic> msg;
      try {
        msg = await conn.recv().timeout(Duration(seconds: cfg.i('keepalive_s')));
      } on TimeoutException {
        final now = DateTime.now();
        if (now.difference(lastRx).inSeconds > cfg.i('idle_timeout_s')) break;
        await conn.send({'type': 'ping'});
        if (now.difference(lastManifest).inSeconds > cfg.i('resync_interval_s')) {
          lastManifest = now;
          await conn.send(await engine.manifestMsg());
        }
        continue;
      }
      lastRx = DateTime.now();
      switch (msg['type']) {
        case 'manifest':
          for (final out in await engine.answer(msg)) {
            await conn.send(out);
          }
        case 'records':
          final (applied, _) = await engine.receive(msg);
          appliedTotal += applied;
          if (applied > 0) emit('changed', {'peer': conn.peerId, 'kind': msg['kind'], 'applied': applied});
        case 'sync_end':
          emit('synced', {'peer': conn.peerId, 'applied': appliedTotal});
          appliedTotal = 0;
        case 'cmd':
          final id = msg['id'] is String ? msg['id'] as String : '';
          Map<String, dynamic> cmd;
          try {
            cmd = validateCommand(msg['cmd'], cfg);
          } on CommandException {
            await conn.send({'type': 'ack', 'id': id, 'ok': false});
            continue;
          }
          await conn.send({'type': 'ack', 'id': id, 'ok': true});
          try {
            onCommand?.call(conn.peerId, cmd);
          } catch (_) {
            // a bad handler must not drop sync
          }
        case 'ack':
          if (msg['id'] is String) onAck?.call(msg['id'] as String);
        case 'ping':
          await conn.send({'type': 'pong'});
        case 'bye':
          await conn.close();
      }
    }
  } catch (_) {
    // peer went away or sent garbage: close
  } finally {
    await conn.close();
  }
}

/// Send one command to the laptop on an open connection.
Future<String> sendCommand(SyncConnection conn, Map<String, dynamic> cmd) async {
  final c = validateCommand(cmd, conn.cfg);
  final id = bytesToHex(randomBytes(16));
  await conn.send({'type': 'cmd', 'id': id, 'cmd': c});
  return id;
}

// ------------------------------------------------------------------ discovery
/// Where the laptop might be: mDNS (_snapy._tcp, matched by device id), then the UDP beacon,
/// then the last host that worked and the QR's host list. Android: holding a
/// WifiManager.MulticastLock (Kotlin) makes mDNS/beacon replies reliable on many phones.
Future<List<(String, int)>> discoverLaptop(PairedLaptop laptop, {SyncConfig? cfg}) async {
  final c = cfg ?? SyncConfig();
  final out = <(String, int)>[];
  final timeout = Duration(seconds: c.i('discovery_timeout_s'));
  try {
    final client = MDnsClient();
    await client.start();
    try {
      final service = c.s('service_type');
      await for (final ptr in client
          .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service))
          .timeout(timeout, onTimeout: (s) => s.close())) {
        if (!ptr.domainName.startsWith('${laptop.id}.')) continue;
        await for (final srv in client
            .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
            .timeout(timeout, onTimeout: (s) => s.close())) {
          await for (final ip in client
              .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))
              .timeout(timeout, onTimeout: (s) => s.close())) {
            out.add((ip.address.address, srv.port));
          }
        }
      }
    } finally {
      client.stop();
    }
  } catch (_) {
    // mDNS unavailable on this network
  }
  if (out.isEmpty) {
    final b = await _beacon(laptop.id, c);
    if (b != null) out.add(b);
  }
  for (final h in laptop.candidates()) {
    if (!out.any((x) => x.$1 == h)) out.add((h, laptop.port));
  }
  return out;
}

Future<(String, int)?> _beacon(String laptopId, SyncConfig c) async {
  RawDatagramSocket? s;
  try {
    s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.send(ascii.encode('SNAPY?1'), InternetAddress(c.s('beacon_group')), c.i('beacon_port'));
    final done = Completer<(String, int)?>();
    final sock = s;
    final sub = sock.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d == null) return;
      try {
        final j = jsonDecode(utf8.decode(d.data)) as Map;
        if (j['t'] == 'snapy' && j['id'] == laptopId && j['port'] is int && !done.isCompleted) {
          done.complete((d.address.address, j['port'] as int));
        }
      } catch (_) {}
    });
    final r = await done.future.timeout(Duration(seconds: c.i('discovery_timeout_s')), onTimeout: () => null);
    await sub.cancel();
    return r;
  } catch (_) {
    return null;
  } finally {
    s?.close();
  }
}

// ------------------------------------------------------------------ high level
/// Pair with the laptop from a scanned QR code; stores the laptop on success.
Future<PairedLaptop> pairWithLaptop(PairingPayload qr, PairingRepository repo,
    {SyncConfig? cfg, DateTime? now}) async {
  if (qr.expired(now ?? DateTime.now())) throw const HandshakeException('This pairing code has expired');
  final me = await repo.identity();
  Object? last;
  for (final host in qr.hosts) {
    try {
      final conn = await connectToLaptop(
          host: host, port: qr.port, me: me, laptopPublicKey: qr.publicKey, laptopId: qr.deviceId,
          pairingSecret: qr.secret, cfg: cfg);
      await conn.send({'type': 'bye'});
      await conn.close();
      final laptop = PairedLaptop(qr.deviceId, qr.name, qr.publicKey, qr.hosts, qr.port, host);
      await repo.saveLaptop(laptop);
      return laptop;
    } catch (e) {
      last = e;
    }
  }
  throw last ?? const SocketException('No laptop address in the code');
}

/// Find the laptop and open a session (try each discovered address in turn).
Future<SyncConnection> connectPaired(PairedLaptop laptop, PairingRepository repo, {SyncConfig? cfg}) async {
  final me = await repo.identity();
  Object? last;
  for (final (host, port) in await discoverLaptop(laptop, cfg: cfg)) {
    try {
      final conn = await connectToLaptop(
          host: host, port: port, me: me, laptopPublicKey: laptop.publicKey, laptopId: laptop.id, cfg: cfg);
      if (laptop.lastHost != host || laptop.port != port) {
        laptop
          ..lastHost = host
          ..port = port;
        await repo.saveLaptop(laptop);
      }
      return conn;
    } catch (e) {
      last = e;
    }
  }
  throw last ?? const SocketException('Laptop not found on this network');
}
