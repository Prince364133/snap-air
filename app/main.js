const { app, BrowserWindow, ipcMain, screen, globalShortcut, dialog, shell, Notification, Tray, Menu, nativeImage, nativeTheme } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const crypto = require('crypto');

let mainWindow;
let tray = null;
let engineProc = null;
let quitting = false;
const crashTimes = [];
const AUTOSTART = process.argv.includes('--autostart');

// ---------------------------------------------------------------- engine
// The HUD starts the Python engine itself so the user launches one thing, and
// restarts it with backoff if it crashes (gives up after 4 crashes in 2 minutes).
// Set SNAP_AIR_EXTERNAL_ENGINE=1 to run the engine yourself (e.g. for debugging).
function logDir() {
    const d = path.join(process.env.APPDATA || app.getPath('userData'), 'SnapAir');
    fs.mkdirSync(d, { recursive: true });
    return d;
}

// ---------------------------------------------------------------- engine auth
// The engine's WebSocket only accepts the HUD: a random per-launch token plus an
// Origin allow-list (engine/src/server/auth.py). When we spawn the engine we make
// the token and pass it in SNAPY_WS_TOKEN. When the engine runs on its own
// (SNAP_AIR_EXTERNAL_ENGINE=1, e.g. `pnpm dev`) it makes one and writes it to
// <data dir>/ws_token, which we read each time the page (re)connects.
const WS_TOKEN = crypto.randomBytes(32).toString('base64url');

function dataDir() {
    // same rule as engine/src/storage.py data_dir()
    if (process.env.SNAP_AIR_DATA) return process.env.SNAP_AIR_DATA;
    return process.env.APPDATA ? path.join(process.env.APPDATA, 'SnapAir') : path.join(require('os').homedir(), '.snap-air');
}

function engineToken() {
    if (process.env.SNAP_AIR_EXTERNAL_ENGINE !== '1') return WS_TOKEN;
    try { return fs.readFileSync(path.join(dataDir(), 'ws_token'), 'utf8').trim(); }
    catch (e) { return ''; }            // engine not up yet: the page retries
}

function startEngine() {
    if (process.env.SNAP_AIR_EXTERNAL_ENGINE === '1' || quitting) return;
    // Installed app: the frozen engine ships in resources/engine (no Python needed).
    // Development: run main.py with the project's virtualenv.
    let cmd, args, engineDir;
    if (app.isPackaged) {
        engineDir = path.join(process.resourcesPath, 'engine');
        cmd = path.join(engineDir, 'snapy-engine.exe');
        args = AUTOSTART ? ['--autostart'] : [];
    } else {
        engineDir = path.join(__dirname, '..', 'engine');
        const venvPy = path.join(engineDir, '.venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');
        cmd = fs.existsSync(venvPy) ? venvPy : 'python';
        args = ['-u', 'main.py', ...(AUTOSTART ? ['--autostart'] : [])];
    }
    const log = fs.openSync(path.join(logDir(), 'engine.log'), 'a');
    engineProc = spawn(cmd, args, {
        cwd: engineDir,
        windowsHide: true,
        stdio: ['ignore', log, log],
        env: { ...process.env, PYTHONIOENCODING: 'utf-8', SNAP_AIR_AUTOSTART: AUTOSTART ? '1' : '0', SNAPY_WS_TOKEN: WS_TOKEN },
    });
    engineProc.on('exit', (code) => {
        engineProc = null;
        if (quitting) return;
        const now = Date.now();
        crashTimes.push(now);
        while (crashTimes.length && now - crashTimes[0] > 120000) crashTimes.shift();
        if (crashTimes.length >= 4) {
            notify('Snapy stopped', 'The engine keeps crashing. Open the log from the tray menu, then choose Restart engine.');
            updateTray();
            return;
        }
        const delay = 1000 * 2 ** (crashTimes.length - 1);      // 1 s, 2 s, 4 s
        console.log(`Engine exited (${code}); restarting in ${delay} ms`);
        setTimeout(startEngine, delay);
    });
    updateTray();
}

function stopEngine() {
    if (engineProc) {
        try { engineProc.kill(); } catch (e) { /* already gone */ }
        engineProc = null;
    }
}

