const { ipcRenderer } = require('electron');

const cursor = document.getElementById('virtual-cursor');
const fpsDisplay = document.getElementById('fps-display');
const gestureDisplay = document.getElementById('gesture-display');
const notesPanel = document.getElementById('notes-panel');
const closeNotesBtn = document.getElementById('close-notes-btn');
const aiToast = document.getElementById('ai-toast');
const aiToastText = document.getElementById('ai-toast-text');

let isNotesOpen = false;

// We connect to the local Python WebSocket Server
function connectWebSocket() {
    const ws = new WebSocket('ws://localhost:8765');

    ws.onopen = () => {
        console.log('Connected to Snap Motion OS Engine');
    };

    ws.onmessage = (event) => {
        const state = JSON.parse(event.data);
        updateUI(state);
    };

    ws.onclose = () => {
        console.log('Disconnected. Retrying in 2 seconds...');
        setTimeout(connectWebSocket, 2000);
    };
}

// Map screen coordinates (Assume standard 1920x1080 for math, but we use percentages or exact px mapped by python)
function updateUI(state) {
    const { gesture, x, y, fps } = state;

    // Update HUD
    fpsDisplay.textContent = fps;
    gestureDisplay.textContent = gesture;

    // Update Virtual Cursor
    if (gesture !== "NONE") {
        cursor.style.display = 'block';
        
        // Since python sends raw coordinates from camera (0-640, 0-480), we scale them to window.
        // BUT wait, Python PyAutoGUI is ALREADY moving the real mouse.
        // For UI feedback, we can just hide the UI cursor and rely on Windows mouse, 
        // OR we can map it to show our glowing dot instead of the Windows cursor.
        // For now, let's pulse the UI based on gesture to show it's working.
        
        if (gesture === "PINCH_INDEX") {
            cursor.classList.add('pinch');
            document.body.style.background = 'rgba(0, 242, 254, 0.05)'; // Subtle flash
            setTimeout(() => document.body.style.background = 'transparent', 200);
        } else {
            cursor.classList.remove('pinch');
        }

        // Logic to trigger UI elements based on specific gesture holds
        // E.g., Open Palm could toggle notes
        if (gesture === "OPEN_PALM" && !isNotesOpen) {
            openNotes();
        }
    } else {
        cursor.style.display = 'none';
    }
}

function openNotes() {
    isNotesOpen = true;
    notesPanel.classList.remove('hidden');
    // Tell electron to allow mouse events so we can click inside the notes panel
    ipcRenderer.send('set-ignore-mouse-events', false);
    showToast('Notes Panel Opened');
}

function closeNotes() {
    isNotesOpen = false;
    notesPanel.classList.add('hidden');
    // Tell electron to ignore mouse events again to pass through to OS
    ipcRenderer.send('set-ignore-mouse-events', true, { forward: true });
}

closeNotesBtn.addEventListener('click', closeNotes);

function showToast(message) {
    aiToastText.textContent = message;
    aiToast.classList.remove('hidden');
    setTimeout(() => {
        aiToast.classList.add('hidden');
    }, 3000);
}

// Initialize
connectWebSocket();
