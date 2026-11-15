"""Turns per-frame hand poses into reliable mouse actions.

Design goals (things that make air-mouse products frustrating, fixed here):
  * No accidental clicks: a pose must be stable for a few frames before it counts,
    and a tap only clicks on *release*, so a pinch that turns into a drag never
    also fires a click.
  * Clicks land where you aimed: the cursor freezes the moment you pinch, and
    stays put briefly after a click so a second tap makes a real double-click.
  * Right-click fires once per pinch (edge triggered), never repeatedly.
  * Tracking dropouts (a frame or two without a hand) don't drop a drag.
  * Scrolling without arm fatigue: "joystick" mode keeps scrolling while two
    fingers are held above/below where you started; "drag" mode is like a touchpad.
"""
import time
from collections import deque

from src.vision.one_euro_filter import OneEuroFilter

# Frames a new pose must persist before we act on it
STABLE_FRAMES = {"PINCH_INDEX": 2, "PINCH_MIDDLE": 3, "NONE": 4}
DEFAULT_STABLE = 3


class GestureController:
    def __init__(self, mouse, screen_w, screen_h, settings=None, on_event=None):
        self.mouse = mouse
        self.screen_w = screen_w
        self.screen_h = screen_h
        self.on_event = on_event or (lambda name, data=None: None)
        self.paused = False

        self.fx = OneEuroFilter()
        self.fy = OneEuroFilter()
        self.cfg = {}
        self.apply_settings(settings or {})

        self.raw_pose = "NONE"
        self.raw_count = 0
        self.pose = "NONE"          # stable pose
        self.pose_since = 0.0

        self.cursor = (screen_w // 2, screen_h // 2)
        self.history = deque(maxlen=12)   # (t, cursor) for "where was I aiming"
        self.freeze_until = 0.0
        self.freeze_pos = None

        self.pinch_start = None     # (t, screen_pos)
        self.dragging = False
        self.last_click_t = 0.0
        self.last_click_pos = None

        self.scroll_origin = None   # camera-space y where two-finger scroll began
        self.scroll_last = None
        self.scroll_acc = 0.0
        self.last_t = None

        self.palm_fired = False
        self.last_hand_t = 0.0

    # ------------------------------------------------------------------ settings
    def apply_settings(self, s):
        def g(k, d):
            return s.get(k, self.cfg.get(k, d))
        smooth = max(1, min(10, int(g("pointer_smoothing", 5))))
        min_cutoff = 3.2 * (0.72 ** (smooth - 1))   # 1 -> 3.2 Hz, 10 -> 0.17 Hz
        for f in (self.fx, self.fy):
            f.min_cutoff = min_cutoff
            f.beta = 0.012
        self.cfg = {
            "pointer_smoothing": smooth,
            "pointer_anchor": g("pointer_anchor", "knuckle"),
            "control_area": max(1, min(10, int(g("control_area", 6)))),
            "pointer_enabled": bool(g("pointer_enabled", True)),
            "hold_to_drag_ms": int(g("hold_to_drag_ms", 450)),
            "drag_enabled": bool(g("drag_enabled", True)),
            "right_click_enabled": bool(g("right_click_enabled", True)),
            "scroll_enabled": bool(g("scroll_enabled", True)),
            "scroll_sensitivity": max(1, min(10, int(g("scroll_sensitivity", 5)))),
            "scroll_invert": bool(g("scroll_invert", False)),
            "scroll_style": g("scroll_style", "joystick"),
            "fist_action": g("fist_action", "clutch"),
            "palm_hold_action": g("palm_hold_action", "none"),
        }

    # ----------------------------------------------------------------- mapping
    def control_box(self):
        """Region of the camera frame (0..1) that maps to the full screen."""
        m = 0.04 + 0.032 * (self.cfg["control_area"] - 1)   # 1 -> 4% margin, 10 -> 33%
        top, bottom = m, 1 - m
        if self.cfg["pointer_anchor"] == "knuckle":
            # The knuckle sits below the fingertips: shift the box down so the
            # top of the screen is reachable without fingers leaving the frame.
            top, bottom = min(0.45, m + 0.10), min(0.97, 1 - m + 0.06)
        return m, top, 1 - m, bottom

    def map_to_screen(self, nx, ny):
        l, t, r, b = self.control_box()
        sx = (nx - l) / max(1e-6, r - l) * (self.screen_w - 1)
        sy = (ny - t) / max(1e-6, b - t) * (self.screen_h - 1)
        return (max(0, min(self.screen_w - 1, sx)), max(0, min(self.screen_h - 1, sy)))

    # ------------------------------------------------------------------- frame
    def update(self, raw_pose, lm, frame_w, frame_h, t=None):
        """Process one camera frame. lm = [[id, x_px, y_px], ...] or []."""
        t = time.perf_counter() if t is None else t
        dt = 0.033 if self.last_t is None else max(1e-3, min(0.2, t - self.last_t))
        self.last_t = t

        if lm:
            self.last_hand_t = t

        # --- debounce pose changes
        if raw_pose == self.raw_pose:
            self.raw_count += 1
        else:
            self.raw_pose, self.raw_count = raw_pose, 1
        needed = STABLE_FRAMES.get(raw_pose, DEFAULT_STABLE)
        prev = self.pose
        if raw_pose != self.pose and self.raw_count >= needed:
            self.pose = raw_pose
            self.pose_since = t
            self._on_pose_change(prev, self.pose, t)

        if self.paused or not lm:
            return self.pose

        anchor_id = 5 if self.cfg["pointer_anchor"] == "knuckle" else 8
        nx, ny = lm[anchor_id][1] / frame_w, lm[anchor_id][2] / frame_h
        target = self.map_to_screen(nx, ny)
        sx, sy = self.fx.filter(target[0], t), self.fy.filter(target[1], t)

        p = self.pose
        if p == "POINTING" or p == "UNKNOWN" or (p == "PINCH_INDEX" and self.dragging):
            self._move(sx, sy, t)
        elif p == "PINCH_INDEX":
            self._pinch_hold(sx, sy, t)
        elif p == "SCROLL":
            mid_y = (lm[8][2] + lm[12][2]) / 2.0 / frame_h
            hand = max(1.0, ((lm[0][1] - lm[9][1]) ** 2 + (lm[0][2] - lm[9][2]) ** 2) ** 0.5) / frame_h
            self._scroll(mid_y, hand, dt)
        elif p == "OPEN_PALM":
            if not self.palm_fired and t - self.pose_since > 0.9:
                self.palm_fired = True
                action = self.cfg["palm_hold_action"]
                if action and action != "none":
                    self.on_event("palm_hold", action)
        elif p == "FIST":
            pass  # clutch: cursor stays where it is while you move/rest your hand

        return self.pose

    def hand_lost(self, t=None):
        """Call when no hand is visible."""
        t = time.perf_counter() if t is None else t
        self.update("NONE", [], 1, 1, t)

    # ---------------------------------------------------------------- handlers
    def _on_pose_change(self, prev, new, t):
        if prev == "PINCH_INDEX":
            self._pinch_release(t, cancel=(new == "NONE"))
        if prev == "SCROLL":
            self.scroll_origin = None
            self.scroll_last = None
            self.scroll_acc = 0.0
        if prev == "OPEN_PALM":
            self.palm_fired = False
        if prev == "FIST" or new == "NONE":
            # Avoid the cursor sliding in from an old filtered position
            self.fx.reset()
            self.fy.reset()

        if self.paused:
            return
        if new == "PINCH_INDEX":
            # Use where the cursor was ~120 ms ago: closing the fingers nudges the
            # hand, and the debounce frames add a little delay on top.
            aim = self.cursor
            for ht, hp in self.history:
                if ht <= t - 0.12:
                    aim = hp
            if aim != self.cursor:
                self.cursor = aim
                self.mouse.move_to(*aim)
            self.pinch_start = (t, aim)
            self.freeze_pos = aim
        elif new == "PINCH_MIDDLE" and self.cfg["right_click_enabled"]:
            self.mouse.click("right", *self.cursor)
            self.freeze_pos, self.freeze_until = self.cursor, t + 0.35
            self.on_event("right_click")
        elif new == "FIST" and self.cfg["fist_action"] not in ("clutch", "none", ""):
            self.on_event("fist", self.cfg["fist_action"])

    def _move(self, sx, sy, t):
        if not self.cfg["pointer_enabled"] and not self.dragging:
            return
        if t < self.freeze_until and self.freeze_pos:
            fx, fy = self.freeze_pos
            # Small movements right after a click are ignored (enables double-click);
            # a deliberate move breaks the freeze immediately.
            if abs(sx - fx) < 28 and abs(sy - fy) < 28:
                return
            self.freeze_until = 0
        pos = (int(sx), int(sy))
        if pos != self.cursor:
            self.cursor = pos
            self.mouse.move_to(*pos)
            self.history.append((t, pos))

    def _pinch_hold(self, sx, sy, t):
        if not self.pinch_start:
            return
        t0, p0 = self.pinch_start
        moved = abs(sx - p0[0]) + abs(sy - p0[1])
        held_ms = (t - t0) * 1000
        if self.cfg["drag_enabled"] and (held_ms >= self.cfg["hold_to_drag_ms"] or moved > 70):
            self.mouse.down(*p0)
            self.dragging = True
            self.on_event("drag_start")

    def _pinch_release(self, t, cancel=False):
        if self.dragging:
            self.mouse.up()
            self.dragging = False
            self.on_event("drag_end")
        elif self.pinch_start and not self.paused and not cancel:
            pos = self.freeze_pos or self.cursor
            self.mouse.click("left", *pos)
            double = (t - self.last_click_t) < 0.5 and self.last_click_pos == pos
            self.last_click_t, self.last_click_pos = t, pos
            self.freeze_pos, self.freeze_until = pos, t + 0.45
            self.on_event("double_click" if double else "click")
        self.pinch_start = None

    def _scroll(self, y, hand, dt):
        if not self.cfg["scroll_enabled"]:
            return
        sens = self.cfg["scroll_sensitivity"]
        sign = -1 if self.cfg["scroll_invert"] else 1
        if self.scroll_origin is None:
            self.scroll_origin = y
            self.scroll_last = y
            return
        if self.cfg["scroll_style"] == "drag":
            dy = (self.scroll_last - y) / hand          # in hand-lengths
            self.scroll_last = y
            self.scroll_acc += dy * sens * 240
        else:
            off = (self.scroll_origin - y) / hand       # + = fingers above start point
            dead = 0.18
            if abs(off) > dead:
                mag = min(1.5, abs(off) - dead)
                notches_per_s = (2 + sens * 2.2) * mag * 2.2
                self.scroll_acc += (1 if off > 0 else -1) * notches_per_s * 120 * dt
        if abs(self.scroll_acc) >= 40:
            delta = int(self.scroll_acc)
            self.scroll_acc -= delta
            self.mouse.wheel(sign * delta)

    # ------------------------------------------------------------------ control
    def release_all(self):
        if self.dragging:
            self.mouse.up()
            self.dragging = False
        self.pinch_start = None

    def set_paused(self, paused):
        self.paused = bool(paused)
        if self.paused:
            self.release_all()

    @property
    def state(self):
        return {"pose": self.pose, "dragging": self.dragging, "paused": self.paused,
                "cursor": self.cursor}
