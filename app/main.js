const { app, BrowserWindow, ipcMain, screen, globalShortcut, dialog, shell, Notification } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

let mainWindow;
let engineProc = null;

// ---------------------------------------------------------------- engine
// The HUD starts the Python engine itself so the user launches one thing.
// Set SNAP_AIR_EXTERNAL_ENGINE=1 to run the engine yourself (e.g. for debugging).
function startEngine() {
    if (process.env.SNAP_AIR_EXTERNAL_ENGINE === '1') return;
    const engineDir = path.join(__dirname, '..', 'engine');
    const venvPy = path.join(engineDir, '.venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');
    const python = fs.existsSync(venvPy) ? venvPy : 'python';
    const logDir = path.join(process.env.APPDATA || app.getPath('userData'), 'SnapAir');
    fs.mkdirSync(logDir, { recursive: true });
    const log = fs.openSync(path.join(logDir, 'engine.log'), 'w');
    engineProc = spawn(python, ['-u', 'main.py'], {
        cwd: engineDir,
        windowsHide: true,
        stdio: ['ignore', log, log],
        env: { ...process.env, PYTHONIOENCODING: 'utf-8' },
    });
    engineProc.on('exit', (code) => {
        console.log('Engine exited with code', code);
        engineProc = null;
    });
}

function stopEngine() {
    if (engineProc) {
        try { engineProc.kill(); } catch (e) { /* already gone */ }
        engineProc = null;
    }
}

// ---------------------------------------------------------------- window
function createWindow() {
    const { x, y, width, height } = screen.getPrimaryDisplay().workArea;

    mainWindow = new BrowserWindow({
        x, y, width, height,
        title: 'Snap Air HUD',
        transparent: true,
        frame: false,
        alwaysOnTop: true,
        hasShadow: false,
        skipTaskbar: true,
        resizable: false,
        webPreferences: { nodeIntegration: true, contextIsolation: false },
    });
    mainWindow.setAlwaysOnTop(true, 'floating');
    // Clicks pass through to the apps underneath except over HUD widgets
    mainWindow.setIgnoreMouseEvents(true, { forward: true });
    mainWindow.loadFile('index.html', { query: { port: process.env.SNAP_AIR_PORT || '8765' } });
    mainWindow.on('page-title-updated', (e) => e.preventDefault());
}

function sendHotkey(name) {
    if (!mainWindow) return;
    if (name === 'command') {
        mainWindow.setIgnoreMouseEvents(false);
        mainWindow.focus();
    }
    mainWindow.webContents.send('hotkey', name);
}

app.disableHardwareAcceleration();

app.whenReady().then(() => {
    startEngine();
    createWindow();

    const shortcuts = {
        'Control+Alt+Space': 'push_to_talk',   // speak one command, no wake word needed
        'Control+Alt+K': 'command',            // type a command
        'Control+Alt+G': 'toggle_gestures',    // emergency stop / resume hand control
        'Control+Alt+S': 'settings',
        'Control+Alt+H': 'toggle_hud',
        'Control+Alt+N': 'meeting',            // start / stop meeting notes
    };
    for (const [accel, name] of Object.entries(shortcuts)) {
        if (!globalShortcut.register(accel, () => sendHotkey(name))) {
            console.warn('Could not register shortcut', accel);
        }
    }
});

app.on('will-quit', () => {
    globalShortcut.unregisterAll();
    stopEngine();
});
app.on('window-all-closed', () => app.quit());

// ---------------------------------------------------------------- IPC
ipcMain.on('set-ignore-mouse-events', (event, ignore) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) win.setIgnoreMouseEvents(ignore, ignore ? { forward: true } : undefined);
});

// After typing a command, hand keyboard focus back to the app underneath
ipcMain.on('release-focus', () => {
    if (mainWindow) {
        mainWindow.setIgnoreMouseEvents(true, { forward: true });
        mainWindow.blur();
    }
});

ipcMain.handle('pick-folder', async () => {
    const r = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'] });
    return r.canceled ? null : r.filePaths[0];
});

ipcMain.on('quit', () => app.quit());

// Start at login (works in development and when packaged)
ipcMain.on('set-login-item', (_e, enabled) => {
    try {
        const opts = { openAtLogin: !!enabled };
        if (!app.isPackaged) { opts.path = process.execPath; opts.args = [app.getAppPath()]; }
        app.setLoginItemSettings(opts);
    } catch (e) { console.warn('login item:', e.message); }
});

ipcMain.on('notify', (_e, { title, body }) => {
    if (Notification.isSupported()) new Notification({ title, body, silent: false }).show();
});

ipcMain.on('open-external', (_e, url) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
});
