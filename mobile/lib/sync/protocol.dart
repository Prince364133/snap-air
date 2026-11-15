/// Snapy sync wire protocol v1 (client side), a port of engine/src/sync/protocol.py.
/// See that file for the full specification; vectors in core/conformance/sync/.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final prologue = utf8.encode('snapy-sync/1');
const protocolVersion = 1;
const nonceLen = 16;
const keyLen = 32;
const tagLen = 16;

class HandshakeException implements Exception {
  final String message;
  const HandshakeException(this.message);
  @override
  String toString() => 'HandshakeException: $message';
}

class FrameException implements Exception {
  final String message;
  const FrameException(this.message);
  @override
  String toString() => 'FrameException: $message';
}

// ------------------------------------------------------------------ encoding helpers
String b64u(List<int> data) => base64Url.encode(data).replaceAll('=', '');

Uint8List unb64u(Object? text) {
  if (text is! String) throw const HandshakeException('expected base64url');
  try {
    return base64Url.decode(text.padRight(text.length + (4 - text.length % 4) % 4, '='));
  } on FormatException {
    throw const HandshakeException('bad base64url');
  }
}

Uint8List hexToBytes(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

String bytesToHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List u32(int n) => (ByteData(4)..setUint32(0, n)).buffer.asUint8List();
Uint8List u64(int n) => (ByteData(8)..setUint64(0, n)).buffer.asUint8List();

/// Canonical JSON like Python's json.dumps(sort_keys=True, separators=(",",":"), ensure_ascii=False).
Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return v.map(_sorted).toList();
  return v;
}

Uint8List encodeJson(Object? obj) => Uint8List.fromList(utf8.encode(jsonEncode(_sorted(obj))));

Map<String, dynamic> decodeJson(List<int> data) {
  try {
    final v = jsonDecode(utf8.decode(data));
    if (v is Map<String, dynamic>) return v;
  } on FormatException {
    // fall through
  }
  throw const HandshakeException('malformed message');
}

/// Length-prefixed frame.
Uint8List frame(List<int> body) => Uint8List.fromList([...u32(body.length), ...body]);

/// Constant-time equality.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

// ------------------------------------------------------------------ primitives
final _x25519 = X25519();
final _hmac = Hmac.sha256();
final _aead = Chacha20.poly1305Aead();

Future<Uint8List> publicKeyOf(List<int> privateKey) async {
  final kp = await _x25519.newKeyPairFromSeed(privateKey);
  return Uint8List.fromList((await kp.extractPublicKey()).bytes);
}

Future<Uint8List> dh(List<int> privateKey, List<int> peerPublic) async {
  if (peerPublic.length != keyLen) throw const HandshakeException('bad public key length');
  final kp = await _x25519.newKeyPairFromSeed(privateKey);
  final shared = await _x25519.sharedSecretKey(
      keyPair: kp, remotePublicKey: SimplePublicKey(peerPublic, type: KeyPairType.x25519));
  final out = Uint8List.fromList(await shared.extractBytes());
  if (constantTimeEquals(out, Uint8List(keyLen))) throw const HandshakeException('invalid public key');
  return out;
}

Future<Uint8List> sha256(List<int> data) async => Uint8List.fromList((await Sha256().hash(data)).bytes);

Future<Uint8List> hmacSha256(List<int> key, List<int> data) async =>
    Uint8List.fromList((await _hmac.calculateMac(data, secretKey: SecretKey(key))).bytes);

Future<Uint8List> hkdf(List<int> ikm, List<int> salt, List<int> info, int length) async {
  final k = await Hkdf(hmac: Hmac.sha256(), outputLength: length)
      .deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);
  return Uint8List.fromList(await k.extractBytes());
}

Future<Uint8List> newPrivateKey() async => randomBytes(32);

// ------------------------------------------------------------------ handshake math
Future<Uint8List> transcriptHash(List<int> m1, List<int> m2) =>
    sha256([...prologue, ...u32(m1.length), ...m1, ...u32(m2.length), ...m2]);

Future<Uint8List> saltFor(List<int>? psk) => psk != null
    ? sha256([...prologue, ...utf8.encode(' psk'), ...psk])
    : sha256([...prologue, ...utf8.encode(' nopsk')]);

class SessionKeys {
  final Uint8List c2s, s2c, mkC, mkS;
  SessionKeys(this.c2s, this.s2c, this.mkC, this.mkS);
  Map<String, String> toHex() => {'c2s': bytesToHex(c2s), 's2c': bytesToHex(s2c), 'mk_c': bytesToHex(mkC), 'mk_s': bytesToHex(mkS)};
}

Future<SessionKeys> deriveKeys(List<int> ee, List<int> es, List<int> se, List<int> ss, List<int>? psk, List<int> th) async {
  final okm = await hkdf([...ee, ...es, ...se, ...ss], await saltFor(psk), [...prologue, ...utf8.encode(' keys'), ...th], 128);
  return SessionKeys(okm.sublist(0, 32), okm.sublist(32, 64), okm.sublist(64, 96), okm.sublist(96, 128));
}

Future<Uint8List> confirmMac(List<int> mk, String role, List<int> th) => hmacSha256(mk, [...utf8.encode(role), ...th]);

// ------------------------------------------------------------------ channel
/// Encrypted, replay-protected frame codec (one counter per direction, strictly sequential).
class Channel {
  final SecretKey _send, _recv;
  int sendCtr = 0;
  int recvCtr = 0;

