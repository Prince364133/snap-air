"""Who may talk to the engine's WebSocket.

The engine listens on localhost, but "localhost" is reachable by every web page the
user opens: a page can do `new WebSocket("ws://localhost:8765")` and, without these
checks, send chat / execute_command. Two independent checks run in the opening
handshake, before any message is read:

1. Origin allow-list. Browsers always send an Origin header with the page's origin
   (https://evil.example), and a page cannot forge it. Only origins listed in
   app.json "server.allowed_origins" are accepted. The Electron HUD is loaded from
   file://, which Chromium reports as "file://" (older versions: "null"). A missing
   Origin means a non-browser client (tests, tools); it still needs the token.
2. Per-launch token. Electron generates a random token, passes it to the engine in
   SNAPY_WS_TOKEN and hands it to the HUD page through the preload bridge; the page
   connects to ws://localhost:<port>/?token=<token>. When nothing passes a token (the
   engine is started on its own, e.g. by `pnpm dev`), the engine makes one and writes
   it to <data dir>/ws_token, which Electron reads. Compared in constant time.
"""
import hmac
import http
import os
import secrets
from urllib.parse import parse_qs, urlsplit

from src import appdata, diag, storage

ENV_VAR = "SNAPY_WS_TOKEN"
DEFAULT_ORIGINS = ["file://", "null"]


def token_file():
    return os.path.join(storage.data_dir(), appdata.get("server.token_file", "ws_token"))


def _write_private(p, text):
    """Write a file only this user can read. On POSIX that's mode 0600; on Windows the
    data folder lives under %APPDATA%, whose ACL already limits it to the user."""
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, p)
    try:
        os.chmod(p, 0o600)
    except OSError as e:
        diag.record("auth.chmod", e, quiet=True)


def load_or_create_token(env=None):
    """The token the engine accepts this launch: SNAPY_WS_TOKEN if Electron passed one,
    otherwise a fresh random one written to the token file for Electron to read."""
    env = os.environ if env is None else env
    given = (env.get(ENV_VAR) or "").strip()
    if given:
        return given
    token = secrets.token_urlsafe(32)
    try:
        _write_private(token_file(), token)
    except OSError as e:
        # the HUD won't be able to connect, but nothing else can either: fail closed
        diag.record("auth.token_file", e)
    return token


def allowed_origins():
    v = appdata.get("server.allowed_origins", DEFAULT_ORIGINS)
    return list(v) if isinstance(v, (list, tuple)) else list(DEFAULT_ORIGINS)


def _token_from_path(path):
    vals = parse_qs(urlsplit(path or "").query).get("token") or [""]
    return vals[0]


def check(path, headers, token, origins=None):
    """None when the handshake may proceed, else (http status, reason).
    `headers` is any mapping with .get(); websockets raises on a duplicated Origin."""
    origins = allowed_origins() if origins is None else origins
    try:
        origin = headers.get("Origin")
    except Exception:                                  # noqa: BLE001 - e.g. MultipleValuesError
        return http.HTTPStatus.FORBIDDEN, "bad origin"
    if origin is not None and origin not in origins:
        return http.HTTPStatus.FORBIDDEN, "origin not allowed"
    given = _token_from_path(path)
    # compare bytes: compare_digest on str requires ASCII, a hostile value might not be
    if not token or not given or not hmac.compare_digest(given.encode("utf-8"), token.encode("utf-8")):
        return http.HTTPStatus.UNAUTHORIZED, "missing or wrong token"
    return None


def process_request(token, origins=None):
    """A websockets `process_request` hook enforcing check()."""
    def hook(connection, request):
        bad = check(request.path, request.headers, token, origins)
        if bad is None:
            return None
        status, reason = bad
        # never log the token or the query string; the origin is fine to log
        try:
            origin = request.headers.get("Origin")
        except Exception:                              # noqa: BLE001
            origin = "?"
        print(f"[HUD] refused a connection ({reason}; origin={origin})")
        return connection.respond(status, reason + "\n")
    return hook
