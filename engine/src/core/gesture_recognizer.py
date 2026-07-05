import math

class GestureRecognizer:
    def __init__(self):
        # Tip landmarks according to MediaPipe
        # 4: Thumb, 8: Index, 12: Middle, 16: Ring, 20: Pinky
        self.tip_ids = [4, 8, 12, 16, 20]
        
    def fingers_up(self, lm_list):
        """
        Returns a list of 5 integers (0 or 1) indicating which fingers are up.
        Index 0: Thumb, 1: Index, 2: Middle, 3: Ring, 4: Pinky
        """
        fingers = []
        if len(lm_list) == 0:
            return fingers
            
        # Thumb: compare x coordinates (assuming right hand for now, needs refinement for robust left/right)
        # Usually checking if thumb tip is to the right/left of the joint.
        # A simpler robust check for general open hand: distance from wrist.
        # But for exact "up" state, checking y is common for 4 fingers, and x for thumb.
        if lm_list[self.tip_ids[0]][1] > lm_list[self.tip_ids[0] - 1][1]:
            fingers.append(1)
        else:
            fingers.append(0)
            
        # 4 Fingers: compare y coordinates (lower y value means it's "higher" on screen)
        for id in range(1, 5):
            if lm_list[self.tip_ids[id]][2] < lm_list[self.tip_ids[id] - 2][2]:
                fingers.append(1)
            else:
                fingers.append(0)
                
        return fingers
        
    def get_distance(self, p1, p2, lm_list):
        """Calculates distance between two landmark points by ID."""
        if len(lm_list) == 0:
            return 0, [0,0], [0,0]
            
        x1, y1 = lm_list[p1][1], lm_list[p1][2]
        x2, y2 = lm_list[p2][1], lm_list[p2][2]
        
        # Center point
        cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
        
        # Euclidean distance
        length = math.hypot(x2 - x1, y2 - y1)
        
        return length, [x1, y1], [x2, y2], [cx, cy]

    def detect_gesture(self, lm_list):
        """
        Analyzes the landmark list and returns the detected gesture string.
        """
        if len(lm_list) == 0:
            return "NONE"
            
        fingers = self.fingers_up(lm_list)
        
        # Check closed fist (all fingers down)
        if fingers.count(1) == 0:
            return "FIST"
            
        # Check open palm (all fingers up)
        if fingers.count(1) == 5:
            return "OPEN_PALM"
            
        # Pinch Index (Thumb and Index close)
        length_index_thumb, _, _, _ = self.get_distance(4, 8, lm_list)
        if length_index_thumb < 30 and fingers[2] == 0 and fingers[3] == 0 and fingers[4] == 0:
            return "PINCH_INDEX"
            
        # Pinch Middle (Thumb and Middle close)
        length_middle_thumb, _, _, _ = self.get_distance(4, 12, lm_list)
        if length_middle_thumb < 30 and fingers[1] == 0 and fingers[3] == 0 and fingers[4] == 0:
            return "PINCH_MIDDLE"

        # Pointing (Only index finger up)
        if fingers == [0, 1, 0, 0, 0] or fingers == [1, 1, 0, 0, 0]:
            return "POINTING"
            
        return "UNKNOWN"
