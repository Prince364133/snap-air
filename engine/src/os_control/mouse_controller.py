import pyautogui
import time

class MouseController:
    def __init__(self, screen_w, screen_h, frame_r=100, smoothening=5):
        self.screen_w = screen_w
        self.screen_h = screen_h
        # frame reduction to allow reaching the edges of the screen easily
        self.frame_r = frame_r 
        self.smoothening = smoothening
        
        self.plocX, self.plocY = 0, 0
        self.clocX, self.clocY = 0, 0
        
        # Disable PyAutoGUI fail-safe for gesture control to prevent crashes if cursor hits a corner
        pyautogui.FAILSAFE = False
        # Remove default delay to make it responsive
        pyautogui.PAUSE = 0
        
    def move(self, x, y, frame_w, frame_h):
        """Moves the mouse to mapped coordinates with smoothing."""
        # Convert coordinates
        x3 = int((x - self.frame_r) * self.screen_w / (frame_w - 2 * self.frame_r))
        y3 = int((y - self.frame_r) * self.screen_h / (frame_h - 2 * self.frame_r))
        
        # Clamp to screen bounds to avoid errors
        x3 = max(0, min(self.screen_w, x3))
        y3 = max(0, min(self.screen_h, y3))
        
        # Smoothen values
        self.clocX = self.plocX + (x3 - self.plocX) / self.smoothening
        self.clocY = self.plocY + (y3 - self.plocY) / self.smoothening
        
        # Move mouse
        pyautogui.moveTo(self.screen_w - self.clocX, self.clocY)
        self.plocX, self.plocY = self.clocX, self.clocY
        
    def click(self, button='left'):
        pyautogui.click(button=button)
        
    def double_click(self):
        pyautogui.doubleClick()
        
    def drag_to(self, x, y):
        # Dragging logic requires updating position while mouse is pressed
        pyautogui.dragTo(x, y, button='left')
