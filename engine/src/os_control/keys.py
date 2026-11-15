"""Full keyboard control by voice.

- Any combination: "press control shift escape", "windows plus h", "ctrl+alt+t",
  "alt f4", "hit f5 three times", or just "control c" / "windows v".
- Whisper often mishears single letters after a modifier ("window plus edge" =
  Win+H, "control see" = Ctrl+C); those are corrected.
- ~60 named Windows actions: "open voice typing", "clipboard history",
  "emoji panel", "task manager", "snap layouts", "new desktop", ...
"""
import re

MODIFIERS = {
    "control": "ctrl", "ctrl": "ctrl", "ctl": "ctrl", "contra": "ctrl", "controls": "ctrl",
    "alt": "alt", "alternate": "alt", "old": "alt", "all": "alt",
    "shift": "shift", "shifts": "shift",
    "windows": "win", "window": "win", "win": "win", "windows key": "win", "window key": "win", "start key": "win",
    "super": "win", "meta": "win",
}

KEYS = {
    "enter": "enter", "return": "enter", "escape": "esc", "esc": "esc", "tab": "tab", "space": "space",
    "spacebar": "space", "space bar": "space", "backspace": "backspace", "back space": "backspace",
    "delete": "delete", "del": "delete", "insert": "insert", "home": "home", "end": "end",
    "page up": "pageup", "page down": "pagedown", "pageup": "pageup", "pagedown": "pagedown",
    "up": "up", "down": "down", "left": "left", "right": "right",
    "up arrow": "up", "down arrow": "down", "left arrow": "left", "right arrow": "right",
    "arrow up": "up", "arrow down": "down", "arrow left": "left", "arrow right": "right",
    "print screen": "printscreen", "printscreen": "printscreen", "prt sc": "printscreen", "prtsc": "printscreen",
    "caps lock": "capslock", "capslock": "capslock", "num lock": "numlock", "scroll lock": "scrolllock",
    "pause": "pause", "break": "pause", "menu": "apps", "context menu key": "apps",
    "plus": "+", "minus": "-", "dash": "-", "equals": "=", "equal": "=", "comma": ",", "period": ".", "dot": ".",
    "full stop": ".", "slash": "/", "forward slash": "/", "backslash": "\\", "semicolon": ";", "colon": ":",
    "quote": "'", "apostrophe": "'", "backtick": "`", "grave": "`", "tilde": "~",
    "left bracket": "[", "right bracket": "]", "open bracket": "[", "close bracket": "]",
    "volume up": "volumeup", "volume down": "volumedown", "mute": "volumemute",
    "play pause": "playpause", "next track": "nexttrack", "previous track": "prevtrack",
}
for _i in range(1, 25):
    KEYS[f"f{_i}"] = f"f{_i}"
NUM_WORDS = {"one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
             "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "zero": "0", "won": "1", "to": "2", "too": "2",
             "for": "4", "ate": "8"}
for _w, _n in list(NUM_WORDS.items()):
    KEYS[f"f {_w}"] = f"f{_n}"
    KEYS[f"f{_w}"] = f"f{_n}"
    KEYS[f"function {_w}"] = f"f{_n}"

# How Whisper tends to spell single letters spoken after a modifier
LETTER_SOUNDS = {
    "a": "a", "ay": "a", "eh": "a", "b": "b", "bee": "b", "be": "b", "c": "c", "see": "c", "sea": "c", "si": "c",
    "d": "d", "dee": "d", "e": "e", "ee": "e", "f": "f", "eff": "f", "ef": "f", "g": "g", "gee": "g", "ji": "g",
    "h": "h", "aitch": "h", "edge": "h", "age": "h", "each": "h", "etch": "h", "itch": "h", "hedge": "h",
    "i": "i", "eye": "i", "j": "j", "jay": "j", "k": "k", "kay": "k", "l": "l", "el": "l", "ell": "l",
    "m": "m", "em": "m", "n": "n", "en": "n", "o": "o", "oh": "o", "p": "p", "pee": "p", "pea": "p",
    "q": "q", "queue": "q", "cue": "q", "kyu": "q", "r": "r", "are": "r", "ar": "r", "s": "s", "es": "s", "ess": "s",
    "t": "t", "tee": "t", "tea": "t", "u": "u", "you": "u", "v": "v", "vee": "v", "we": "v", "w": "w",
    "double you": "w", "double u": "w", "x": "x", "ex": "x", "y": "y", "why": "y", "wai": "y", "z": "z",
    "zed": "z", "zee": "z", "zet": "z",
}

