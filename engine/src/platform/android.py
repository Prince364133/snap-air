"""Snapy's brain on Android.

The same Python that runs the Windows engine runs inside the Android app (via
Chaquopy): the full Assistant — command understanding, Hinglish, "the 4th video",
memory, tasks and reminders, notes, the cloud/local AI brain. Only the "hands" differ.
On Windows they press keys and click; here every side effect becomes an *event* that
Kotlin handles with Android APIs:

  {"type": "op", ...}          phone action (open app, volume, back…)     -> OpExecutor.kt
  {"type": "speak", ...}       say something                              -> Android TextToSpeech
  {"type": "reminders", ...}   upcoming reminders                         -> AlarmManager + notifications
  {"type": "chat_message"|"assistant_state"|"toast"|…}                     -> Flutter UI

Kotlin:  init(dir) · core().send(text, source) · core().next_events(timeout) -> JSON list
"""
import datetime as dt
import difflib
import json
import os
import queue
import threading


def _jsonable(v):
    return isinstance(v, (str, int, float, bool, type(None), list, dict))


class ActionRecorder:
    """Stands in for the desktop OSActions: every PC action becomes a phone op event."""

    def __init__(self, emit):
        self.emit = emit
        self.clip = ""

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)

        def rec(*args, **kwargs):
            self.emit({"type": "op", "op": name, "args": [a for a in args if _jsonable(a)],
                       "kwargs": {k: v for k, v in kwargs.items() if _jsonable(v)}})
        return rec

    # queries the brain makes (answered from phone state, not recorded)
    def find_window(self, name):
        return None                      # phones have apps, not windows: the brain falls back to launching

    def list_windows(self):
        return []

    def clipboard(self):
        return self.clip

    def launch(self, apps, target):
        self.emit({"type": "op", "op": "launch_app", "args": [target], "kwargs": {}})

    def open_url(self, url, *args, **kwargs):
        """Links to services that have an app open in the app (WhatsApp Web -> WhatsApp)."""
        from urllib.parse import urlparse
        from src import appdata
        host = (urlparse(url).hostname or "").lower()
        links = appdata.get("android.app_links", {}) or {}
        pkg = links.get(host) or links.get(host[4:] if host.startswith("www.") else host) or links.get(
            ".".join(host.split(".")[-2:]))
        self.emit({"type": "op", "op": "open_url", "args": [url], "kwargs": {"package": pkg} if pkg else {}})


class AndroidApps:
    """Installed apps (label -> package), sent by Kotlin. Same find() contract as the desktop AppIndex."""

    def __init__(self):
        self.apps = {}

    def set(self, items):
        self.apps = {str(i["label"]).lower(): i["package"] for i in items if i.get("label") and i.get("package")}

    def find(self, name):
        q = (name or "").lower().strip()
        if not q or not self.apps:
            return None
        if q in self.apps:
            return q, self.apps[q]
        starts = [k for k in self.apps if k.startswith(q) or q in k.split()]
        if starts:
            k = min(starts, key=len)
            return k, self.apps[k]
        close = difflib.get_close_matches(q, list(self.apps), n=1, cutoff=0.75)
        return (close[0], self.apps[close[0]]) if close else None

    def launch(self, target):
        pass                             # executed by Kotlin via the op event


class AndroidSpeaker:
    """The Assistant's voice: Android TextToSpeech (native Hindi, Tamil, Telugu… voices)."""

    def __init__(self, emit):
        self.emit = emit
        self.busy = False
        self.speaking = False
        self.engine = "android"
        self.last_spoke = 0.0

    def say(self, text, lang="en"):
        if text and text.strip():
            self.emit({"type": "speak", "text": text, "lang": lang or "en"})

    def interrupt(self):
        self.emit({"type": "speak_stop"})

    def wait_done(self, timeout=60):
        return True

    def enabled(self):
        return True


class AndroidMeeting:
    """Meeting notes arrive in a later phase (microphone only on Android — Play forbids call recording)."""
    recording = False
    segments = []

    def start(self, *a, **k):
        return False

    def stop(self, *a, **k):
        return None

    def bookmark(self, *a, **k):
        return None

    def state(self):
        return {"recording": False, "title": None, "elapsed": 0, "live": "", "words": 0, "bookmarks": 0, "error": None}

    def transcript(self):
        return ""


