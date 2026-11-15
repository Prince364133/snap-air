"""Snapy sync wire protocol v1: handshake state machines and the encrypted channel.

Transport: TCP on the LAN. Every frame is  u32_be(length) || body.

Handshake (4 frames, JSON bodies; the client is the phone, the server is the laptop):
  m1 C->S  {"t":"hello","v":1,"mode":"pair"|"session","id","name","e","s","n"}
  m2 S->C  {"t":"hello","v":1,"id","name","e","n"}
      e = fresh ephemeral X25519 public key, s = long-term (static) public key,
      n = 16 random bytes; all binary fields base64url without padding.
  th  = SHA256(PROLOGUE || u32(len m1) || m1 || u32(len m2) || m2)      (exact bytes on the wire)
  ikm = DH(e_c,E_s) || DH(e_c,S_s) || DH(s_c,E_s) || DH(s_c,S_s)          (ee, es, se, ss)
  salt= SHA256(PROLOGUE || " psk" || pairing_secret)  in pair mode
        SHA256(PROLOGUE || " nopsk")                   in session mode
  okm = HKDF-SHA256(ikm, salt, info = PROLOGUE || " keys" || th, 128)
        k_c2s = okm[0:32]  k_s2c = okm[32:64]  mk_c = okm[64:96]  mk_s = okm[96:128]
  m3 S->C  {"t":"confirm","mac": HMAC(mk_s, "server" || th)}
  m4 C->S  {"t":"confirm","mac": HMAC(mk_c, "client" || th)}
Pair mode: the client learned S_s and the one-time secret from the QR code; the secret
authenticates the client's new static key. Session mode: both static keys are already
pinned, so es/se/ss authenticate both sides; ee gives forward secrecy.

After the handshake every frame body is
  ctr(u64_be) || ChaCha20-Poly1305(key_dir, nonce = 0x00000000 || ctr, plaintext, aad = PROLOGUE || ctr)
with one counter per direction starting at 0; a frame whose counter is not exactly the
next expected one is rejected (replay / reorder / drop), and the session is closed.
The plaintext is a UTF-8 JSON object (see session.py for the message types).
"""
import json
import struct

from src.sync import crypto as C

PROLOGUE = b"snapy-sync/1"
VERSION = 1
NONCE_LEN = 16
MODES = ("pair", "session")
MAX_ID = 128
MAX_NAME = 64


class HandshakeError(Exception):
    """The peer failed to authenticate or sent a malformed handshake (no secrets in the message)."""


class ReplayError(C.CryptoError):
    """A frame arrived with an unexpected counter."""


def encode_json(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True, ensure_ascii=False).encode("utf-8")


def decode_json(data: bytes) -> dict:
    try:
        obj = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise HandshakeError("malformed message") from e
    if not isinstance(obj, dict):
        raise HandshakeError("malformed message")
    return obj


