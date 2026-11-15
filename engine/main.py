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
import subprocess
import sys
import threading
import time

from src import diag  # noqa: E402  (tiny, no dependencies: records errors that used to be swallowed)

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)   # engine.log updates live
    except Exception as _e:                   # no console (windowed build): nothing to reconfigure
        diag.record("startup.stdio", _e, quiet=True)


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

from src import storage, appdata
from src.config import Settings
from src.server import auth as ws_auth
from src.server.router import Router
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
from src.voice.voice_listener import VoiceListener, sounds_unfinished
from src.web import tools as webtools
_probe("all imports")

PREVIEW_TITLE = "Snapy - Camera"
PORT = int(os.environ.get("SNAP_AIR_PORT") or appdata.get("server.port"))

storage.migrate()                     # upgrade data files written by older versions before anything reads them
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
    except Exception as e:                    # a client that just disconnected; the handler drops it
        diag.record("ws.send", e, quiet=True)


def toast(message, ok=True, source=""):
    if message:
        print(f"[{source or 'Snapy'}] {message}")
        send_all({"type": "toast", "message": message, "ok": ok, "source": source})


# -------------------------------------------------------------- components
llm = LLM(settings)                    # local model (Ollama)
cloud = CloudLLM(settings)             # optional cloud model (user's API key)
brain = Brain(llm, cloud, settings)    # routes each request: local / cloud / auto
# Nothing goes to a cloud provider until the user has seen what would be sent and allowed it
cloud.require_ack = True
cloud.on_preview = lambda sample: send_all({"type": "cloud_preview", "sample": sample})
memory = MemoryStore(llm=brain.for_purpose("memory"), settings=settings)
tasks = TaskStore()
notes = NoteStore()
agent = AgentController(settings=settings)
state["brain"] = "cloud" if brain.is_cloud else ("local" if llm.ready() else "none")


def user_languages():
    """Languages to choose between in "auto" mode: English + Hindi, plus any the user listed."""
    names = appdata.get("languages", {})
    out = list(appdata.get("default_listen_languages", ["en"]))
    for l in (memory.profile.get("languages") or []) if "memory" in globals() else []:
        code = names.get(str(l).strip().lower(), str(l).strip().lower()[:2])
        if code in names.values() and code not in out:
            out.append(code)
    return tuple(out)


def whisper_model_name():
    lang = settings["voice_language"]
    q = settings["speech_quality"]
    # mixed English/Hindi uses the multilingual table; "tiny" mis-detects languages too often,
    # so app.json maps even "fast" to "base" there
    table = appdata.get("speech_models.english" if lang == "en" else "speech_models.multilingual")
    return table.get(q) or table["fast"]


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


# "Record this video": the video's own sound straight from Windows (not the mic), transcribed
# on this PC so you can ask about it. No notes/tasks are created and no audio is kept.
def _on_video_capture(st):
    send_all({"type": "video_capture", **st})


video_capture = MeetingRecorder(transcribe_fn=_transcribe_meeting, llm=brain, on_update=_on_video_capture,
                                on_auto_stop=lambda: assistant.stop_video_capture("en", False))

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
    if app and not meeting.recording and (app != _last_call_offer["app"] or time.time() - _last_call_offer["t"] > appdata.get("timings.call_offer_cooldown_s")):
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
assistant.video_capture = video_capture
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


# A pause in the middle of a sentence must not split it into two commands: a phrase that
# sounds unfinished ("open youtube and", "remind me to") waits briefly for the rest.
_pending_speech = {"text": "", "armed": False, "lang": "en", "timer": None}
_pending_lock = threading.Lock()


def on_transcript(text, armed, lang="en"):
    with _pending_lock:
        p = _pending_speech
        if p["timer"] is not None:
            p["timer"].cancel()
            text = (p["text"] + " " + text).strip()
            armed = armed or p["armed"]
            p.update(text="", timer=None)
        if sounds_unfinished(text):
            p.update(text=text, armed=armed, lang=lang)
            p["timer"] = threading.Timer(float(settings["continuation_wait_s"]), _flush_pending)
            p["timer"].start()
            send_all({"type": "transcript", "text": text + " …", "lang": lang})
            return
    _handle_transcript(text, armed, lang)