  Channel(List<int> sendKey, List<int> recvKey)
      : _send = SecretKey(sendKey),
        _recv = SecretKey(recvKey);

  static List<int> _nonce(List<int> ctr) => [0, 0, 0, 0, ...ctr];

  Future<Uint8List> seal(List<int> plaintext) async {
    final ctr = u64(sendCtr);
    final box = await _aead.encrypt(plaintext, secretKey: _send, nonce: _nonce(ctr), aad: [...prologue, ...ctr]);
    sendCtr++;
    return Uint8List.fromList([...ctr, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> open(List<int> body) async {
    if (body.length < 8 + tagLen) throw const FrameException('short frame');
    final ctrBytes = body.sublist(0, 8);
    final ctr = ByteData.sublistView(Uint8List.fromList(ctrBytes)).getUint64(0);
    if (ctr != recvCtr) throw const FrameException('unexpected frame counter');
    final ct = body.sublist(8, body.length - tagLen);
    final tag = body.sublist(body.length - tagLen);
    try {
      final plain = await _aead.decrypt(SecretBox(ct, nonce: _nonce(ctrBytes), mac: Mac(tag)),
          secretKey: _recv, aad: [...prologue, ...ctrBytes]);
      recvCtr++;
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const FrameException('frame authentication failed');
    }
  }

  Future<Uint8List> sendJson(Object obj) => seal(encodeJson(obj));
  Future<Map<String, dynamic>> openJson(List<int> body) async => decodeJson(await open(body));
}

// ------------------------------------------------------------------ client handshake
Uint8List _key(Map<String, dynamic> o, String name) {
  final v = unb64u(o[name]);
  if (v.length != keyLen) throw HandshakeException('bad field $name');
  return v;
}

String _text(Map<String, dynamic> o, String name, int limit) {
  final v = o[name];
  if (v is! String || v.isEmpty || v.length > limit) throw HandshakeException('bad field $name');
  return v;
}

/// Phone side. message1 -> readMessage2 -> readConfirm -> message4 -> channel().
class ClientHandshake {
  final List<int> staticPriv, ephPriv, nonce, serverStaticPub;
  final String deviceId, name, mode;
  final List<int>? psk;
  final String? expectServerId;
  Uint8List? m1, th;
  SessionKeys? keys;
  String? serverId, serverName;
  bool _serverOk = false;

  ClientHandshake({
    required this.staticPriv,
    required this.deviceId,
    required this.name,
    required this.serverStaticPub,
    this.mode = 'session',
    this.psk,
    this.expectServerId,
    required this.ephPriv,
    required this.nonce,
  }) {
    if ((mode == 'pair') != (psk != null) || !(mode == 'pair' || mode == 'session')) {
      throw ArgumentError('pair mode needs the pairing secret; session mode must not have one');
    }
  }

  static Future<ClientHandshake> create({
    required List<int> staticPriv,
    required String deviceId,
    required String name,
    required List<int> serverStaticPub,
    String mode = 'session',
    List<int>? psk,
    String? expectServerId,
  }) async =>
      ClientHandshake(
          staticPriv: staticPriv,
          deviceId: deviceId,
          name: name,
          serverStaticPub: serverStaticPub,
          mode: mode,
          psk: psk,
          expectServerId: expectServerId,
          ephPriv: await newPrivateKey(),
          nonce: randomBytes(nonceLen));

  Future<Uint8List> message1() async {
    m1 = encodeJson({
      't': 'hello',
      'v': protocolVersion,
      'mode': mode,
      'id': deviceId,
      'name': name,
      'e': b64u(await publicKeyOf(ephPriv)),
      's': b64u(await publicKeyOf(staticPriv)),
      'n': b64u(nonce),
    });
    return m1!;
  }

  Future<void> readMessage2(List<int> m2) async {
    final o = decodeJson(m2);
    if (o['t'] != 'hello' || o['v'] != protocolVersion) throw const HandshakeException('unsupported hello');
    serverId = _text(o, 'id', 128);
    serverName = _text(o, 'name', 64);
    if (expectServerId != null && !constantTimeEquals(utf8.encode(serverId!), utf8.encode(expectServerId!))) {
      throw const HandshakeException('unexpected server');
    }
    final eS = _key(o, 'e');
    if (unb64u(o['n']).length != nonceLen) throw const HandshakeException('bad nonce');
    th = await transcriptHash(m1!, m2);
    keys = await deriveKeys(await dh(ephPriv, eS), await dh(ephPriv, serverStaticPub), await dh(staticPriv, eS),
        await dh(staticPriv, serverStaticPub), psk, th!);
  }

  Future<void> readConfirm(List<int> m3) async {
    final o = decodeJson(m3);
    List<int> mac = const [];
    if (o['t'] == 'confirm') {
      try {
        mac = unb64u(o['mac']);
      } on HandshakeException {
        mac = const [];
      }
    }
    if (!constantTimeEquals(mac, await confirmMac(keys!.mkS, 'server', th!))) {
      throw const HandshakeException('server failed to authenticate');
    }
    _serverOk = true;
  }

  Future<Uint8List> message4() async {
    if (!_serverOk) throw const HandshakeException('server not authenticated yet');
    return encodeJson({'t': 'confirm', 'mac': b64u(await confirmMac(keys!.mkC, 'client', th!))});
  }

  Channel channel() => Channel(keys!.c2s, keys!.s2c);
}
