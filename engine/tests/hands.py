"""Synthetic MediaPipe-style hand landmarks for tests."""
import math

# Unit hand: wrist at origin, fingers pointing up (-y), middle-MCP distance = 1
EXT = {"pip": -1.45, "dip": -1.72, "tip": -1.95}
BASE_X = {"index": -0.25, "middle": 0.0, "ring": 0.22, "pinky": 0.42}
MCP_Y = {"index": -1.0, "middle": -1.0, "ring": -0.97, "pinky": -0.9}
ORDER = ["index", "middle", "ring", "pinky"]


def _finger(name, state):
    x, y0 = BASE_X[name], MCP_Y[name]
    if state == "up":
        return [(x, y0), (x, y0 - 0.45), (x, y0 - 0.72), (x, y0 - 0.95)]
    # curled: tip folds back toward the palm
    return [(x, y0), (x, y0 - 0.35), (x + 0.02, y0 - 0.15), (x + 0.03, y0 + 0.05)]


def make_hand(pose="POINTING", cx=320, cy=300, scale=90, angle_deg=0):
    thumb = [(-0.35, -0.2), (-0.55, -0.4), (-0.7, -0.6), (-0.8, -0.8)]
    fingers = {n: "down" for n in ORDER}
    if pose == "POINTING":
        fingers["index"] = "up"
    elif pose == "SCROLL":
        fingers["index"] = fingers["middle"] = "up"
    elif pose == "OPEN_PALM":
        fingers = {n: "up" for n in ORDER}
    elif pose == "FIST":
        thumb = [(-0.3, -0.2), (-0.4, -0.45), (-0.3, -0.7), (-0.15, -0.8)]
    pts = {}
    for n in ORDER:
        pts[n] = _finger(n, fingers[n])
    if pose == "PINCH_INDEX":
        pts["index"] = [(-0.25, -1.0), (-0.3, -1.4), (-0.42, -1.55), (-0.5, -1.6)]
        thumb = [(-0.35, -0.2), (-0.55, -0.55), (-0.55, -1.1), (-0.5, -1.56)]
    elif pose == "PINCH_MIDDLE":
        pts["middle"] = [(0.0, -1.0), (0.0, -1.4), (-0.1, -1.55), (-0.2, -1.6)]
        thumb = [(-0.35, -0.2), (-0.5, -0.55), (-0.4, -1.1), (-0.2, -1.56)]

    unit = [(0.0, 0.0)] + thumb
    for n in ORDER:
        unit += pts[n]

    a = math.radians(angle_deg)
    out = []
    for i, (x, y) in enumerate(unit):
        rx = x * math.cos(a) - y * math.sin(a)
        ry = x * math.sin(a) + y * math.cos(a)
        out.append([i, cx + rx * scale, cy + ry * scale])
    return out


class FakeMouse:
    def __init__(self):
        self.calls = []
        self.pos = (0, 0)
        self.is_down = False

    def move_to(self, x, y):
        self.pos = (x, y)
        self.calls.append(("move", x, y))

    def click(self, button="left", x=None, y=None):
        self.calls.append(("click", button, x, y))

    def down(self, x=None, y=None):
        self.is_down = True
        self.calls.append(("down", x, y))

    def up(self):
        self.is_down = False
        self.calls.append(("up",))

    def wheel(self, delta):
        self.calls.append(("wheel", delta))

    def of(self, kind):
        return [c for c in self.calls if c[0] == kind]