function restartEngine() {
    crashTimes.length = 0;
    if (engineProc) {
        const p = engineProc;
        p.once('exit', () => setTimeout(startEngine, 500));
        engineProc = null;
        try { p.kill(); } catch (e) { startEngine(); }
    } else startEngine();
}

function appIcon() { return path.join(__dirname, 'assets', 'snapy-app-256.png'); }
// tray: white logo on a dark taskbar, black logo on a light one
function trayIcon() {
    return nativeImage.createFromPath(path.join(__dirname, 'assets', nativeTheme.shouldUseDarkColors ? 'snapy-white-32.png' : 'snapy-black-32.png'));
}

function notify(title, body) {
    if (Notification.isSupported()) new Notification({ title, body, icon: appIcon() }).show();
}

// ---------------------------------------------------------------- window
function createWindow() {
    const { x, y, width, height } = screen.getPrimaryDisplay().workArea;
    mainWindow = new BrowserWindow({
        x, y, width, height,
        title: 'Snapy HUD',
        transparent: true,
        frame: false,
        alwaysOnTop: true,
        hasShadow: false,
        skipTaskbar: true,
        resizable: false,
        icon: appIcon(),
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            contextIsolation: true,
            nodeIntegration: false,
            sandbox: true,
        },
    });
    mainWindow.setAlwaysOnTop(true, 'floating');
    // Clicks pass through to the apps underneath except over HUD widgets
    mainWindow.setIgnoreMouseEvents(true, { forward: true });
    mainWindow.loadFile('index.html', { query: { port: process.env.SNAP_AIR_PORT || '8765', autostart: AUTOSTART ? '1' : '0' } });
    mainWindow.on('page-title-updated', (e) => e.preventDefault());
    // never let the overlay navigate away or open windows
    mainWindow.webContents.on('will-navigate', (e) => e.preventDefault());
    mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
}

function sendHotkey(name) {
    if (!mainWindow) return;
    if (['command', 'assistant', 'today', 'settings'].includes(name)) {
        mainWindow.setIgnoreMouseEvents(false);
        mainWindow.focus();
    }
    mainWindow.webContents.send('hotkey', name);
}

// ---------------------------------------------------------------- tray
function updateTray() {
    if (!tray) return;
    const running = !!engineProc || process.env.SNAP_AIR_EXTERNAL_ENGINE === '1';
    const login = app.getLoginItemSettings().openAtLogin;
    tray.setToolTip(running ? 'Snapy — running on this laptop' : 'Snapy — engine stopped');
    tray.setContextMenu(Menu.buildFromTemplate([
        { label: running ? 'Snapy is running' : 'Engine stopped', enabled: false },
        { type: 'separator' },
        { label: 'Open assistant', accelerator: 'Ctrl+Alt+J', click: () => sendHotkey('assistant') },
        { label: 'Today', accelerator: 'Ctrl+Alt+T', click: () => sendHotkey('today') },
        { label: 'Talk', accelerator: 'Ctrl+Alt+Space', click: () => sendHotkey('push_to_talk') },
        { label: 'Meeting notes', accelerator: 'Ctrl+Alt+N', click: () => sendHotkey('meeting') },
        { label: 'Settings', accelerator: 'Ctrl+Alt+S', click: () => sendHotkey('settings') },
        { type: 'separator' },
        { label: 'Show / hide HUD', accelerator: 'Ctrl+Alt+H', click: () => sendHotkey('toggle_hud') },
        { label: 'Pause / resume gestures', accelerator: 'Ctrl+Alt+G', click: () => sendHotkey('toggle_gestures') },
        { label: 'Start at login', type: 'checkbox', checked: login, click: (i) => setLoginItem(i.checked) },
        { type: 'separator' },
        { label: 'Restart engine', click: restartEngine },
        { label: 'Open data folder', click: () => shell.openPath(logDir()) },
        { label: 'Open engine log', click: () => shell.openPath(path.join(logDir(), 'engine.log')) },
        { type: 'separator' },
        { label: 'Quit Snapy', click: () => app.quit() },
    ]));
}

