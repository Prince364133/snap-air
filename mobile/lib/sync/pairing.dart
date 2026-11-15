/// QR pairing payload, this phone's identity and the paired laptop, persisted through a
/// [SecureKeyStore] (Android Keystore-backed in the app).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';
import 'sync_store.dart';

class PairingPayload {
  final String deviceId, name, secretB64, pkB64;
  final List<String> hosts;
  final int port, expiresAt;

  PairingPayload(this.deviceId, this.name, this.hosts, this.port, this.secretB64, this.pkB64, this.expiresAt);

  Uint8List get secret => unb64u(secretB64);
  Uint8List get publicKey => unb64u(pkB64);

  /// Parse the QR text shown by the laptop HUD. Throws [FormatException] if it isn't one.
  static PairingPayload parse(String text) {
    Object? o;
    try {
      o = jsonDecode(text.trim());
    } on FormatException {
      throw const FormatException('Not a Snapy pairing code');
    }
    if (o is! Map || o['t'] != 'snapy-pair' || o['v'] != 1) throw const FormatException('Not a Snapy pairing code');
    final id = o['id'], name = o['name'], port = o['port'], secret = o['secret'], pk = o['pk'], exp = o['exp'];
    final hosts = o['hosts'];
    if (id is! String || id.isEmpty || name is! String || port is! int || port < 1 || port > 65535 ||
        secret is! String || pk is! String || exp is! int || hosts is! List) {
      throw const FormatException('Incomplete pairing code');
    }
    final p = PairingPayload(id, name, [for (final h in hosts) if (h is String && h.isNotEmpty) h], port, secret, pk, exp);
    try {
      if (p.secret.length != 32 || p.publicKey.length != 32) throw const FormatException('Bad pairing keys');
    } on HandshakeException {
      throw const FormatException('Bad pairing keys');
    }
    return p;
  }

  bool expired(DateTime now) => now.millisecondsSinceEpoch ~/ 1000 >= expiresAt;
}

class PairedLaptop {
  final String id, name;
  final Uint8List publicKey;
  List<String> hosts;
  int port;
  String? lastHost;

  PairedLaptop(this.id, this.name, this.publicKey, this.hosts, this.port, [this.lastHost]);

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'pk': b64u(publicKey), 'hosts': hosts, 'port': port, 'last_host': lastHost};

  static PairedLaptop fromJson(Map<String, dynamic> j) => PairedLaptop(j['id'] as String, j['name'] as String,
      unb64u(j['pk']), List<String>.from(j['hosts'] as List? ?? const []), j['port'] as int, j['last_host'] as String?);

  /// Hosts to try, best first: last that worked, then the QR candidates.
  List<String> candidates() => [?lastHost, ...hosts.where((h) => h != lastHost)];
}

class DeviceIdentity {
  final String deviceId, name;
  final Uint8List _priv;
  final Uint8List publicKey;
  DeviceIdentity(this.deviceId, this.name, this._priv, this.publicKey);
  Uint8List get privateKey => _priv;

  @override
  String toString() => 'DeviceIdentity($deviceId)'; // never print the key
}

/// Keys inside the SecureKeyStore.
class SyncKeys {
  static const identity = 'snapy_sync_identity'; // {device_id, name, priv}
  static const laptops = 'snapy_sync_laptops'; // [PairedLaptop]
}

class PairingRepository {
  final SecureKeyStore store;
  PairingRepository(this.store);

  Future<DeviceIdentity> identity({String name = 'Snapy phone'}) async {
    final raw = await store.read(SyncKeys.identity);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final priv = unb64u(j['priv']);
        return DeviceIdentity(j['device_id'] as String, j['name'] as String, priv, await publicKeyOf(priv));
      } catch (_) {
        // corrupted: make a new identity (laptops will need re-pairing)
      }
    }
    final priv = await newPrivateKey();
    final id = 'android-${bytesToHex(randomBytes(5))}';
    await store.write(SyncKeys.identity, jsonEncode({'device_id': id, 'name': name, 'priv': b64u(priv)}));
    return DeviceIdentity(id, name, priv, await publicKeyOf(priv));
  }

  Future<List<PairedLaptop>> laptops() async {
    final raw = await store.read(SyncKeys.laptops);
    if (raw == null) return [];
    try {
      return [for (final j in jsonDecode(raw) as List) PairedLaptop.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveLaptop(PairedLaptop l) async {
    final all = (await laptops()).where((x) => x.id != l.id).toList()..add(l);
    await store.write(SyncKeys.laptops, jsonEncode([for (final x in all) x.toJson()]));
  }

  Future<void> removeLaptop(String id) async {
    final all = (await laptops()).where((x) => x.id != id).toList();
    await store.write(SyncKeys.laptops, jsonEncode([for (final x in all) x.toJson()]));
  }
}
