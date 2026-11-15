"""Screen understanding, layer 1: the Windows UI Automation (accessibility) tree.

The same structure screen readers use: every button, link, text field, tab and
list item with its name and on-screen rectangle. It's free, local, instant and
exact (no vision model, no screenshots leaving the PC), and it covers browsers
too (Chrome/Edge expose web pages through UIA). Vision (OCR / a small VLM) is
the fallback for pixels with no structure — see docs/COMPUTER_USE.md.

Supports:
  "click the subscribe button", "open the Settings tab", "click the second video",
  "click the video on the top left", "type hello world in the search box",
  "what's on my screen?"
"""
import difflib
import re
import time

try:
    import uiautomation as auto
except Exception:  # pragma: no cover
    auto = None

# UIA control types we treat as things a person can act on
ACTIONABLE = {"ButtonControl", "HyperlinkControl", "EditControl", "ComboBoxControl", "ListItemControl",
              "MenuItemControl", "TabItemControl", "CheckBoxControl", "RadioButtonControl", "TreeItemControl",
              "SplitButtonControl", "DataItemControl", "ImageControl", "DocumentControl"}
TYPE_WORDS = {
    "button": {"ButtonControl", "SplitButtonControl"}, "link": {"HyperlinkControl"},
    "field": {"EditControl", "ComboBoxControl", "DocumentControl"}, "box": {"EditControl", "ComboBoxControl"},
    "search": {"EditControl", "ComboBoxControl"}, "input": {"EditControl"}, "textbox": {"EditControl"},
    "tab": {"TabItemControl"}, "menu": {"MenuItemControl"}, "checkbox": {"CheckBoxControl"},
    "option": {"ListItemControl", "RadioButtonControl", "MenuItemControl"}, "item": {"ListItemControl", "TreeItemControl"},
    "video": {"HyperlinkControl", "ListItemControl"}, "result": {"HyperlinkControl", "ListItemControl"},
    "image": {"ImageControl"}, "picture": {"ImageControl"}, "thumbnail": {"HyperlinkControl", "ImageControl"},
}
ORDINALS = {"first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2, "fourth": 3, "4th": 3,
            "fifth": 4, "5th": 4, "sixth": 5, "last": -1, "pehla": 0, "pehli": 0, "doosra": 1, "doosri": 1,
            "teesra": 2, "teesri": 2}


class Element:
    __slots__ = ("name", "ctype", "rect", "control", "depth")

    def __init__(self, name, ctype, rect, control, depth):
        self.name, self.ctype, self.rect, self.control, self.depth = name, ctype, rect, control, depth

    @property
    def center(self):
        l, t, r, b = self.rect
        return (l + r) // 2, (t + b) // 2

    @property
    def area(self):
        l, t, r, b = self.rect
        return max(0, r - l) * max(0, b - t)

    def as_dict(self, i=None):
        d = {"name": self.name[:120], "type": self.ctype.replace("Control", "").lower(), "rect": list(self.rect)}
        if i is not None:
            d["id"] = i
        return d


def foreground_window():
    if auto is None:
        return None
    from src.os_control import windows as win
    hwnd = win.ensure_target_focus()
    if not hwnd:
        return None
    try:
        return auto.ControlFromHandle(hwnd)
    except Exception:
        return None


CAPTION = {"minimize", "maximize", "restore", "close", "restore down", "system", "system menu"}


def snapshot(window=None, max_elements=400, max_depth=40, time_budget=2.5):
    """Visible, named, actionable elements of the foreground window (or `window`).
    Chromium (Chrome, Edge, Electron) builds its accessibility tree lazily on the
    first UIA request, so if a browser window shows no page content yet we wait
    briefly and read it again."""
    els, root = _snapshot(window, max_elements, max_depth, time_budget)
    try:
        chromium = root is not None and root.ClassName.startswith("Chrome_WidgetWin")
    except Exception:
        chromium = False
    if chromium and not any(e.ctype in ("HyperlinkControl", "EditControl", "DocumentControl", "ListItemControl")
                            for e in els):
        for _ in range(4):
            time.sleep(0.5)
            els, root = _snapshot(root, max_elements, max_depth, time_budget)
            if any(e.ctype in ("HyperlinkControl", "EditControl", "ListItemControl") for e in els):
                break
    return els, root


