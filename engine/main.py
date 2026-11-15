"""Snapy engine.

camera -> gestures -> mouse            (optional, off until enabled)
microphone -> voice -> assistant       (commands, personal intents, local LLM)
activity tracker / scheduler           (routine learning, reminders, greeting, nudges)
WebSocket ws://localhost:8765          (the Electron HUD)
"""
import asyncio
import datetime as dt
import json
import os
import re
import shutil
import sys
import threading
import time

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)   # engine.log updates live
    except Exception:
        pass


def _probe(stage):
    """Diagnostics: SNAPY_PROBE=1 checks the microphone after each startup stage."""
    if not os.environ.get("SNAPY_PROBE"):
        return
    try:
        import sounddevice as _sd
        _sd.rec(1600, samplerate=16000, channels=1, dtype="float32")
        _sd.wait()
        print(f"[Probe] mic OK after {stage}", flush=True)
    except Exception as _e:
        print(f"[Probe] mic FAIL after {stage}: {_e}", flush=True)


_probe("stdlib")
import cv2
_probe("cv2")
import websockets

from src import storage
from src.config import Settings
from src.ai.agent_controller import AgentController
_probe("agent (pyautogui)")
from src.brain.assistant import Assistant
from src.brain.briefing import Briefing
from src.brain.llm import LLM, compatibility, is_compatible
from src.brain.cloud import Brain, CloudLLM, PROVIDERS
from src import secrets_store
from src.brain.memory import MemoryStore
from src.core.gesture_controller import GestureController
from src.core.gesture_recognizer import GestureRecognizer
from src.life import system_scan
from src.life.activity import ActivityTracker
from src.life.meeting import MeetingRecorder
from src.life.notes import NoteStore
from src.life.tasks import TaskStore, human_time
from src.os_control.mouse_controller import MouseController
_probe("before tts import")
from src.voice.tts import Speaker, ENGLISH_VOICES
from src.voice.voice_listener import VoiceListener
from src.web import tools as webtools
_probe("all imports")

PREVIEW_TITLE = "Snapy - Camera"
PORT = int(os.environ.get("SNAP_AIR_PORT", "8765"))

settings = Settings()
clients = set()
ws_loop = None

state = {
    "gesture": "NONE", "fps": 0, "cursor": [0, 0], "dragging": False, "gestures_paused": False,
    "hand_visible": False, "camera": "off", "voice_status": "Loading speech model…",
    "voice_mode": settings["voice_mode"], "voice_armed": False, "mic_level": 0.0,
    "assistant": "idle", "speak_level": 0.0, "in_call": None, "recording": False,
    "brain": "none",
}


# ----------------------------------------------------------------- messaging
def send_all(payload):
    if ws_loop and clients:
        msg = json.dumps(payload, default=str)
        for c in list(clients):
            asyncio.run_coroutine_threadsafe(_safe_send(c, msg), ws_loop)


async def _safe_send(c, msg):
    try:
        await c.send(msg)
    except Exception:
        pass


def toast(message, ok=True, source=""):
    if message:
        print(f"[{source or 'Snapy'}] {message}")
        send_all({"type": "toast", "message": message, "ok": ok, "source": source})


# -------------------------------------------------------------- components
llm = LLM(settings)                    # local model (Ollama)
cloud = CloudLLM(settings)             # optional cloud model (user's API key)
brain = Brain(llm, cloud, settings)    # routes each request: local / cloud / auto
memory = MemoryStore(llm=brain.for_purpose("memory"), settings=settings)
tasks = TaskStore()
notes = NoteStore()
agent = AgentController(settings=settings)
state["brain"] = "cloud" if brain.is_cloud else ("local" if llm.ready() else "none")


def whisper_model_name():
    lang = settings["voice_language"]
    q = settings["speech_quality"]
    if lang == "en":
        return {"fast": "tiny.en", "balanced": "tiny.en", "accurate": "small.en"}.get(q, "tiny.en")
    return {"fast": "tiny", "balanced": "base", "accurate": "small"}.get(q, "base")


voice = VoiceListener(model_name=whisper_model_name(), sensitivity=settings["mic_sensitivity"],
                      language=settings["voice_language"])
time.sleep(4) if os.environ.get("SNAPY_PROBE") else None
_probe("whisper loading")


def _on_speak_level(level):
    state["speak_level"] = round(level, 4)


def _on_speaking(on):
    state["assistant"] = "speaking" if on else ("thinking" if assistant.working else "idle")


def _on_caption(text):
    send_all({"type": "caption", "text": text})