def frame(body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + body


def transcript_hash(m1: bytes, m2: bytes) -> bytes:
    return C.sha256(PROLOGUE + struct.pack(">I", len(m1)) + m1 + struct.pack(">I", len(m2)) + m2)


def salt_for(psk):
    return C.sha256(PROLOGUE + b" psk" + psk) if psk is not None else C.sha256(PROLOGUE + b" nopsk")


def derive(ee, es, se, ss, psk, th):
    okm = C.hkdf(ee + es + se + ss, salt_for(psk), PROLOGUE + b" keys" + th, 128)
    return {"c2s": okm[0:32], "s2c": okm[32:64], "mk_c": okm[64:96], "mk_s": okm[96:128]}


def confirm_mac(mk, role: bytes, th):
    return C.hmac_sha256(mk, role + th)


def _key(obj, name):
    try:
        v = C.unb64u(obj.get(name))
    except C.CryptoError as e:
        raise HandshakeError("bad field " + name) from e
    if len(v) != C.KEY_LEN:
        raise HandshakeError("bad field " + name)
    return v


def _nonce(obj):
    try:
        v = C.unb64u(obj.get("n"))
    except C.CryptoError as e:
        raise HandshakeError("bad nonce") from e
    if len(v) != NONCE_LEN:
        raise HandshakeError("bad nonce")
    return v


def _text(obj, name, limit):
    v = obj.get(name)
    if not isinstance(v, str) or not v or len(v) > limit:
        raise HandshakeError("bad field " + name)
    return v


def _check_hello(obj):
    if obj.get("t") != "hello" or obj.get("v") != VERSION:
        raise HandshakeError("unsupported hello")


class Channel:
    """Encrypted, replay-protected frame codec for one direction pair."""

    def __init__(self, send_key: bytes, recv_key: bytes):
        self._send_key, self._recv_key = send_key, recv_key
        self.send_ctr = 0
        self.recv_ctr = 0

    @staticmethod
    def _nonce(ctr):
        return b"\x00\x00\x00\x00" + struct.pack(">Q", ctr)

    def seal(self, plaintext: bytes) -> bytes:
        ctr = struct.pack(">Q", self.send_ctr)
        body = ctr + C.seal(self._send_key, self._nonce(self.send_ctr), plaintext, PROLOGUE + ctr)
        self.send_ctr += 1
        return body

    def open(self, body: bytes) -> bytes:
        if len(body) < 8 + C.TAG_LEN:
            raise C.CryptoError("short frame")
        ctr = struct.unpack(">Q", body[:8])[0]
        if ctr != self.recv_ctr:
            raise ReplayError("unexpected frame counter")
        plain = C.open_(self._recv_key, self._nonce(ctr), body[8:], PROLOGUE + body[:8])
        self.recv_ctr += 1
        return plain

    def send_json(self, obj) -> bytes:
        return self.seal(encode_json(obj))

    def open_json(self, body: bytes) -> dict:
        return decode_json(self.open(body))


class ClientHandshake:
    """Phone side (also used by tests and laptop-to-laptop)."""

    def __init__(self, static_priv, device_id, name, server_static_pub, mode="session", psk=None,
                 expect_server_id=None, eph_priv=None, nonce=None):
        if mode not in MODES or (mode == "pair") != (psk is not None):
            raise ValueError("pair mode needs the pairing secret; session mode must not have one")
        self.s = static_priv
        self.e = eph_priv or C.new_private_key()
        self.n = nonce or C.random_bytes(NONCE_LEN)
        self.id, self.name, self.mode, self.psk = device_id, name, mode, psk
        self.S_s = server_static_pub
        self.expect_server_id = expect_server_id
        self.m1 = None
        self.th = self.keys = None
        self.server_id = self.server_name = None
        self._server_ok = False

    def message1(self) -> bytes:
        self.m1 = encode_json({"t": "hello", "v": VERSION, "mode": self.mode, "id": self.id, "name": self.name,
                               "e": C.b64u(C.public_key(self.e)), "s": C.b64u(C.public_key(self.s)),
                               "n": C.b64u(self.n)})
        return self.m1

    def read_message2(self, m2: bytes):
        obj = decode_json(m2)
        _check_hello(obj)
        self.server_id = _text(obj, "id", MAX_ID)
        self.server_name = _text(obj, "name", MAX_NAME)
        if self.expect_server_id is not None and not C.equal(self.server_id.encode(), self.expect_server_id.encode()):
            raise HandshakeError("unexpected server")
        E_s = _key(obj, "e")
        _nonce(obj)
        self.th = transcript_hash(self.m1, m2)
        try:
            self.keys = derive(C.dh(self.e, E_s), C.dh(self.e, self.S_s), C.dh(self.s, E_s), C.dh(self.s, self.S_s),
                               self.psk, self.th)
        except C.CryptoError as e:
            raise HandshakeError("key agreement failed") from e

    def read_confirm(self, m3: bytes):
        obj = decode_json(m3)
        try:
            mac = C.unb64u(obj.get("mac")) if obj.get("t") == "confirm" else b""
        except C.CryptoError:
            mac = b""
        if not C.equal(mac, confirm_mac(self.keys["mk_s"], b"server", self.th)):
            raise HandshakeError("server failed to authenticate")
        self._server_ok = True

    def message4(self) -> bytes:
        if not self._server_ok:
            raise HandshakeError("server not authenticated yet")
        return encode_json({"t": "confirm", "mac": C.b64u(confirm_mac(self.keys["mk_c"], b"client", self.th))})

    def channel(self) -> Channel:
        return Channel(self.keys["c2s"], self.keys["s2c"])


class ServerHandshake:
    """Laptop side.

    resolve(mode, client_id, client_static_pub) -> psk bytes (pair mode) or None (session
    mode, after checking that client_static_pub is the pinned key for client_id); it raises
    HandshakeError to refuse the client.
    """

    def __init__(self, static_priv, device_id, name, resolve, eph_priv=None, nonce=None):
        self.s = static_priv
        self.e = eph_priv or C.new_private_key()
        self.n = nonce or C.random_bytes(NONCE_LEN)
        self.id, self.name, self.resolve = device_id, name, resolve
        self.mode = self.client_id = self.client_name = self.client_static = None
        self.th = self.keys = None
        self.done = False

    def read_message1(self, m1: bytes) -> bytes:
        obj = decode_json(m1)
        _check_hello(obj)
        mode = obj.get("mode")
        if mode not in MODES:
            raise HandshakeError("bad mode")
        self.mode = mode
        self.client_id = _text(obj, "id", MAX_ID)
        self.client_name = _text(obj, "name", MAX_NAME)
        E_c = _key(obj, "e")
        self.client_static = _key(obj, "s")
        _nonce(obj)
        psk = self.resolve(mode, self.client_id, self.client_static)
        if (mode == "pair") != (psk is not None):
            raise HandshakeError("refused")
        m2 = encode_json({"t": "hello", "v": VERSION, "id": self.id, "name": self.name,
                          "e": C.b64u(C.public_key(self.e)), "n": C.b64u(self.n)})
        self.th = transcript_hash(m1, m2)
        try:
            self.keys = derive(C.dh(self.e, E_c), C.dh(self.s, E_c), C.dh(self.e, self.client_static),
                               C.dh(self.s, self.client_static), psk, self.th)
        except C.CryptoError as e:
            raise HandshakeError("key agreement failed") from e
        return m2

    def message3(self) -> bytes:
        return encode_json({"t": "confirm", "mac": C.b64u(confirm_mac(self.keys["mk_s"], b"server", self.th))})

    def read_message4(self, m4: bytes):
        obj = decode_json(m4)
        try:
            mac = C.unb64u(obj.get("mac")) if obj.get("t") == "confirm" else b""
        except C.CryptoError:
            mac = b""
        if not C.equal(mac, confirm_mac(self.keys["mk_c"], b"client", self.th)):
            raise HandshakeError("client failed to authenticate")
        self.done = True

    def channel(self) -> Channel:
        if not self.done:
            raise HandshakeError("handshake not finished")
        return Channel(self.keys["s2c"], self.keys["c2s"])