def _flush_pending():
    with _pending_lock:
        p = _pending_speech
        text, armed, lang = p["text"], p["armed"], p["lang"]
        p.update(text="", timer=None)
    if text:
        _handle_transcript(text, armed, lang)


def _handle_transcript(text, armed, lang="en"):
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

from src.os_control.media import MediaWatcher, SystemAudioMeter  # noqa: E402


system_audio = SystemAudioMeter()


def _on_media(st):
    state["media"] = st
    system_audio.set_active(bool(st["playing"] and settings["smart_media_listening"]))
    send_all({"type": "media", **st})


media = MediaWatcher(on_change=_on_media)
voice.system_level_fn = lambda: system_audio.level


def apply_listening_timing():
    voice.end_of_speech_s = float(settings["end_of_speech_s"])
    voice.max_utterance_s = float(settings["max_utterance_s"])


apply_listening_timing()

# Snapy-level actions requested by voice (quit, emoji burst) go to the HUD


def _on_agent_ui(msg):
    send_all(msg)
    if msg.get("action") == "quit":
        # the HUD closes the app; make sure the engine follows even if no HUD is connected
        threading.Timer(4.0, lambda: os._exit(0)).start()


agent.on_ui = _on_agent_ui


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
        except Exception as e:            # only a warm-up: the real request reports its own errors
            diag.record("llm.prewarm", e)
    threading.Thread(target=go, daemon=True).start()