speaker = Speaker(settings, on_level=_on_speak_level, on_state=_on_speaking, on_caption=_on_caption)
from src.os_control.vision import Vision, ocr_available  # noqa: E402
vision = Vision(settings, cloud)          # OCR / local / cloud screen vision (fallback after UI Automation)
time.sleep(4) if os.environ.get("SNAPY_PROBE") else None
_probe("Kokoro loaded")
# Full duplex: the mic stays open while Snapy talks. An echo guard raises the bar for
# "the user is speaking" by what the speakers are playing; talking over Snapy stops it.
voice.talking_fn = lambda: speaker.speaking or time.time() - speaker.last_spoke < 0.3
voice.echo_level_fn = lambda: state.get("speak_level", 0.0)
voice.headphones_fn = lambda: bool(settings["headphones"])
voice.suppress_fn = lambda: (not settings["barge_in"]) and (speaker.speaking or time.time() - speaker.last_spoke < 0.4)


def _on_barge_in():
    speaker.interrupt()
    assistant.interrupt()
    state["voice_status"] = "Listening…"
    send_all({"type": "barge_in"})


voice.on_barge_in = _on_barge_in


def _transcribe_meeting(audio):
    if voice.model is None:
        return ""
    segs, _ = voice.model.transcribe(audio, language=voice.language, beam_size=1, temperature=0.0,
                                     without_timestamps=True, condition_on_previous_text=False, vad_filter=True)
    return " ".join(s.text.strip() for s in segs).strip()


def _on_meeting(st):
    state["recording"] = st["recording"]
    send_all({"type": "meeting", **st})


meeting = MeetingRecorder(transcribe_fn=_transcribe_meeting, llm=brain, notes=notes, tasks=tasks, memory=memory,
                          on_update=_on_meeting,
                          on_auto_stop=lambda: assistant._finish_meeting("en", False))   # 20 min of silence

session_started = threading.Event()


def _on_session_start(now, gap):
    session_started.gap = gap
    session_started.set()


def _on_break_due(minutes):
    send_all({"type": "banner", "kind": "break", "title": "Time for a short break?",
              "text": f"You've been at it for {minutes} minutes. Stand up, stretch, rest your eyes."})


_last_call_offer = {"app": None, "t": 0}


def _on_call_change(app):
    state["in_call"] = app
    assistant.in_call = app           # stay silent during calls
    if app:
        speaker.interrupt()
    if app and not meeting.recording and (app != _last_call_offer["app"] or time.time() - _last_call_offer["t"] > 1800):
        _last_call_offer.update(app=app, t=time.time())
        send_all({"type": "banner", "kind": "call", "title": f"In a call on {app}?",
                  "text": "Want me to take notes? Let everyone know you're recording.", "app": app})


activity = ActivityTracker(settings=settings, on_session_start=_on_session_start, on_break_due=_on_break_due,
                           on_call_change=_on_call_change)
briefing = Briefing(memory, tasks, notes, activity, settings=settings, weather_fn=webtools.weather, agent=agent)
assistant = Assistant(settings, agent, memory, tasks, notes, activity, briefing, meeting, brain, speaker,
                      emit=lambda p: (_track_assistant(p), send_all(p)), web=webtools)
assistant.on_follow_up = lambda seconds: voice.arm(seconds)
assistant.vision = vision
threading.Thread(target=ocr_available, daemon=True).start()


def _track_assistant(p):
    if p.get("type") == "assistant_state":
        state["assistant"] = "speaking" if speaker.speaking and p["state"] == "idle" else p["state"]


memory.on_change = lambda: send_all({"type": "memory", "profile": memory.profile, "memories": memory.memories})
gestures = None


# ------------------------------------------------------------ agent wiring
def set_gestures_paused(paused):
    state["gestures_paused"] = paused
    if gestures:
        gestures.set_paused(paused)


def on_agent_note(text):
    note = notes.add(text)
    memory.journal_add("note", text)
    send_all({"type": "note_added", "note": note})


def on_ui(action, **data):
    if action == "open_notes":
        action, data = "open_drawer", {"tab": "notes"}
    elif action == "open_guide":
        action, data = "open_drawer", {"tab": "help"}
    send_all({"type": "ui_action", "action": action, **data})


agent.set_callbacks(notes_callback=on_agent_note, ui_callback=on_ui, gesture_callback=set_gestures_paused,
                    voice_callback=lambda mode: settings.update({"voice_mode": mode}))