class SnapyCore:
    def __init__(self, data_dir):
        os.environ["SNAP_AIR_DATA"] = data_dir
        os.environ.setdefault("SNAP_AIR_SETTINGS", os.path.join(data_dir, "settings.json"))
        from src.ai.agent_controller import AgentController
        from src.brain.assistant import Assistant
        from src.brain.briefing import Briefing
        from src.brain.cloud import Brain, CloudLLM
        from src.brain.llm import LLM
        from src.brain.memory import MemoryStore
        from src.config import Settings
        from src.life.activity import ActivityTracker
        from src.life.notes import NoteStore
        from src.life.tasks import TaskStore
        from src import storage

        self.events = queue.Queue()
        self.settings = Settings(os.environ["SNAP_AIR_SETTINGS"])
        self.os = ActionRecorder(self.emit)
        self.apps = AndroidApps()
        self.agent = AgentController(settings=self.settings, os_actions=self.os, app_index=self.apps)
        self.agent.on_ui = self.emit
        # AI brain: on-device model when available, else the user's cloud key (same router as Windows)
        self.local = LLM(self.settings)
        self.cloud = CloudLLM(self.settings)
        self.brain = Brain(self.local, self.cloud, self.settings)
        self.memory = MemoryStore(llm=self.brain.for_purpose("memory"), settings=self.settings)
        self.tasks = TaskStore()
        self.notes = NoteStore()
        self.activity = ActivityTracker(settings=self.settings, folder=os.path.join(storage.data_dir(), "activity"))
        self.briefing = Briefing(self.memory, self.tasks, self.notes, self.activity, settings=self.settings, agent=self.agent)
        try:
            from src.web import tools as web
        except Exception:
            web = None
        self.speaker = AndroidSpeaker(self.emit)
        self.assistant = Assistant(self.settings, self.agent, self.memory, self.tasks, self.notes, self.activity,
                                   self.briefing, AndroidMeeting(), self.brain, self.speaker, emit=self._assistant_emit,
                                   web=web)
        self.assistant.screen_available = False   # on-screen clicking arrives with Phase 4 scripts
        self._sync_reminders()

    # ------------------------------------------------------------ events
    def emit(self, event):
        self.events.put(event)

    def _assistant_emit(self, event):
        self.emit(event)
        if event.get("type") in ("chat_message", "tasks") and event.get("final", True):
            self._sync_reminders()

    def next_events(self, timeout=1.0):
        """Block up to `timeout` s for events; returns a JSON list (Kotlin polls this on a thread)."""
        out = []
        try:
            out.append(self.events.get(timeout=float(timeout)))
            while True:
                out.append(self.events.get_nowait())
        except queue.Empty:
            pass
        return json.dumps(out, ensure_ascii=False, default=str)

    def _sync_reminders(self):
        """All upcoming reminders, so Android can schedule real alarms (they fire even if Snapy is closed)."""
        items = []
        for t in self.tasks.open_tasks():
            when = t.get("remind_at")
            if not when or t.get("fired"):
                continue
            try:
                at = dt.datetime.fromisoformat(when)
            except ValueError:
                continue
            items.append({"id": t["id"], "title": t["title"], "at_ms": int(at.timestamp() * 1000)})
        self.emit({"type": "reminders", "items": items})

    # ------------------------------------------------------------ API for Kotlin / Dart
    def set_apps(self, apps_json):
        self.apps.set(json.loads(apps_json))
        return len(self.apps.apps)

    def set_clipboard(self, text):
        self.os.clip = text or ""

    def send(self, text, source="typed"):
        """A user message (typed in the sheet, or spoken in Phase 3). Replies arrive as events."""
        text = (text or "").strip()
        if text:
            self.assistant.handle(text, source)
        return "ok"

    def interrupt(self):
        self.assistant.interrupt()
        return "ok"

    def set_api_key(self, provider, key):
        from src import secrets_store
        secrets_store.set_key(f"cloud_{provider}", key or "")
        self.settings.update({"cloud_provider": provider})
        self.cloud.last_error = None
        return json.dumps(self.brain_status())

    def update_settings(self, changes_json):
        self.settings.update(json.loads(changes_json))
        return "ok"

    def brain_status(self):
        from src.brain.cloud import PROVIDERS
        return {"mode": self.settings.get("ai_provider"), "local_ready": bool(self.local.ready()),
                "cloud_configured": self.cloud.configured(), "provider": self.cloud.provider, "model": self.cloud.model,
                "providers": {k: v["label"] for k, v in PROVIDERS.items()}, "error": self.cloud.last_error}

    def brain_status_json(self):
        return json.dumps(self.brain_status())

    def snapshot(self):
        """Tasks, notes and memories for the app's lists."""
        return json.dumps({
            "tasks": self.tasks.open_tasks(),
            "notes": self.notes.items[-50:],
            "memories": [{"id": m.get("id"), "text": m.get("text"), "category": m.get("category")}
                         for m in self.memory.memories][-100:],
        }, ensure_ascii=False, default=str)

    def complete_task(self, task_id):
        self.tasks.complete(task_id)
        self._sync_reminders()
        return "ok"

    def reminder_fired(self, task_id):
        """Android showed the notification: mark it so it isn't scheduled again."""
        self.tasks.due_reminders()          # marks every reminder whose time has come as fired
        self._sync_reminders()
        return "ok"


_core = None
_lock = threading.Lock()


def init(data_dir, cipher=None):
    """Entry point for Kotlin (Chaquopy). `cipher` = Kotlin object with encrypt(bytes)/decrypt(bytes)."""
    global _core
    with _lock:
        if _core is None:
            if cipher is not None:
                from src import secrets_store
                secrets_store.set_cipher(lambda b: bytes(cipher.encrypt(b)), lambda b: bytes(cipher.decrypt(b)))
            _core = SnapyCore(data_dir)
    return "ok"


def core():
    return _core
