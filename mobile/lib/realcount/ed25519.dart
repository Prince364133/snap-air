/// Ed25519 signature verification (RFC 8032, §5.1.7), verify-only, pure Dart.
/// Used for the weekly signed rules file; speed doesn't matter (one check a week).
/// Tested against the RFC 8032 test vectors in test/signed_rules_test.dart.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha512;

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _q = (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;
final BigInt _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);

BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);

class _Pt {
  final BigInt x, y, z, t;
  const _Pt(this.x, this.y, this.z, this.t);
}

final _Pt _zero = _Pt(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

final _Pt _base = () {
  final y = (BigInt.from(4) * _inv(BigInt.from(5))) % _p;
  final x = _recoverX(y, 0)!;
  return _Pt(x, y, BigInt.one, (x * y) % _p);
}();

_Pt _add(_Pt a, _Pt b) {
  final aa = ((a.y - a.x) * (b.y - b.x)) % _p;
  final bb = ((a.y + a.x) * (b.y + b.x)) % _p;
  final c = (BigInt.two * a.t * b.t * _d) % _p;
  final dd = (BigInt.two * a.z * b.z) % _p;
  final e = bb - aa, f = dd - c, g = dd + c, h = bb + aa;
  return _Pt((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Pt _mul(BigInt s, _Pt p) {
  var q = _zero;
  var pp = p;
  while (s > BigInt.zero) {
    if (s.isOdd) q = _add(q, pp);
    pp = _add(pp, pp);
    s = s >> 1;
  }
  return q;
}

bool _equal(_Pt a, _Pt b) =>
    (a.x * b.z - b.x * a.z) % _p == BigInt.zero && (a.y * b.z - b.y * a.z) % _p == BigInt.zero;

BigInt? _recoverX(BigInt y, int sign) {
  if (y >= _p) return null;
  final x2 = ((y * y - BigInt.one) * _inv(_d * y * y + BigInt.one)) % _p;
  if (x2 == BigInt.zero) return sign == 1 ? null : BigInt.zero;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return x;
}

BigInt _le(List<int> b) {
  var r = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

_Pt? _decompress(List<int> s) {
  if (s.length != 32) return null;
  var y = _le(s);
  final sign = (y >> 255).toInt() & 1;
  y = y & ((BigInt.one << 255) - BigInt.one);
  final x = _recoverX(y, sign);
  if (x == null) return null;
  return _Pt(x, y, BigInt.one, (x * y) % _p);
}

/// true only for a valid signature of [message] by [publicKey] (32 bytes; signature 64 bytes).
bool ed25519Verify(List<int> publicKey, List<int> message, List<int> signature) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final a = _decompress(publicKey);
  if (a == null) return false;
  final rBytes = signature.sublist(0, 32);
  final r = _decompress(rBytes);
  if (r == null) return false;
  final s = _le(signature.sublist(32));
  if (s >= _q) return false;
  final h = _le(sha512.convert(Uint8List.fromList([...rBytes, ...publicKey, ...message])).bytes) % _q;
  return _equal(_mul(s, _base), _add(r, _mul(h, a)));
}