function setLoginItem(enabled) {
    try {
        // '--autostart' lets Snapy know it was started by Windows (quiet start + morning greeting).
        // Note: openAtLogin doesn't work for APPX/MSIX packages — ship an NSIS installer.
        const opts = { openAtLogin: !!enabled, args: ['--autostart'] };
        if (!app.isPackaged) { opts.path = process.execPath; opts.args = [app.getAppPath(), '--autostart']; }
        app.setLoginItemSettings(opts);
    } catch (e) { console.warn('login item:', e.message); }
    updateTray();
}

app.disableHardwareAcceleration();

if (!app.requestSingleInstanceLock()) {
    app.quit();
} else {
    app.on('second-instance', () => sendHotkey('assistant'));
    app.whenReady().then(() => {
        startEngine();
        createWindow();
        tray = new Tray(trayIcon());
        nativeTheme.on('updated', () => tray && tray.setImage(trayIcon()));
        tray.on('click', () => sendHotkey('assistant'));
        updateTray();

        const shortcuts = {
            'Control+Alt+Space': 'push_to_talk',   // talk / interrupt
            'Control+Alt+K': 'command',            // type
            'Control+Alt+J': 'assistant',          // assistant drawer
            'Control+Alt+T': 'today',              // today drawer
            'Control+Alt+G': 'toggle_gestures',    // emergency stop / resume hand control
            'Control+Alt+S': 'settings',
            'Control+Alt+H': 'toggle_hud',
            'Control+Alt+N': 'meeting',            // start / stop meeting notes
        };
        for (const [accel, name] of Object.entries(shortcuts)) {
            if (!globalShortcut.register(accel, () => sendHotkey(name))) console.warn('Could not register shortcut', accel);
        }
    });
}

app.on('before-quit', () => { quitting = true; });
app.on('will-quit', () => {
    globalShortcut.unregisterAll();
    stopEngine();
});
app.on('window-all-closed', () => app.quit());

// Defence in depth for any web contents (the HUD, a devtools window, anything a future
// change adds): no navigation, no new windows, no <webview>.
app.on('web-contents-created', (_e, contents) => {
    contents.on('will-navigate', (e) => e.preventDefault());
    contents.on('will-attach-webview', (e) => e.preventDefault());
    contents.setWindowOpenHandler(() => ({ action: 'deny' }));
});

// ---------------------------------------------------------------- IPC
// Every channel answers only our own HUD page loaded from our own index.html.
function fromHud(event) {
    if (!mainWindow || mainWindow.isDestroyed() || event.sender !== mainWindow.webContents) return false;
    const frame = event.senderFrame;
    return !frame || (frame === mainWindow.webContents.mainFrame && frame.url.startsWith('file://'));
}

function onHud(channel, fn) {
    ipcMain.on(channel, (event, ...args) => { if (fromHud(event)) fn(event, ...args); });
}

onHud('set-ignore-mouse-events', (_e, ignore) => {
    mainWindow.setIgnoreMouseEvents(!!ignore, ignore ? { forward: true } : undefined);
});

// After typing a command, hand keyboard focus back to the app underneath
onHud('release-focus', () => {
    mainWindow.setIgnoreMouseEvents(true, { forward: true });
    mainWindow.blur();
});

ipcMain.handle('pick-folder', async (event) => {
    if (!fromHud(event)) return null;
    const r = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'] });
    return r.canceled ? null : r.filePaths[0];
});

onHud('quit', () => app.quit());
// Only our own HUD page may ask for the engine token
ipcMain.handle('ws-token', (event) => (fromHud(event) ? engineToken() : ''));
onHud('set-login-item', (_e, enabled) => setLoginItem(enabled));
onHud('notify', (_e, msg) => { if (msg && msg.title) notify(String(msg.title).slice(0, 120), String(msg.body || '').slice(0, 400)); });
onHud('open-external', (_e, url) => {
    // only real web links: never file:, ms-settings:, or a custom protocol handler
    let u = null;
    try { u = typeof url === 'string' ? new URL(url) : null; } catch (e) { u = null; }
    if (u && (u.protocol === 'https:' || u.protocol === 'http:')) shell.openExternal(u.toString());
});
