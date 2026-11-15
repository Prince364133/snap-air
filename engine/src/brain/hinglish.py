"""Hinglish / Hindi (Devanagari) -> English command normaliser, so everyday
commands like "youtube kholo", "neeche scroll karo", "awaaz badhao" run
instantly through the command grammar without the LLM."""
import re

# Devanagari words people commonly use for commands -> Latin Hinglish
DEVANAGARI = {
    "खोलो": "kholo", "खोल": "khol", "बंद": "band", "करो": "karo", "कर": "kar", "दो": "do", "चलाओ": "chalao",
    "चला": "chala", "रोको": "roko", "नीचे": "neeche", "ऊपर": "upar", "आवाज़": "awaaz", "आवाज": "awaaz",
    "बढ़ाओ": "badhao", "बढाओ": "badhao", "कम": "kam", "स्क्रॉल": "scroll", "यूट्यूब": "youtube",
    "गाना": "gaana", "अगला": "agla", "पिछला": "pichla", "टैब": "tab", "वापस": "wapas", "जाओ": "jao",
    "सर्च": "search", "क्रोम": "chrome", "म्यूट": "mute", "रुको": "ruko", "बजाओ": "bajao", "पर": "par",
    "पे": "pe", "में": "mein", "को": "ko", "और": "aur", "थोड़ा": "thoda", "ज़्यादा": "zyada",
}

# (pattern on Latin Hinglish, replacement English command). Order matters.
RULES = [
    (r"^(.+?) (?:pe|par|mein) (.+?) (?:chalao|chala do|lagao|laga do|bajao|baja do|play karo)$", r"play \2 on \1"),
    (r"^(.+?) (?:chalao|chala do|bajao|baja do|play karo|laga do|lagao)$", r"play \1"),
    (r"^(?:thoda )?(?:neeche|niche) (?:scroll )?(?:karo|kar do|jao|le jao)$|^scroll (?:neeche|niche) karo$", "scroll down"),
    (r"^(?:thoda )?(?:upar|oopar) (?:scroll )?(?:karo|kar do|jao|le jao)$|^scroll upar karo$", "scroll up"),
    (r"^(?:awaaz|awaz|volume|aawaz) (?:badhao|badha do|tez karo|zyada karo|upar karo)$", "volume up"),
    (r"^(?:awaaz|awaz|volume|aawaz) (?:kam karo|kam kar do|dheere karo|ghatao|neeche karo)$", "volume down"),
    (r"^(?:awaaz|awaz|volume|aawaz) band (?:karo|kar do)$|^mute (?:karo|kar do)$", "mute"),
    (r"^(?:gaana|video|music) (?:roko|rok do|band karo|pause karo)$|^(?:roko|ruko)$", "pause"),
    (r"^(?:agla|next) (?:gaana|song|video)(?: chalao| lagao)?$|^agla gaana$", "next song"),
    (r"^(?:agla|next) tab(?: pe jao| kholo)?$", "next tab"),
    (r"^(?:pichla|previous|pichhla) tab(?: pe jao)?$", "previous tab"),
    (r"^(?:naya|new) tab (?:kholo|khol do)$", "new tab"),
    (r"^tab band (?:karo|kar do)$", "close tab"),
    (r"^wapas (?:jao|chalo)$|^peeche jao$", "go back"),
    (r"^(.+?) (?:pe|par) (?:jao|switch karo|le chalo)$", r"switch to \1"),
    (r"^(.+?) (?:kholo|khol do|open karo|chalu karo|start karo)$", r"open \1"),
    (r"^(.+?) band (?:karo|kar do)$", r"close \1"),
    (r"^(.+?) (?:search karo|dhoondo|google karo)$", r"search for \1"),
    (r"^screenshot (?:lo|le lo|lena)$", "screenshot"),
    (r"^desktop dikhao$|^sab minimize karo$", "show desktop"),
]

QUESTION_OR_CREATIVE = re.compile(
    r"\?\s*$|^(?:write|draft|compose|create|generate|make|give) (?:me|us|a|an|some)\b|^(?:explain|describe|summari[sz]e|"
    r"translate|why|how|what|who|when|where|which|can you|could you|tell me|help me)\b|\b(samjhao|batao|kya hai|kaise)\b",
    re.I)


def to_latin(text):
    out = text
    for dev, lat in sorted(DEVANAGARI.items(), key=lambda x: -len(x[0])):
        out = out.replace(dev, lat)
    return out


def normalize_command(text):
    """Return an English command for a Hinglish/Hindi command, else None."""
    t = to_latin(text).lower().strip()
    t = re.sub(r"[।.!,]+", " ", t)
    t = re.sub(r"^(?:yaar|please|zara|jaldi|snap)\s+", "", re.sub(r"\s+", " ", t)).strip()
    t = re.sub(r"\s+(?:na|please|yaar|zara)$", "", t)
    for pat, rep in RULES:
        if re.match(pat, t):
            out = re.sub(pat, rep, t).strip()
            out = re.sub(r'\b(?:kuch|koi|thoda|zara|accha sa|achha sa|ek|wala|waala)\s+', '', out)   # fillers
            return out if out != t else None
    return None


def is_question_or_creative(text):
    """'write me a poem', 'explain X', '...?' must go to the LLM, never be typed/executed."""
    return bool(QUESTION_OR_CREATIVE.search(text.strip()))
