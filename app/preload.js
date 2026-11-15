// Narrow, explicit bridge between the HUD page and the Electron main process.
// The page runs with contextIsolation and no Node access; it can only use these calls.
const { contextBridge, ipcRenderer } = require('electron');

const SEND = new Set(['set-ignore-mouse-events', 'release-focus', 'quit', 'set-login-item', 'notify', 'open-external']);
const INVOKE = new Set(['pick-folder']);
const ON = new Set(['hotkey']);

contextBridge.exposeInMainWorld('snap', {
    send: (channel, ...args) => { if (SEND.has(channel)) ipcRenderer.send(channel, ...args); },
    invoke: (channel, ...args) => (INVOKE.has(channel) ? ipcRenderer.invoke(channel, ...args) : Promise.reject(new Error('blocked'))),
    on: (channel, cb) => { if (ON.has(channel)) ipcRenderer.on(channel, (_e, ...args) => cb(null, ...args)); },
    clipboardWrite: (text) => navigator.clipboard.writeText(text),
});
