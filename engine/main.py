import cv2
import asyncio
import websockets
import json
import threading
import pyautogui

from src.vision.hand_tracker import HandTracker
from src.core.gesture_recognizer import GestureRecognizer
from src.os_control.mouse_controller import MouseController

# Global state for WebSocket broadcasting
current_state = {
    "gesture": "NONE",
    "x": 0,
    "y": 0,
    "fps": 0
}

clients = set()

async def ws_handler(websocket):
    clients.add(websocket)
    try:
        async for message in websocket:
            # Handle incoming UI messages (e.g., settings updates)
            data = json.loads(message)
            print(f"Received from UI: {data}")
    finally:
        clients.remove(websocket)

async def broadcast_state():
    while True:
        if clients:
            message = json.dumps(current_state)
            websockets.broadcast(clients, message)
        await asyncio.sleep(1/30) # 30 FPS broadcast rate

async def run_server():
    async with websockets.serve(ws_handler, "localhost", 8765):
        await broadcast_state()

def start_ws_server():
    print("Starting WebSocket server on ws://localhost:8765")
    asyncio.run(run_server())

def main_cv_loop():
    global current_state
    
    # Initialize Camera
    cap = cv2.VideoCapture(0)
    # Set resolution
    wCam, hCam = 640, 480
    cap.set(3, wCam)
    cap.set(4, hCam)
    
    # Initialize screen size
    wScr, hScr = pyautogui.size()
    
    # Initialize Modules
    tracker = HandTracker(detection_con=0.7, max_hands=1)
    recognizer = GestureRecognizer()
    mouse = MouseController(wScr, hScr)
    
    import time
    pTime = 0
    
    print("Starting Computer Vision Engine...")
    
    while True:
        success, img = cap.read()
        if not success:
            continue
            
        img = tracker.find_hands(img)
        lm_list = tracker.find_position(img, draw=False)
        
        gesture = "NONE"
        cx, cy = 0, 0
        
        if len(lm_list) != 0:
            gesture = recognizer.detect_gesture(lm_list)
            
            # Use Index finger tip (ID 8) for cursor location
            cx, cy = lm_list[8][1], lm_list[8][2]
            
            # Map gesture to OS Actions
            if gesture == "POINTING":
                # Move cursor
                mouse.move(cx, cy, wCam, hCam)
                
            elif gesture == "PINCH_INDEX":
                # Click (with a simple debouncing mechanism in reality)
                mouse.click()
                # Pause slightly to avoid multiple clicks
                time.sleep(0.2)
        
        # Calculate FPS
        cTime = time.time()
        fps = 1 / (cTime - pTime) if (cTime - pTime) > 0 else 0
        pTime = cTime
        
        # Update global state for UI
        current_state["gesture"] = gesture
        current_state["x"] = cx
        current_state["y"] = cy
        current_state["fps"] = int(fps)
        
        # Draw info on frame (for local debugging)
        cv2.putText(img, f'FPS: {int(fps)}', (20, 50), cv2.FONT_HERSHEY_PLAIN, 3, (255, 0, 0), 3)
        cv2.putText(img, f'Gesture: {gesture}', (20, 100), cv2.FONT_HERSHEY_PLAIN, 3, (0, 255, 0), 3)
        
        # Show Image
        cv2.imshow("Snap Motion OS - Debug View", img)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    # Start WebSocket server in a separate thread
    ws_thread = threading.Thread(target=start_ws_server, daemon=True)
    ws_thread.start()
    
    # Run the CV loop on the main thread (OpenCV requires this)
    main_cv_loop()
