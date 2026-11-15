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
        # meeting notes: the phone's speech recognizer supplies text (microphone only — Play forbids call audio)
        from src.life.meeting import MeetingRecorder
        from src.life.realcount import RealCount
        self.meeting = MeetingRecorder(transcribe_fn=None, llm=self.brain, notes=self.notes, tasks=self.tasks,
                                       memory=self.memory, on_update=lambda st: self.emit({"type": "meeting", **st}),
                                       on_auto_stop=lambda: self.assistant._finish_meeting("en", False))
        self.meeting.capture_devices = False
        self.realcount = RealCount()
        self.assistant = Assistant(self.settings, self.agent, self.memory, self.tasks, self.notes, self.activity,
                                   self.briefing, self.meeting, self.brain, self.speaker, emit=self._assistant_emit,
                                   web=web)
        self.assistant.screen_available = False   # phone screen taps go through PhoneSkills (accessibility)
        self.contacts = None                       # Kotlin: find(name) -> JSON [{name, number}]
        self.pending = None                        # an action waiting for "yes"
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
        items = json.loads(apps_json)
        self.apps.set(items)
        for i in items:                                  # app names for "how long on Instagram?"
            self.realcount.labels.setdefault(i["package"], i["label"])
        return len(self.apps.apps)

    def set_clipboard(self, text):
        self.os.clip = text or ""

    def send(self, text, source="typed"):
        """A user message (typed or spoken). Phone actions are handled here; everything else
        goes to the shared Assistant. Replies arrive as events."""
        text = (text or "").strip()
        if not text:
            return "ok"
        speak = source == "voice"
        clean = self.agent.strip_wake_original(text) if self.agent.strip_wake_word(text)[0] else text
        answer = self.realcount.answer(clean)            # "how many reels did I watch this week?"
        if answer:
            self.emit({"type": "chat_message", "id": f"rc{len(answer)}{id(answer)}", "role": "assistant",
                       "text": answer, "final": True, "ts": 0})
            if speak:
                self.speaker.say(answer)
            return "ok"
        if self._phone(text, speak):
            return "ok"
        self.assistant.handle(text, source)
        return "ok"

    # ------------------------------------------------------------ phone actions
    def _say(self, text, speak, error=False):
        self.emit({"type": "chat_message", "id": f"p{id(text)}{len(text)}", "role": "assistant", "text": text,
                   "final": True, "error": error, "ts": 0})
        if speak:
            self.speaker.say(text)

    def _op(self, op, **kwargs):
        self.emit({"type": "op", "op": op, "args": [], "kwargs": kwargs})

    def _lookup(self, name):
        if self.contacts is None:
            return None, "Contacts aren't available."
        from src import appdata
        tries = (appdata.get("android.contact_aliases", {}) or {}).get(name.lower(), [name])
        found = []
        for n in tries:                                  # "mom" also finds "Mummy" / "Maa"
            try:
                found = json.loads(str(self.contacts.find(n)))
            except Exception as e:
                return None, f"I couldn't read your contacts ({e})."
            if isinstance(found, dict) and found.get("error") == "permission":
                return None, "Allow Contacts for Snapy (Settings → Permissions), then try again."
            if found:
                break
        if not found:
            return None, f"I couldn't find “{name}” in your contacts."
        return found[0], None

    def _phone(self, text, speak):
        """Returns True if the message was a phone action (or a yes/no to one)."""
        from src.brain import phone_intents as P
        clean = self.agent.strip_wake_original(text) if self.agent.strip_wake_word(text)[0] else text

        if self.pending:
            act, self.pending = self.pending, None
            if P.YES.match(clean.strip()):
                self._run(act, speak)
                return True
            if P.NO.match(clean.strip()):
                self._say("Okay, cancelled.", speak)
                return True
            # anything else: forget the pending action and treat this as a new request

        intent = P.parse(clean)
        if not intent:
            return False
        k = intent["kind"]
        if k in ("whatsapp", "sms", "call"):
            who, err = self._lookup(intent["contact"])
            if err:
                self._say(err, speak, error=True)
                return True
            intent.update(name=who["name"], number=who["number"])
            if k == "call":
                q = f"Call {who['name']}?"
            else:
                q = f"Send to {who['name']}{' on WhatsApp' if k == 'whatsapp' else ''}: “{intent['text']}”?"
            self.pending = intent
            self._say(q + " Say yes to send." if k != "call" else q, speak)
            return True
        self._run(intent, speak)
        return True

    def _run(self, a, speak):
        k = a["kind"]
        if k == "whatsapp":
            self._op("whatsapp_send", number=a["number"], text=a["text"])
            self._say(f"Sending to {a['name']} on WhatsApp.", speak)
        elif k == "sms":
            self._op("sms", number=a["number"], text=a["text"])
            self._say(f"Your message to {a['name']} is ready — tap Send.", speak)
        elif k == "call":
            self._op("call", number=a["number"], video=bool(a.get("video")))
            self._say(f"Calling {a['name']}.", speak)
        elif k == "alarm":
            self._op("alarm", hour=a["hour"], minute=a["minute"], label=a["label"])
            h = a["hour"] % 12 or 12
            self._say(f"Alarm set for {h}:{a['minute']:02d} {'am' if a['hour'] < 12 else 'pm'}.", speak)
        elif k == "timer":
            self._op("timer", seconds=a["seconds"])
            mins = a["seconds"] // 60
            self._say(f"Timer set for {mins} minute{'s' if mins != 1 else ''}." if mins else f"Timer set for {a['seconds']} seconds.", speak)
        elif k == "navigate":
            self._op("navigate", place=a["place"])
            self._say(f"Getting directions to {a['place']}.", speak)
        elif k == "torch":
            self._op("torch", on=a["on"])
            self._say("Torch on." if a["on"] else "Torch off.", speak)
        elif k == "panel":
            self._op("panel", panel=a["panel"])
            self._say(f"Here are your {a['panel'].replace('internet', 'internet').title()} settings.", speak)
        elif k == "type":
            self._op("type_text", text=a["text"])
        elif k == "tap":
            self._op("screen_tap", query=a["target"])

    # ------------------------------------------------------------ Real Count, briefing, meetings
    def update_usage(self, usage_json):
        """Today's screen time from Android's usage stats (Kotlin, about once a minute)."""
        self.realcount.save_usage(json.loads(usage_json))
        return "ok"

    def limits_json(self):
        return json.dumps({"limits": self.settings.get("app_limits") or {}, "break": bool(self.settings.get("break_screen"))})

    def set_limit(self, package, minutes):
        limits = dict(self.settings.get("app_limits") or {})
        if int(minutes) > 0:
            limits[package] = int(minutes)
        else:
            limits.pop(package, None)
        self.settings.update({"app_limits": limits})
        return self.limits_json()

    def weekly_summary(self):
        return self.realcount.weekly_summary()

    def morning_brief(self):
        """The same greeting as Windows, as notification text: {"title", "text"} or {} if already greeted."""
        if not self.briefing.should_greet():
            return "{}"
        b = self.briefing.build(include_weather=False)
        self.briefing.mark_greeted()
        return json.dumps({"title": b.get("title") or "Good morning", "text": " ".join(b.get("lines") or [])[:400]})

    def add_meeting_text(self, text):
        """A transcribed phrase while meeting notes are on (from the phone's recognizer)."""
        return "ok" if self.meeting.add_text("Room", text) else "ignored"     # the phone mic hears everyone

    def find_on_screen(self, query, nodes_json):
        """Kotlin sends the accessibility nodes of the current screen; the same matcher as
        Windows (screen.find: name, type, ordinal, corner) picks one. -> index or -1."""
        from src.os_control import screen
        nodes = json.loads(nodes_json)
        els = [screen.Element(n.get("name", ""), n.get("type", "ButtonControl"), tuple(n["rect"]), i, n.get("depth", 5))
               for i, n in enumerate(nodes)]
        el, why = screen.find(query, els)
        return json.dumps({"index": el.control if el is not None else -1, "why": why})

    def interrupt(self):
        self.assistant.interrupt()
        return "ok"

    # ------------------------------------------------------------ voice
    def sounds_unfinished(self, text):
        """Same pause logic as Windows: "open youtube and…" waits for the rest of the sentence."""
        from src.voice.voice_listener import sounds_unfinished
        return bool(sounds_unfinished(text))

    def voice_config(self):
        """Recognizer locale, wake phrases (follow the assistant's name) and pause timing."""
        from src import appdata
        lang = (self.settings.get("voice_language") or "auto").lower()
        locales = appdata.get("android.speech_locales", {}) or {}
        name = (self.settings.get("agent_name") or "Snapy").strip().lower()
        phrases = list(appdata.get("android.wake_phrases", []) or [])
        if name and name not in ("snapy", "snappy"):
            phrases = [name, f"hey {name}", f"hi {name}", f"okay {name}"] + phrases
        return json.dumps({
            "locale": locales.get(lang, locales.get("auto", "en-IN")),
            "wake_phrases": phrases,
            "continuation_wait_ms": int(float(self.settings.get("continuation_wait_s") or 1.5) * 1000),
            "wake_enabled": bool(self.settings.get("android_wake_word")),
            "wake_model": appdata.get("android.wake_model"),
        })

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
        return {"mode": self.settings.get("ai_provider"), "voice_language": self.settings.get("voice_language") or "auto",
                "local_ready": bool(self.local.ready()),
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


def init(data_dir, cipher=None, contacts=None):
    """Entry point for Kotlin (Chaquopy). `cipher` = object with encrypt(bytes)/decrypt(bytes);
    `contacts` = object with find(name) -> JSON [{name, number}] (or {"error": "permission"})."""
    global _core
    with _lock:
        if _core is None:
            if cipher is not None:
                from src import secrets_store
                secrets_store.set_cipher(lambda b: bytes(cipher.encrypt(b)), lambda b: bytes(cipher.decrypt(b)))
            _core = SnapyCore(data_dir)
            _core.contacts = contacts
    return "ok"


def core():
    return _core