def _snapshot(window=None, max_elements=400, max_depth=40, time_budget=2.5):
    if auto is None:
        return [], None
    root = window or foreground_window()
    if root is None:
        return [], None
    try:
        wr = root.BoundingRectangle
        win_rect = (wr.left, wr.top, wr.right, wr.bottom)
    except Exception:
        win_rect = None
    out, start = [], time.time()
    with auto.UIAutomationInitializerInThread():
        for ctrl, depth in auto.WalkControl(root, includeTop=False, maxDepth=max_depth):
            if time.time() - start > time_budget or len(out) >= max_elements:
                break
            try:
                ctype = ctrl.ControlTypeName
                if ctype not in ACTIONABLE:
                    continue
                name = (ctrl.Name or "").strip()
                if not name and ctype != "EditControl":
                    continue
                if ctype == "EditControl" and not name:
                    name = (getattr(ctrl, "AutomationId", "") or "text field").strip()
                r = ctrl.BoundingRectangle
                rect = (r.left, r.top, r.right, r.bottom)
                if r.right - r.left < 4 or r.bottom - r.top < 4 or ctrl.IsOffscreen:
                    continue
                if win_rect and (r.right < win_rect[0] or r.left > win_rect[2] or r.bottom < win_rect[1] or r.top > win_rect[3]):
                    continue
                out.append(Element(name, ctype, rect, ctrl, depth))
            except Exception:
                continue
    return out, root


def _type_filter(query):
    q = query.lower()
    types = set()
    for w, ts in TYPE_WORDS.items():
        if re.search(r"\b" + w + r"s?\b", q):
            types |= ts
    return types


def _strip_words(query):
    q = re.sub(r"\b(click|tap|double|right|select|choose|hit|open|play|watch|the|a|an|on|in|at|of|to|this|that|please|button|link|field|box|tab|icon|option|item|"
               r"menu|video|result|thumbnail|image|picture|section|area|side|corner|one|wala|wali|pe|par)\b", " ", query.lower())
    for w in list(ORDINALS) + ["top", "bottom", "left", "right", "upper", "lower", "middle", "center", "centre", "first", "last"]:
        q = re.sub(r"\b" + re.escape(w) + r"\b", " ", q)
    return re.sub(r"\s+", " ", q).strip()


def _spatial(query):
    q = query.lower()
    vert = "top" if re.search(r"\b(top|upper|above|upar)\b", q) else "bottom" if re.search(r"\b(bottom|lower|below|neeche)\b", q) else None
    horiz = "left" if re.search(r"\b(left|baayen|baaye)\b", q) else "right" if re.search(r"\b(right|daayen|daaye)\b", q) else None
    ordinal = None
    for w, i in ORDINALS.items():
        if re.search(r"\b" + re.escape(w) + r"\b", q):
            ordinal = i
            break
    n = re.search(r"\b(?:number|no\.?|#)\s*(\d+)\b", q)
    if n:
        ordinal = int(n.group(1)) - 1
    return vert, horiz, ordinal


def _score_name(target, name):
    if not target:
        return 0.0
    n = name.lower()
    if target == n:
        return 1.0
    if target in n:
        return 0.85 + 0.1 * (len(target) / max(len(n), 1))
    tw, nw = set(target.split()), set(re.findall(r"\w+", n))
    overlap = len(tw & nw) / max(1, len(tw))
    return max(overlap * 0.8, difflib.SequenceMatcher(None, target, n[:len(target) + 10]).ratio() * 0.7)


