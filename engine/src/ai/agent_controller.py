"""Snapy command agent: turns spoken/typed phrases into desktop actions.

Tier 0 is a deterministic command grammar (instant, offline, predictable).
Tier 1 (optional) asks a local Ollama model to rewrite an unrecognised phrase
into one of the supported commands - it never runs arbitrary actions.

Unrecognised speech does nothing (it does NOT open a web search), so normal
conversation near the microphone can't trigger random actions.
"""
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.parse
import webbrowser

import requests

from src.os_control import windows as win
from src.os_control.apps import AppIndex
from src.os_control import keys as K
from src import core_loader as core
from src import diag  # noqa: E402

NUMBER_WORDS = core.config("vocab.numbers.count", {}) or {}        # core/rules/vocab.json

WEBSITES = {
    "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com",
    "google": "https://www.google.com", "github": "https://github.com",
    "chatgpt": "https://chat.openai.com", "claude": "https://claude.ai",
    "netflix": "https://www.netflix.com", "twitter": "https://x.com", "x": "https://x.com",
    "linkedin": "https://www.linkedin.com", "reddit": "https://www.reddit.com",
    "whatsapp": "https://web.whatsapp.com", "google drive": "https://drive.google.com",
    "drive": "https://drive.google.com", "google docs": "https://docs.google.com",
    "maps": "https://maps.google.com", "google maps": "https://maps.google.com",
    "calendar": "https://calendar.google.com", "stack overflow": "https://stackoverflow.com",
    "amazon": "https://www.amazon.com", "instagram": "https://www.instagram.com",
    "facebook": "https://www.facebook.com", "wikipedia": "https://www.wikipedia.org",
}

KEY_NAMES = {
    "enter": "enter", "return": "enter", "escape": "esc", "esc": "esc", "tab": "tab",
    "space": "space", "spacebar": "space", "backspace": "backspace", "delete": "delete",
    "up": "up", "down": "down", "left": "left", "right": "right", "home": "home", "end": "end",
    "page up": "pageup", "page down": "pagedown", "control": "ctrl", "ctrl": "ctrl",
    "shift": "shift", "alt": "alt", "windows": "win", "win": "win", "insert": "insert",
    **{f"f{i}": f"f{i}" for i in range(1, 13)},
}

# Whisper hallucinates these on noise/silence (core/rules/vocab.json)
HALLUCINATIONS = set(core.config("vocab.hallucinations", []) or [])