# Named Windows actions (Windows 10/11)
SHORTCUTS = [
    (r"voice typing|dictation|voice type|speech typing", ("win", "h"), "Voice typing"),
    (r"clipboard(?: history)?|paste history", ("win", "v"), "Clipboard history"),
    (r"emoji(?:s)?(?: panel| picker| keyboard)?|emoticons?", ("win", "."), "Emoji panel"),
    (r"task manager", ("ctrl", "shift", "esc"), "Task Manager"),
    (r"run(?: dialog| box| window)?", ("win", "r"), "Run dialog"),
    (r"(?:windows |system |pc )settings", ("win", "i"), "Windows Settings"),
    (r"notifications?(?: (?:center|panel))?|notification centre|calendar flyout", ("win", "n"), "Notifications"),
    (r"quick settings|action cent(?:er|re)|control cent(?:er|re)", ("win", "a"), "Quick settings"),
    (r"widgets?", ("win", "w"), "Widgets"),
    (r"start(?: menu)?|windows menu", ("win",), "Start menu"),
    (r"windows search|search (?:bar|box)|start search", ("win", "s"), "Search"),
    (r"task view|timeline", ("win", "tab"), "Task view"),
    (r"new (?:virtual )?desktop|add (?:a )?desktop", ("ctrl", "win", "d"), "New desktop"),
    (r"close (?:this |the )?(?:virtual )?desktop", ("ctrl", "win", "f4"), "Closed desktop"),
    (r"snap layouts?|layouts", ("win", "z"), "Snap layouts"),
    (r"project(?:ion)?(?: screen)?|second screen|display mode|duplicate screen|extend screen", ("win", "p"), "Project"),
    (r"game bar|xbox bar", ("win", "g"), "Game Bar"),
    (r"(?:start |stop )?screen record(?:ing|er)?|record (?:the )?screen", ("win", "alt", "r"), "Screen recording"),
    (r"magnifier|zoom (?:in )?(?:on )?(?:the )?screen", ("win", "+"), "Magnifier"),
    (r"close magnifier|exit magnifier", ("win", "esc"), "Closed Magnifier"),
    (r"narrator|screen reader", ("ctrl", "win", "enter"), "Narrator"),
    (r"full screenshot|screenshot (?:of )?(?:the )?(?:whole|full|entire) screen|save (?:a )?screenshot", ("win", "printscreen"), "Screenshot saved to Pictures"),
    (r"file explorer|explorer|this pc|my computer", ("win", "e"), "File Explorer"),
    (r"copilot", ("win", "c"), "Copilot"),
    (r"cast|connect (?:to )?(?:a )?(?:display|screen|tv)", ("win", "k"), "Cast"),
    (r"accessibility(?: settings)?|ease of access", ("win", "u"), "Accessibility"),
    (r"system (?:info|information|properties)|about (?:this )?pc", ("win", "pause"), "System info"),
    (r"power (?:user )?menu|quick link menu|admin menu", ("win", "x"), "Power user menu"),
    (r"(?:keyboard |input )?language switch|switch (?:keyboard )?(?:layout|language)|change (?:keyboard )?language", ("win", "space"), "Switched input language"),
    (r"on[- ]?screen keyboard|touch keyboard", ("ctrl", "win", "o"), "On-screen keyboard"),
    (r"(?:open )?(?:the )?feedback hub", ("win", "f"), "Feedback Hub"),
    (r"restore (?:all )?(?:minimi[sz]ed )?windows|undo minimi[sz]e all", ("win", "shift", "m"), "Restored windows"),
    (r"minimi[sz]e everything|minimi[sz]e all windows", ("win", "m"), "Minimised everything"),
    (r"peek at (?:the )?desktop|desktop peek", ("win", ","), "Desktop peek"),
    (r"next (?:virtual )?desktop", ("ctrl", "win", "right"), "Next desktop"),
    (r"previous (?:virtual )?desktop", ("ctrl", "win", "left"), "Previous desktop"),
    (r"move (?:the )?window to (?:the )?(?:next|other) (?:monitor|screen|display)", ("win", "shift", "right"), "Moved window"),
    (r"rename(?: (?:this|it|file))?", ("f2",), "Rename"),
    (r"properties", ("alt", "enter"), "Properties"),
    (r"address bar|url bar", ("ctrl", "l"), "Address bar"),
    (r"print(?: this| page)?", ("ctrl", "p"), "Print"),
    (r"(?:open )?downloads? (?:page|list)|browser downloads", ("ctrl", "j"), "Downloads"),
    (r"(?:browser )?history", ("ctrl", "h"), "History"),
    (r"bookmark (?:this|the) page|add bookmark", ("ctrl", "d"), "Bookmarked"),
    (r"incognito(?: window)?|private window|inprivate", ("ctrl", "shift", "n"), "Private window"),
    (r"new window", ("ctrl", "n"), "New window"),
    (r"dev ?tools|developer tools|inspect element", ("f12",), "Developer tools"),
    (r"command palette", ("ctrl", "shift", "p"), "Command palette"),
    (r"(?:integrated |vs code )?terminal toggle|toggle (?:the )?terminal", ("ctrl", "`"), "Toggled terminal"),
    (r"quick open|go to file", ("ctrl", "p"), "Quick open"),
    (r"comment (?:this |the )?line|toggle comment", ("ctrl", "/"), "Toggled comment"),
    (r"format (?:the )?(?:document|file|code)", ("shift", "alt", "f"), "Formatted"),
    (r"save as", ("ctrl", "shift", "s"), "Save as"),
    (r"bold(?: text)?", ("ctrl", "b"), "Bold"), (r"italic(?:s)?", ("ctrl", "i"), "Italic"),
    (r"underline", ("ctrl", "u"), "Underline"),
    (r"redo", ("ctrl", "y"), "Redo"),
]
SHORTCUT_PREFIX = r"(?:(?:please )?(?:open|show|start|launch|turn on|toggle|bring up|pull up|use|do|activate|enable|go to)(?: the| my)? )?"