# ---------------------------------------------------------------- settings
def on_settings_changed(changed):
    if gestures:
        gestures.apply_settings(settings.as_dict())
    if "voice_mode" in changed:
        apply_voice_mode()
    if set(changed) & {"end_of_speech_s", "max_utterance_s"}:
        apply_listening_timing()
    if "smart_media_listening" in changed:
        system_audio.set_active(bool(media.playing and settings["smart_media_listening"]))
    if "mic_sensitivity" in changed:
        voice.set_sensitivity(changed["mic_sensitivity"])
    if "voice_language" in changed or "speech_quality" in changed:
        voice.set_language(settings["voice_language"])
        voice.allowed_langs = user_languages()
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
    except Exception as e:
        diag.record("models.native_voices", e, quiet=True)   # sent every ~5 s: count, don't spam the log
        st["native_voices"] = {}
    try:
        st["vision"] = vision.status()
    except Exception as e:
        diag.record("models.vision", e, quiet=True)
        st["vision"] = {}
    # "configured" = a key is saved (the UI's meaning); "consent_pending" = not yet allowed to use it
    st["cloud"] = {"provider": cloud.provider, "model": cloud.model, "base_url": cloud.base_url,
                   "configured": cloud.has_key(), "consent_pending": cloud.consent_pending(),
                   "key": secrets_store.masked(f"cloud_{cloud.provider}"),
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
    if not llm.pull_cancelled():
        toast(f"{name} is ready" if ok else f"Couldn't download {name}: {llm.last_error}", ok, "model")
    return ok


def cancel_job(kind):
    """Each Cancel button stops only its own job: a model download ("cancel_pull"), the AI
    engine install ("cancel_install"), or first-run setup and whatever step it is on ("cancel_setup")."""
    stop_pull = kind in ("cancel_pull", "cancel_setup")
    stop_install = kind in ("cancel_install", "cancel_setup")
    if kind == "cancel_setup":
        setup.cancel()
    if stop_pull and llm.pulling:
        llm.cancel_pull()
    if stop_install and _ollama_install.get("status") == "running":   # the installer itself can't be stopped
        _cancel_ollama.set()
        _ollama_install.update(status="cancelled", pct=0)
    send_all(models_payload())
    toast({"cancel_pull": "Model download cancelled", "cancel_install": "AI engine download cancelled",
           "cancel_setup": "Setup cancelled"}[kind], True, "model")


def refresh_brain_state():
    state["brain"] = "cloud" if brain.is_cloud else ("local" if llm.ready() else "none")
    send_all({"type": "state_update", **state})
    send_all(models_payload())


def save_api_key(prov, key):
    """Store (or remove) a cloud key, then check it with one tiny request before calling
    the cloud brain live. "auto" uses the cloud while online and the key works, and the
    local model otherwise, so a dropped connection never leaves Snapy without a brain."""
    secrets_store.set_key(f"cloud_{prov}", key)
    settings.update({"cloud_provider": prov})
    cloud.last_error = None
    label = PROVIDERS.get(prov, {}).get("label", prov)
    if not key:
        if settings.get("ai_provider") == "cloud":
            settings.update({"ai_provider": "auto"})
        refresh_brain_state()
        toast("API key removed", True, "cloud")
        return
    if settings.get("ai_provider") != "cloud":
        settings.update({"ai_provider": "auto"})
    try:
        secs, _ = cloud.test()
        toast(f"API key saved — {label} answered in {secs}s", True, "cloud")
    except Exception as e:
        toast(f"Key saved, but {label} didn't answer: {e}", False, "cloud")
    refresh_brain_state()


_ollama_install = {"status": None, "pct": 0}
_cancel_ollama = threading.Event()
from src.setup_assets import (Setup, SetupCancelled, whisper_ready, kokoro_ready,  # noqa: E402
                              WHISPER_REPO, WHISPER_FILES, KOKORO_URL, KOKORO_FILES)
setup = Setup(on_change=lambda st: send_all(st))


def run_setup():
    """First-run downloads with real progress: speech, voice, AI engine, AI model."""
    import importlib.util
    if not setup.try_start():          # one run at a time, even if Retry is pressed mid-cancel
        return
    try:
        local_ai = settings["ai_provider"] != "cloud"
        from src.brain.llm import _ollama_exe
        has_runtime = bool(_ollama_exe())
        rec = compatibility()["recommended"]
        has_brain = False
        if has_runtime and llm.ensure_server():
            installed = llm.installed_models()
            cur = settings["llm_model"]
            has_brain = any(m in (cur, cur + ":latest", rec, rec + ":latest") for m in installed) or any(
                m["compatible"] and any(i in (m["name"], m["name"] + ":latest") for i in installed)
                for m in compatibility()["models"])
        wname = whisper_model_name()
        setup.plan(need_speech=not whisper_ready(wname),
                   need_voice=importlib.util.find_spec("kokoro_onnx") is not None and not kokoro_ready(),
                   need_runtime=local_ai and not has_runtime,
                   need_brain=local_ai and not has_brain, brain_name=rec)
        if not setup.items:
            return
        from src.voice.tts import model_dir as kokoro_dir
        for it in list(setup.items):
            if setup.cancelled:
                break                    # cancel() already marked the remaining items
            try:
                if it["id"] == "speech":
                    d = os.path.join(storage.data_dir(), "models", f"faster-whisper-{wname}")
                    setup.fetch("speech", [(WHISPER_REPO.format(name=wname) + f, os.path.join(d, f)) for f in WHISPER_FILES])
                    voice.reload()
                elif it["id"] == "voice":
                    setup.fetch("voice", [(KOKORO_URL + f, os.path.join(kokoro_dir(), f)) for f in KOKORO_FILES])
                    speaker.reload()
                elif it["id"] == "runtime":
                    install_ollama(progress_item="runtime")
                    if _ollama_install.get("status") == "cancelled":
                        raise SetupCancelled()
                    if _ollama_install.get("status") != "done":
                        raise RuntimeError(_ollama_install.get("error") or "the AI engine didn't install")
                elif it["id"] == "brain":
                    if not llm.ensure_server():
                        raise RuntimeError("the AI engine isn't running")
                    setup.update("brain", state="downloading")

                    def prog(p):
                        if p.get("total") and p["total"] > 50_000_000:      # the model weights layer
                            setup.get("brain").update(done=p["done"], total=p["total"])
                        setup._emit()
                    if not llm.pull(rec, on_progress=prog):
                        if llm.pull_cancelled():
                            raise SetupCancelled()
                        raise RuntimeError(llm.last_error or "download failed")
                    settings.update({"llm_model": rec})
                    setup.update("brain", state="done", done=setup.get("brain")["total"])
                    send_all(models_payload())
            except SetupCancelled:
                setup.update(it["id"], state="cancelled", speed=0, error=None)
                break
            except Exception as e:
                setup.update(it["id"], state="error", error=str(e)[:160])
    finally:
        setup.finish()


def install_ollama(progress_item=None):
    """Download and silently install Ollama (the free local AI runtime), then the
    recommended model for this PC. With progress_item, reports bytes to first-run setup."""
    import tempfile
    import requests as rq
    if _ollama_install["status"] in ("running", "installing"):
        return
    _cancel_ollama.clear()
    _ollama_install.update(status="running", pct=0)
    send_all(models_payload())
    try:
        dest = os.path.join(tempfile.gettempdir(), appdata.get("ollama.installer_file"))
        with rq.get(appdata.get("ollama.installer_url"), stream=True, timeout=(10, 120)) as r:
            r.raise_for_status()
            total = int(r.headers.get("content-length") or 0)
            done, t0 = 0, time.time()
            if progress_item:
                setup.update(progress_item, state="downloading", total=total or setup.get(progress_item)["total"])
            with open(dest, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    if _cancel_ollama.is_set():
                        break
                    f.write(chunk)
                    done += len(chunk)
                    if progress_item:
                        el = max(0.5, time.time() - t0)
                        setup.get(progress_item).update(done=done, speed=int(done / el))
                        setup._emit()
                    if total:
                        _ollama_install["pct"] = round(done * 90 / total, 1)
                        if not progress_item:
                            send_all(models_payload())
        if _cancel_ollama.is_set():
            # a half-downloaded installer is useless (and must never be run): remove it
            try:
                os.remove(dest)
            except OSError as e:
                diag.record("setup.remove_partial_installer", e)
            _ollama_install.update(status="cancelled", pct=0)
            send_all(models_payload())
            return
        # From here the Windows installer runs; it can't be stopped safely, so Cancel is ignored
        _ollama_install.update(status="installing", pct=92)
        if progress_item:
            setup.update(progress_item, state="installing", speed=0)
        send_all(models_payload())
        import subprocess as sp
        sp.run([dest, *appdata.get("ollama.installer_args", [])], timeout=appdata.get("ollama.install_timeout_s"))
        _ollama_install.update(status="done", pct=100)
        if progress_item:
            setup.update(progress_item, state="done", done=setup.get(progress_item)["total"])
        else:
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
        "data_dir": storage.data_dir(), "setup": setup.state(),
        "cloud_preview": cloud.preview_sample if cloud.consent_pending() else None,
        **{k: v for k, v in models_payload().items() if k != "type"},
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
    threading.Thread(target=run_setup, daemon=True).start()   # anything still missing, with progress
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
                elif not quiet and gap and gap >= appdata.get("timings.welcome_back_gap_s") and settings["welcome_back"] and memory.profile.get("onboarded"):
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
                    activity.data.get("last_active") and time.time() - activity.data["last_active"] < appdata.get("timings.recently_active_s"):
                wrapup_offered = now.date()
                send_all({"type": "banner", "kind": "wrapup", "title": "Wrapping up for today?",
                          "text": "I can summarise what you did and what's left for tomorrow."})
        except Exception as e:
            print("[Scheduler]", e)
        time.sleep(10)


# --------------------------------------------------------------- websocket
# One handler per message type (src/server/router.py). A handler gets (msg, ctx) and
# may return a dict that goes back to the asking client only; ctx.bg runs slow work
# off the event loop. Unknown types are ignored, as before.
router = Router()
on = router.on


class _Ctx:
    def __init__(self, ws, loop):
        self.ws = ws
        self.loop = loop

    def bg(self, fn, *a):
        self.loop.run_in_executor(None, fn, *a)


@on("chat", "execute_command")
def _h_chat(d, ctx):
    text = (d.get("text") or d.get("command") or "").strip()
    if text:
        llm_prewarm()
        assistant.handle(text, "typed")


@on("interrupt")
def _h_interrupt(d, ctx):
    assistant.interrupt()


@on("tts_test")
def _h_tts_test(d, ctx):
    speaker.interrupt()
    name = memory.profile.get("preferred_name") or memory.profile.get("name") or ""
    speaker.say(f"Hi{' ' + name if name else ''}! This is how I sound. I'm ready when you are.")


@on("push_to_talk")
def _h_push_to_talk(d, ctx):
    assistant.interrupt()
    voice.arm(float(d.get("seconds", 7)))
    llm_prewarm()


@on("cancel_listen")
def _h_cancel_listen(d, ctx):
    voice.disarm()
    state["voice_status"] = "Ready"


@on("toggle_gestures")
def _h_toggle_gestures(d, ctx):
    if not settings["gestures_enabled"]:
        settings.update({"gestures_enabled": True})
        toast("Gestures on — camera starting", True, "gestures")
    else:
        set_gestures_paused(not state["gestures_paused"])
        toast("Gestures paused" if state["gestures_paused"] else "Gestures resumed", True, "gestures")


@on("update_settings")
def _h_update_settings(d, ctx):
    settings.update(d.get("settings", {}))


@on("request")
def _h_request(d, ctx):
    what = d.get("what")
    if what == "today":
        return today_payload()
    if what == "activity":
        return {"type": "activity", "summary": activity.summary(d.get("day")),
                "routine": memory.profile.get("routine", {})}
    if what == "models":
        return models_payload()
    if what == "diagnostics":                    # trust centre: what went wrong, how often
        return {"type": "diagnostics", **diag.summary()}
    if what == "briefing":
        ctx.bg(lambda: send_all({"type": "briefing", "show": True, **briefing.build()}))
    elif what == "wrapup":
        ctx.bg(lambda: send_all({"type": "wrapup", **briefing.wrap_up()}))


# tasks
@on("task_add")
def _h_task_add(d, ctx):
    if not d.get("text"):
        return
    task = tasks.add_from_text(d["text"], source="typed")
    send_all({"type": "tasks", "tasks": tasks.open_tasks()})
    toast(f"Added “{task['title']}”" + (f" — {human_time(task['remind_at'])}" if task["remind_at"] else ""))


@on("task_update")
def _h_task_update(d, ctx):
    tasks.update(d.get("id"), **{k: v for k, v in d.items() if k in ("title", "done", "remind_at")})
    send_all({"type": "tasks", "tasks": tasks.open_tasks()})


@on("task_delete")
def _h_task_delete(d, ctx):
    tasks.delete(d.get("id"))
    send_all({"type": "tasks", "tasks": tasks.open_tasks()})


@on("task_snooze")
def _h_task_snooze(d, ctx):
    tasks.snooze(d.get("id"), int(d.get("minutes") or appdata.get("timings.snooze_default_min")))
    send_all({"type": "tasks", "tasks": tasks.open_tasks()})


# notes
@on("note_add", "add_note")
def _h_note_add(d, ctx):
    if d.get("text"):
        on_agent_note(d["text"].strip())


@on("note_delete", "delete_note")
def _h_note_delete(d, ctx):
    notes.delete(d.get("id"))
    send_all({"type": "notes", "notes": notes.items})


# memory & profile
@on("memory_add")
def _h_memory_add(d, ctx):
    if d.get("text"):
        memory.add(d["text"], d.get("category", "fact"), int(d.get("importance", 4)), source="manual")


@on("memory_update")
def _h_memory_update(d, ctx):
    memory.update(d.get("id"), **{k: v for k, v in d.items() if k in ("text", "importance", "category", "pinned")})


@on("memory_delete")
def _h_memory_delete(d, ctx):
    memory.delete(d.get("id"))


@on("memory_forget_all")
def _h_memory_forget_all(d, ctx):
    memory.forget_all()


@on("profile_update")
def _h_profile_update(d, ctx):
    memory.update_profile(d.get("profile", {}))


@on("export_data")
def _h_export_data(d, ctx):
    p = storage.path(f"export-{storage.today()}.json")
    storage.write_json(p, {**memory.export(), "tasks": tasks.items, "notes": notes.items})
    os.startfile(os.path.dirname(p))


@on("open_privacy_mic")
def _h_open_privacy_mic(d, ctx):
    os.startfile("ms-settings:privacy-microphone")


@on("open_data_folder")
def _h_open_data_folder(d, ctx):
    os.startfile(storage.data_dir())


@on("delete_all_data")
def _h_delete_all_data(d, ctx):
    ctx.bg(delete_all_data)


# meeting
@on("meeting_start")
def _h_meeting_start(d, ctx):
    if not meeting.recording:
        meeting.start(d.get("title"))
        toast("Taking meeting notes", True, "meeting")


@on("meeting_stop")
def _h_meeting_stop(d, ctx):
    if meeting.recording:
        ctx.bg(assistant._finish_meeting, "en", False)


@on("meeting_bookmark")
def _h_meeting_bookmark(d, ctx):
    if meeting.recording:
        meeting.bookmark(d.get("label", ""))


# routine
@on("start_my_day")
def _h_start_my_day(d, ctx):
    assistant.pending = None
    assistant.handle("start my day", "typed")


@on("action_review")
def _h_action_review(d, ctx):
    note = next((n for n in notes.items if n["id"] == d.get("note_id")), None)
    if note:
        task = meeting.review_action(note, d.get("action_id"), d.get("decision", "dismiss"))
        send_all({"type": "notes", "notes": notes.items})
        if task:
            send_all({"type": "tasks", "tasks": tasks.open_tasks()})
            toast(f"Added “{task['title']}” to your tasks")


@on("voice_onboarding")
def _h_voice_onboarding(d, ctx):
    assistant.begin_voice_onboarding()
    voice.arm(10)


@on("focus_stop")
def _h_focus_stop(d, ctx):
    assistant.focus.stop()
    send_all({"type": "focus", **assistant.focus.state()})


@on("context_delete")
def _h_context_delete(d, ctx):
    assistant.contexts.delete(d.get("id"))
    send_all({"type": "contexts", "contexts": assistant.contexts.items})


@on("clear_activity")
def _h_clear_activity(d, ctx):
    shutil.rmtree(os.path.join(storage.data_dir(), "activity"), ignore_errors=True)
    os.makedirs(os.path.join(storage.data_dir(), "activity"), exist_ok=True)
    activity.day, activity.data = None, None
    toast("Activity history cleared", True, "privacy")


@on("dismiss_briefing")
def _h_dismiss_briefing(d, ctx):
    assistant.pending = None


@on("shutdown", "quit")
def _h_shutdown(d, ctx):
    print("[Engine] Shutdown requested by client")

    def _do_exit():
        time.sleep(0.15)
        os._exit(0)
    threading.Thread(target=_do_exit, daemon=True).start()


# onboarding & models
@on("scan_system")
def _h_scan_system(d, ctx):
    ctx.bg(lambda: send_all({"type": "scan", **system_scan.scan(agent.apps)}))


@on("onboarding_complete")
def _h_onboarding_complete(d, ctx):
    ctx.bg(complete_onboarding, d)


@on("set_api_key")
def _h_set_api_key(d, ctx):
    ctx.bg(save_api_key, d.get("provider") or cloud.provider, (d.get("key") or "").strip())


@on("cloud_preview_ack")
def _h_cloud_preview_ack(d, ctx):
    """Answer to the one-time "what's sent to the cloud" dialog."""
    cloud.preview_sample = None
    if d.get("allow"):
        settings.update({"cloud_preview_ack": True})
        toast("Cloud brain allowed — personal details are masked before sending", True, "cloud")
    else:
        settings.update({"ai_provider": "local"})
        toast("Staying on this PC — nothing goes to the cloud", True, "cloud")
    refresh_brain_state()


@on("cancel_pull", "cancel_install", "cancel_setup")
def _h_cancel(d, ctx):
    cancel_job(d["type"])


@on("cloud_test")
def _h_cloud_test(d, ctx):
    def _test():
        try:
            secs, out = cloud.test()
            toast(f"Cloud brain works — answered in {secs}s", True, "cloud")
        except Exception as e:
            toast(f"Cloud test failed: {e}", False, "cloud")
        send_all(models_payload())
    ctx.bg(_test)


@on("open_speech_settings")
def _h_open_speech_settings(d, ctx):
    os.startfile("ms-settings:speech")


@on("vision_install")
def _h_vision_install(d, ctx):
    ctx.bg(pull_model, appdata.get("vision.install_model"))


@on("setup_retry")
def _h_setup_retry(d, ctx):
    ctx.bg(run_setup)


@on("install_ollama")
def _h_install_ollama(d, ctx):
    ctx.bg(install_ollama)


@on("model_pull")
def _h_model_pull(d, ctx):
    if d.get("name"):
        ctx.bg(pull_model, d["name"])


@on("model_select")
def _h_model_select(d, ctx):
    if not d.get("name"):
        return
    ok, reason = is_compatible(d["name"])
    if ok:
        settings.update({"llm_model": d["name"]})
    else:
        toast(f"Your system isn't compatible with {d['name']}. {reason}", False, "model")


async def ws_handler(ws):
    clients.add(ws)
    print("[HUD] connected")
    await ws.send(json.dumps(full_hello(), default=str))
    ctx = _Ctx(ws, asyncio.get_running_loop())

    async def reply(payload):
        await ws.send(json.dumps(payload, default=str))

    try:
        async for message in ws:
            try:
                d = json.loads(message)
            except ValueError:
                continue
            if isinstance(d, dict):
                await router.dispatch(d, ctx, reply)
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
        host = appdata.get("server.host")
        # Only the HUD may connect: a per-launch token plus an Origin allow-list, so a web
        # page in the user's browser can't drive Snapy through localhost (src/server/auth.py)
        token = ws_auth.load_or_create_token()
        async with websockets.serve(ws_handler, host, PORT, process_request=ws_auth.process_request(token),
                                    max_size=int(appdata.get("server.max_message_mb")) * 1024 * 1024):
            print(f"[HUD] WebSocket server on ws://{host}:{PORT}")
            await broadcast_state()
    except OSError as e:
        print("[HUD] Could not start WebSocket server (is another engine running?):", e)
        os._exit(1)


# ------------------------------------------------------------------ camera
def open_camera(index):
    backend = cv2.CAP_DSHOW if sys.platform == "win32" else cv2.CAP_ANY
    cap = cv2.VideoCapture(index, backend)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, appdata.get("camera.width"))
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, appdata.get("camera.height"))
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
            cv2.imshow(PREVIEW_TITLE, cv2.resize(img, (appdata.get("camera.preview_width"), appdata.get("camera.preview_height"))))
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


def close_osk():
    try:
        subprocess.run(["taskkill", "/f", "/im", "osk.exe"], capture_output=True,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except Exception as e:
        diag.record("startup.close_osk", e, quiet=True)


def startup():
    # make sure on-screen keyboard is not lingering
    close_osk()
    # the greeting itself is triggered by the activity tracker's session start
    send_all(models_payload())
    run_setup()                      # first run (or a model was removed): download what's missing, with progress
    send_all(models_payload())


if __name__ == "__main__":
    apply_voice_mode()
    voice.start()
    media.start()
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