# ------------------------------------------------------------------- voice
WAKE_PREFIX = re.compile(r"^\W*(?:(?:hey|hi|ok|okay|uh|um)\W+)?(?:snap+(?:y|ie|i|ey)|snap(?:\W*air)?)\W*", re.I)


_mic_banner_sent = [False]


def on_voice_status(s):
    state["voice_status"] = s
    if "blocked" in s and not _mic_banner_sent[0]:
        _mic_banner_sent[0] = True
        send_all({"type": "banner", "kind": "problem", "title": "Snapy can't use your microphone",
                  "text": "Windows privacy settings are blocking it. Turn on microphone access for Snapy, then I'll start listening automatically.",
                  "action": {"label": "Open privacy settings", "type": "open_privacy_mic"}})


def on_transcript(text, armed, lang="en"):
    mode = settings["voice_mode"]
    send_all({"type": "transcript", "text": text, "lang": lang})
    heard_wake, rest = agent.strip_wake_word(text)
    clean = agent.strip_wake_original(text) if heard_wake else text.strip()
    if armed:
        voice.disarm()
        if agent.normalize(clean) in ("", "you", "thank you", "bye"):
            state["voice_status"] = "Ready"
            return
        llm_prewarm()
        assistant.handle(clean, "voice", lang)
    elif heard_wake:
        if not rest:
            voice.arm(6)                       # "Snap" ... (pause) ... "what's on today?"
            llm_prewarm()
            state["voice_status"] = "Listening…"
            return
        llm_prewarm()
        assistant.handle(clean, "voice", lang)
    elif mode == "always":
        r = agent.execute_intent(text)        # commands only; never chats back at overheard speech
        if r.action not in ("ignored", "unknown"):
            toast(r.message, r.ok, "voice")
    state["voice_status"] = "Ready"


voice.set_callbacks(on_transcript=on_transcript, on_status=on_voice_status)


def apply_voice_mode():
    state["voice_mode"] = settings["voice_mode"]
    voice.enabled = settings["voice_mode"] in ("wake", "always")


_prewarm_t = [0.0]


def llm_prewarm():
    """Load the model into RAM when the user starts talking (hides the load time)."""
    if time.time() - _prewarm_t[0] < 120:
        return
    _prewarm_t[0] = time.time()

    def go():
        try:
            if not brain.is_cloud and llm.ready():
                # warm the model AND its prompt cache with the real instructions
                from src.brain.assistant import SYSTEM, ACTION_SCHEMA
                list(llm.stream([{"role": "system", "content": SYSTEM}, {"role": "user", "content": "hi"}],
                                schema=ACTION_SCHEMA, max_tokens=1))
        except Exception:
            pass
    threading.Thread(target=go, daemon=True).start()


# ---------------------------------------------------------------- settings
def on_settings_changed(changed):
    if gestures:
        gestures.apply_settings(settings.as_dict())
    if "voice_mode" in changed:
        apply_voice_mode()
    if "mic_sensitivity" in changed:
        voice.set_sensitivity(changed["mic_sensitivity"])
    if "voice_language" in changed or "speech_quality" in changed:
        voice.set_language(settings["voice_language"])
        voice.set_model(whisper_model_name())
    if "tts_enabled" in changed and not changed["tts_enabled"]:
        speaker.interrupt()
    if "llm_model" in changed and not llm.has_model(changed["llm_model"]):
        if is_compatible(changed["llm_model"])[0]:
            threading.Thread(target=pull_model, args=(changed["llm_model"],), daemon=True).start()
    send_all({"type": "settings", "settings": settings.as_dict()})


settings.on_change(on_settings_changed)


def models_payload():
    st = llm.status()
    st["voices"] = ENGLISH_VOICES
    st["tts_engine"] = speaker.engine
    st["whisper"] = whisper_model_name()
    st["installing_ollama"] = _ollama_install
    try:
        st["native_voices"] = speaker.voice_status()
    except Exception:
        st["native_voices"] = {}
    try:
        st["vision"] = vision.status()
    except Exception:
        st["vision"] = {}
    st["cloud"] = {"provider": cloud.provider, "model": cloud.model, "base_url": cloud.base_url,
                   "configured": cloud.configured(), "key": secrets_store.masked(f"cloud_{cloud.provider}"),
                   "providers": PROVIDERS, "active": brain.is_cloud, "error": cloud.last_error}
    return {"type": "models", **st}


