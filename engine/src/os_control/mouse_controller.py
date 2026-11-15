"""Thin OS mouse wrapper. Keeps all pyautogui calls in one place so the
gesture logic can be unit-tested with a fake mouse."""
import pyautogui

pyautogui.FAILSAFE = False
pyautogui.PAUSE = 0

WHEEL_DELTA = 120  # one wheel "notch" on Windows


class MouseController:
    def __init__(self):
        self.is_down = False

    @staticmethod
    def screen_size():
        w, h = pyautogui.size()
        return int(w), int(h)

    @staticmethod
    def position():
        p = pyautogui.position()
        return int(p[0]), int(p[1])

    def move_to(self, x, y):
        pyautogui.moveTo(int(x), int(y))

    def click(self, button="left", x=None, y=None):
        if x is not None:
            pyautogui.click(int(x), int(y), button=button)
        else:
            pyautogui.click(button=button)

    def down(self, x=None, y=None):
        if not self.is_down:
            if x is not None:
                pyautogui.moveTo(int(x), int(y))
            pyautogui.mouseDown(button="left")
            self.is_down = True

    def up(self):
        if self.is_down:
            pyautogui.mouseUp(button="left")
            self.is_down = False

    def wheel(self, delta):
        """Scroll by raw wheel delta (120 = one notch, positive = up)."""
        if delta:
            pyautogui.scroll(int(delta))

    def hwheel(self, delta):
        if delta:
            pyautogui.hscroll(int(delta))