def find(query, elements):
    """Best element for a spoken description; returns (element, why) or (None, reason)."""
    if not elements:
        return None, "I can't read this window's controls."
    types = _type_filter(query)
    target = _strip_words(query)
    vert, horiz, ordinal = _spatial(query)
    # never pick window caption buttons (Minimize/Close…) unless the user names them
    if not any(c in query.lower() for c in CAPTION):
        elements = [e for e in elements if e.name.lower() not in CAPTION]
    pool = [e for e in elements if not types or e.ctype in types]
    if types and not pool:
        return None, "I don't see anything like that on this screen."
    if "video" in query.lower() or "thumbnail" in query.lower() or "result" in query.lower():
        # videos/results are the big content links, not tiny nav links
        pool = [e for e in pool if len(e.name) > 15 and e.area > 2500]
        if not pool:
            return None, "I don't see any videos on this screen."
    if target:
        scored = sorted(((_score_name(target, e.name), e) for e in pool), key=lambda x: -x[0])
        best = [e for s, e in scored if s >= max(0.5, scored[0][0] - 0.05)] if scored and scored[0][0] >= 0.5 else []
        if not best:
            return None, f"I couldn't find “{target}” on this screen."
        pool = best
    if vert or horiz or ordinal is not None:
        # reading order: rows top->bottom (bucketed), then left->right
        rows = sorted(pool, key=lambda e: (round(e.rect[1] / 60), e.rect[0]))
        if vert == "bottom":
            rows = sorted(pool, key=lambda e: (-round(e.rect[3] / 60), e.rect[0]))
        if horiz == "right":
            rows = sorted(rows, key=lambda e: (round((e.rect[1] if vert != "bottom" else -e.rect[3]) / 60), -e.rect[2]))
        idx = ordinal if ordinal is not None else 0
        if idx < 0:
            idx = len(rows) + idx
        if 0 <= idx < len(rows):
            return rows[idx], "position"
        return None, f"There are only {len(rows)} matching items here."
    # no spatial hint: biggest, shallowest match
    return sorted(pool, key=lambda e: (e.depth, -e.area))[0], "name"


def _visible_point(element):
    """A point inside the element that isn't covered by another window (e.g. the
    On-Screen Keyboard or an always-on-top player), or None."""
    import ctypes
    from ctypes import wintypes
    u = ctypes.windll.user32
    u.WindowFromPoint.restype = wintypes.HWND
    u.GetAncestor.restype = wintypes.HWND
    try:
        target = element.control.GetTopLevelControl().NativeWindowHandle
    except Exception:
        return element.center
    l, t, r, b = element.rect
    for fx, fy in ((0.5, 0.5), (0.25, 0.3), (0.75, 0.3), (0.25, 0.75), (0.75, 0.75), (0.1, 0.1), (0.9, 0.9)):
        x, y = int(l + (r - l) * fx), int(t + (b - t) * fy)
        if u.GetAncestor(u.WindowFromPoint(wintypes.POINT(x, y)), 2) == target:
            return x, y
    return None


def click(element, double=False, right=False):
    """Prefer the accessibility 'Invoke' action (works even if something covers the
    element, and doesn't move the mouse); fall back to a real click on a visible point."""
    import pyautogui
    if not right and not double:
        for getter in ("GetInvokePattern", "GetLegacyIAccessiblePattern"):
            try:
                pat = getattr(element.control, getter)()
                if pat:
                    if getter == "GetInvokePattern":
                        pat.Invoke()
                    else:
                        pat.DoDefaultAction()
                    return True
            except Exception:
                continue
    pt = _visible_point(element)
    if pt is None:
        return False
    pyautogui.click(*pt, clicks=2 if double else 1, button="right" if right else "left")
    return True


def type_into(element, text, submit=False):
    import pyautogui
    try:
        element.control.SetFocus()
    except Exception:
        pass
    x, y = element.center
    pyautogui.click(x, y)
    time.sleep(0.15)
    pyautogui.hotkey("ctrl", "a")
    if text.isascii():
        pyautogui.write(text, interval=0.005)
    else:
        import pyperclip
        old = pyperclip.paste()
        pyperclip.copy(text)
        pyautogui.hotkey("ctrl", "v")
        time.sleep(0.1)
        pyperclip.copy(old)
    if submit:
        pyautogui.press("enter")
    return True


def describe(elements, root=None, limit=25):
    """Short, speakable summary of what's on screen + the list for the LLM."""
    title = ""
    try:
        title = root.Name if root is not None else ""
    except Exception:
        pass
    counts = {}
    for e in elements:
        k = e.ctype.replace("Control", "").lower()
        counts[k] = counts.get(k, 0) + 1
    main = sorted(elements, key=lambda e: (round(e.rect[1] / 60), e.rect[0]))
    items = [e.as_dict(i) for i, e in enumerate(main[:limit])]
    parts = ", ".join(f"{v} {k}{'s' if v > 1 else ''}" for k, v in sorted(counts.items(), key=lambda x: -x[1])[:4])
    return {"title": title, "summary": f"“{title[:60]}” — {parts}." if title else parts, "items": items}
