"""Persistent user settings for Snap Air.

Settings live in %APPDATA%/SnapAir/settings.json (or ~/.snap-air on other OSes)
so they survive restarts and are shared by the engine and the HUD.
"""
import json
import os
import threading

DEFAULTS = {
    # --- Pointer ---
    "pointer_smoothing": 5,        # 1 (raw / fastest) .. 10 (smoothest)
    "pointer_anchor": "knuckle",   # "knuckle" = stable while pinching, "fingertip" = precise
    "control_area": 6,             # 1 (whole camera frame) .. 10 (small box = fast pointer)
    "pointer_enabled": True,

    # --- Clicking ---
    "pinch_sensitivity": 5,        # 1 (fingers must really touch) .. 10 (loose)
    "hold_to_drag_ms": 450,        # how long a pinch must be held before it becomes a drag
    "drag_enabled": True,
    "right_click_enabled": True,

    # --- Scrolling ---
    "scroll_enabled": True,
    "scroll_sensitivity": 5,       # 1..10
    "scroll_style": "joystick",    # "joystick" = hold fingers above/below start to keep scrolling, "drag" = touchpad-like
    "scroll_invert": False,       # True = "natural" (move fingers up -> content moves up)
    "voice_scroll_amount": 5,      # wheel notches per "scroll down"

    # --- Gesture shortcuts (action names from agent command list, or "none") ---
    "palm_hold_action": "none",    # what holding an open palm for 1s does
    "fist_action": "clutch",       # "clutch" = freeze pointer while you reposition your hand

    # --- Voice ---
    "voice_mode": "wake",          # "wake" (say "Snap ..."), "always", "push" (hotkey only), "off"
    "wake_words": ["snapy", "snappy", "hey snapy", "snap"],
    "voice_language": "en",        # "en" = fastest (tiny.en ~0.4 s); "auto" = detect language (multilingual, ~1.5 s)
    "speech_quality": "fast",      # fast (tiny) | balanced (base) | accurate (small) Whisper models
    "mic_sensitivity": 5,          # 1 (only loud speech) .. 10 (very sensitive)
    "use_ollama": False,           # (legacy) let the LLM map unknown phrases to commands
    "ollama_model": "qwen3:1.7b",
    "follow_up_seconds": 8,        # after Snap answers, listen this long for a follow-up without the wake word
    "headphones": False,           # True = allow interrupting Snap by voice (no speaker echo)

    # --- Assistant voice (TTS) ---
    "tts_enabled": True,
    "tts_voice": "af_heart",
    "tts_speed": 1.0,
    "native_indic_voices": True,   # native-speaker Piper voices for Hindi, Telugu, Malayalam, Marathi, Bengali…
    "indic_voices": {},            # per-language choice, e.g. {"hi": "hi_IN-rohan-medium"}
    "personal_use_voices": False,  # allow voices whose licence is non-commercial (personal use only)
    "vision_mode": "auto",         # auto: OCR + local/cloud vision when the accessibility tree can't see it | off
    "vision_local": "auto",        # auto: local vision model only with a GPU (CPU ~90 s/screenshot) | on | off
    "vision_model": "",            # Ollama vision model; empty = best installed
    "speak_typed_replies": False,  # also speak answers to typed questions
    "speak_confirmations": False,  # speak "Scrolled down" etc. for quick commands

    # --- AI brain ---
    "smart_media_listening": True, # while a video/song plays, raise the mic bar by how loud the video leaks in
    "end_of_speech_s": 0.8,        # quiet needed before a phrase counts as finished
    "continuation_wait_s": 1.5,    # an unfinished-sounding phrase waits this long for the rest
    "max_utterance_s": 20,
    "agent_name": "Snapy",         # users can rename their assistant; it answers to this name
    "android_wake_word": False,    # Android: listen for "Hey Snapy" in the background (opt-in)
    "app_limits": {},              # Real Count daily limits, {package: minutes} (off unless set)
    "break_screen": False,         # at a limit, show a 10-second breathing break (opt-in)
    "llm_model": "qwen3:1.7b",
    "ai_provider": "auto",         # local | cloud | auto (cloud when an API key is set and online)
    "cloud_provider": "gemini",    # gemini | openai | compatible
    "cloud_model": "",             # empty = provider default
    "cloud_base_url": "",          # for OpenAI-compatible endpoints
    "cloud_for_memory": False,     # memory learning stays on-device unless allowed
    "cloud_redact": True,          # mask emails, phone/card numbers, keys and user paths before anything goes to the cloud
    "cloud_preview_ack": False,    # the user has seen "what's sent" and allowed cloud calls (asked once, before the first one)
    "llm_keep_alive": "15m",       # unload the model from RAM after this much idle time
    "internet_tools": True,        # web search / weather when you ask for them

    # --- Memory & routine ---
    "memory_learning": True,       # learn durable facts from conversations
    "activity_tracking": False,    # opt-in (asked during onboarding): local app-usage tracking
    "activity_privacy": "standard",  # standard = app names + project/site names; all = also window titles
    "activity_exclude": ["keepass", "keepassxc", "1password", "bitwarden", "lastpass", "dashlane"],
    "activity_retention_days": 30,
    "break_reminder_minutes": 0,   # 0 = off; e.g. 50 = nudge after 50 min of continuous work
    "daily_greeting": True,
    "greeting_voice": False,       # speak the morning greeting (default: show a card)
    "start_at_login": False,
    "welcome_back": True,         # short "welcome back" after 3+ hours away
    "recap_time": "",              # e.g. "18:30" = offer an end-of-day recap then (empty = at work end)
    "morning_apps": [],            # extra apps for "start my day"
    "barge_in": True,             # interrupt Snap by talking over it (echo-guarded on speakers)

    # --- Attention (Windows Real Count) ---
    "attention_enabled": True,     # count Shorts/Reels/videos watched in the browser (counts only, on this PC)
    "attention_nudges": True,      # gentle nudges (max 1 / 20 min, never in calls); nothing is ever blocked
    "attention_read_urls": True,   # peek at the address bar for /shorts/ /reels/ hints (memory only, never stored)
    "attention_soft_limit": 0,     # chip turns amber at this many shorts/reels a day (0 = shared default)
    "attention_limits": {},        # daily soft limits per site, {"YouTube": minutes} (off unless set)
    "attention_bedtime": "",       # "23:00" wind-down nudge time ("" = shared default, "off" = none)
    "attention_weekly_report": True,  # Sunday attention report card, once a week

    # --- Gestures ---
    "gestures_enabled": False,     # camera stays off until the user turns gestures on

    # --- Camera / system ---
    "camera_index": 0,
    "show_camera_preview": True,
    "idle_sleep_seconds": 20,      # drop to low FPS after this long with no hand

    # --- Workspace ---
    "project_dir": "",             # folder used by "open project", "run project", "git status"
    "project_run_command": "",     # override (e.g. "npm run dev"); empty = auto-detect

    # --- Phone sync (src/sync) ---
    "sync_enabled": False,         # opt-in: pair a phone over the LAN, end-to-end encrypted, no server
    "sync_focus_to_phone": True,   # focus on the laptop also starts focus + DND on paired phones
}