def pull_model(name):
    ok, reason = is_compatible(name)
    if not ok:
        toast(f"Your system isn't compatible with {name}. {reason}", False, "model")
        return False
    llm.ensure_server()
    ok = llm.pull(name, on_progress=lambda p: send_all(models_payload()))
    send_all(models_payload())
    toast(f"{name} is ready" if ok else f"Couldn't download {name}: {llm.last_error}", ok, "model")
    return ok


_ollama_install = {"status": None, "pct": 0}


def install_ollama():
    """Download and silently install Ollama (the free local AI runtime), then the
    recommended model for this PC."""
    import tempfile
    import requests as rq
    if _ollama_install["status"] == "running":
        return
    _ollama_install.update(status="running", pct=0)
    send_all(models_payload())
    try:
        dest = os.path.join(tempfile.gettempdir(), "OllamaSetup.exe")
        with rq.get("https://ollama.com/download/OllamaSetup.exe", stream=True, timeout=(10, 120)) as r:
            r.raise_for_status()
            total = int(r.headers.get("content-length") or 0)
            done = 0
            with open(dest, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
                    done += len(chunk)
                    if total:
                        _ollama_install["pct"] = round(done * 90 / total, 1)
                        send_all(models_payload())
        _ollama_install.update(status="installing", pct=92)
        send_all(models_payload())
        import subprocess as sp
        sp.run([dest, "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES"], timeout=900)
        _ollama_install.update(status="done", pct=100)
        auto_setup_model()
    except Exception as e:
        _ollama_install.update(status="error", pct=0, error=str(e))
        toast(f"Couldn't install the local AI engine: {e}", False, "model")
    send_all(models_payload())


def auto_setup_model():
    """Pick and install the best model this PC can run smoothly — automatically."""
    if settings["ai_provider"] == "cloud" or not llm.ensure_server():
        return
    comp = compatibility()
    installed = llm.installed_models()
    has = lambda n: any(m == n or m == n + ":latest" for m in installed)   # noqa: E731
    current = settings["llm_model"]
    if has(current) and is_compatible(current)[0]:
        return
    rec = comp["recommended"]
    usable = [m["name"] for m in comp["models"] if m["compatible"] and has(m["name"])]
    if has(rec) or usable:
        settings.update({"llm_model": rec if has(rec) else usable[0]})
        return
    settings.update({"llm_model": rec})
    toast(f"Setting up the AI brain for this PC ({rec})…", True, "model")
    pull_model(rec)


# ------------------------------------------------------------------- data
def today_payload():
    return {"type": "today", "tasks": tasks.open_tasks(), "activity": activity.summary(),
            "notes_today": notes.on_day(storage.today()), "meeting": meeting.state()}


def full_hello():
    return {
        "type": "hello", "settings": settings.as_dict(), "profile": memory.profile, "memories": memory.memories,
        "notes": notes.items, "tasks": tasks.open_tasks(), "catalogue": AgentController.catalogue(),
        "activity": activity.summary(), "routine": memory.profile.get("routine", {}),
        "meeting": meeting.state(), "onboarding_needed": not memory.profile.get("onboarded"),
        "focus": assistant.focus.state(), "contexts": assistant.contexts.items,
        "autostarted": "--autostart" in sys.argv or os.environ.get("SNAP_AIR_AUTOSTART") == "1",
        "data_dir": storage.data_dir(), **{k: v for k, v in models_payload().items() if k != "type"},
    }


def delete_all_data():
    memory.forget_all()
    for t in list(tasks.items):
        tasks.delete(t["id"])
    for n in list(notes.items):
        notes.delete(n["id"])
    for sub in ("activity", os.path.join("memory", "journal"), os.path.join("memory", "conversations")):
        p = os.path.join(storage.data_dir(), sub)
        shutil.rmtree(p, ignore_errors=True)
        os.makedirs(p, exist_ok=True)
    activity.day, activity.data = None, None
    toast("All personal data deleted", True, "privacy")


def complete_onboarding(data):
    profile = data.get("profile") or {}
    profile["onboarded"] = True
    memory.update_profile(profile)
    settings.update(data.get("settings") or {})
    scan = data.get("scan") or {}
    apps = scan.get("apps") or {}
    if profile.get("editor"):
        memory.add(f"Main code editor is {profile['editor']}", "preference", 4, source="onboarding")
    if apps.get("browsers"):
        memory.add(f"Uses {apps['browsers'][0]} as web browser", "preference", 2, source="onboarding")
    if apps.get("communication"):
        memory.add("Uses " + ", ".join(apps["communication"][:3]) + " to communicate", "fact", 2, source="onboarding")
    if profile.get("role"):
        memory.add(f"Works as {profile['role']}", "fact", 4, source="onboarding")
    threading.Thread(target=auto_setup_model, daemon=True).start()   # best model this PC can run
    send_all({"type": "onboarding_done"})
    threading.Thread(target=greet_now, kwargs={"force": True}, daemon=True).start()


# ----------------------------------------------------------- proactivity
_greet_lock = threading.Lock()


def greet_now(force=False):
    if not _greet_lock.acquire(blocking=False):
        return
    try:
        _greet(force)
    finally:
        _greet_lock.release()


def _greet(force=False):
    if not memory.profile.get("onboarded"):
        return
    if not force and not briefing.should_greet(in_call=state["in_call"]):
        return
    for _ in range(120):                      # wait for the HUD to be up
        if clients:
            break
        time.sleep(0.5)
    try:
        briefing.reflect()
    except Exception as e:
        print("[Briefing] reflect failed:", e)
    b = briefing.build()
    briefing.mark_greeted()
    if b["plan"]:
        assistant.pending = {"kind": "plan", "plan": b["plan"]}
    send_all({"type": "briefing", "show": True, **b})
    memory.journal_add("greeting", " ".join([b["title"]] + b["lines"]))
    if settings["greeting_voice"]:
        speaker.say(briefing.spoken(b))


def scheduler():
    last_maint = None
    wrapup_offered = None
    while True:
        now = dt.datetime.now()
        try:
            for t in tasks.due_reminders(now):
                quiet = bool(state["in_call"]) or assistant.focus.active
                timer = t.get("source") == "timer"
                send_all({"type": "banner", "kind": "reminder", "title": "Timer done" if timer else "Reminder",
                          "text": t["title"], "task": t, "quiet": quiet})
                if timer:
                    tasks.complete(t["id"])
                send_all({"type": "tasks", "tasks": tasks.open_tasks()})
                memory.journal_add("reminder", t["title"])
                if settings["tts_enabled"] and not state["in_call"]:      # calls: notification only
                    speaker.say("Time's up!" if timer else f"Reminder: {t['title']}")
            if session_started.is_set():
                session_started.clear()
                gap = getattr(session_started, "gap", None)
                quiet = bool(state["in_call"]) or assistant.focus.active
                if not quiet and briefing.should_greet(now, in_call=state["in_call"]):
                    threading.Thread(target=greet_now, daemon=True).start()
                elif not quiet and gap and gap >= 3 * 3600 and settings["welcome_back"] and memory.profile.get("onboarded"):
                    n_open = len(tasks.open_tasks())
                    name = memory.profile.get("preferred_name") or memory.profile.get("name") or ""
                    send_all({"type": "banner", "kind": "info", "title": f"Welcome back{', ' + name if name else ''}!",
                              "text": f"You have {n_open} open task{'s' if n_open != 1 else ''}." if n_open else
                              "Nothing pending — what's next?"})
            if last_maint != now.date():
                last_maint = now.date()
                activity.prune(int(settings["activity_retention_days"]))
                memory.prune()
                threading.Thread(target=memory.ensure_vectors, daemon=True).start()
            end = settings["recap_time"] or memory.profile.get("work_end") or "18:00"
            if wrapup_offered != now.date() and now.strftime("%H:%M") >= end and activity.data and \
                    activity.data.get("last_active") and time.time() - activity.data["last_active"] < 600:
                wrapup_offered = now.date()
                send_all({"type": "banner", "kind": "wrapup", "title": "Wrapping up for today?",
                          "text": "I can summarise what you did and what's left for tomorrow."})
        except Exception as e:
            print("[Scheduler]", e)
        time.sleep(10)


# --------------------------------------------------------------- websocket
async def ws_handler(ws):
    clients.add(ws)
    print("[HUD] connected")
    await ws.send(json.dumps(full_hello(), default=str))
    loop = asyncio.get_running_loop()

    def bg(fn, *a):
        loop.run_in_executor(None, fn, *a)

    try:
        async for message in ws:
            try:
                d = json.loads(message)
            except ValueError:
                continue
            t = d.get("type")
            if t in ("chat", "execute_command"):
                text = (d.get("text") or d.get("command") or "").strip()
                if text:
                    llm_prewarm()
                    assistant.handle(text, "typed")
            elif t == "interrupt":
                assistant.interrupt()
            elif t == "tts_test":
                speaker.interrupt()
                name = memory.profile.get("preferred_name") or memory.profile.get("name") or ""
                speaker.say(f"Hi{' ' + name if name else ''}! This is how I sound. I'm ready when you are.")
            elif t == "push_to_talk":
                assistant.interrupt()
                voice.arm(float(d.get("seconds", 7)))
                llm_prewarm()
            elif t == "cancel_listen":
                voice.disarm()
                state["voice_status"] = "Ready"
            elif t == "toggle_gestures":
                if not settings["gestures_enabled"]:
                    settings.update({"gestures_enabled": True})
                    toast("Gestures on — camera starting", True, "gestures")
                else:
                    set_gestures_paused(not state["gestures_paused"])
                    toast("Gestures paused" if state["gestures_paused"] else "Gestures resumed", True, "gestures")
            elif t == "update_settings":
                settings.update(d.get("settings", {}))
            elif t == "request":
                what = d.get("what")
                if what == "today":
                    await ws.send(json.dumps(today_payload(), default=str))
                elif what == "activity":
                    await ws.send(json.dumps({"type": "activity", "summary": activity.summary(d.get("day")),
                                              "routine": memory.profile.get("routine", {})}, default=str))
                elif what == "models":
                    await ws.send(json.dumps(models_payload(), default=str))
                elif what == "briefing":
                    bg(lambda: send_all({"type": "briefing", "show": True, **briefing.build()}))
                elif what == "wrapup":
                    bg(lambda: send_all({"type": "wrapup", **briefing.wrap_up()}))
            # tasks
            elif t == "task_add" and d.get("text"):
                task = tasks.add_from_text(d["text"], source="typed")
                send_all({"type": "tasks", "tasks": tasks.open_tasks()})
                toast(f"Added “{task['title']}”" + (f" — {human_time(task['remind_at'])}" if task["remind_at"] else ""))
            elif t == "task_update":
                tasks.update(d.get("id"), **{k: v for k, v in d.items() if k in ("title", "done", "remind_at")})
                send_all({"type": "tasks", "tasks": tasks.open_tasks()})
            elif t == "task_delete":
                tasks.delete(d.get("id"))
                send_all({"type": "tasks", "tasks": tasks.open_tasks()})
            elif t == "task_snooze":
                tasks.snooze(d.get("id"), int(d.get("minutes", 10)))
                send_all({"type": "tasks", "tasks": tasks.open_tasks()})
            # notes
            elif t in ("note_add", "add_note") and d.get("text"):
                on_agent_note(d["text"].strip())
            elif t in ("note_delete", "delete_note"):
                notes.delete(d.get("id"))
                send_all({"type": "notes", "notes": notes.items})
            # memory & profile
            elif t == "memory_add" and d.get("text"):
                memory.add(d["text"], d.get("category", "fact"), int(d.get("importance", 4)), source="manual")
            elif t == "memory_update":
                memory.update(d.get("id"), **{k: v for k, v in d.items() if k in ("text", "importance", "category", "pinned")})
            elif t == "memory_delete":
                memory.delete(d.get("id"))
            elif t == "memory_forget_all":
                memory.forget_all()
            elif t == "profile_update":
                memory.update_profile(d.get("profile", {}))
            elif t == "export_data":
                p = storage.path(f"export-{storage.today()}.json")
                storage.write_json(p, {**memory.export(), "tasks": tasks.items, "notes": notes.items})
                os.startfile(os.path.dirname(p))
            elif t == "open_privacy_mic":
                os.startfile("ms-settings:privacy-microphone")
            elif t == "open_data_folder":
                os.startfile(storage.data_dir())
            elif t == "delete_all_data":
                bg(delete_all_data)
            # meeting
            elif t == "meeting_start" and not meeting.recording:
                meeting.start(d.get("title"))
                toast("Taking meeting notes", True, "meeting")
            elif t == "meeting_stop" and meeting.recording:
                bg(assistant._finish_meeting, "en", False)
            # routine
            elif t == "start_my_day":
                assistant.pending = None
                assistant.handle("start my day", "typed")
            elif t == "action_review":
                note = next((n for n in notes.items if n["id"] == d.get("note_id")), None)
                if note:
                    task = meeting.review_action(note, d.get("action_id"), d.get("decision", "dismiss"))
                    send_all({"type": "notes", "notes": notes.items})
                    if task:
                        send_all({"type": "tasks", "tasks": tasks.open_tasks()})
                        toast(f"Added “{task['title']}” to your tasks")
            elif t == "meeting_bookmark" and meeting.recording:
                meeting.bookmark(d.get("label", ""))
            elif t == "voice_onboarding":
                assistant.begin_voice_onboarding()
                voice.arm(10)
            elif t == "focus_stop":
                assistant.focus.stop()
                send_all({"type": "focus", **assistant.focus.state()})
            elif t == "context_delete":
                assistant.contexts.delete(d.get("id"))
                send_all({"type": "contexts", "contexts": assistant.contexts.items})
            elif t == "clear_activity":
                shutil.rmtree(os.path.join(storage.data_dir(), "activity"), ignore_errors=True)
                os.makedirs(os.path.join(storage.data_dir(), "activity"), exist_ok=True)
                activity.day, activity.data = None, None
                toast("Activity history cleared", True, "privacy")
            elif t == "dismiss_briefing":
                assistant.pending = None
            # onboarding & models
            elif t == "scan_system":
                bg(lambda: send_all({"type": "scan", **system_scan.scan(agent.apps)}))
            elif t == "onboarding_complete":
                bg(complete_onboarding, d)
            elif t == "set_api_key":
                prov = d.get("provider") or cloud.provider
                secrets_store.set_key(f"cloud_{prov}", d.get("key", ""))
                settings.update({"cloud_provider": prov})
                cloud.last_error = None
                send_all(models_payload())
                toast("API key saved (encrypted on this PC)" if d.get("key") else "API key removed", True, "cloud")
            elif t == "cloud_test":
                def _test():
                    try:
                        secs, out = cloud.test()
                        toast(f"Cloud brain works — answered in {secs}s", True, "cloud")
                    except Exception as e:
                        toast(f"Cloud test failed: {e}", False, "cloud")
                    send_all(models_payload())
                bg(_test)
            elif t == "open_speech_settings":
                os.startfile("ms-settings:speech")
            elif t == "vision_install":
                bg(pull_model, "qwen3.5:4b")
            elif t == "install_ollama":
                bg(install_ollama)
            elif t == "model_pull" and d.get("name"):
                bg(pull_model, d["name"])
            elif t == "model_select" and d.get("name"):
                ok, reason = is_compatible(d["name"])
                if ok:
                    settings.update({"llm_model": d["name"]})
                else:
                    toast(f"Your system isn't compatible with {d['name']}. {reason}", False, "model")
    except websockets.ConnectionClosed:
        pass
    finally:
        clients.discard(ws)


async def broadcast_state():
    last, tick = None, 0
    while True:
        if clients:
            state["voice_armed"] = voice.armed
            state["mic_level"] = round(voice.level, 4)
            state["recording"] = meeting.recording
            state["brain"] = "cloud" if brain.is_cloud else ("local" if llm.ready() else "none")
            if assistant.working and not speaker.speaking:
                state["assistant"] = "thinking"
            elif not assistant.working and not speaker.speaking and state["assistant"] != "idle":
                state["assistant"] = "idle"
            msg = json.dumps({"type": "state_update", **state})
            if msg != last:
                websockets.broadcast(clients, msg)
                last = msg
            tick += 1
            if tick % 150 == 0:          # every ~5 s
                websockets.broadcast(clients, json.dumps(models_payload(), default=str))
        await asyncio.sleep(1 / 30)


async def run_server():
    global ws_loop
    ws_loop = asyncio.get_running_loop()
    try:
        async with websockets.serve(ws_handler, "localhost", PORT, max_size=8 * 1024 * 1024):
            print(f"[HUD] WebSocket server on ws://localhost:{PORT}")
            await broadcast_state()
    except OSError as e:
        print("[HUD] Could not start WebSocket server (is another engine running?):", e)
        os._exit(1)


# ------------------------------------------------------------------ camera
def open_camera(index):
    backend = cv2.CAP_DSHOW if sys.platform == "win32" else cv2.CAP_ANY
    cap = cv2.VideoCapture(index, backend)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    cap.set(cv2.CAP_PROP_FPS, 30)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    return cap if cap.isOpened() else None


def on_gesture_event(name, data=None):
    send_all({"type": "gesture_event", "event": name, "data": data})
    if name in ("palm_hold", "fist") and data:
        if data == "listen":
            assistant.interrupt()
            voice.arm(7)
            llm_prewarm()
            toast("Listening — say a command", True, "gesture")
        else:
            assistant.handle(data, "gesture")


def camera_loop():
    global gestures

    mouse = MouseController()
    sw, sh = mouse.screen_size()
    tracker = None
    recognizer = GestureRecognizer(settings["pinch_sensitivity"])
    gestures = GestureController(mouse, sw, sh, settings.as_dict(), on_event=on_gesture_event)
    settings.on_change(lambda c: recognizer.set_pinch_sensitivity(settings["pinch_sensitivity"])
                       if "pinch_sensitivity" in c else None)
    cap, cam_index, preview_open, fails = None, None, False, 0
    last_hand, p_time = time.time(), time.time()

    while True:
        if not settings["gestures_enabled"]:
            if cap is not None:
                cap.release()
                cap = None
                gestures.hand_lost()
            if preview_open:
                cv2.destroyWindow(PREVIEW_TITLE)
                cv2.waitKey(1)
                preview_open = False
            state.update(camera="off", hand_visible=False, gesture="NONE")
            time.sleep(0.5)
            continue
        if tracker is None:
            try:
                from src.vision.hand_tracker import HandTracker   # loaded only when gestures are on
                tracker = HandTracker(max_hands=1)
            except Exception as e:
                print("[Vision] Hand tracking unavailable:", e)
                state["camera"] = "unavailable"
                settings.update({"gestures_enabled": False})
                toast("Hand gestures aren't available on this PC — voice and keyboard still work.", False, "gestures")
                continue
        if cap is None or settings["camera_index"] != cam_index:
            if cap is not None:
                cap.release()
            cam_index = settings["camera_index"]
            cap = open_camera(cam_index)
            if cap is None:
                state["camera"] = "unavailable"
                time.sleep(2)
                continue
        ok, img = cap.read()
        if not ok:
            fails += 1
            if fails > 30:
                state["camera"] = "unavailable"
                cap.release()
                cap, fails = None, 0
            time.sleep(0.03)
            continue
        fails = 0
        state["camera"] = "ok"
        img = cv2.flip(img, 1)
        h, w = img.shape[:2]
        show = settings["show_camera_preview"]
        img = tracker.find_hands(img, draw=show)
        lm = tracker.find_position(img)
        if lm and len(lm) >= 21:
            last_hand = time.time()
            gestures.update(recognizer.detect_gesture(lm), lm, w, h)
        else:
            recognizer.detect_gesture([])
            gestures.hand_lost()
        now = time.time()
        fps = 1 / max(1e-3, now - p_time)
        p_time = now
        state.update({"gesture": gestures.pose, "fps": int(state["fps"] * 0.8 + fps * 0.2),
                      "cursor": list(gestures.cursor), "dragging": gestures.dragging,
                      "hand_visible": bool(lm), "gestures_paused": gestures.paused})
        if show:
            l, t, r, b = gestures.control_box()
            cv2.rectangle(img, (int(l * w), int(t * h)), (int(r * w), int(b * h)), (255, 0, 255), 2)
            label = "PAUSED" if gestures.paused else gestures.pose + (" (DRAG)" if gestures.dragging else "")
            cv2.putText(img, label, (12, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
            cv2.imshow(PREVIEW_TITLE, cv2.resize(img, (320, 240)))
            if not preview_open:
                cv2.setWindowProperty(PREVIEW_TITLE, cv2.WND_PROP_TOPMOST, 1)
                preview_open = True
            cv2.waitKey(1)
            if cv2.getWindowProperty(PREVIEW_TITLE, cv2.WND_PROP_VISIBLE) < 1:
                settings.update({"show_camera_preview": False})
        elif preview_open:
            cv2.destroyWindow(PREVIEW_TITLE)
            cv2.waitKey(1)
            preview_open = False
        if now - last_hand > settings["idle_sleep_seconds"]:
            time.sleep(0.15)


def startup():
    # the greeting itself is triggered by the activity tracker's session start
    send_all(models_payload())
    if memory.profile.get("onboarded"):
        auto_setup_model()           # first run after onboarding / model removed: install the right one
    send_all(models_payload())


if __name__ == "__main__":
    apply_voice_mode()
    voice.start()
    activity.start()
    threading.Thread(target=lambda: asyncio.run(run_server()), daemon=True).start()
    threading.Thread(target=scheduler, daemon=True).start()
    threading.Thread(target=startup, daemon=True).start()
    try:
        while True:
            try:
                camera_loop()
            except KeyboardInterrupt:
                raise
            except Exception as e:
                # the camera/gesture layer must never take down voice, the assistant or the HUD link
                import traceback
                traceback.print_exc()
                print("[Vision] camera loop crashed, restarting in 5 s:", e)
                if gestures:
                    gestures.release_all()
                time.sleep(5)
    except KeyboardInterrupt:
        pass
    finally:
        if gestures:
            gestures.release_all()
        activity.stop()
        voice.stop()
