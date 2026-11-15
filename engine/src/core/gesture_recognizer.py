"""Hand pose classification from MediaPipe landmarks.

All thresholds are relative to the size of the hand in the image, so the
gestures work the same whether your hand is 30 cm or 1 m from the camera.
Pinches use hysteresis (tighter to start, looser to release) so a held
pinch/drag doesn't flicker off when your fingers drift slightly apart.
"""
import math

WRIST = 0
THUMB_IP, THUMB_TIP = 3, 4
PINKY_MCP = 17
INDEX_MCP, INDEX_PIP, INDEX_TIP = 5, 6, 8
MIDDLE_MCP, MIDDLE_PIP, MIDDLE_TIP = 9, 10, 12
RING_PIP, RING_TIP = 14, 16
PINKY_PIP, PINKY_TIP = 18, 20


def _d(lm, a, b):
    return math.hypot(lm[a][1] - lm[b][1], lm[a][2] - lm[b][2])


class GestureRecognizer:
    POSES = ("NONE", "POINTING", "SCROLL", "PINCH_INDEX", "PINCH_MIDDLE",
             "OPEN_PALM", "FIST", "UNKNOWN")

    def __init__(self, pinch_sensitivity=5):
        self.active_pinch = None  # "PINCH_INDEX" / "PINCH_MIDDLE" while held
        self.set_pinch_sensitivity(pinch_sensitivity)

    def set_pinch_sensitivity(self, level):
        level = max(1, min(10, int(level)))
        # Ratio of thumb-tip distance to hand size. ~0.1 = touching, ~0.7 = open.
        self.pinch_on = 0.15 + 0.022 * level      # level 5 -> 0.26
        self.pinch_off = self.pinch_on * 1.55     # must open clearly to release

    @staticmethod
    def hand_size(lm):
        return max(1.0, _d(lm, WRIST, MIDDLE_MCP))

    @staticmethod
    def finger_extended(lm, tip, pip):
        # Rotation-invariant: an extended finger's tip is clearly farther from
        # the wrist than its middle joint; a curled one folds back toward it.
        return _d(lm, WRIST, tip) > _d(lm, WRIST, pip) * 1.12

    def fingers_up(self, lm):
        if len(lm) < 21:
            return []
        return [
            1 if _d(lm, THUMB_TIP, PINKY_MCP) > _d(lm, THUMB_IP, PINKY_MCP) else 0,
            1 if self.finger_extended(lm, INDEX_TIP, INDEX_PIP) else 0,
            1 if self.finger_extended(lm, MIDDLE_TIP, MIDDLE_PIP) else 0,
            1 if self.finger_extended(lm, RING_TIP, RING_PIP) else 0,
            1 if self.finger_extended(lm, PINKY_TIP, PINKY_PIP) else 0,
        ]

    def detect_gesture(self, lm):
        if len(lm) < 21:
            self.active_pinch = None
            return "NONE"

        size = self.hand_size(lm)
        f = self.fingers_up(lm)
        ti = _d(lm, THUMB_TIP, INDEX_TIP) / size
        tm = _d(lm, THUMB_TIP, MIDDLE_TIP) / size
        # A curled-up finger in a fist can rest near the thumb; a real pinch keeps
        # the fingertip out in front of the knuckle.
        index_forward = _d(lm, WRIST, INDEX_TIP) > _d(lm, WRIST, INDEX_MCP) * 1.12
        middle_forward = _d(lm, WRIST, MIDDLE_TIP) > _d(lm, WRIST, MIDDLE_MCP) * 1.12

        # Keep holding an existing pinch until fingers open past the release threshold
        if self.active_pinch == "PINCH_INDEX" and ti < self.pinch_off:
            return "PINCH_INDEX"
        if self.active_pinch == "PINCH_MIDDLE" and tm < self.pinch_off and ti > self.pinch_on:
            return "PINCH_MIDDLE"
        self.active_pinch = None

        if ti < self.pinch_on and index_forward and tm > ti:
            self.active_pinch = "PINCH_INDEX"
            return "PINCH_INDEX"
        if tm < self.pinch_on and middle_forward and ti > self.pinch_on * 1.6 and not f[1]:
            self.active_pinch = "PINCH_MIDDLE"
            return "PINCH_MIDDLE"

        index, middle, ring, pinky = f[1], f[2], f[3], f[4]
        if index and middle and ring and pinky:
            return "OPEN_PALM"
        if not index and not middle and not ring and not pinky:
            return "FIST"
        if index and middle and not ring and not pinky:
            return "SCROLL"
        if index and not middle and not ring and not pinky:
            return "POINTING"
        return "UNKNOWN"