# ---------------------------------------------------------------- shared parsing (core/README.md)
def normalize_text(text):
    t = text.lower().strip()
    t = t.replace("’", "'").replace("-", " ")
    t = re.sub(r"[\"“”.,!?;:()]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def sound_key(word):
    """Rough phonetic key so Whisper's spellings of a name match ("Meera" ~ "Mira")."""
    w = word.lower()
    for x, y in core.config("vocab.wake.phonetic", []) or []:
        w = w.replace(x, y)
    w = re.sub(r"(.)\1+", r"\1", w)
    return re.sub(r"h$", "", w)


def wake_variants(agent_name="Snapy", wake_words=None):
    words = set(wake_words or [])
    name = normalize_text(agent_name or "")
    names = {name, name.replace(" ", "")} if name else set()
    builtin = set(core.config("vocab.wake.builtin", []) or [])
    # longest first; equal lengths alphabetically (deterministic on every runtime)
    return sorted({normalize_text(w) for w in words} | builtin | names, key=lambda v: (-len(v), v))


def strip_wake(text, agent_name="Snapy", wake_words=None):
    """-> (heard_wake_word, remaining normalised text). The wake word may follow up to two
    filler words; custom names are fuzzy-matched by sound."""
    norm = normalize_text(text)
    filler = "^" + core.fragment("wake_filler")
    suffix = re.escape(core.config("vocab.wake.optional_suffix", " air"))
    for v in wake_variants(agent_name, wake_words):
        m = re.match(filler + re.escape(v) + "(?:" + suffix + r")?\b\s*(.*)$", norm, re.ASCII)
        if m:
            return True, m.group(1).strip()
    name = normalize_text(agent_name or "")
    builtin = set(core.config("vocab.wake.builtin", []) or [])
    if name and name not in builtin and len(name) >= int(core.config("vocab.wake.fuzzy_min_name_len", 4)):
        import difflib
        m = re.match(filler + r"(\S+(?: \S+)?)\s*(.*)$", norm, re.ASCII)
        if m:
            cand_words = m.group(1).split()
            ratio = float(core.config("vocab.wake.fuzzy_min_ratio", 0.8))
            for k in (len(name.split()), 1):
                cand = " ".join(cand_words[:k])
                if difflib.SequenceMatcher(None, sound_key(cand), sound_key(name)).ratio() >= ratio:
                    return True, (" ".join(cand_words[k:]) + " " + m.group(2)).strip()
    return False, norm


def plain(cmd):
    """'can you please open youtube' -> 'open youtube' (the rules expect plain commands)."""
    out = core.strip("polite_prefix", cmd).strip()
    out = core.strip("polite_suffix", out).strip()
    return out or cmd


def plain_original(original):
    out = core.strip("polite_prefix_original", original)
    return out.strip() or original


def ordinal(cmd):
    """Which result the user wants: 'play arijit songs, the 4th video' -> ('play arijit songs', 4),
    'play the second result of lofi' -> ('play lofi', 2), 'video number 3' -> 3."""
    words = core.config("ordinals", {}) or {}
    for _, m in core.matches("ordinal", cmd):
        tok = m.group("n")
        n = int(tok) if tok.isdigit() else words.get(tok)
        keep = m.groupdict().get("keep") or ""
        rest = re.sub(r"\s+", " ", cmd[:m.start()] + keep + " " + cmd[m.end():]).strip(" ,")
        if n and rest:
            return rest, n
    return cmd, None


def play_request(cmd):
    """Music/video requests, always using the user's own words as the search:
    'open youtube and play some hindi music', 'listen to hindi romantic songs',
    'hindi gaane chalao', 'arijit singh ke gaane bajao', 'play X on youtube'."""
    topicless = set(core.domain("play_topicless_words")) | set((core.config("ordinals", {}) or {}).keys())
    reject = set(core.domain("play_reject"))
    for _, m in core.matches("play", cmd):
        q = core.strip("play_filler_prefix", m.group("q").strip())
        q = core.strip("play_suffix", q).strip()
        q = core.rewrite("play_fixes", q)         # speech recognition hears "Hindi" as "Hindu"
        # "play the 4th video" with no topic = click it on the current screen, not a new search
        if all(w in topicless or w.isdigit() for w in q.split()):
            return None
        if q and q not in reject:
            return q
    return None


class Result:
    def __init__(self, ok, message, action=None):
        self.ok, self.message, self.action = ok, message, action

    def __repr__(self):
        return f"Result({self.ok}, {self.message!r})"


class OSActions:
    """Every side effect goes through here (swapped for a fake in tests)."""

    def __init__(self):
        import pyautogui
        pyautogui.FAILSAFE = False
        pyautogui.PAUSE = 0
        self.pg = pyautogui

    def hotkey(self, *keys):
        k_set = {str(k).lower() for k in keys}
        if "win" in k_set and "ctrl" in k_set and "o" in k_set:
            return
        win.ensure_target_focus()
        self.pg.hotkey(*keys)

    def press(self, key, times=1):
        win.ensure_target_focus()
        for _ in range(times):
            self.pg.press(key)

    def media(self, key, times=1):
        for _ in range(times):
            self.pg.press(key)  # media keys are global: no focus needed

    def wheel(self, delta):
        win.ensure_target_focus()
        self.pg.scroll(int(delta))

    def lock(self):
        import ctypes
        ctypes.windll.user32.LockWorkStation()

    def hwheel(self, delta):
        win.ensure_target_focus()
        self.pg.hscroll(int(delta))

    def click(self, button="left", double=False):
        if double:
            self.pg.doubleClick()
        else:
            self.pg.click(button=button)

    def mouse_down(self):
        self.pg.mouseDown()

    def mouse_up(self):
        self.pg.mouseUp()

    def type_text(self, text):
        win.ensure_target_focus()
        if text.isascii():
            self.pg.write(text, interval=0.005)
        else:  # pyautogui can't type unicode: go through the clipboard
            import pyperclip
            old = pyperclip.paste()
            pyperclip.copy(text)
            self.pg.hotkey("ctrl", "v")
            time.sleep(0.15)
            pyperclip.copy(old)

    def clipboard(self):
        import pyperclip
        return pyperclip.paste()

    def open_url(self, url):
        webbrowser.open(url)

    def launch(self, apps, target):
        apps.launch(target)

    def focus_window(self, hwnd):
        return win.focus(hwnd)

    def find_window(self, name):
        return win.find_window(name)

    def list_windows(self):
        return win.list_windows()

    def window_cmd(self, cmd):
        return win.show_window(cmd)

    def run_terminal(self, command, cwd):
        flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
        if command:
            subprocess.Popen(["powershell.exe", "-NoExit", "-Command", command], cwd=cwd, creationflags=flags)
        else:
            try:
                subprocess.Popen(["wt.exe", "-d", cwd], cwd=cwd)
            except FileNotFoundError:
                subprocess.Popen(["powershell.exe", "-NoExit"], cwd=cwd, creationflags=flags)

    # characters cmd.exe acts on inside a .cmd/.bat launcher's arguments (VS Code's "code" is code.cmd)
    _CMD_META = set('"%^&|<>!\r\n')

    def open_editor(self, path):
        """Open a folder in the first installed editor (app.json "dev.editor_commands"), else
        Explorer. No shell: the folder is one argument and never parsed as a command line."""
        from src import appdata
        path = os.path.abspath(path)
        for exe in appdata.get("dev.editor_commands", []) or []:
            full = shutil.which(exe)
            if not full:
                continue                     # not installed: try the next one (shell=True never failed here)
            if full.lower().endswith((".cmd", ".bat")) and self._CMD_META & set(path):
                diag.record("agent.open_editor_unsafe_path", None, quiet=True, editor=exe)
                continue
            try:
                subprocess.Popen([full, path], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                return exe
            except OSError as e:
                diag.record("agent.open_editor", e, quiet=True, editor=exe)
        os.startfile(path)
        return "explorer"


class AgentController:
    def __init__(self, settings=None, os_actions=None, app_index=None):
        self.settings = settings
        self.os = os_actions or OSActions()
        self.apps = app_index or AppIndex()
        self.ui_callback = None
        self.notes_callback = None
        self.gesture_callback = None   # fn(paused: bool)
        self.voice_callback = None     # fn(mode: str)
        self.last_command = None
        self.on_ui = None              # fn(message) -> HUD (quit, emoji burst…)
        self.autoscroll_dir = 0
        self.autoscroll_speed = 1.0
        self._autoscroll_thread = None
        self.commands = self._build_commands()

    # ---------------------------------------------------------------- wiring
    def set_callbacks(self, notes_callback=None, ui_callback=None, gesture_callback=None,
                      voice_callback=None):
        self.notes_callback = notes_callback or self.notes_callback
        self.ui_callback = ui_callback or self.ui_callback
        self.gesture_callback = gesture_callback or self.gesture_callback
        self.voice_callback = voice_callback or self.voice_callback

    def _s(self, key, default=None):
        if self.settings is None:
            return default
        v = self.settings.get(key)
        return default if v is None else v

    def _ui(self, action, **data):
        if self.ui_callback:
            self.ui_callback(action, **data) if data else self.ui_callback(action)

    # ------------------------------------------------------------ text utils
    @staticmethod
    def normalize(text):
        return normalize_text(text)

    BUILTIN_WAKE = set(core.config("vocab.wake.builtin", []) or [])

    @property
    def agent_name(self):
        return (self._s("agent_name", "Snapy") or "Snapy").strip()

    def wake_variants(self):
        return wake_variants(self.agent_name, self._s("wake_words", ["snapy", "snap"]))

    def strip_wake_word(self, text):
        """Returns (heard_wake_word, remaining_text). Accepts it in the first
        few words ("uh, snapy, ..."), and fuzzy-matches custom names because
        Whisper spells uncommon names in different ways ("Meera" -> "Mira")."""
        return strip_wake(text, self.agent_name, self._s("wake_words", ["snapy", "snap"]))

    @staticmethod
    def _sound(word):
        return sound_key(word)

    def strip_wake_original(self, raw):
        """Remove the wake word from the original text (keeps casing for notes/typing)."""
        heard, rest = self.strip_wake_word(raw)
        if not heard:
            return raw.strip()
        words = raw.strip().split()
        n_rest = len(rest.split())
        return " ".join(words[len(words) - n_rest:]) if n_rest else ""

    @staticmethod
    def parse_count(s, default=1):
        s = (s or "").strip()
        if not s:
            return default
        m = re.search(r"\d+", s)
        if m:
            return max(1, min(50, int(m.group())))
        for w, n in NUMBER_WORDS.items():
            if re.search(r"\b" + w + r"\b", s):
                return n
        if re.search(r"\b(a lot|lots|much|way)\b", s):
            return 3
        if re.search(r"\b(a bit|a little|little|slightly)\b", s):
            return 0.4
        return default

    @staticmethod
    def payload(original, pattern):
        """Pull free text (note, search query...) out of the original-cased text."""
        m = re.search(pattern, original, re.I)
        if not m:
            return ""
        return m.group(m.lastindex or 0).strip().rstrip(".!?").strip()

    # ------------------------------------------------------------- execution
    def execute_intent(self, text, require_wake=False):
        """Run a phrase. With require_wake=True the phrase must contain the wake
        word (used for always-on listening) - otherwise it's ignored."""
        raw = (text or "").strip()
        heard_wake, cmd = self.strip_wake_word(raw)
        if require_wake and not heard_wake:
            return Result(False, "", "ignored")
        if cmd in HALLUCINATIONS and not heard_wake:
            return Result(False, "", "ignored")
        if heard_wake and not cmd:
            return Result(True, "Listening for a command…", "wake")

        # Payload text keeps original casing, minus the wake word
        original = self.strip_wake_original(raw)

        cmd, original = self._plain(cmd), self._plain_original(original)
        special = self._special(cmd)
        if special:
            return special
        cmd_wo, nth = self._ordinal(cmd)
        play = self._play_request(cmd_wo)
        if play:
            self.play_youtube(play, nth) if nth and nth > 1 else self.play_youtube(play)
            which = f" (result {nth})" if nth and nth > 1 else ""
            result = Result(True, f'Playing "{play}" on YouTube{which}', "youtube")
            self.last_command = (cmd, original)
            return result
        result = self._run(cmd, original)
        if result is None:
            result = self._try_compound(cmd, original)
        if result is None and self._s("use_ollama", False):
            mapped = self._ask_ollama(cmd)
            if mapped and self.normalize(mapped) != cmd:
                result = self._run(self.normalize(mapped), mapped)
                if result:
                    result.message += f'  (understood as "{mapped}")'
        if result is None:
            return Result(False, f'Didn\'t understand "{cmd}". Say "Snapy, help" for commands.', "unknown")
        if result.action not in ("repeat", "help", "wake"):
            self.last_command = (cmd, original)
        return result

    def _plain(self, cmd):
        """'can you please open youtube' -> 'open youtube' (the rules expect plain commands)."""
        return plain(cmd)

    def _plain_original(self, original):
        return plain_original(original)

    QUIT = re.compile(r"(?:close|quit|exit|shut ?down|turn off|stop|band karo|band ho ja(?:o)?|band kar do)"
                      r"(?: (?:yourself|snapy|snappy|snap|the assistant|the app|assistant))?(?: now| please)?")
    EMOJI = re.compile(r"(?:.*\b)?(?:emoji|emojis|emoticons|smileys)\b.*")

    def _special(self, cmd):
        """Snapy-level actions: quit itself, emoji burst."""
        name = self.normalize(self.agent_name)
        if self.QUIT.fullmatch(cmd) and (cmd.split()[0] in ("quit", "exit", "shutdown", "shut", "band") or
                                         re.search(r"yourself|snapy|snappy|snap\b|assistant|the app|" + re.escape(name), cmd)):
            if self.on_ui:
                self.on_ui({"type": "ui_action", "action": "quit"})
            return Result(True, f"Closing {self.agent_name}. See you soon!", "quit")
        if self.EMOJI.fullmatch(cmd) and re.search(r"\b(show|render|display|put|throw|send|rain|shower|draw|dikhao|"
                                                   r"bhejo|karo|some|good|nice|cool)\b", cmd):
            from src import appdata
            sets = appdata.get("emoji_sets", {}) or {}
            chosen = next((v for k, v in sets.items() if k != "default" and re.search(rf"\b(?:{k})", cmd)), sets.get("default", []))
            if self.on_ui:
                self.on_ui({"type": "ui_action", "action": "emoji", "emojis": chosen})
            return Result(True, "Here you go! " + " ".join(chosen[:4]), "emoji")
        return None

    @staticmethod
    def _ordinal(cmd):
        return ordinal(cmd)

    @staticmethod
    def _play_request(cmd):
        return play_request(cmd)

    def _run(self, cmd, original):
        for pattern, fn in self.commands:
            m = re.fullmatch(pattern, cmd)
            if m:
                try:
                    r = fn(m, original)
                except Exception as e:
                    return Result(False, f"Failed: {e}", "error")
                if r is not None:
                    return r
        return None

    def _try_compound(self, cmd, original):
        """"open youtube and play lofi" / "go back then scroll down" """
        for sep in (" and then ", " then ", " and "):
            if sep in cmd:
                parts = cmd.split(sep)
                oparts = re.split(re.escape(sep.strip()), original, flags=re.I)
                results = []
                for i, part in enumerate(parts):
                    op = oparts[i] if len(oparts) == len(parts) else part
                    r = self._run(part.strip(), op.strip())
                    if r is None:
                        break
                    results.append(r)
                    time.sleep(0.6)  # let the previous action (app/page) settle
                else:
                    return Result(all(r.ok for r in results), " → ".join(r.message for r in results), "compound")
        return None

    # -------------------------------------------------------------- commands
    def _build_commands(self):
        C = []

        def cmd(pattern):
            def deco(fn):
                C.append((pattern, fn))
                return fn
            return deco

        o = self.os
        step = lambda: int(self._s("voice_scroll_amount", 5)) * 120  # noqa: E731

        # ---- keyboard: named Windows actions and bare key combos come first, so
        # "open voice typing" or "windows plus h" never fall into the app launcher
        @cmd(r"(.+)")
        def _(m, orig):
            hit = K.find_shortcut(m.group(1))
            if hit:
                keys, label = hit
                o.hotkey(*keys)
                return Result(True, f"{label} ({K.describe(keys)})", "key")
            combo = K.parse_combo(m.group(1), require_modifier=True)
            if combo:
                return self.press_combo(combo)
            return None

        # ---- repeat / cancel
        @cmd(r"(again|repeat|do that again|one more time|more)")
        def _(m, orig):
            if not self.last_command:
                return Result(False, "Nothing to repeat yet", "repeat")
            r = self._run(*self.last_command)
            return r or Result(False, "Nothing to repeat", "repeat")

        @cmd(r"(cancel|never mind|nevermind|nothing|ignore that)")
        def _(m, orig):
            return Result(True, "Cancelled", "cancel")

        # ---- scrolling
        @cmd(r"(?:keep scrolling|auto scroll|start scrolling|scroll slowly)(?: (up|down))?")
        def _(m, orig):
            self.start_autoscroll(-1 if (m.group(1) or "down") == "down" else 1)
            return Result(True, "Auto-scrolling — say \"Snapy, stop\" (or faster/slower)", "autoscroll")

        @cmd(r"(stop|stop scrolling|stop it|halt|freeze)")
        def _(m, orig):
            was = self.autoscroll_dir != 0
            self.stop_autoscroll()
            return Result(True, "Stopped scrolling" if was else "Stopped", "stop")

        @cmd(r"(faster|speed up|scroll faster)")
        def _(m, orig):
            self.autoscroll_speed = min(6.0, self.autoscroll_speed * 1.6)
            return Result(True, f"Scroll speed {self.autoscroll_speed:.1f}x", "speed")

        @cmd(r"(slower|slow down|scroll slower)")
        def _(m, orig):
            self.autoscroll_speed = max(0.25, self.autoscroll_speed / 1.6)
            return Result(True, f"Scroll speed {self.autoscroll_speed:.1f}x", "speed")

        @cmd(r"page (up|down)")
        def _(m, orig):
            o.press("pageup" if m.group(1) == "up" else "pagedown")
            return Result(True, f"Page {m.group(1)}", "scroll")

        @cmd(r"(?:scroll |move |go )?(up|down)(?: (.+?))?(?: times)?")
        def _(m, orig):
            amount_words = m.group(2) or ""
            if amount_words and not re.search(r"\d|one|two|three|four|five|six|seven|eight|nine|ten|"
                                              r"once|twice|couple|few|lot|bit|little|much|more|slightly|to|too|for",
                                              amount_words):
                return None
            n = self.parse_count(amount_words)
            self.stop_autoscroll()
            d = 1 if m.group(1) == "up" else -1
            o.wheel(d * int(step() * n))
            return Result(True, f"Scrolled {m.group(1)}" + (f" ×{n:g}" if n != 1 else ""), "scroll")

        @cmd(r"(?:scroll |go |jump )?(?:to )?(?:the )?(top|bottom|beginning|end)(?: of (?:the )?page)?")
        def _(m, orig):
            top = m.group(1) in ("top", "beginning")
            o.hotkey("ctrl", "home" if top else "end")
            return Result(True, "Jumped to top" if top else "Jumped to bottom", "scroll")

        @cmd(r"(?:scroll )?(left|right)(?: (.+?))?")
        def _(m, orig):
            if m.group(2) and not re.search(r"\d|bit|lot|little", m.group(2)):
                return None
            d = 1 if m.group(1) == "right" else -1
            o.hwheel(d * step())
            return Result(True, f"Scrolled {m.group(1)}", "scroll")

        # ---- mouse by voice (point with your hand, click with your voice)
        @cmd(r"(?:left )?click|click (?:it|that|here)|tap")
        def _(m, orig):
            o.click()
            return Result(True, "Clicked", "click")

        @cmd(r"double click|double tap")
        def _(m, orig):
            o.click(double=True)
            return Result(True, "Double-clicked", "click")

        @cmd(r"right click|context menu")
        def _(m, orig):
            o.click("right")
            return Result(True, "Right-clicked", "click")

        @cmd(r"(?:hold|grab|press and hold|start drag(?:ging)?)(?: (?:it|that|here|click))?")
        def _(m, orig):
            o.mouse_down()
            return Result(True, "Holding — move your hand, then say \"Snapy, release\"", "hold")

        @cmd(r"(?:release|let go|drop(?: it)?)")
        def _(m, orig):
            o.mouse_up()
            return Result(True, "Released", "release")

        # ---- app & tab switching
        @cmd(r"(?:switch|alt tab|switch app|switch apps|switch window|next app|next window|other app|last app|previous app|switch back)")
        def _(m, orig):
            o.hotkey("alt", "tab")
            return Result(True, "Switched app", "switch")

        @cmd(r"(?:switch|go|change|jump|move)(?: the)?(?: window| app| screen| tab)? (?:over )?to (?:the )?(.+?)(?: app| window| ide)?|(.+?) (?:pe|par) (?:jao|chalo|switch karo)")
        def _(m, orig):
            name = m.group(1) or m.group(2)
            if name in ("next tab", "previous tab", "last tab"):
                return None
            tabm = re.fullmatch(r"tab (\w+)", name)
            if tabm:
                n = self.parse_count(tabm.group(1), None)
                if n:
                    o.hotkey("ctrl", "9" if n >= 9 else str(int(n)))
                    return Result(True, f"Tab {int(n)}", "tab")
            found = o.find_window(name)
            if found:
                o.focus_window(found[0])
                return Result(True, f"Switched to {found[1][:60]}", "focus")
            # Not open: offer to launch it instead
            app = self.apps.find(name)
            if app:
                o.launch(self.apps, app[1])
                return Result(True, f"{app[0].title()} wasn't open — launching it", "launch")
            return Result(False, f"No open window matches \"{name}\"", "focus")

        @cmd(r"(?:next tab|switch tab|tab switch|tab|change tab|tab right)")
        def _(m, orig):
            o.hotkey("ctrl", "tab")
            return Result(True, "Next tab", "tab")

        @cmd(r"(?:previous tab|prev tab|last tab|back tab|tab left)")
        def _(m, orig):
            o.hotkey("ctrl", "shift", "tab")
            return Result(True, "Previous tab", "tab")

        @cmd(r"(?:new tab|open (?:a )?new tab|open tab)")
        def _(m, orig):
            o.hotkey("ctrl", "t")
            return Result(True, "New tab", "tab")

        @cmd(r"close (?:this |the )?tab")
        def _(m, orig):
            o.hotkey("ctrl", "w")
            return Result(True, "Closed tab", "tab")

        @cmd(r"(?:reopen|restore|undo close) (?:the )?(?:closed |last )?tab")
        def _(m, orig):
            o.hotkey("ctrl", "shift", "t")
            return Result(True, "Reopened tab", "tab")

        @cmd(r"(?:go )?back|previous page")
        def _(m, orig):
            o.hotkey("alt", "left")
            return Result(True, "Back", "nav")

        @cmd(r"(?:go )?forward|next page")
        def _(m, orig):
            o.hotkey("alt", "right")
            return Result(True, "Forward", "nav")

        @cmd(r"(?:refresh|reload)(?: (?:the )?page)?")
        def _(m, orig):
            o.press("f5")
            return Result(True, "Refreshed", "nav")

        @cmd(r"zoom (in|out|reset)|reset zoom")
        def _(m, orig):
            g = m.group(1) or "reset"
            o.hotkey("ctrl", {"in": "=", "out": "-", "reset": "0"}[g])
            return Result(True, f"Zoom {g}", "zoom")

        @cmd(r"(?:full ?screen|exit full ?screen|toggle full ?screen)")
        def _(m, orig):
            o.press("f11")
            return Result(True, "Toggled full screen", "window")

        # ---- window management
        @cmd(r"(?:minimi[sz]e all|show (?:the )?desktop|hide (?:all )?windows|clear (?:the )?screen)")
        def _(m, orig):
            o.hotkey("win", "d")
            return Result(True, "Showing desktop", "window")

        @cmd(r"minimi[sz]e(?: (?:this|the))?(?: window| app)?")
        def _(m, orig):
            o.window_cmd(win.SW_MINIMIZE)
            return Result(True, "Minimized window", "window")

        @cmd(r"maximi[sz]e(?: (?:this|the))?(?: window| app)?")
        def _(m, orig):
            o.window_cmd(win.SW_MAXIMIZE)
            return Result(True, "Maximized window", "window")

        @cmd(r"(?:restore|unmaximi[sz]e)(?: (?:this|the))?(?: window)?")
        def _(m, orig):
            o.window_cmd(win.SW_RESTORE)
            return Result(True, "Restored window", "window")

        @cmd(r"(?:snap|move|put)(?: (?:this|the))?(?: window)? (?:to the )?(left|right)")
        def _(m, orig):
            o.hotkey("win", m.group(1))
            return Result(True, f"Snapped window {m.group(1)}", "window")

        @cmd(r"close (?:this |the )?(?:window|app)")
        def _(m, orig):
            o.hotkey("alt", "f4")
            return Result(True, "Closed window", "window")

        @cmd(r"(?:task view|show (?:all )?windows|all windows)")
        def _(m, orig):
            o.hotkey("win", "tab")
            return Result(True, "Task view", "window")

        @cmd(r"(next|previous) desktop")
        def _(m, orig):
            o.hotkey("ctrl", "win", "right" if m.group(1) == "next" else "left")
            return Result(True, f"{m.group(1).title()} desktop", "window")

        @cmd(r"(?:take a )?(?:screenshot|screen shot|capture (?:the )?screen|snip)")
        def _(m, orig):
            o.hotkey("win", "shift", "s")
            return Result(True, "Snipping tool — drag to capture", "window")

        @cmd(r"lock (?:the |my )?(?:screen|computer|pc|laptop|system)|lock it")
        def _(m, orig):
            o.lock()     # Win+L can't be simulated; Windows' LockWorkStation API works
            return Result(True, "Locked", "window")

        # ---- editing / keyboard
        for pat, keys, label in [
            (r"copy(?: (?:this|that|it))?", ("ctrl", "c"), "Copied"),
            (r"paste(?: (?:it|that|here))?", ("ctrl", "v"), "Pasted"),
            (r"cut(?: (?:this|that|it))?", ("ctrl", "x"), "Cut"),
            (r"undo(?: that)?", ("ctrl", "z"), "Undo"),
            (r"redo(?: that)?", ("ctrl", "y"), "Redo"),
            (r"select all", ("ctrl", "a"), "Selected all"),
            (r"save(?: (?:it|this|file|the file))?", ("ctrl", "s"), "Saved"),
        ]:
            C.append((pat, (lambda k, lbl: lambda m, orig: (o.hotkey(*k), Result(True, lbl, "edit"))[1])(keys, label)))

        @cmd(r"(?:press|hit|push|tap) (.+)")
        def _(m, orig):
            combo = K.parse_combo(m.group(0))
            if not combo:
                return Result(False, f"I don't know the key \"{m.group(1)}\" — try e.g. \"press control shift t\".", "key")
            return self.press_combo(combo)

        @cmd(r"(?:type|write|dictate) (.+)")
        def _(m, orig):
            if re.match(r"(a )?note\b", m.group(1)):
                return None   # "write a note ..." is a note, not typing
            text = self.payload(orig, r"^\W*(?:type|write|dictate)\W+(.+)$") or m.group(1)
            o.type_text(text)
            return Result(True, f"Typed \"{text[:40]}\"", "type")

        @cmd(r"(?:find|search (?:the )?page for|find on page) (.+)")
        def _(m, orig):
            text = self.payload(orig, r"(?:find on page|search (?:the )?page for|find)\W+(.+)$") or m.group(1)
            o.hotkey("ctrl", "f")
            time.sleep(0.15)
            o.type_text(text)
            return Result(True, f"Finding \"{text}\"", "find")

        @cmd(r"new line|next line")
        def _(m, orig):
            o.press("enter")
            return Result(True, "New line", "key")

        # ---- media
        @cmd(r"(?:play|pause|resume|play pause|pause (?:the )?(?:video|music|song)|play (?:the )?(?:video|music)|toggle play)")
        def _(m, orig):
            o.media("playpause")
            return Result(True, "Play/Pause", "media")

        @cmd(r"(?:next|skip)(?: (?:song|track|video))?|skip (?:this|it)")
        def _(m, orig):
            o.media("nexttrack")
            return Result(True, "Next track", "media")

        @cmd(r"(?:previous|last|prev) (?:song|track|video)")
        def _(m, orig):
            o.media("prevtrack")
            return Result(True, "Previous track", "media")

        @cmd(r"(?:turn (?:the )?)?(?:volume (up|down)|(?:turn it|turn) (up|down)|(louder)|(quieter|softer))(?: (?:by )?(.+?))?")
        def _(m, orig):
            up = bool(m.group(1) == "up" or m.group(2) == "up" or m.group(3))
            amount = m.group(5) or ""
            if not amount:
                presses = 5                         # each key press = 2%
            elif re.search(r"\blot\b|much|way", amount):
                presses = 10
            else:
                n = self.parse_count(amount, 10)
                presses = 2 if n < 1 else max(1, round(n / 2))   # "by 10" = 10%
            o.media("volumeup" if up else "volumedown", presses)
            return Result(True, f"Volume {'up' if up else 'down'} ({presses * 2}%)", "media")

        @cmd(r"(?:mute|unmute|toggle mute|silence)(?: (?:the )?(?:sound|audio|volume))?")
        def _(m, orig):
            o.media("volumemute")
            return Result(True, "Toggled mute", "media")

        # ---- youtube / spotify / web
        @cmd(r"(?:play|watch|put on) (.+?) on youtube|youtube (?:play |search )?(.+)|search youtube for (.+)|(?:open youtube and )?(?:play|watch) (.+?)(?: on youtube)?")
        def _(m, orig):
            query = next(g for g in m.groups() if g)
            if not ("youtube" in m.group(0)):
                return None   # plain "play X" without youtube is handled by media/spotify rules
            self.play_youtube(query)
            return Result(True, f"Playing \"{query}\" on YouTube", "youtube")

        @cmd(r"(?:play|put on) (.+?) on spotify")
        def _(m, orig):
            q = m.group(1)
            o.open_url("spotify:search:" + urllib.parse.quote(q))
            return Result(True, f"Searching Spotify for \"{q}\" — press play", "spotify")

        @cmd(r"(?:play|put on|watch) (?:some )?(.+)")
        def _(m, orig):
            q = m.group(1)
            if q in ("it", "that", "this", "music", "video", "the video", "the music"):
                return None
            self.play_youtube(q)
            return Result(True, f"Playing \"{q}\" on YouTube", "youtube")

        @cmd(r"(?:search|google|look up|search for|search google for) (.+)")
        def _(m, orig):
            q = self.payload(orig, r"(?:search google for|search for|search|google|look up)\W+(.+)$") or m.group(1)
            o.open_url("https://www.google.com/search?q=" + urllib.parse.quote(q))
            return Result(True, f"Searching Google for \"{q}\"", "search")

        # ---- developer workflow
        @cmd(r"open (?:my |the )?(?:project|workspace|code editor|editor)|open (?:the )?project in (?:vs )?code")
        def _(m, orig):
            d = self._project_dir()
            if not d:
                return self._need_project()
            used = o.open_editor(d)
            return Result(True, f"Opened {os.path.basename(d)} in {used}", "dev")

        @cmd(r"(?:run|start|launch) (?:my |the )?(?:project|app|server|dev server)")
        def _(m, orig):
            d = self._project_dir()
            if not d:
                return self._need_project()
            run = self._s("project_run_command", "") or self.detect_run_command(d)
            if not run:
                return Result(False, "Couldn't tell how to run this project — set a run command in Settings", "dev")
            o.run_terminal(run, d)
            return Result(True, f"Running `{run}` in {os.path.basename(d)}", "dev")

        @cmd(r"(?:run |show )?git (status|pull|log|diff)")
        def _(m, orig):
            d = self._project_dir()
            if not d:
                return self._need_project()
            sub = {"log": "log --oneline -15", "diff": "diff --stat"}.get(m.group(1), m.group(1))
            o.run_terminal(f"git {sub}", d)
            return Result(True, f"git {m.group(1)} in {os.path.basename(d)}", "dev")

        @cmd(r"(?:open|launch|start) (?:a |the |new )?(?:terminal|power ?shell|command line|console)")
        def _(m, orig):
            d = self._project_dir() or os.path.expanduser("~")
            o.run_terminal("", d)
            return Result(True, f"Terminal in {os.path.basename(d) or d}", "dev")

        # ---- Snapy itself
        @cmd(r"(?:open |show )?(?:snap(?: air)? |snapp?y |snappy's )?(?:settings|preferences|options|setting|configuration)|configure|customi[sz]e(?: snap(?: air)?)?")
        def _(m, orig):
            self._ui("open_settings")
            return Result(True, "Opened Snapy settings", "ui")

        @cmd(r"(?:close|hide) (?:the )?(?:settings|notes|guide|help|panel|panels|everything)")
        def _(m, orig):
            self._ui("close_panels")
            return Result(True, "Closed panels", "ui")

        @cmd(r"(?:open |show )(?:my )?(?:smart )?notes|notes")
        def _(m, orig):
            self._ui("open_notes")
            return Result(True, "Opened notes", "ui")

        @cmd(r"(?:take|add|make|write|save) (?:a )?note(?: (?:that|to|saying))?(?: (.+))?|note (?:down |that )?(.+)|remember (?:that |to )?(.+)")
        def _(m, orig):
            text = self.payload(orig, r"(?:take|add|make|write|save)\W+(?:a\W+)?note\W*(?:(?:that|to|saying)\W+)?(.+)$") \
                or self.payload(orig, r"note\W+(?:down\W+|that\W+)?(.+)$") \
                or self.payload(orig, r"remember\W+(?:that\W+)?(.+)$")
            if not text:
                return Result(False, "What should the note say? e.g. \"Snapy, take note buy milk\"", "note")
            if re.fullmatch(r"(?i)(the )?clipboard|what i copied", text):
                text = (o.clipboard() or "").strip()
                if not text:
                    return Result(False, "Clipboard is empty", "note")
            if self.notes_callback:
                self.notes_callback(text)
            return Result(True, f"Note saved: \"{text[:60]}\"", "note")

        @cmd(r"(?:help|what can (?:i|you) (?:say|do)|show (?:the )?(?:guide|commands|help)|(?:open |show )?(?:gesture )?guide|commands)")
        def _(m, orig):
            self._ui("open_guide")
            return Result(True, "Showing commands", "help")

        @cmd(r"(?:pause|stop|disable|turn off) (?:the )?(?:gestures?|tracking|hand tracking|mouse|camera)|gestures? off")
        def _(m, orig):
            if self.gesture_callback:
                self.gesture_callback(True)
            return Result(True, "Gestures paused — say \"Snapy, resume gestures\"", "gestures")

        @cmd(r"(?:resume|start|enable|turn on) (?:the )?(?:gestures?|tracking|hand tracking|mouse|camera)|gestures? on")
        def _(m, orig):
            if self.gesture_callback:
                self.gesture_callback(False)
            return Result(True, "Gestures resumed", "gestures")

        @cmd(r"(?:stop|pause) listening|(?:mute|turn off) (?:the )?(?:mic|microphone|voice)|go to sleep")
        def _(m, orig):
            if self.voice_callback:
                self.voice_callback("push")
            return Result(True, "Voice paused — press Ctrl+Alt+Space to talk", "voice")

        @cmd(r"(?:hide|show|toggle) (?:the )?(?:hud|overlay|bar)")
        def _(m, orig):
            self._ui("toggle_hud")
            return Result(True, "Toggled HUD", "ui")

        # ---- open apps / websites (last: most general)
        @cmd(r"(?:open|launch|start|run) (.+)")
        def _(m, orig):
            return self.open_anything(m.group(1))

        @cmd(r"(?:close|kill|exit|hide) (?:the )?(?:on[- ]?screen |touch )?keyboard")
        def _(m, orig):
            try:
                subprocess.run(["taskkill", "/f", "/im", "osk.exe"], capture_output=True,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            except Exception as e:
                diag.record("agent.close_osk", e, quiet=True)
            return Result(True, "Closed On-Screen Keyboard", "close")

        @cmd(r"close (.+)")
        def _(m, orig):
            found = o.find_window(m.group(1))
            if not found:
                return Result(False, f"No open window matches \"{m.group(1)}\"", "close")
            o.focus_window(found[0])
            o.hotkey("alt", "f4")
            return Result(True, f"Closed {found[1][:50]}", "close")

        return C

    # --------------------------------------------------------------- helpers
    def press_combo(self, combo):
        keys, times = combo["keys"], combo["times"]
        if tuple(keys) in K.BLOCKED:
            return Result(False, K.BLOCKED[tuple(keys)], "key")
        if len(keys) == 1:
            self.os.press(keys[0], int(times))
        else:
            for _ in range(int(times)):
                self.os.hotkey(*keys)
        return Result(True, "Pressed " + K.describe(keys) + (f" ×{times}" if times > 1 else ""), "key")

    def open_anything(self, name):
        name = name.strip()
        clean_target = name.lower()
        if any(b in clean_target for b in ("on-screen keyboard", "on screen keyboard", "touch keyboard", "osk")):
            return Result(False, "On-screen keyboard is disabled", "blocked")
        name = re.sub(r"^(the|my|a)\s+", "", name)
        name = re.sub(r"\s+(website|site|web site)$", "", name)
        # punctuation was stripped: "github com" / "github dot com" -> github.com
        name = re.sub(r"\s+dot\s+", ".", name)
        name = re.sub(r"^([\w-]+(?:\.[\w-]+)*) (com|org|net|io|dev|ai|app|in|co|co\.uk|edu|gov)$", r"\1.\2", name)
        if name in WEBSITES:
            self.os.open_url(WEBSITES[name])
            return Result(True, f"Opened {name.title()}", "web")
        if re.fullmatch(r"[\w-]+(\.[\w-]+)+(/\S*)?", name):
            self.os.open_url("https://" + name)
            return Result(True, f"Opened {name}", "web")
        app = self.apps.find(name)
        if app:
            # Already open? Bring it forward instead of starting a second copy.
            found = self.os.find_window(name)
            if found:
                self.os.focus_window(found[0])
                return Result(True, f"Switched to {found[1][:50]}", "focus")
            self.os.launch(self.apps, app[1])
            return Result(True, f"Opening {app[0].title()}", "launch")
        return Result(False, f"Couldn't find an app or site called \"{name}\"", "launch")

    def play_youtube(self, query, nth=1):
        """Open the n-th YouTube result directly (so it actually plays),
        falling back to the search results page."""
        from src import appdata
        url = appdata.get("web.youtube_search") + urllib.parse.quote(query)
        try:
            html = requests.get(url, timeout=3, headers={"User-Agent": "Mozilla/5.0",
                                                         "Accept-Language": "en-US,en;q=0.9"}).text
            ids = list(dict.fromkeys(re.findall(r'"videoRenderer":\{"videoId":"([\w-]{11})"', html))) or \
                list(dict.fromkeys(re.findall(r'"videoId":"([\w-]{11})"', html)))
            if ids:
                url = "https://www.youtube.com/watch?v=" + ids[min(max(1, int(nth)), len(ids)) - 1]
        except Exception as e:
            diag.record("agent.youtube_search", e, quiet=True)
        self.os.open_url(url)
        return url

    def _project_dir(self):
        d = (self._s("project_dir", "") or "").strip().strip('"')
        return d if d and os.path.isdir(d) else ""

    def _need_project(self):
        self._ui("open_settings", focus="project_dir")
        return Result(False, "Set your project folder in Snapy settings first", "dev")

    @staticmethod
    def detect_run_command(d):
        pj = os.path.join(d, "package.json")
        if os.path.exists(pj):
            try:
                with open(pj, encoding="utf-8") as f:
                    scripts = json.load(f).get("scripts", {})
            except Exception:
                scripts = {}
            pm = "pnpm" if os.path.exists(os.path.join(d, "pnpm-lock.yaml")) else \
                 "yarn" if os.path.exists(os.path.join(d, "yarn.lock")) else "npm"
            for script in ("dev", "start", "serve"):
                if script in scripts:
                    return f"{pm} start" if script == "start" else f"{pm} run {script}"
        if os.path.exists(os.path.join(d, "manage.py")):
            return "python manage.py runserver"
        for f in ("main.py", "app.py", "run.py"):
            if os.path.exists(os.path.join(d, f)):
                return f"python {f}"
        for f in ("run.bat", "run.ps1", "start.bat"):
            if os.path.exists(os.path.join(d, f)):
                return f".\\{f}"
        if os.path.exists(os.path.join(d, "Cargo.toml")):
            return "cargo run"
        if os.path.exists(os.path.join(d, "go.mod")):
            return "go run ."
        if os.path.exists(os.path.join(d, "pubspec.yaml")):
            return "flutter run"
        return ""

    # ------------------------------------------------------------ autoscroll
    def start_autoscroll(self, direction):
        self.autoscroll_dir = direction
        if self._autoscroll_thread and self._autoscroll_thread.is_alive():
            return
        self._autoscroll_thread = threading.Thread(target=self._autoscroll_loop, daemon=True)
        self._autoscroll_thread.start()

    def stop_autoscroll(self):
        self.autoscroll_dir = 0

    def _autoscroll_loop(self):
        acc = 0.0
        while self.autoscroll_dir:
            acc += 120 * 1.2 * self.autoscroll_speed * 0.05   # ~1.2 notches/sec at 1x
            if acc >= 30:
                self.os.wheel(self.autoscroll_dir * int(acc))
                acc -= int(acc)
            time.sleep(0.05)

    # ---------------------------------------------------------------- ollama
    def _ask_ollama(self, phrase):
        prompt = core.prompt("command_rewrite", phrase=phrase)
        try:
            from src import appdata
            r = requests.post(appdata.get("ollama.host") + "/api/generate", timeout=6, json={
                "model": self._s("ollama_model", "qwen2.5:3b"), "prompt": prompt, "stream": False,
                "options": {"temperature": 0, "num_predict": 20}})
            text = r.json().get("response", "").strip().splitlines()[0].strip().strip('"')
            return None if not text or "none" in text.lower() else text
        except Exception as e:
            diag.record("agent.ollama_rewrite", e, quiet=True)
            return None

    # ----------------------------------------------------------- catalogue
    @staticmethod
    def catalogue():
        """Shown in the HUD guide: what you can actually say."""
        return [
            ("Scrolling", ["scroll down / up", "scroll down 3 times", "scroll down a bit", "page down",
                           "go to top / bottom", "keep scrolling → faster / slower → stop", "again"]),
            ("Apps & windows", ["switch app", "switch to chrome", "open spotify", "open github",
                                "minimize / maximize", "snap left / right", "show desktop",
                                "close window", "task view", "next desktop"]),
            ("Browser & tabs", ["next tab / previous tab", "switch to tab 3", "new tab", "close tab",
                                "reopen tab", "go back / forward", "refresh", "zoom in / out",
                                "search for <anything>", "find <text on page>"]),
            ("Media", ["play lofi hip hop on youtube", "play <song> on spotify", "pause / play",
                       "next song", "volume up / down", "volume up by 10", "mute"]),
            ("Mouse & keyboard", ["click / double click / right click", "hold → release",
                                  "press enter", "press control shift t", "type <text>",
                                  "copy / paste / undo / save / select all"]),
            ("Developer", ["open project", "run project", "git status", "open terminal"]),
            ("Snapy", ["take note <text>", "note clipboard", "open notes", "open settings",
                          "pause gestures / resume gestures", "stop listening", "help"]),
        ]