_lock = threading.Lock()


def settings_dir():
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    path = os.path.join(base, "SnapAir") if os.environ.get("APPDATA") else os.path.join(base, ".snap-air")
    os.makedirs(path, exist_ok=True)
    return path


def settings_path():
    """SNAP_AIR_SETTINGS, else settings.json in settings_dir(). Resolved when a Settings is
    made (not at import), so a process (or a test) can point it elsewhere first."""
    return os.environ.get("SNAP_AIR_SETTINGS") or os.path.join(settings_dir(), "settings.json")


_FALSE_WORDS = {"", "0", "false", "no", "off", "none", "null"}


def coerce(key, v):
    """v converted to the type of DEFAULTS[key]; raises TypeError/ValueError when it can't be.
    Floats stay floats (they used to be stored as strings, e.g. "1.5", which other devices
    reading the synced settings profile reject), and "false"/"off" strings are False."""
    default = DEFAULTS[key]
    if isinstance(default, bool):
        if isinstance(v, str):
            return v.strip().lower() not in _FALSE_WORDS
        return bool(v)
    if isinstance(default, (int, float)):
        if isinstance(v, bool) or v is None:
            raise TypeError(f"{key} needs a number")
        f = float(v)
        if f != f or f in (float("inf"), float("-inf")):
            raise ValueError(f"{key} needs a finite number")
        return int(f) if isinstance(default, int) else f
    if isinstance(default, dict):
        if not isinstance(v, dict):
            raise TypeError(f"{key} needs an object")
        return dict(v)
    if isinstance(default, list):
        if isinstance(v, str):
            v = [w.strip().lower() for w in v.split(",") if w.strip()]
        if not isinstance(v, (list, tuple)):
            raise TypeError(f"{key} needs a list")
        return list(v)
    if v is None:
        raise TypeError(f"{key} needs text")
    return str(v)


class Settings:
    def __init__(self, path=None):
        self.path = path or settings_path()
        self.data = dict(DEFAULTS)
        self._listeners = []
        self._lock = threading.RLock()
        self.load()

    def load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                saved = json.load(f)
            for k, v in saved.items():
                if k in DEFAULTS:
                    try:
                        self.data[k] = coerce(k, v)      # also repairs values older builds stored as text
                    except (TypeError, ValueError):
                        pass                             # keep the default for a value of the wrong type
        except FileNotFoundError:
            pass
        except Exception as e:
            print("[Settings] Could not read settings, using defaults:", e)

    def save(self):
        with self._lock, _lock:
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2, ensure_ascii=False)
            os.replace(tmp, self.path)

    def get(self, key):
        return self.data.get(key, DEFAULTS.get(key))

    def __getitem__(self, key):
        return self.get(key)

    def update(self, changes, persist=True):
        """Apply a dict of changes (unknown keys and wrong types are ignored). Thread-safe:
        the HUD, the voice thread and phone sync all change settings."""
        applied = {}
        with self._lock:
            for k, v in (changes or {}).items():
                if k not in DEFAULTS:
                    continue
                try:
                    v = coerce(k, v)
                except (TypeError, ValueError):
                    continue
                if self.data.get(k) != v:
                    self.data[k] = v
                    applied[k] = v
            if applied and persist:
                self.save()
        if applied:
            for cb in list(self._listeners):        # outside the lock: listeners may update settings
                try:
                    cb(applied)
                except Exception as e:
                    print("[Settings] listener error:", e)
        return applied

    def on_change(self, cb):
        self._listeners.append(cb)

    def as_dict(self):
        with self._lock:
            return dict(self.data)