def _tokens(text):
    t = text.lower().strip()
    t = re.sub(r"^(?:please |can you |could you )?(?:press|hit|push|tap|type the shortcut|use the shortcut|do|key)\s+", "", t)
    # stray words Whisper puts before a modifier: "press one window plus edge", "press the control c"
    t = re.sub(r"^(?:the|a|an|one|on|un|in|uh|um)\s+(?=(?:windows?|win|control|ctrl|alt|shift|super)\b)", "", t)
    t = re.sub(r"[+,]", " ", t)
    t = re.sub(r"\b(plus|and|then|with|together|key|keys|button)\b", " ", t)
    t = re.sub(r"[.!?]+$", "", t)
    return re.sub(r"\s+", " ", t).strip()


def parse_combo(text, require_modifier=False):
    """'windows plus h' -> ['win','h']; returns None when the phrase isn't purely keys."""
    t = _tokens(text)
    if not t:
        return None
    times = 1
    tm = re.search(r"\s(\d+|two|three|four|five|twice|thrice) times$", t)
    if tm:
        times = {"two": 2, "twice": 2, "three": 3, "thrice": 3, "four": 4, "five": 5}.get(tm.group(1)) or int(tm.group(1))
        t = t[:tm.start()].strip()
    keys, rest = [], t
    names = sorted(set(MODIFIERS) | set(KEYS), key=len, reverse=True)
    while rest:
        for name in names:
            if rest == name or rest.startswith(name + " "):
                keys.append(MODIFIERS.get(name) or KEYS[name])
                rest = rest[len(name):].strip()
                break
        else:
            tok, _, rest2 = rest.partition(" ")
            two = " ".join(rest.split()[:2])
            if two in LETTER_SOUNDS and keys and keys[-1] in ("ctrl", "alt", "shift", "win"):
                keys.append(LETTER_SOUNDS[two]); rest = rest[len(two):].strip(); continue
            if len(tok) == 1 and (tok.isalnum() or tok in "`-=[]\\;',./"):
                keys.append(tok)
            elif tok in LETTER_SOUNDS and keys and keys[-1] in ("ctrl", "alt", "shift", "win"):
                keys.append(LETTER_SOUNDS[tok])       # misheard letter after a modifier
            elif tok in NUM_WORDS and keys and keys[-1] in ("ctrl", "alt", "shift", "win"):
                keys.append(NUM_WORDS[tok])
            else:
                return None
            rest = rest2.strip()
    if not keys:
        return None
    mods = [k for k in keys if k in ("ctrl", "alt", "shift", "win")]
    if require_modifier and not mods and not (len(keys) == 1 and re.fullmatch(r"f\d+|esc|printscreen", keys[0])):
        return None
    # modifiers first, keep order otherwise
    ordered = [k for k in ("ctrl", "alt", "shift", "win") if k in mods] + [k for k in keys if k not in mods]
    return {"keys": ordered, "times": times}


def find_shortcut(text):
    t = text.lower().strip().rstrip(".!?")
    t = re.sub(r"^(?:hey |ok )?snap\w*\W*", "", t)
    for pat, keys, label in SHORTCUTS:
        if re.fullmatch(SHORTCUT_PREFIX + "(?:" + pat + ")", t):
            return keys, label
    return None


def describe(keys):
    pretty = {"ctrl": "Ctrl", "alt": "Alt", "shift": "Shift", "win": "Win", "esc": "Esc", "enter": "Enter",
              "printscreen": "PrtSc", "pageup": "PgUp", "pagedown": "PgDn"}
    return "+".join(pretty.get(k, k.upper() if len(k) == 1 else k.capitalize()) for k in keys)


# Things Windows doesn't let any app simulate
BLOCKED = {("ctrl", "alt", "delete"): "Windows doesn't let apps press Ctrl+Alt+Delete (it's a security key). "
                                     "I can open Task Manager or lock the PC instead."}
