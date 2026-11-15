"""Crypto primitives for Snapy sync (thin wrappers over the `cryptography` package).

X25519 key agreement, HKDF-SHA256, HMAC-SHA256, ChaCha20-Poly1305 (IETF, 12-byte nonce).
Nothing here logs or returns key material except to the caller.
"""
import base64
import hashlib
import hmac
import os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

KEY_LEN = 32
TAG_LEN = 16


class CryptoError(Exception):
    """Authentication or key-agreement failure. Carries no secret material."""


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def unb64u(text: str) -> bytes:
    if not isinstance(text, str):
        raise CryptoError("expected base64url text")
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except (ValueError, TypeError) as e:
        raise CryptoError("bad base64url") from e


def random_bytes(n: int) -> bytes:
    return os.urandom(n)


def new_private_key() -> bytes:
    return X25519PrivateKey.generate().private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())


def public_key(private: bytes) -> bytes:
    return X25519PrivateKey.from_private_bytes(private).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def dh(private: bytes, peer_public: bytes) -> bytes:
    if len(peer_public) != KEY_LEN:
        raise CryptoError("bad public key length")
    try:
        shared = X25519PrivateKey.from_private_bytes(private).exchange(X25519PublicKey.from_public_bytes(peer_public))
    except ValueError as e:                 # all-zero output: low-order point
        raise CryptoError("invalid public key") from e
    if hmac.compare_digest(shared, bytes(KEY_LEN)):
        raise CryptoError("invalid public key")
    return shared


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def equal(a: bytes, b: bytes) -> bool:
    """Constant-time comparison."""
    return hmac.compare_digest(a, b)


def seal(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes) -> bytes:
    return ChaCha20Poly1305(key).encrypt(nonce, plaintext, aad)


def open_(key: bytes, nonce: bytes, ciphertext: bytes, aad: bytes) -> bytes:
    try:
        return ChaCha20Poly1305(key).decrypt(nonce, ciphertext, aad)
    except Exception as e:                  # InvalidTag
        raise CryptoError("frame authentication failed") from e
