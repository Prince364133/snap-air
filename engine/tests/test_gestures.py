import unittest

from src.core.gesture_controller import GestureController
from src.core.gesture_recognizer import GestureRecognizer
from tests.hands import FakeMouse, make_hand

W, H = 640, 480
DT = 1 / 30


class RecognizerTests(unittest.TestCase):
    def test_all_poses_at_any_distance_and_tilt(self):
        for scale in (55, 90, 150):            # far, normal, close to camera
            for angle in (-30, 0, 25):          # tilted hand
                for pose in ("POINTING", "SCROLL", "OPEN_PALM", "FIST", "PINCH_INDEX", "PINCH_MIDDLE"):
                    r = GestureRecognizer()
                    got = r.detect_gesture(make_hand(pose, scale=scale, angle_deg=angle))
                    self.assertEqual(got, pose, f"{pose} scale={scale} angle={angle}")

    def test_no_hand(self):
        self.assertEqual(GestureRecognizer().detect_gesture([]), "NONE")

    def test_pinch_hysteresis_holds_while_fingers_drift(self):
        r = GestureRecognizer()
        hand = make_hand("PINCH_INDEX", scale=100)
        self.assertEqual(r.detect_gesture(hand), "PINCH_INDEX")
        # open the pinch a little (above the start threshold, below release)
        drift = [list(p) for p in hand]
        drift[4][1] -= 0.33 * 100   # thumb tip 0.33 hand-lengths away
        self.assertEqual(r.detect_gesture(drift), "PINCH_INDEX")
        self.assertNotEqual(GestureRecognizer().detect_gesture(drift), "PINCH_INDEX")


class Sim:
    """Feeds frames through recognizer + controller with a fake clock."""

    def __init__(self, **settings):
        self.mouse = FakeMouse()
        self.events = []
        self.rec = GestureRecognizer()
        self.gc = GestureController(self.mouse, 1920, 1080, settings,
                                    on_event=lambda n, d=None: self.events.append((n, d)))
        self.t = 0.0

    def frames(self, pose, n, cx=320, cy=300, **kw):
        for _ in range(n):
            self.t += DT
            lm = make_hand(pose, cx=cx, cy=cy, **kw)
            self.gc.update(self.rec.detect_gesture(lm), lm, W, H, self.t)

    def lost(self, n):
        for _ in range(n):
            self.t += DT
            self.rec.detect_gesture([])
            self.gc.hand_lost(self.t)


