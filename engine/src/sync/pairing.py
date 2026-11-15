"""Device identity, one-time pairing secrets and the pinned-peer list.

Identity: this device's id ("windows-<10 hex>"), display name and long-term X25519 key.
The private key is kept with secrets_store (DPAPI on Windows; a platform cipher elsewhere),
never in plain JSON. Public data lives in <data dir>/sync/identity.json.

Pairing secret: 32 random bytes shown once in the QR code, valid for sync.pairing_ttl_s,
consumed by the first successful pairing, burned after sync.pairing_max_attempts failures.
"""
import os
import socket
import threading
import time
import uuid

from src.sync import conf
from src.sync import crypto as C

KEY_NAME = "sync_static_key"


def _default_key_store():
    from src import secrets_store
    return secrets_store.get_key, secrets_store.set_key


class Identity:
    def __init__(self, device_id, name, private_key):
        self.device_id, self.name = device_id, name
        self._priv = private_key
        self.public_key = C.public_key(private_key)

    @property
    def private_key(self):
        return self._priv

    def __repr__(self):                    # never print the key
        return f"Identity({self.device_id!r})"

    @classmethod
    def load_or_create(cls, path, read, write, key_get=None, key_set=None, platform="windows", name=None):
        if key_get is None or key_set is None:
            key_get, key_set = _default_key_store()
        info = read(path, {}) or {}
        priv = None
        raw = key_get(KEY_NAME)
        if raw:
            try:
                priv = C.unb64u(raw)
            except C.CryptoError:
                priv = None
        if not priv or len(priv) != C.KEY_LEN or C.b64u(C.public_key(priv)) != info.get("pk"):
            priv = C.new_private_key()                 # first run, or the key store was reset
            key_set(KEY_NAME, C.b64u(priv))
            info = {"device_id": info.get("device_id") or f"{platform}-{uuid.uuid4().hex[:10]}",
                    "pk": C.b64u(C.public_key(priv))}
        info["name"] = name or info.get("name") or _hostname()
        write(path, info)
        return cls(info["device_id"], info["name"][:64], priv)


def _hostname():
    try:
        return (socket.gethostname() or "Snapy laptop")[:64]
    except OSError:
        return "Snapy laptop"


def lan_addresses():
    """IPv4 addresses a phone on the same LAN could reach (no packets are sent)."""
    found = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.append(info[4][0])
    except OSError:
        pass
    try:                                            # the interface of the default route
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("10.255.255.255", 1))
            found.append(s.getsockname()[0])
        finally:
            s.close()
    except OSError:
        pass
    out = []
    for a in found:
        if a.startswith("127.") or a.startswith("169.254.") or a == "0.0.0.0" or a in out:
            continue
        out.append(a)
    return out


class PairingManager:
    def __init__(self, clock=time.time, ttl_s=None, max_attempts=None):
        self.clock = clock
        self.ttl_s = conf.get("pairing_ttl_s") if ttl_s is None else ttl_s
        self.max_attempts = conf.get("pairing_max_attempts") if max_attempts is None else max_attempts
        self.lock = threading.Lock()
        self._secret = None
        self._expires = 0.0
        self._failures = 0

    def start(self):
        """A fresh secret (replaces any earlier one). Returns (secret, expires_at epoch s)."""
        with self.lock:
            self._secret = C.random_bytes(32)
            self._expires = self.clock() + float(self.ttl_s)
            self._failures = 0
            return self._secret, self._expires

    def active(self):
        """The secret if it is still usable, else None."""
        with self.lock:
            if self._secret is None:
                return None
            if self.clock() >= self._expires or self._failures >= self.max_attempts:
                self._secret = None
                return None
            return self._secret

    def consume(self, secret):
        """Mark used after a successful pairing; True if it was the live secret."""
        with self.lock:
            ok = self._secret is not None and C.equal(secret, self._secret) and self.clock() < self._expires
            self._secret = None
            return ok

    def failed(self):
        with self.lock:
            self._failures += 1
            if self._failures >= self.max_attempts:
                self._secret = None

    def cancel(self):
        with self.lock:
            self._secret = None

    @property
    def expires_at(self):
        return self._expires if self._secret is not None else 0.0


class PeerStore:
    """Pinned peers: [{id, name, pk, paired_at, last_seen, last_host}] in sync/peers.json."""

    def __init__(self, path, read, write):
        self.path, self._read, self._write = path, read, write
        self.lock = threading.RLock()
        data = read(path, []) or []
        self.items = [p for p in data if isinstance(p, dict) and p.get("id") and p.get("pk")]

    def get(self, peer_id):
        with self.lock:
            return next((dict(p) for p in self.items if p["id"] == peer_id), None)

    def public_key(self, peer_id):
        p = self.get(peer_id)
        return C.unb64u(p["pk"]) if p else None

    def add(self, peer_id, name, pk, now=None):
        with self.lock:
            self.items = [p for p in self.items if p["id"] != peer_id]
            self.items.append({"id": peer_id, "name": name, "pk": C.b64u(pk),
                               "paired_at": int(now or time.time()), "last_seen": None, "last_host": None})
            self._write(self.path, self.items)

    def seen(self, peer_id, host=None, now=None):
        with self.lock:
            for p in self.items:
                if p["id"] == peer_id:
                    p["last_seen"] = int(now or time.time())
                    if host:
                        p["last_host"] = host
            self._write(self.path, self.items)

    def remove(self, peer_id):
        with self.lock:
            before = len(self.items)
            self.items = [p for p in self.items if p["id"] != peer_id]
            self._write(self.path, self.items)
            return len(self.items) != before

    def public_list(self):
        with self.lock:
            return [{k: p.get(k) for k in ("id", "name", "paired_at", "last_seen", "last_host")} for p in self.items]


def data_path(*parts):
    from src import storage
    return storage.path("sync", *parts)


def ensure_dir(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
