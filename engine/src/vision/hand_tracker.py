import os
import time
import urllib.request

import cv2
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision

MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/hand_landmarker/"
             "hand_landmarker/float16/latest/hand_landmarker.task")


class HandTracker:
    """MediaPipe HandLandmarker in VIDEO mode (tracks between frames instead of
    re-detecting every frame: faster and steadier)."""

    def __init__(self, max_hands=1, detection_con=0.6, track_con=0.5):
        model_path = os.path.join(os.path.dirname(__file__), "hand_landmarker.task")
        if not os.path.exists(model_path):
            print("[Vision] Downloading hand model…")
            urllib.request.urlretrieve(MODEL_URL, model_path)

        options = vision.HandLandmarkerOptions(
            base_options=python.BaseOptions(model_asset_path=model_path),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=max_hands,
            min_hand_detection_confidence=detection_con,
            min_hand_presence_confidence=0.5,
            min_tracking_confidence=track_con,
        )
        self.detector = vision.HandLandmarker.create_from_options(options)
        self.connections = vision.HandLandmarksConnections.HAND_CONNECTIONS
        self.results = None
        self._t0 = time.perf_counter()
        self._last_ts = -1

    def find_hands(self, img, draw=True):
        img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=img_rgb)
        ts = int((time.perf_counter() - self._t0) * 1000)
        if ts <= self._last_ts:
            ts = self._last_ts + 1
        self._last_ts = ts
        self.results = self.detector.detect_for_video(mp_image, ts)

        if draw and self.results and self.results.hand_landmarks:
            h, w, _ = img.shape
            for hand in self.results.hand_landmarks:
                for c in self.connections:
                    p1, p2 = hand[c.start], hand[c.end]
                    cv2.line(img, (int(p1.x * w), int(p1.y * h)), (int(p2.x * w), int(p2.y * h)), (0, 255, 0), 2)
                for lm in hand:
                    cv2.circle(img, (int(lm.x * w), int(lm.y * h)), 3, (255, 0, 255), cv2.FILLED)
        return img

    def find_position(self, img, hand_no=0, draw=False):
        """[[id, x_px, y_px], ...] for one hand, or [] if none."""
        lm_list = []
        if self.results and self.results.hand_landmarks and len(self.results.hand_landmarks) > hand_no:
            h, w = img.shape[:2]
            for i, lm in enumerate(self.results.hand_landmarks[hand_no]):
                # floats, not ints: sub-pixel precision matters when 640 px of
                # camera are stretched across a 1920 px screen
                lm_list.append([i, lm.x * w, lm.y * h])
        return lm_list