class ControllerTests(unittest.TestCase):
    def test_pointing_moves_cursor_in_direction_of_hand(self):
        s = Sim()
        s.frames("POINTING", 15, cx=250)
        x1 = s.gc.cursor[0]
        s.frames("POINTING", 15, cx=400)
        self.assertGreater(s.gc.cursor[0], x1 + 300)

    def test_quick_pinch_is_exactly_one_click_where_you_aimed(self):
        s = Sim()
        s.frames("POINTING", 20)
        aim = s.gc.cursor
        s.frames("PINCH_INDEX", 5)
        s.frames("POINTING", 6)
        clicks = s.mouse.of("click")
        self.assertEqual(len(clicks), 1)
        self.assertEqual(clicks[0][1], "left")
        self.assertLessEqual(abs(clicks[0][2] - aim[0]) + abs(clicks[0][3] - aim[1]), 4)
        self.assertEqual(s.mouse.of("down"), [])

    def test_two_quick_pinches_make_a_double_click_at_same_spot(self):
        s = Sim()
        s.frames("POINTING", 20)
        s.frames("PINCH_INDEX", 4)
        s.frames("POINTING", 5)
        s.frames("PINCH_INDEX", 4)
        s.frames("POINTING", 5)
        clicks = s.mouse.of("click")
        self.assertEqual(len(clicks), 2)
        self.assertEqual(clicks[0][2:], clicks[1][2:])
        self.assertIn(("double_click", None), s.events)

    def test_hold_pinch_drags_and_never_clicks(self):
        s = Sim(hold_to_drag_ms=400)
        s.frames("POINTING", 20)
        s.frames("PINCH_INDEX", 18)                 # ~600 ms
        self.assertEqual(len(s.mouse.of("down")), 1)
        before = s.gc.cursor
        s.frames("PINCH_INDEX", 15, cx=420)          # drag to the right
        self.assertGreater(s.gc.cursor[0], before[0] + 200)
        s.frames("POINTING", 5)
        self.assertEqual(len(s.mouse.of("up")), 1)
        self.assertEqual(s.mouse.of("click"), [])

    def test_drag_disabled_means_hold_is_just_a_click(self):
        s = Sim(drag_enabled=False)
        s.frames("POINTING", 10)
        s.frames("PINCH_INDEX", 30)
        s.frames("POINTING", 5)
        self.assertEqual(s.mouse.of("down"), [])
        self.assertEqual(len(s.mouse.of("click")), 1)

    def test_right_click_fires_once_per_pinch(self):
        s = Sim()
        s.frames("POINTING", 10)
        s.frames("PINCH_MIDDLE", 40)
        rc = [c for c in s.mouse.of("click") if c[1] == "right"]
        self.assertEqual(len(rc), 1)

    def test_single_frame_flicker_does_not_click(self):
        s = Sim()
        s.frames("POINTING", 10)
        s.frames("PINCH_INDEX", 1)
        s.frames("POINTING", 10)
        self.assertEqual(s.mouse.of("click"), [])

    def test_losing_hand_mid_pinch_cancels_click_and_releases_drag(self):
        s = Sim()
        s.frames("POINTING", 10)
        s.frames("PINCH_INDEX", 4)
        s.lost(10)
        self.assertEqual(s.mouse.of("click"), [])
        s2 = Sim()
        s2.frames("POINTING", 10)
        s2.frames("PINCH_INDEX", 25)
        s2.lost(10)
        self.assertEqual(len(s2.mouse.of("up")), 1)

    def test_brief_tracking_dropout_keeps_drag(self):
        s = Sim()
        s.frames("POINTING", 10)
        s.frames("PINCH_INDEX", 25)
        s.lost(2)                                   # 2 dropped frames
        s.frames("PINCH_INDEX", 5)
        self.assertEqual(s.mouse.of("up"), [])

    def test_joystick_scroll_direction_and_rest(self):
        s = Sim(scroll_sensitivity=5)
        s.frames("SCROLL", 10, cy=300)              # start point
        self.assertEqual(s.mouse.of("wheel"), [])
        s.frames("SCROLL", 30, cy=300)              # hold still -> no scroll
        self.assertEqual(s.mouse.of("wheel"), [])
        s.frames("SCROLL", 30, cy=250)              # fingers raised ~0.55 hand
        up = sum(c[1] for c in s.mouse.of("wheel"))
        self.assertGreater(up, 120)                 # at least a notch per second
        s.frames("SCROLL", 30, cy=350)
        total = sum(c[1] for c in s.mouse.of("wheel"))
        self.assertLess(total, up)                  # now scrolling down

    def test_scroll_invert(self):
        s = Sim(scroll_invert=True)
        s.frames("SCROLL", 10, cy=300)
        s.frames("SCROLL", 30, cy=250)
        self.assertLess(sum(c[1] for c in s.mouse.of("wheel")), 0)

    def test_drag_style_scroll(self):
        s = Sim(scroll_style="drag")
        s.frames("SCROLL", 5, cy=300)
        for y in range(300, 200, -5):
            s.frames("SCROLL", 1, cy=y)
        self.assertGreater(sum(c[1] for c in s.mouse.of("wheel")), 0)

    def test_fist_freezes_cursor(self):
        s = Sim()
        s.frames("POINTING", 15, cx=300)
        s.frames("FIST", 5, cx=300)                  # close the hand in place...
        pos = s.gc.cursor
        s.frames("FIST", 20, cx=450)                 # ...then move it: cursor stays
        self.assertEqual(s.gc.cursor, pos)

    def test_palm_hold_fires_configured_action_once(self):
        s = Sim(palm_hold_action="listen")
        s.frames("OPEN_PALM", 60)
        self.assertEqual(s.events.count(("palm_hold", "listen")), 1)
        s2 = Sim()                                   # default: nothing
        s2.frames("OPEN_PALM", 60)
        self.assertEqual([e for e in s2.events if e[0] == "palm_hold"], [])

    def test_paused_does_nothing(self):
        s = Sim()
        s.gc.set_paused(True)
        s.frames("POINTING", 10, cx=200)
        s.frames("PINCH_INDEX", 5)
        s.frames("POINTING", 5)
        s.frames("SCROLL", 30, cy=200)
        self.assertEqual(s.mouse.calls, [])

    def test_pointer_disabled_still_allows_scroll(self):
        s = Sim(pointer_enabled=False)
        s.frames("POINTING", 20, cx=200)
        self.assertEqual(s.mouse.of("move"), [])


if __name__ == "__main__":
    unittest.main()
