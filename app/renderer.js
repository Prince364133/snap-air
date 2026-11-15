/* Snapy HUD renderer */
// contextIsolation: the page talks to Electron only through the preload bridge
const ipcRenderer = window.snap || { send() {}, invoke: async () => null, on() {} };

// Line icons (no emoji icons in the UI chrome)
const ICONS = {
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    chat: '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
    note: '<path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5M9 13h7M9 17h5"/>',
    check: '<rect x="3" y="3" width="18" height="18" rx="4"/><path d="m8 12 3 3 5-6"/>',
    brain: '<path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 3 3h0a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2z"/><path d="M15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-3 3h0a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    up: '<path d="M12 19V5M5 12l7-7 7 7"/>',
    bell: '<path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0"/>',
    phone: '<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z"/>',
    coffee: '<path d="M17 8h1a4 4 0 0 1 0 8h-1M3 8h14v9a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4z"/><path d="M6 2v2M10 2v2M14 2v2"/>',
    moon: '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 16v-4M12 8h0"/>',
    shield: '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
    chart: '<path d="M3 3v18h18M7 15l4-4 3 3 5-6"/>',
    rocket: '<path d="M5 15c-1 1-2 5-2 5s4-1 5-2M14 4c3-1 6 0 6 0s1 3 0 6l-7 7-6-6z"/><circle cx="15" cy="9" r="1.5"/>',
    voice: '<path d="M2 10v4M6 6v12M10 3v18M14 8v8M18 5v14M22 10v4"/>',
    hand: '<path d="M18 11V6a2 2 0 0 0-4 0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.9-6-2.4l-3.6-3.6a2 2 0 0 1 2.8-2.8L7 15"/>',
    star: '<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z"/>',
    leaf: '<path d="M11 20A7 7 0 0 1 4 13c0-6 6-9 16-9 0 10-3 16-9 16z"/><path d="M4 20c4-4 7-6 11-8"/>',
};
const svg = (name, size = 16) => `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ''}</svg>`;
function applyIcons(root = document) {
    root.querySelectorAll('[data-icon]').forEach((el) => { if (!el.dataset.iconDone) { el.innerHTML = svg(el.dataset.icon, el.classList.contains('ib') ? 15 : 16); el.dataset.iconDone = '1'; } });
}

// ------------------------------------------------------------------ utils
const $ = (id) => document.getElementById(id);
const NAME = () => ((typeof S !== 'undefined' && S && S.agent_name) || 'Snapy').trim() || 'Snapy';
const esc = (s) => String(s ?? '').replace(/[&<>'"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[c]));
function h(tag, attrs = {}, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
        if (k === 'class') e.className = v;
        else if (k === 'html') e.innerHTML = v;
        else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
        else if (v !== undefined && v !== null && v !== false) e.setAttribute(k, v === true ? '' : v);
    }
    for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) e.append(c.nodeType ? c : document.createTextNode(c));
    return e;
}
function fmtDur(sec) {
    sec = Math.round(sec || 0);
    const hh = Math.floor(sec / 3600), mm = Math.floor((sec % 3600) / 60);
    if (hh) return `${hh}h ${String(mm).padStart(2, '0')}m`;
    return mm ? `${mm}m` : `${sec}s`;
}
const clock = (ts) => new Date(ts * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
function dueText(iso) {
    if (!iso) return '';
    const d = new Date(iso), now = new Date();
    const t = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    const tomorrow = new Date(now); tomorrow.setDate(now.getDate() + 1);
    if (d.toDateString() === now.toDateString()) return (d < now ? 'Overdue · ' : 'Today ') + t;
    if (d.toDateString() === tomorrow.toDateString()) return 'Tomorrow ' + t;
    return d.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' }) + ' ' + t;
}
function dayLabel(ts) {
    const d = new Date(ts * 1000), now = new Date();
    const y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === now.toDateString()) return 'Today';
    if (d.toDateString() === y.toDateString()) return 'Yesterday';
    return d.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'short' });
}
const COLORS = ['#0a84ff', '#30d158', '#ff9f0a', '#bf5af2', '#ff375f', '#64d2ff', '#ffd60a', '#8e8e93'];

// ------------------------------------------------------------------ state
let socket = null, connected = false;
let S = {}, profile = {}, memories = [], notes = [], tasks = [], catalogue = [], activity = null, routine = {};
let models = {}, meeting = {}, eng = {}, briefing = null, scan = null, dataDir = '';
let lastTranscript = { text: '', t: 0 };
let focus = {}, contexts = [], noteFilter = 'all', openNoteId = null;
let attention = null;      // today's Shorts/Reels count on this PC (engine: src/life/attention.py)
let flashUntil = 0;

function send(obj) {
    if (socket && socket.readyState === WebSocket.OPEN) { socket.send(JSON.stringify(obj)); return true; }
    return false;
}

// The engine only accepts this page: it checks the Origin (file://) and a per-launch
// token that Electron hands over through the preload bridge (main.js "engine auth").
// The token goes in ?token= because browsers can't set headers on a WebSocket. It is
// fetched on every attempt: with an external engine (pnpm dev) it may appear later.
async function connect() {
    const port = new URLSearchParams(location.search).get('port') || '8765';
    let token = '';
    try { token = (window.snap && window.snap.wsToken) ? (await window.snap.wsToken()) || '' : ''; } catch (e) { token = ''; }
    socket = new WebSocket(`ws://localhost:${port}/?token=${encodeURIComponent(token)}`);
    socket.onopen = () => { connected = true; renderIsland(); };
    socket.onclose = () => { connected = false; renderIsland(); setTimeout(connect, 1500); };
    socket.onerror = () => {};
    socket.onmessage = (ev) => {
        let d; try { d = JSON.parse(ev.data); } catch (e) { return; }
        const fn = HANDLERS[d.type];
        if (fn) { try { fn(d); } catch (e) { console.error(d.type, e); } }
    };
}

const HANDLERS = {
    hello(d) {
        S = d.settings; profile = d.profile; memories = d.memories || []; notes = d.notes || []; tasks = d.tasks || [];
        catalogue = d.catalogue || []; activity = d.activity; routine = d.routine || {}; meeting = d.meeting || {};
        dataDir = d.data_dir || '';
        models = d;
        focus = d.focus || {}; contexts = d.contexts || [];
        SETUP = d.setup || null; setTimeout(renderSetup, 0);
        ipcRenderer.send('set-login-item', !!S.start_at_login);
        renderAll();
        if (d.onboarding_needed) openOnboarding();
        if (d.cloud_preview) showCloudPreview(d.cloud_preview);
        if (d.attention) { attention = d.attention; renderAttention(); }
    },
    attention(d) { attention = d; renderAttention(); },
    cloud_preview(d) { showCloudPreview(d.sample); },
    state_update(d) { eng = d; renderIsland(); renderCursor(); updateMeters(); },
    settings(d) { S = d.settings; renderName(); bindSettings(); if (activeTab === 'settings') renderSettings(); renderSuggestions(); },
    memory(d) { profile = d.profile; memories = d.memories; renderMemory(); },
    tasks(d) { tasks = d.tasks; renderTasks(); renderGlance(); },
    notes(d) { notes = d.notes; renderNotes(); renderGlance(); renderTodayExtras(); },
    note_added(d) { notes.unshift(d.note); renderNotes(); renderGlance(); renderTodayExtras(); },
    today(d) { tasks = d.tasks; activity = d.activity; meeting = d.meeting; renderTasks(); renderGlance(); renderMeeting(); },
    activity(d) { activity = d.summary; routine = d.routine || routine; renderActivity(); renderGlance(); },
    setup(d) { SETUP = d; renderSetup(); },
    models(d) { models = d; if (activeTab === 'settings') renderModelSection(); if (obOpen) renderObStep(); },
    meeting(d) { meeting = d; renderMeeting(); renderIsland(); },
    chat_message(d) { renderMessage(d); },
    assistant_state(d) { if (d.state === 'thinking') showThinking(); else hideThinking(); },
    transcript(d) { lastTranscript = { text: d.text, t: Date.now() }; renderIsland(); },
    toast(d) { showToast(d.message, d.ok !== false); },
    banner(d) { showBanner(d); },
    briefing(d) { briefing = d; renderBriefingCard(); if (d.show) showGreeting(d); },
    wrapup(d) { showBanner({ kind: 'info', title: 'Your day', text: d.text }); },
    memory_learned(d) { showToast('Learned: ' + d.items.join('; '), true); },
    scan(d) { scan = d; if (obOpen) renderObStep(); },
    onboarding_done(d) { closeOnboarding(); if (d && d.start_at_login !== undefined) ipcRenderer.send('set-login-item', !!d.start_at_login); },
    action_log() {},
    gesture_event(d) { if (['click', 'double_click', 'right_click'].includes(d.event)) flashUntil = Date.now() + 250; },
    caption(d) { showCaption(d.text); },
    barge_in() { hideCaption(); },
    focus(d) { focus = d; renderFocus(); },
    contexts(d) { contexts = d.contexts; renderContexts(); },
    onboarding_voice(d) { if (d.step === 'name') { closeOnboarding(); openDrawer('assistant'); } },
    ui_action(d) {
        if (d.action === 'open_settings') { openDrawer('settings'); if (d.focus) highlightSetting(d.focus); }
        else if (d.action === 'open_note') { openDrawer('notes'); openNoteDetail(d.id); }
        else if (d.action === 'open_drawer') { if (d.tab === 'notes' && d.filter) setNoteFilter(d.filter); openDrawer(d.tab || 'assistant'); }
        else if (d.action === 'close_panels') closeDrawer();
        else if (d.action === 'toggle_hud') document.body.classList.toggle('hud-hidden');
        else if (d.action === 'quit') setTimeout(shutdownSnapy, 1200);       // let "See you soon" be heard
        else if (d.action === 'emoji') emojiBurst(d.emojis || []);
    },
    video_capture(d) { videoCapture = d; renderIsland(); },
};

// ------------------------------------------------------------------- orbs
const orbs = {
    island: new Orb($('island-orb')), drawer: new Orb($('drawer-orb')),
    empty: new Orb($('empty-orb')), greeting: new Orb($('greeting-orb')),
};
const GESTURE_SHORT = { POINTING: 'Point', SCROLL: 'Scroll', PINCH_INDEX: 'Pinch', PINCH_MIDDLE: 'Right-click', OPEN_PALM: 'Palm', FIST: 'Hold' };
let captionAt = 0;
function showCaption(text) {
    captionAt = Date.now();
    const cap = $('island-caption');
    if (cap) {
        cap.textContent = text;
        cap.classList.remove('hidden');
    }
}
function hideCaption() {
    const cap = $('island-caption');
    if (cap) cap.classList.add('hidden');
}
function renderFocus() {
    const on = focus && focus.active;
    $('island-focus').classList.toggle('hidden', !on);
}
setInterval(() => {
    if (focus && focus.active) {
        focus.remaining = Math.max(0, (focus.remaining || 0) - 1);
        $('focus-time').textContent = `${Math.floor(focus.remaining / 60)}:${String(focus.remaining % 60).padStart(2, '0')}`;
        if (!focus.remaining) { focus.active = false; renderFocus(); }
    }
}, 1000);
$('island-focus').addEventListener('click', (e) => { e.stopPropagation(); send({ type: 'focus_stop' }); });
// any element with data-open="<tab>" opens that drawer tab
document.addEventListener('click', (e) => {
    const t = e.target.closest('[data-open]');
    if (t) { e.stopPropagation(); toggleDrawer(t.dataset.open); }
}, true);
function orbState() {
    if (!connected) return ['off', 0];
    if (eng.assistant === 'speaking') return ['speaking', Math.min(1, (eng.speak_level || 0) * 7)];
    if (eng.assistant === 'thinking') return ['thinking', 0.3];
    if (eng.voice_armed || /Hearing|Listening/.test(eng.voice_status || '')) return ['listening', Math.min(1, Math.sqrt(eng.mic_level || 0) * 4)];
    return ['idle', 0];
}

// ----------------------------------------------------------------- island
function renderIsland() {
    const [st, lvl] = orbState();
    for (const o of Object.values(orbs)) { o.setState(st); o.setLevel(lvl); o.setRecording(!!meeting.recording); }
    let text;
    if (!connected) text = `Starting ${NAME()}…`;
    else if (Date.now() - lastTranscript.t < 2500 && lastTranscript.text) text = `“${lastTranscript.text}”`;
    else if (eng.assistant === 'speaking') text = 'Speaking…';
    else if (eng.assistant === 'thinking') text = 'Thinking…';
    else if (eng.voice_armed || /Hearing/.test(eng.voice_status || '')) text = 'Listening…';
    else if (/Transcrib/.test(eng.voice_status || '')) text = '…';
    else if (/Loading|failed|unavailable/i.test(eng.voice_status || '')) text = eng.voice_status;
    else if (SETUP && SETUP.running && !SETUP.complete && (SETUP.items || []).length) text = `Setting up… ${setupPct(SETUP)}%`;
    else if (videoCapture && videoCapture.recording) text = 'Listening to the video…';
    else if (meeting.recording) text = 'Taking meeting notes';
    else if (eng.voice_mode === 'push') text = 'Press Ctrl+Alt+Space to talk';
    else text = `Say “${NAME()}…”`;
    $('island-status').textContent = text;
    const aiDot = $('island-ai-dot');
    if (aiDot) {
        aiDot.classList.remove('dot-orange', 'dot-green', 'dot-red');
        if (!connected || eng.brain === 'none') {
            aiDot.classList.add('dot-red');
            aiDot.title = 'No AI configured or offline';
        } else if (eng.brain === 'cloud') {
            aiDot.classList.add('dot-green');
            aiDot.title = 'AI active (Cloud API)';
        } else {
            aiDot.classList.add('dot-orange');
            aiDot.title = 'AI active (Local on-device)';
        }
    }
    const gestureOn = eng.camera === 'ok' && eng.hand_visible && !eng.gestures_paused;
    $('island-gesture').classList.toggle('hidden', !gestureOn);
    if (gestureOn) $('island-gesture').textContent = (GESTURE_SHORT[eng.gesture] || 'Hand');
    if (st === 'idle' && Date.now() - captionAt > 2500) hideCaption();
    $('island-rec').classList.toggle('hidden', !meeting.recording);

    if (meeting.recording && meeting.elapsed !== undefined) {
        const e = eng.recording ? Math.max(meeting.elapsed, 0) : 0;
        $('rec-time').textContent = `${Math.floor(e / 60)}:${String(e % 60).padStart(2, '0')}`;
    }
    $('chat-mic').classList.toggle('live', !!eng.voice_armed);
}
// keep the recording timer ticking smoothly
setInterval(() => { if (meeting.recording) { meeting.elapsed = (meeting.elapsed || 0) + 1; renderIsland(); } }, 1000);

// ------------------------------------------------- hold-to-shutdown (3s)
let holdTimer = null;
let holdStart = 0;
let didHoldShutdown = false;

function startHoldShutdown(e) {
    if (e && e.button !== undefined && e.button !== 0) return;
    if (e.target && e.target.closest('#island-focus')) return;
    holdStart = Date.now();
    didHoldShutdown = false;
    clearInterval(holdTimer);
    holdTimer = setInterval(() => {
        const elapsed = Date.now() - holdStart;
        if (elapsed >= 500) {
            $('island').classList.add('holding-shutdown');
            const remain = Math.max(1, Math.ceil((3000 - elapsed) / 1000));
            $('island-status').textContent = `Shutting down in ${remain}s…`;
        }
        if (elapsed >= 3000) {
            clearInterval(holdTimer);
            holdTimer = null;
            didHoldShutdown = true;
            $('island').classList.remove('holding-shutdown');
            $('island').classList.add('shut-down');
            $('island-status').textContent = 'Shutting down Snapy…';
            shutdownSnapy();
        }
    }, 50);
}

function cancelHoldShutdown() {
    if (holdTimer) {
        clearInterval(holdTimer);
        holdTimer = null;
    }
    if (!didHoldShutdown && $('island').classList.contains('holding-shutdown')) {
        $('island').classList.remove('holding-shutdown');
        renderIsland();
    }
}

function shutdownSnapy() {
    try { send({ type: 'shutdown' }); } catch (e) {}
    setTimeout(() => {
        try { ipcRenderer.send('quit'); } catch (e) {}
        try { window.close(); } catch (e) {}
    }, 200);
}

const islandEl = $('island');
islandEl.addEventListener('mousedown', startHoldShutdown);
islandEl.addEventListener('mouseup', cancelHoldShutdown);
islandEl.addEventListener('mouseleave', cancelHoldShutdown);
window.addEventListener('mouseup', cancelHoldShutdown);

islandEl.addEventListener('touchstart', (e) => startHoldShutdown(e.touches ? e.touches[0] : e), { passive: true });
islandEl.addEventListener('touchend', cancelHoldShutdown);
islandEl.addEventListener('touchcancel', cancelHoldShutdown);

islandEl.addEventListener('click', (e) => {
    if (didHoldShutdown) {
        didHoldShutdown = false;
        e.stopPropagation();
        e.preventDefault();
        return;
    }
    if (e.target.id === 'island-orb') { talk(); return; }
    if (e.target.closest('#island-focus')) return;
    toggleDrawer();
});
function talk() {
    if (eng.assistant === 'speaking' || eng.assistant === 'thinking') send({ type: 'interrupt' });
    else if (eng.voice_armed) send({ type: 'cancel_listen' });
    else send({ type: 'push_to_talk', seconds: 7 });
}

// ------------------------------------------------- click-through handling
let capturing = null;
function setCapture(on) {
    if (on !== capturing) { capturing = on; ipcRenderer.send('set-ignore-mouse-events', !on); }
}
document.addEventListener('mousemove', (e) => setCapture(!!e.target.closest('.interactive')));
document.addEventListener('mouseleave', () => setCapture(false));
setCapture(false);

// ----------------------------------------------------------------- drawer
let activeTab = 'assistant';
function openDrawer(tab) {
    $('drawer').classList.add('open');
    document.body.classList.add('drawer-open');
    $('drawer').setAttribute('aria-hidden', 'false');
    if (tab) selectTab(tab);
    if (activeTab === 'assistant') setTimeout(() => $('chat-input').focus(), 120);
}
function closeDrawer() {
    $('drawer').classList.remove('open');
    document.body.classList.remove('drawer-open');
    $('drawer').setAttribute('aria-hidden', 'true');
    ipcRenderer.send('release-focus');
    capturing = false;   // main process just made the window click-through
}
function toggleDrawer(tab) { $('drawer').classList.contains('open') && (!tab || tab === activeTab) ? closeDrawer() : openDrawer(tab); }
$('drawer-close').onclick = closeDrawer;
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !obOpen) closeDrawer(); });

function selectTab(tab) {
    if (tab === 'notes' && activeTab === 'notes' && openNoteId) {
        openNoteId = null;
        $('drawer').classList.remove('wide');
        renderNotes();
        return;
    }
    activeTab = tab;
    document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
    document.querySelectorAll('.tab-panel').forEach((p) => p.classList.toggle('active', p.dataset.panel === tab));
    $('drawer').classList.toggle('wide', tab === 'notes' && !!openNoteId);
    if (tab === 'today' || tab === 'tasks') send({ type: 'request', what: 'today' });
    if (tab === 'help') renderHelp();
    if (tab === 'activity') send({ type: 'request', what: 'activity' });
    if (tab === 'settings') { send({ type: 'request', what: 'models' }); renderSettings(); }
    if (tab === 'memory') renderMemory();
    if (tab === 'notes') renderNotes();
}
document.querySelectorAll('#tabs button').forEach((b) => (b.onclick = () => selectTab(b.dataset.tab)));

// ------------------------------------------------------------------- chat
const msgEls = {};
let thinkingEl = null;
function renderMessage(d) {
    $('chat-empty').classList.add('hidden');
    const chat = $('chat');
    let e = msgEls[d.id];
    if (!e) {
        hideThinking();
        if (d.command) {
            e = h('div', { class: 'msg command' + (d.ok === false ? ' fail' : '') }, d.text);
        } else {
            e = h('div', { class: `msg ${d.role}` + (d.error ? ' error' : '') });
        }
        msgEls[d.id] = e;
        chat.append(e);
        if (d.role === 'user' && d.source === 'voice') chat.append(h('div', { class: 'msg-meta right' }, '🎙 voice'));
    }
    if (!d.command) e.textContent = d.text;
    e.classList.toggle('typing', d.final === false);
    if (d.final && d.sources && d.sources.length) {
        const src = h('div', { class: 'sources' }, ...d.sources.map((s) => h('a', { href: '#', title: s.url, onclick: (ev) => { ev.preventDefault(); ipcRenderer.send('open-external', s.url); } }, '↗ ' + s.title)));
        e.append(src);
    }
    if (d.final && d.web) e.title = 'Used the internet';
    if (d.final && d.open_tab && $('drawer').classList.contains('open') && activeTab === 'assistant') {
        /* stay on chat; the info is in the reply */
    }
    chat.scrollTop = chat.scrollHeight;
}
function showThinking() {
    const chat = $('chat');
    const last = chat.lastElementChild;
    if (thinkingEl || !last) return;
    const afterUser = last.classList.contains('user') ||
        (last.classList.contains('msg-meta') && last.previousElementSibling && last.previousElementSibling.classList.contains('user'));
    if (!afterUser) return;
    thinkingEl = h('div', { class: 'thinking-dots' }, h('i'), h('i'), h('i'));
    chat.append(thinkingEl);
    chat.scrollTop = chat.scrollHeight;
}
function hideThinking() { if (thinkingEl) { thinkingEl.remove(); thinkingEl = null; } }

function sendChat(text) {
    text = (text ?? $('chat-input').value).trim();
    if (!text) return;
    if (!send({ type: 'chat', text })) { showToast(`${NAME()} is starting…`, false); return; }
    $('chat-input').value = '';
}
$('chat-send').onclick = () => sendChat();
$('chat-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') sendChat(); });
$('chat-mic').onclick = talk;

function renderSuggestions() {
    const name = profile.preferred_name || profile.name;
    const hr = new Date().getHours();
    $('empty-hello').textContent = `Good ${hr < 12 ? 'morning' : hr < 17 ? 'afternoon' : 'evening'}${name ? ', ' + name : ''}. What can I do?`;
    const items = ['Start my day', "What's on today?", 'Take meeting notes', 'Remind me in 30 minutes to stretch', 'What did I do yesterday?'];
    $('suggestions').replaceChildren(...items.map((t) => h('button', { class: 'chip', onclick: () => sendChat(t) }, t)));
}

// ------------------------------------------------------------------ today
function renderBriefingCard() {
    const box = $('today-briefing');
    if (!briefing) { box.replaceChildren(); return; }
    const b = briefing;
    const w = b.weather ? h('span', { class: 'chip static' }, `${b.weather.temp}° ${b.weather.desc} · ${b.weather.city}`) : null;
    box.replaceChildren(h('div', { class: 'card' },
        h('div', { class: 'card-head' }, h('h3', {}, b.title), h('button', { class: 'mini', onclick: () => send({ type: 'request', what: 'briefing' }) }, 'Refresh')),
        ...b.lines.map((l) => h('p', { class: 'caption', style: 'margin-bottom:4px' }, l)),
        w ? h('div', { class: 'chip-row' }, w) : null,
        b.plan && b.plan.length ? h('ol', { class: 'plan-list' }, ...b.plan.map((p) => h('li', {}, p.label))) : null,
        b.plan && b.plan.length ? h('button', { class: 'btn primary wide', onclick: () => send({ type: 'start_my_day' }) }, 'Start my day') : null));
}

function renderMeeting() {
    const btn = $('meeting-btn'), live = $('meeting-live');
    if (meeting.recording) {
        btn.textContent = 'Stop & write notes';
        btn.classList.add('recording');
        $('meeting-status').textContent = `● Recording · ${meeting.words || 0} words`;
        live.textContent = meeting.live ? `“…${meeting.live.slice(-140)}”` : 'Listening to the call…';
        live.classList.add('rec');
    } else {
        btn.textContent = 'Start taking notes';
        btn.classList.remove('recording');
        $('meeting-status').textContent = meeting.error ? '⚠ ' + meeting.error : '';
        live.textContent = 'Capture what\'s said in a call — I\'ll write the summary, decisions and action items.';
        live.classList.remove('rec');
    }
}
$('meeting-btn').onclick = () => send({ type: meeting.recording ? 'meeting_stop' : 'meeting_start' });

function taskRow(t) {
    const overdue = t.remind_at && new Date(t.remind_at) < new Date();
    return h('li', {},
        h('button', { class: 'check', title: 'Mark done', onclick: () => send({ type: 'task_update', id: t.id, done: true }) }),
        h('div', { class: 'grow' }, h('div', { class: 'title' }, t.title),
            t.remind_at ? h('div', { class: 'meta' + (overdue ? ' due' : '') }, (t.source === 'timer' ? 'Timer · ' : '') + dueText(t.remind_at)) : null,
            t.source === 'meeting' ? h('div', { class: 'meta' }, 'From a meeting') : null),
        h('div', { class: 'row-actions' },
            t.remind_at ? h('button', { class: 'mini', onclick: () => send({ type: 'task_snooze', id: t.id, minutes: 30 }) }, '+30m') : null,
            h('button', { class: 'mini', title: 'Delete', onclick: () => send({ type: 'task_delete', id: t.id }) }, 'Delete')));
}
function renderTodayExtras() {
    const tl = $('today-tasks');
    tl.replaceChildren(...(tasks.length ? tasks.slice(0, 4).map(taskRow) : [h('li', { class: 'empty' }, 'Nothing pending.')]));
    const reviews = [];
    for (const n of notes) for (const a of (n.actions || [])) if (a.status === 'pending') reviews.push([n, a]);
    $('review-card').classList.toggle('hidden', !reviews.length);
    $('review-list').replaceChildren(...reviews.slice(0, 6).map(([n, a]) => actionRow(n, a)));
}
function actionRow(n, a) {
    const decide = (decision) => send({ type: 'action_review', note_id: n.id, action_id: a.id, decision });
    return h('div', { class: 'action-row' },
        h('div', { class: 'grow' }, h('div', { class: 'title' }, a.task),
            h('div', { class: 'meta' }, `${n.title || 'Meeting'} · ${a.owner && a.owner !== 'unassigned' ? a.owner : 'no owner'}${a.due ? ' · ' + a.due : ''}`)),
        a.status === 'pending' ? h('div', { class: 'row gap8' },
            h('button', { class: 'btn small primary', onclick: () => decide('accept') }, a.mine ? 'Add to my tasks' : 'Mine'),
            h('button', { class: 'btn small', onclick: () => decide('not_mine') }, 'Not mine'),
            h('button', { class: 'mini', onclick: () => decide('dismiss') }, 'Dismiss'))
            : h('span', { class: 'caption' }, { accepted: 'Added', not_mine: 'Not mine', dismissed: 'Dismissed' }[a.status] || ''));
}
function renderContexts() {
    $('contexts-card').classList.toggle('hidden', !contexts.length);
    $('contexts-list').replaceChildren(...contexts.slice().reverse().map((c) => h('li', {},
        h('div', { class: 'grow' }, h('div', { class: 'title' }, c.name),
            h('div', { class: 'meta' }, `${c.apps.length} apps${c.branch ? ' · ' + c.branch : ''} · ${new Date(c.saved).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' })}`)),
        h('button', { class: 'btn small', onclick: () => send({ type: 'chat', text: 'resume ' + c.name }) }, 'Resume'),
        h('button', { class: 'mini', onclick: () => send({ type: 'context_delete', id: c.id }) }, 'Delete'))));
}
function renderTasks() {
    renderTodayExtras();
    const list = $('task-list');
    $('tasks-count').textContent = tasks.length ? `${tasks.length} open` : '';
    if (!tasks.length) { list.replaceChildren(h('li', { class: 'empty' }, `Nothing pending. Say “${NAME()}, remind me at 5 to push the PR”.`)); return; }
    list.replaceChildren(...tasks.map(taskRow));
}
function addTask() { const v = $('task-input').value.trim(); if (v && send({ type: 'task_add', text: v })) $('task-input').value = ''; }
$('task-add').onclick = addTask;
$('task-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') addTask(); });

function renderGlance() {
    const a = activity || {};
    const today = new Date().toDateString();
    const nToday = notes.filter((n) => new Date(n.ts * 1000).toDateString() === today).length;
    $('glance').replaceChildren(
        h('div', { class: 'stat' }, h('b', {}, fmtDur(a.total_active || 0)), h('span', {}, 'active today')),
        h('div', { class: 'stat' }, h('b', {}, a.first_active ? clock(a.first_active) : '—'), h('span', {}, 'started')),
        h('div', { class: 'stat' }, h('b', {}, String(nToday)), h('span', {}, nToday === 1 ? 'note' : 'notes')));
}

// ------------------------------------------------------------------ notes
function setNoteFilter(f) {
    noteFilter = f;
    document.querySelectorAll('#note-filter button').forEach((b) => b.classList.toggle('active', b.dataset.f === f));
    openNoteId = null;
    $('drawer').classList.remove('wide');
    renderNotes();
}
document.querySelectorAll('#note-filter button').forEach((b) => (b.onclick = () => setNoteFilter(b.dataset.f)));
function openNoteDetail(id) { openNoteId = id; $('drawer').classList.add('wide'); renderNotes(); }
function renderNoteDetail(n) {
    const box = $('notes-list');
    const list = (title, items) => (items && items.length ? [h('h4', {}, title), h('ul', {}, ...items.map((x) => h('li', {}, x)))] : []);
    const isMeeting = n.kind === 'meeting';
    let detailContent;
    if (isMeeting) {
        detailContent = h('div', { class: 'detail-cols' },
            h('div', {},
                ...list('Summary', n.summary), ...list('Key points', n.key_points), ...list('Decisions', n.decisions),
                n.actions && n.actions.length ? [h('h4', {}, 'Action items'), ...n.actions.map((a) => actionRow(n, a))] : [],
                n.bookmarks && n.bookmarks.length ? [h('h4', {}, 'Bookmarks'), h('ul', {}, ...n.bookmarks.map((b) => h('li', {}, `${Math.floor(b.t / 60)}:${String(b.t % 60).padStart(2, '0')} — ${b.label}`)))] : []),
            h('div', {}, h('h4', {}, 'Transcript'), h('pre', { class: 'transcript' }, n.transcript || '—')));
    } else {
        detailContent = h('div', { style: 'margin: 14px 0;' },
            h('pre', { class: 'transcript', style: 'max-height: none;' }, n.text || '—'));
    }

    box.replaceChildren(h('div', { class: 'note-detail' },
        h('button', { class: 'mini', style: 'margin-bottom: 8px;', onclick: () => { openNoteId = null; $('drawer').classList.remove('wide'); renderNotes(); } }, '‹ All notes'),
        h('h2', {}, n.title || (isMeeting ? 'Meeting' : 'Note')),
        h('div', { class: 'caption', style: 'margin-bottom: 12px;' }, `${dayLabel(n.ts)} · ${clock(n.ts)}${n.duration ? ' · ' + fmtDur(n.duration) : ''}${n.ai_summary === false ? ' · summary without AI' : ''}`),
        detailContent,
        h('div', { class: 'row gap8', style: 'margin-top:12px' },
            h('button', { class: 'btn small', onclick: () => { navigator.clipboard.writeText(noteAsText(n)); showToast('Copied'); } }, isMeeting ? 'Copy notes' : 'Copy note'),
            h('button', { class: 'btn small danger', onclick: () => confirmDo(isMeeting ? 'Delete this meeting note?' : 'Delete this note?', "This can't be undone.", () => { send({ type: 'note_delete', id: n.id }); openNoteId = null; $('drawer').classList.remove('wide'); }) }, 'Delete'))));
}
function renderNotes() {
    const isDetail = !!openNoteId;
    $('note-input')?.closest('.add-row')?.classList.toggle('hidden', isDetail);
    $('note-filter')?.classList.toggle('hidden', isDetail);
    $('note-search')?.classList.toggle('hidden', isDetail);
    if (openNoteId) {
        const n = notes.find((x) => x.id === openNoteId);
        if (n) { renderNoteDetail(n); return; }
        openNoteId = null; $('drawer').classList.remove('wide');
        $('note-input')?.closest('.add-row')?.classList.remove('hidden');
        $('note-filter')?.classList.remove('hidden');
        $('note-search')?.classList.remove('hidden');
    }
    const q = $('note-search').value.trim().toLowerCase();
    const today = new Date().toDateString();
    const list = notes.filter((n) => (!q || JSON.stringify([n.text, n.title, n.summary, n.transcript]).toLowerCase().includes(q)) &&
        (noteFilter === 'all' || (noteFilter === 'today' && new Date(n.ts * 1000).toDateString() === today) ||
         (noteFilter === 'meeting' && n.kind === 'meeting')));
    const box = $('notes-list');
    if (!list.length) { box.replaceChildren(h('div', { class: 'empty' }, q ? 'No matching notes.' : `No notes yet. Say “${NAME()}, take note …” or start meeting notes.`)); return; }
    const out = [];
    let lastDay = null;
    for (const n of list) {
        const dl = dayLabel(n.ts);
        if (dl !== lastDay) { out.push(h('div', { class: 'day-label' }, dl)); lastDay = dl; }
        const actions = h('div', { class: 'row-actions' },
            h('button', { class: 'mini', title: 'Copy', onclick: (e) => { e.stopPropagation(); navigator.clipboard.writeText(noteAsText(n)); showToast('Copied'); } }, 'Copy'),
            h('button', { class: 'mini', title: 'Delete', onclick: (e) => { e.stopPropagation(); confirmDo('Delete this note?', 'This can\'t be undone.', () => send({ type: 'note_delete', id: n.id })); } }, '✕'));
        if (n.kind === 'meeting') {
            out.push(h('div', { class: 'note meeting clickable', title: 'Click to open details', onclick: (e) => { if (!e.target.closest('.row-actions, button, a')) openNoteDetail(n.id); } }, actions,
                h('div', { class: 'note-title' }, h('span', { class: 'badge' }, 'MEETING'), n.title || 'Meeting',
                    n.review_pending ? h('span', { class: 'badge warn' }, 'REVIEW') : null),
                h('div', { class: 'note-meta' }, `${clock(n.ts)} · ${fmtDur(n.duration || 0)}`)));
        } else {
            out.push(h('div', { class: 'note clickable', title: 'Click to open details', onclick: (e) => { if (!e.target.closest('.row-actions, button, a')) openNoteDetail(n.id); } }, actions,
                h('div', { class: 'note-title' },
                    n.kind && n.kind !== 'note' ? h('span', { class: 'badge' }, n.kind.toUpperCase()) : null,
                    n.title || (n.text.length > 60 ? n.text.slice(0, 57) + '…' : n.text)),
                h('div', { class: 'note-meta' }, clock(n.ts))));
        }
    }
    box.replaceChildren(...out);
}
function noteAsText(n) {
    if (n.kind !== 'meeting') return n.text;
    const L = [n.title || 'Meeting', ''];
    if (n.summary) L.push('Summary:', ...n.summary.map((s) => '• ' + s), '');
    if (n.decisions && n.decisions.length) L.push('Decisions:', ...n.decisions.map((s) => '• ' + s), '');
    if (n.actions && n.actions.length) L.push('Action items:', ...n.actions.map((a) => `• ${a.task}${a.owner ? ' — ' + a.owner : ''}${a.due ? ' (' + a.due + ')' : ''}`));
    return L.join('\n');
}
$('note-search').addEventListener('input', renderNotes);
function addNote() { const v = $('note-input').value.trim(); if (v && send({ type: 'note_add', text: v })) $('note-input').value = ''; }
$('note-add').onclick = addNote;
$('note-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') addNote(); });

// ----------------------------------------------------------------- memory
const PROFILE_FIELDS = [
    ['preferred_name', 'What should I call you?', 'text'], ['role', 'What you do', 'text'], ['city', 'City (for weather)', 'text'],
    ['work_start', 'Work starts', 'time'], ['work_end', 'Work ends', 'time'], ['languages', 'Languages', 'text'], ['editor', 'Main editor / IDE', 'text'],
];
function renderMemory() {
    const form = $('profile-form');
    if (!form.contains(document.activeElement)) {
        form.replaceChildren(...PROFILE_FIELDS.map(([k, label, type]) => {
            const val = Array.isArray(profile[k]) ? profile[k].join(', ') : (profile[k] || (k === 'preferred_name' ? profile.name || '' : ''));
            const inp = h('input', { type, value: val, placeholder: '—' });
            inp.addEventListener('change', () => {
                let v = inp.value.trim();
                if (k === 'languages') v = v.split(',').map((s) => s.trim()).filter(Boolean);
                send({ type: 'profile_update', profile: { [k]: v } });
            });
            return h('div', { class: 'g-row' }, h('span', {}, label), inp);
        }));
    }
    $('mem-count').textContent = memories.length ? `${memories.length} remembered` : '';
    const box = $('mem-list');
    if (!memories.length) { box.replaceChildren(h('div', { class: 'empty' }, 'Nothing yet. Tell me things like “remember that my standup is at 10”.')); return; }
    const order = ['instruction', 'person', 'project', 'preference', 'routine', 'goal', 'fact', 'event'];
    const groups = {};
    for (const m of memories) (groups[m.category] = groups[m.category] || []).push(m);
    const out = [];
    for (const cat of order.concat(Object.keys(groups).filter((c) => !order.includes(c)))) {
        if (!groups[cat]) continue;
        out.push(h('div', { class: 'mem-cat' }, { instruction: 'How I should behave', person: 'People', project: 'Projects', preference: 'Preferences', routine: 'Routine', goal: 'Goals', fact: 'Facts', event: 'Events' }[cat] || cat));
        for (const m of groups[cat].sort((a, b) => (b.pinned - a.pinned) || (b.importance - a.importance))) {
            const text = h('div', { class: 'mem-text', title: `Learned ${new Date(m.created).toLocaleDateString()} · from ${m.source}` }, m.text);
            const edit = () => {
                text.contentEditable = 'true'; text.focus();
                document.getSelection().selectAllChildren(text);
                const done = () => { text.contentEditable = 'false'; const v = text.textContent.trim(); if (v && v !== m.text) send({ type: 'memory_update', id: m.id, text: v }); };
                text.addEventListener('blur', done, { once: true });
                text.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); text.blur(); } });
            };
            out.push(h('div', { class: 'mem' + (m.pinned ? ' pinned' : '') }, text,
                h('span', { class: 'dots', title: `Importance ${m.importance}/5` }, '●'.repeat(m.importance)),
                h('div', { class: 'row-actions' },
                    h('button', { class: 'mini' + (m.pinned ? ' on' : ''), title: 'Always keep in mind', onclick: () => send({ type: 'memory_update', id: m.id, pinned: !m.pinned }) }, m.pinned ? 'Pinned' : 'Pin'),
                    h('button', { class: 'mini', title: 'Edit', onclick: edit }, 'Edit'),
                    h('button', { class: 'mini', title: 'Forget', onclick: () => send({ type: 'memory_delete', id: m.id }) }, '✕'))));
        }
    }
    box.replaceChildren(...out);
}
function addMemory() { const v = $('mem-input').value.trim(); if (v && send({ type: 'memory_add', text: v })) $('mem-input').value = ''; }
$('mem-add').onclick = addMemory;
$('mem-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') addMemory(); });
$('mem-export').onclick = () => send({ type: 'export_data' });
$('act-clear').onclick = () => confirmDo('Clear your activity history?', 'All recorded app usage will be deleted. Your routine will be relearned.', () => send({ type: 'clear_activity' }));
$('mem-forget').onclick = () => confirmDo('Forget everything about you?', 'Your profile and every memory will be deleted. Tasks, notes and activity stay.', () => send({ type: 'memory_forget_all' }));

// --------------------------------------------------------------- activity
function renderActivity() {
    const a = activity;
    if (!a) return;
    $('act-stats').replaceChildren(
        h('div', { class: 'stat' }, h('b', {}, fmtDur(a.total_active)), h('span', {}, 'active today')),
        h('div', { class: 'stat' }, h('b', {}, fmtDur(a.focus_seconds)), h('span', {}, 'in focused blocks (25m+)')),
        h('div', { class: 'stat' }, h('b', {}, a.first_active ? clock(a.first_active) : '—'), h('span', {}, 'first active')),
        h('div', { class: 'stat' }, h('b', {}, String(a.switches || 0)), h('span', {}, 'app switches')));
    // timeline
    const tl = $('act-timeline');
    const segs = a.timeline || [];
    const appColor = {};
    (a.top_apps || []).forEach((x, i) => (appColor[x.name] = COLORS[i % COLORS.length]));
    if (segs.length) {
        const start = segs[0][0], end = Math.max(segs[segs.length - 1][1], start + 1);
        $('act-range').textContent = `${clock(start)} – ${clock(end)}`;
        tl.replaceChildren(...segs.map(([s, e, name]) => h('i', { style: `left:${((s - start) / (end - start)) * 100}%;width:${((e - s) / (end - start)) * 100}%;background:${appColor[name] || '#8e8e93'}`, title: `${name} ${clock(s)}–${clock(e)}` })));
    } else { tl.replaceChildren(); $('act-range').textContent = 'No activity yet today'; }
    const hours = new Array(24).fill(0);
    for (const [s0, e0] of segs) {
        let s1 = s0;
        while (s1 < e0) {
            const d = new Date(s1 * 1000), hEnd = new Date(d); hEnd.setMinutes(60, 0, 0);
            const until = Math.min(e0, hEnd.getTime() / 1000);
            hours[d.getHours()] += until - s1;
            s1 = until;
        }
    }
    const used = hours.map((v, i) => [i, v]).filter(([, v]) => v > 0);
    const lo = used.length ? Math.min(...used.map(([i]) => i)) : 9, hi = used.length ? Math.max(...used.map(([i]) => i)) : 18;
    $('act-hours').replaceChildren(...hours.slice(lo, hi + 1).map((v, k) => h('div', { class: 'hour', title: `${lo + k}:00 — ${fmtDur(v)}` },
        h('i', { style: `height:${Math.max(2, (v / 3600) * 100)}%` }), h('span', {}, String((lo + k) % 24)))));
    const maxApp = Math.max(1, ...(a.top_apps || []).map((x) => x.seconds));
    $('act-apps').replaceChildren(...((a.top_apps || []).length ? a.top_apps.map((x, i) => h('div', { class: 'bar-row' },
        h('span', {}, x.name), h('span', { class: 'dur' }, fmtDur(x.seconds)),
        h('div', { class: 'bar' }, h('i', { style: `width:${(x.seconds / maxApp) * 100}%;background:${COLORS[i % COLORS.length]}` })))) : [h('div', { class: 'empty' }, 'I\'ll show your app time here as you work.')]));
    const ps = [...(a.projects || []).map((p) => ({ ...p, kind: 'project' })), ...(a.sites || []).map((p) => ({ ...p, kind: 'site' }))];
    const maxP = Math.max(1, ...ps.map((x) => x.seconds));
    $('act-projects-card').classList.toggle('hidden', !ps.length);
    $('act-projects').replaceChildren(...ps.map((x) => h('div', { class: 'bar-row' },
        h('span', {}, (x.kind === 'project' ? '📁 ' : '🌐 ') + x.name), h('span', { class: 'dur' }, fmtDur(x.seconds)),
        h('div', { class: 'bar' }, h('i', { style: `width:${(x.seconds / maxP) * 100}%;background:${x.kind === 'project' ? '#30d158' : '#64d2ff'}` })))));
    const r = routine || {};
    $('act-routine').replaceChildren(...(r.days_observed ? [
        h('p', {}, `Observed for ${r.days_observed} day${r.days_observed > 1 ? 's' : ''}.`),
        r.typical_start ? h('p', {}, `You usually start around ${r.typical_start}.`) : null,
        r.usual_first_apps && r.usual_first_apps.length ? h('p', {}, 'First thing you open: ' + r.usual_first_apps.map((x) => x.name).join(', ') + '.') : null,
        r.top_projects && r.top_projects.length ? h('p', {}, 'Main projects this week: ' + r.top_projects.join(', ') + '.') : null,
    ] : [h('p', {}, 'I\'m still learning your routine. After a couple of days I\'ll know when you start and what you open first — and offer to set it up for you each morning.')]));
}

// --------------------------------------------------------------- settings
const LANGS = [['auto', 'Detect automatically'], ['en', 'English only (fastest)'], ['hi', 'Hindi'], ['es', 'Spanish'], ['fr', 'French'], ['de', 'German'], ['pt', 'Portuguese'], ['it', 'Italian'], ['ja', 'Japanese'], ['zh', 'Chinese'], ['ar', 'Arabic'], ['bn', 'Bengali'], ['ta', 'Tamil'], ['te', 'Telugu'], ['mr', 'Marathi']];
const SETTINGS = [
    ['General', [
        { key: 'agent_name', type: 'text', label: 'Assistant name', sub: 'It answers to this name — “Hey <name>, …”', placeholder: 'Snapy' },
        { key: 'start_at_login', type: 'switch', label: 'Start when I sign in' },
        { key: 'daily_greeting', type: 'switch', label: 'Morning greeting & briefing', sub: 'Once a day, never during a call' },
        { key: 'greeting_voice', type: 'switch', label: 'Speak the greeting out loud' },
        { key: 'welcome_back', type: 'switch', label: 'Say “welcome back” after 3+ hours away' },
        { key: 'recap_time', type: 'select', label: 'End-of-day recap', options: [['', 'At my work end time'], ['17:00', '5:00 PM'], ['18:00', '6:00 PM'], ['18:30', '6:30 PM'], ['19:00', '7:00 PM'], ['20:00', '8:00 PM']] },
        { key: 'break_reminder_minutes', type: 'select', label: 'Wellbeing break nudges', num: true, options: [[0, 'Off'], [30, 'Every 30 min'], [50, 'Every 50 min'], [90, 'Every 90 min']] },
        { key: 'internet_tools', type: 'switch', label: 'Use the internet when I ask', sub: 'Web search and weather only — your data never leaves' },
    ]],
    ['Attention', [
        { key: 'attention_enabled', type: 'switch', label: 'Count shorts & reels in my browser', sub: 'YouTube Shorts, Instagram & Facebook Reels, TikTok — counts only, on this PC' },
        { key: 'attention_nudges', type: 'switch', label: 'Gentle nudges', sub: 'At most one every 20 minutes, never during calls. Nothing is blocked.', when: () => S.attention_enabled },
        { key: 'attention_soft_limit', type: 'select', label: 'Chip turns amber at', num: true, options: [[0, 'Default'], [20, '20 a day'], [40, '40 a day'], [60, '60 a day'], [100, '100 a day']], when: () => S.attention_enabled },
        { key: 'attention_bedtime', type: 'select', label: 'Bedtime wind-down', options: [['', 'Default'], ['22:00', '10:00 PM'], ['23:00', '11:00 PM'], ['00:00', 'Midnight'], ['off', 'Off']], when: () => S.attention_enabled },
        { key: 'attention_weekly_report', type: 'switch', label: 'Sunday attention report', when: () => S.attention_enabled },
        { key: 'attention_read_urls', type: 'switch', label: 'Read the address bar for Shorts/Reels hints', sub: 'More accurate counting. The address is never stored.', when: () => S.attention_enabled },
    ]],
    ['Listening', [
        { key: 'voice_mode', type: 'select', label: 'How I listen', options: [['wake', 'Wake word — say my name first'], ['push', 'Only when I press Ctrl+Alt+Space'], ['always', 'Always (commands only)']] },
        { key: 'wake_words', type: 'text', label: 'Wake words' },
        { key: 'voice_language', type: 'select', label: 'Language I speak', options: LANGS },
        { key: 'speech_quality', type: 'select', label: 'Speech recognition', options: [['fast', 'Fast'], ['balanced', 'Balanced'], ['accurate', 'Accurate (slower)']] },
        { key: 'mic_sensitivity', type: 'range', label: 'Microphone sensitivity', min: 1, max: 10, step: 1, meter: true },
        { key: 'follow_up_seconds', type: 'select', label: 'Keep listening after I answer', num: true, options: [[0, 'Off'], [5, '5 seconds'], [8, '8 seconds'], [12, '12 seconds']] },
        { key: 'barge_in', type: 'switch', label: 'Interrupt me by talking', sub: 'Speak while I talk and I stop at once' },
        { key: 'headphones', type: 'switch', label: 'I use headphones', sub: 'No speaker echo — interrupting works even when you speak softly' },
    ]],
    ['Voice', [
        { key: 'native_indic_voices', type: 'switch', label: 'Native Indian voices', sub: 'Native-speaker voices for Indian languages (downloaded on first use)' },
        { key: 'native_status', type: 'native_status', label: 'Languages' },
        { key: 'open_speech_settings', type: 'action', label: 'Hindi, Tamil and more', sub: 'Add Windows’ own voices (e.g. Hindi Hemant / Kalpana): Speech → Add voices', button: 'Add voices', action: 'open_speech_settings' },
        { key: 'personal_use_voices', type: 'switch', label: 'Personal-use voices', sub: 'Extra Hindi and Malayalam voices whose licence allows personal, non-commercial use only' },
        { key: 'indic_voices', type: 'hindi_voice', label: 'Personal-use Hindi voice', when: () => S.personal_use_voices },
        { key: 'tts_enabled', type: 'switch', label: 'Speak replies' },
        { key: 'tts_voice', type: 'select', label: 'Voice', options: () => (models.voices || [['af_heart', 'Heart']]) },
        { key: 'tts_speed', type: 'range', label: 'Speed', min: 0.8, max: 1.3, step: 0.05 },
        { key: 'speak_typed_replies', type: 'switch', label: 'Also speak when I type' },
        { key: 'speak_confirmations', type: 'switch', label: 'Confirm quick commands out loud' },
        { key: 'tts_preview', type: 'action', label: 'Hear how I sound', button: 'Preview', action: 'tts_test' },
    ]],
    ['AI brain', 'models'],
    ['Screen vision', [
        { key: 'vision_mode', type: 'select', label: 'When I can’t read a window', options: [['auto', 'Use text recognition and a vision model'], ['off', 'Don’t look at the screen']] },
        { key: 'vision_local', type: 'select', label: 'Local vision model', options: [['auto', 'Only with a graphics card (fast)'], ['on', 'Always (private, slow on CPU)'], ['off', 'Never']] },
        { key: 'vision_status', type: 'vision_status', label: 'Status' },
        { key: 'vision_install', type: 'action', label: 'Install local vision model', sub: 'Qwen3.5 4B (about 3.4 GB). Only installs if this PC can run it.', button: 'Install', action: 'vision_install', when: () => !(models.vision || {}).local_model },
    ]],
    ['Gestures', [
        { key: 'gestures_enabled', type: 'switch', label: 'Hand gestures (uses the camera)', sub: 'Point to move, pinch to click, two fingers to scroll' },
        { key: 'show_camera_preview', type: 'switch', label: 'Small camera preview' },
        { key: 'pointer_smoothing', type: 'range', label: 'Pointer smoothing', min: 1, max: 10, step: 1 },
        { key: 'control_area', type: 'range', label: 'Pointer speed', min: 1, max: 10, step: 1 },
        { key: 'pinch_sensitivity', type: 'range', label: 'Pinch sensitivity', min: 1, max: 10, step: 1 },
        { key: 'scroll_style', type: 'select', label: 'Two-finger scroll', options: [['joystick', 'Joystick (hold to keep scrolling)'], ['drag', 'Touchpad']] },
        { key: 'scroll_sensitivity', type: 'range', label: 'Scroll speed', min: 1, max: 10, step: 1 },
        { key: 'palm_hold_action', type: 'select', label: 'Hold open palm', options: [['none', 'Nothing'], ['listen', 'Listen for a command'], ['play pause', 'Play / pause'], ['show desktop', 'Show desktop']] },
        { key: 'fist_action', type: 'select', label: 'Fist', options: [['clutch', 'Freeze pointer'], ['play pause', 'Play / pause'], ['none', 'Nothing']] },
    ]],
    ['Workspace', [
        { key: 'project_dir', type: 'folder', label: 'Main project folder', sub: 'Used by “start my day” and “run project”' },
        { key: 'project_run_command', type: 'text', label: 'Run command', placeholder: 'auto-detect' },
        { key: 'morning_apps', type: 'text', label: 'Also open in “Start my day”', placeholder: 'e.g. Slack, Spotify' },
    ]],
    ['Phone', 'phone'],
    ['Privacy & data', 'privacy'],
];

function settingControl(it) {
    const v = S[it.key];
    if (it.type === 'native_status') {
        const names = { hi: 'Hindi', te: 'Telugu', ml: 'Malayalam', mr: 'Marathi', bn: 'Bengali', ne: 'Nepali', ur: 'Urdu', ta: 'Tamil', gu: 'Gujarati', kn: 'Kannada', pa: 'Punjabi' };
        const st = models.native_voices || {};
        const parts = Object.keys(names).filter((k) => st[k]).map((k) => `${names[k]}: ${st[k].voice ? st[k].voice + (st[k].source === 'windows' ? ' (Windows)' : '') : 'multilingual voice'}`);
        return h('span', { class: 'caption', style: 'max-width:260px;text-align:right' }, parts.join(' · ') || '…');
    }
    if (it.type === 'vision_status') {
        const v = models.vision || {};
        const bits = ['Accessibility tree ✓', v.ocr ? 'Text recognition ✓' : 'Text recognition unavailable',
            v.local_active ? `Local model ✓ (${v.local_model})` : v.local_model ? `Local model installed (${v.local_model}), off on this PC` : 'No local model',
            v.cloud ? 'Cloud vision ✓' : 'Cloud vision off'];
        return h('span', { class: 'caption', style: 'max-width:260px;text-align:right' }, bits.join(' · '));
    }
    if (it.type === 'hindi_voice') {
        const cur = (S.indic_voices || {}).hi || 'hi_IN-priyamvada-medium';
        const sel = h('select', { class: 'select' }, ...[['hi_IN-priyamvada-medium', 'Priyamvada (female)'], ['hi_IN-pratham-medium', 'Pratham (male)'], ['hi_IN-rohan-medium', 'Rohan (male)']].map(([v, l]) => { const o = h('option', { value: v }, l); if (v === cur) o.selected = true; return o; }));
        sel.onchange = () => updateSetting('indic_voices', { ...(S.indic_voices || {}), hi: sel.value });
        return sel;
    }
    if (it.type === 'action') return h('button', { class: 'btn small', onclick: () => send({ type: it.action }) }, it.button || 'Go');
    if (it.type === 'switch') {
        const c = h('input', { type: 'checkbox', class: 'switch' });
        c.checked = !!v;
        c.onchange = () => { updateSetting(it.key, c.checked); if (it.key === 'start_at_login') ipcRenderer.send('set-login-item', c.checked); if (it.key === 'personal_use_voices') { renderSettings(); send({ type: 'request', what: 'models' }); } };
        return c;
    }
    if (it.type === 'select') {
        const opts = typeof it.options === 'function' ? it.options() : it.options;
        const s = h('select', { class: 'select' }, ...opts.map(([ov, ol]) => { const o = h('option', { value: ov }, ol); if (String(ov) === String(v)) o.selected = true; return o; }));
        s.onchange = () => updateSetting(it.key, it.num ? +s.value : s.value);
        return s;
    }
    if (it.type === 'range') {
        const r = h('input', { type: 'range', min: it.min, max: it.max, step: it.step, value: v });
        const lab = h('span', { class: 'caption', style: 'min-width:34px;text-align:right' }, String(v));
        r.oninput = () => { lab.textContent = r.value; updateSetting(it.key, +r.value, true); };
        return h('div', { class: 'row', style: 'gap:10px;flex:0 1 210px' }, r, lab);
    }
    if (it.type === 'folder') {
        const inp = h('input', { type: 'text', value: v || '', placeholder: 'Choose a folder' });
        inp.onchange = () => updateSetting(it.key, inp.value);
        const b = h('button', { class: 'btn small', onclick: async () => { const p = await ipcRenderer.invoke('pick-folder'); if (p) { inp.value = p; updateSetting(it.key, p); } } }, 'Browse…');
        return h('div', { class: 'row', style: 'gap:6px;flex:0 1 230px' }, inp, b);
    }
    const inp = h('input', { type: 'text', value: Array.isArray(v) ? v.join(', ') : (v || ''), placeholder: it.placeholder || '' });
    inp.onchange = () => updateSetting(it.key, inp.value);
    return inp;
}

let pending = {}, pendingT = null;
function updateSetting(key, value, debounce) {
    S[key] = value; pending[key] = value;
    clearTimeout(pendingT);
    pendingT = setTimeout(() => { send({ type: 'update_settings', settings: pending }); pending = {}; }, debounce ? 250 : 0);
}

// ------------------------------------------------------------------ QR code (pairing)
// Minimal QR encoder (byte mode, EC level M, versions 1-40, ISO/IEC 18004), after Nayuki's
// public-domain algorithm. Inline so the HUD needs no CDN or extra dependency.
const QR = (() => {
    const ECC = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
    const BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];
    const FORMAT_M = 0;
    const bit = (x, i) => ((x >>> i) & 1) !== 0;
    function rawModules(v) {
        let r = (16 * v + 128) * v + 64;
        if (v >= 2) { const n = Math.floor(v / 7) + 2; r -= (25 * n - 10) * n - 55; if (v >= 7) r -= 36; }
        return r;
    }
    const dataCodewords = (v) => Math.floor(rawModules(v) / 8) - ECC[v] * BLOCKS[v];
    function mul(x, y) { let z = 0; for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11D); z ^= ((y >>> i) & 1) * x; } return z; }
    function divisor(deg) {
        const r = new Array(deg).fill(0); r[deg - 1] = 1; let root = 1;
        for (let i = 0; i < deg; i++) { for (let j = 0; j < deg; j++) { r[j] = mul(r[j], root); if (j + 1 < deg) r[j] ^= r[j + 1]; } root = mul(root, 2); }
        return r;
    }
    function remainder(data, div) {
        const r = div.map(() => 0);
        for (const b of data) { const f = b ^ r.shift(); r.push(0); div.forEach((c, i) => { r[i] ^= mul(c, f); }); }
        return r;
    }
    function alignPositions(v, size) {
        if (v === 1) return [];
        const n = Math.floor(v / 7) + 2, step = Math.floor((v * 8 + n * 3 + 5) / (n * 4 - 4)) * 2, out = [6];
        for (let p = size - 7; out.length < n; p -= step) out.splice(1, 0, p);
        return out;
    }
    function encode(text, forceMask) {
        const bytes = Array.from(new TextEncoder().encode(text));
        let v = 1;
        for (; v <= 40; v++) if (4 + (v < 10 ? 8 : 16) + bytes.length * 8 <= dataCodewords(v) * 8) break;
        if (v > 40) throw new Error('QR: text too long');
        const bits = [];
        const put = (val, len) => { for (let i = len - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
        put(4, 4); put(bytes.length, v < 10 ? 8 : 16); bytes.forEach((b) => put(b, 8));
        const cap = dataCodewords(v) * 8;
        put(0, Math.min(4, cap - bits.length));
        put(0, (8 - bits.length % 8) % 8);
        for (let pad = 0xEC; bits.length < cap; pad ^= 0xEC ^ 0x11) put(pad, 8);
        const data = [];
        for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));
        // error correction + interleave
        const nb = BLOCKS[v], el = ECC[v], raw = Math.floor(rawModules(v) / 8), nShort = nb - raw % nb, shortLen = Math.floor(raw / nb);
        const div = divisor(el), blocks = [];
        for (let i = 0, k = 0; i < nb; i++) {
            const d = data.slice(k, k + shortLen - el + (i < nShort ? 0 : 1)); k += d.length;
            const e = remainder(d, div); if (i < nShort) d.push(0); blocks.push(d.concat(e));
        }
        const cw = [];
        for (let i = 0; i < blocks[0].length; i++) blocks.forEach((b, j) => { if (i !== shortLen - el || j >= nShort) cw.push(b[i]); });
        // matrix
        const size = v * 4 + 17;
        const m = Array.from({ length: size }, () => new Array(size).fill(false));
        const fn = Array.from({ length: size }, () => new Array(size).fill(false));
        const set = (x, y, d) => { m[y][x] = d; fn[y][x] = true; };
        for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
        for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]]) {
            for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
                const d = Math.max(Math.abs(dx), Math.abs(dy)), x = cx + dx, y = cy + dy;
                if (x >= 0 && x < size && y >= 0 && y < size) set(x, y, d !== 2 && d !== 4);
            }
        }
        const al = alignPositions(v, size);
        al.forEach((ax, i) => al.forEach((ay, j) => {
            if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) return;
            for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
        }));
        const format = (mask) => {
            const d = (FORMAT_M << 3) | mask; let r = d;
            for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537);
            const b = ((d << 10) | r) ^ 0x5412;
            for (let i = 0; i <= 5; i++) set(8, i, bit(b, i));
            set(8, 7, bit(b, 6)); set(8, 8, bit(b, 7)); set(7, 8, bit(b, 8));
            for (let i = 9; i < 15; i++) set(14 - i, 8, bit(b, i));
            for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(b, i));
            for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(b, i));
            set(8, size - 8, true);
        };
        format(0);
        if (v >= 7) {
            let r = v; for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1F25);
            const b = (v << 12) | r;
            for (let i = 0; i < 18; i++) { const a = size - 11 + i % 3, c = Math.floor(i / 3); set(a, c, bit(b, i)); set(c, a, bit(b, i)); }
        }
        let i = 0;
        for (let right = size - 1; right >= 1; right -= 2) {
            if (right === 6) right = 5;
            for (let vert = 0; vert < size; vert++) for (let j = 0; j < 2; j++) {
                const x = right - j, up = ((right + 1) & 2) === 0, y = up ? size - 1 - vert : vert;
                if (!fn[y][x] && i < cw.length * 8) { m[y][x] = bit(cw[i >>> 3], 7 - (i & 7)); i++; }
            }
        }
        const MASKS = [(x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
            (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => (x * y) % 2 + (x * y) % 3 === 0,
            (x, y) => ((x * y) % 2 + (x * y) % 3) % 2 === 0, (x, y) => ((x + y) % 2 + (x * y) % 3) % 2 === 0];
        const applyMask = (k) => { for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fn[y][x] && MASKS[k](x, y)) m[y][x] = !m[y][x]; };
        // penalty (runs, 2x2 blocks, dark balance) picks the mask; any mask decodes
        const penalty = () => {
            let p = 0, dark = 0;
            for (let a = 0; a < size; a++) {
                for (const horiz of [true, false]) {
                    let run = 1;
                    for (let b = 1; b < size; b++) {
                        const cur = horiz ? m[a][b] : m[b][a], prev = horiz ? m[a][b - 1] : m[b - 1][a];
                        if (cur === prev) { run++; if (run === 5) p += 3; else if (run > 5) p++; } else run = 1;
                    }
                }
            }
            for (let y = 0; y < size - 1; y++) for (let x = 0; x < size - 1; x++) {
                const c = m[y][x]; if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1]) p += 3;
            }
            m.forEach((row) => row.forEach((c) => { if (c) dark++; }));
            const total = size * size;
            return p + (Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
        };
        let best = forceMask;
        if (best === undefined) {
            let min = Infinity;
            for (let k = 0; k < 8; k++) { applyMask(k); format(k); const s = penalty(); if (s < min) { min = s; best = k; } applyMask(k); }
        }
        applyMask(best); format(best);
        return { size, modules: m, version: v, mask: best };
    }
    function svg(text, scale = 4, border = 4) {
        const q = encode(text), n = q.size + border * 2;
        let d = '';
        for (let y = 0; y < q.size; y++) for (let x = 0; x < q.size; x++) if (q.modules[y][x]) d += `M${x + border},${y + border}h1v1h-1z`;
        return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n} ${n}" width="${n * scale}" height="${n * scale}" shape-rendering="crispEdges" role="img" aria-label="Pairing QR code"><rect width="100%" height="100%" fill="#fff"/><path d="${d}" fill="#000"/></svg>`;
    }
    return { encode, svg };
})();
// ------------------------------------------------------------------ QR end

// ------------------------------------------------------------------ Phone (sync, engine: src/sync)
// Pair a phone by QR over the LAN; the QR holds a one-time secret (5 min, single use), so it is
// only drawn on screen and dropped as soon as the window closes or the phone pairs.
let syncInfo = { enabled: false, running: false, devices: [] }, syncPair = null, syncPairTimer = null, syncAsked = 0;

Object.assign(HANDLERS, {
    sync_devices(d) {
        const before = (syncInfo.devices || []).length;
        syncInfo = d;
        if (syncPair && (d.devices || []).length > before) { clearSyncPair(); showToast('Phone paired'); }
        renderPhoneSection();
    },
    sync_pair(d) {
        if (d.error) { showToast(d.error, false); return; }
        syncPair = d;
        clearInterval(syncPairTimer);
        syncPairTimer = setInterval(() => {
            if (!syncPair || Date.now() / 1000 >= syncPair.expires_at) clearSyncPair();
            renderPhoneSection();
        }, 1000);
        renderPhoneSection();
    },
    sync_sent(d) { showToast(d.ok ? 'Sent to your phone' : (d.error || 'Not sent'), !!d.ok); },
});

function clearSyncPair() {
    if (syncPair) send({ type: 'sync_pair_cancel' });
    syncPair = null;
    clearInterval(syncPairTimer);
    syncPairTimer = null;
}

function phoneSection() {
    if (Date.now() - syncAsked > 5000) { syncAsked = Date.now(); send({ type: 'sync_devices' }); }
    const box = h('div', { class: 'grouped phone-section', id: 'phone-section' });
    fillPhoneSection(box);
    return box;
}

function renderPhoneSection() {
    const box = $('phone-section');
    if (box) fillPhoneSection(box);
}

function fillPhoneSection(box) {
    const sw = (key, label, sub) => {
        const c = h('input', { type: 'checkbox', class: 'switch' });
        c.checked = !!S[key];
        c.onchange = () => { updateSetting(key, c.checked); if (key === 'sync_enabled' && !c.checked) clearSyncPair(); };
        return h('div', { class: 'g-row' }, h('span', {}, label, h('span', { class: 'sub' }, sub)), c);
    };
    const rows = [sw('sync_enabled', 'Sync with my phone',
        'Memory, tasks, notes and settings over your Wi-Fi, end-to-end encrypted. No Snapy server, nothing leaves your network.')];
    if (S.sync_enabled) {
        rows.push(sw('sync_focus_to_phone', 'Focus here silences my phone', 'Starting focus on this PC starts focus and Do Not Disturb on the phone'));
        if (syncPair) {
            const left = Math.max(0, Math.round(syncPair.expires_at - Date.now() / 1000));
            let qr = null;
            try { qr = h('div', { class: 'phone-qr', html: QR.svg(syncPair.qr, 4) }); } catch (e) { qr = h('span', { class: 'caption danger-text' }, 'Couldn\'t draw the code'); }
            rows.push(h('div', { class: 'g-row col phone-pair' }, qr,
                h('span', { class: 'caption' }, `On your phone: Snapy → Settings → Pair with laptop, then scan this code. It works once and expires in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}.`),
                h('button', { class: 'btn small', onclick: () => { clearSyncPair(); renderPhoneSection(); } }, 'Cancel')));
        } else {
            rows.push(h('div', { class: 'g-row' }, h('span', {}, 'Pair a phone', h('span', { class: 'sub' }, syncInfo.running ? 'Shows a one-time code to scan' : 'Starting sync…')),
                h('button', { class: 'btn small primary', disabled: !syncInfo.running, onclick: () => send({ type: 'sync_pair_start' }) }, 'Show code')));
        }
        for (const dev of syncInfo.devices || []) {
            const seen = dev.connected ? 'Connected' : dev.last_seen ? 'Last seen ' + new Date(dev.last_seen * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : 'Not connected yet';
            rows.push(h('div', { class: 'g-row' },
                h('span', {}, h('i', { class: 'phone-dot' + (dev.connected ? ' on' : '') }), dev.name || dev.id, h('span', { class: 'sub' }, seen)),
                h('div', { class: 'row', style: 'gap:6px' },
                    h('button', { class: 'btn small', disabled: !dev.connected, onclick: () => send({ type: 'sync_now' }) }, 'Sync now'),
                    h('button', { class: 'btn small', onclick: () => confirmDo('Unpair this phone?', 'It stops syncing. Pair again any time with a new code.', () => send({ type: 'sync_unpair', id: dev.id })) }, 'Unpair'))));
        }
    }
    box.replaceChildren(...rows);
}

function renderSettings() {
    const root = $('settings-root');
    if (root.contains(document.activeElement) && document.activeElement.type === 'text') return;
    const out = [];
    for (const [title, items] of SETTINGS) {
        out.push(h('div', { class: 'group-title' }, title));
        if (items === 'models') { out.push(h('div', { id: 'model-section' })); continue; }
        if (items === 'privacy') { out.push(privacySection()); continue; }
        if (items === 'phone') { out.push(phoneSection()); continue; }
        if (items === 'help') { out.push(helpSection()); continue; }
        out.push(h('div', { class: 'grouped' }, ...items.filter((it) => !it.when || it.when()).map((it) => {
            const row = h('div', { class: 'g-row', 'data-key': it.key }, h('span', {}, it.label, it.sub ? h('span', { class: 'sub' }, it.sub) : null), settingControl(it));
            if (it.meter) return h('div', { class: 'g-row col', 'data-key': it.key }, row, h('div', { class: 'meter' }, h('i', { id: 'mic-meter' })));
            return row;
        })));
    }
    root.replaceChildren(...out);
    renderModelSection();
}

function renderModelSection() {
    const box = $('model-section');
    if (!box) return;
    const m = models || {};
    const installed = m.installed || [];
    const has = (n) => installed.some((x) => x === n || x === n + ':latest');
    const cat = m.catalog || { models: [], hardware: {} };
    const hw = cat.hardware || {};
    const cl = m.cloud || {};
    const mode = S.ai_provider || 'auto';
    const oi = m.installing_ollama || {};

    // provider switch
    const seg = h('nav', { class: 'segmented small' }, ...[['local', 'On this PC'], ['auto', 'Auto'], ['cloud', 'Cloud']].map(([v, l]) =>
        h('button', { class: mode === v ? 'active' : '', onclick: () => { updateSetting('ai_provider', v); renderModelSection(); } }, l)));
    const modeHelp = {
        local: 'Private and offline. Speed depends on your PC.',
        auto: 'Uses the cloud when a key is set and you are online, otherwise this PC.',
        cloud: 'Fastest answers (about half a second) and no load on your laptop. Conversation text and meeting transcripts go to your provider; commands, memory files and activity stay here.',
    }[mode];

    // local status
    let status, dot;
    if (oi.status === 'running' || oi.status === 'installing') {
        status = oi.status === 'running' ? `Downloading the local AI engine… ${Math.round(oi.pct || 0)}%` : 'Installing the local AI engine…';
        dot = 'busy';
    } else if (!m.ollama_installed) { status = 'The local AI engine (Ollama) is not installed.'; dot = 'bad'; }
    else if (!m.server) { status = 'Starting the local AI engine…'; dot = 'busy'; }
    else if (m.pulling && m.pulling.status !== 'error') { status = `Installing ${m.pulling.name}… ${Math.round(m.pulling.pct || 0)}%`; dot = 'busy'; }
    else if (m.ready) { status = `Ready · ${m.current}`; dot = 'ok'; }
    else { status = `${m.current} is not installed yet`; dot = 'bad'; }

    // model dropdown, 1B -> 14B; incompatible models are disabled with the reason
    const sel = h('select', { class: 'select', style: 'max-width:none;flex:1' }, ...cat.models.map((x) => {
        const tag = x.recommended ? ' — recommended for this PC' : x.compatible ? (has(x.name) ? ' — installed' : '') : ' — not compatible with this PC';
        const o = h('option', { value: x.name }, `${x.label} (${x.size})${tag}`);
        if (!x.compatible) o.disabled = true;
        if (x.name === (pickedModel || m.current)) o.selected = true;
        return o;
    }));
    sel.onchange = () => { pickedModel = sel.value; renderModelSection(); };
    const picked = cat.models.find((x) => x.name === (pickedModel || m.current)) || cat.models[0] || {};
    let action = null;
    const pulling = m.pulling && m.pulling.status !== 'error';
    if (picked.name) {
        if (!picked.compatible) action = h('span', { class: 'caption danger-text' }, 'Not compatible');
        else if (pulling && m.pulling.name === picked.name) action = h('span', { class: 'caption' }, 'Downloading…');
        else if (has(picked.name)) action = picked.name === m.current ? h('span', { class: 'caption' }, 'In use')
            : h('button', { class: 'btn small primary', onclick: () => send({ type: 'model_select', name: picked.name }) }, 'Use');
        else action = h('button', { class: 'btn small primary', disabled: !m.ollama_installed || pulling,
            onclick: () => send({ type: 'model_pull', name: picked.name }) }, `Install ${picked.size}`);
    }

    // one Cancel per running job, and it stops only that job
    const cancelBtn = oi.status === 'running'
        ? h('button', { class: 'btn small', onclick: () => send({ type: 'cancel_install' }) }, 'Cancel')
        : pulling ? h('button', { class: 'btn small', onclick: () => send({ type: 'cancel_pull' }) }, `Cancel ${m.pulling.name}`)
        : null;

    const localRows = [
        h('div', { class: 'g-row' },
            h('span', {}, h('span', { class: 'status-dot ' + dot }), status),
            cancelBtn || (!m.ollama_installed && oi.status !== 'running' && oi.status !== 'installing'
                ? h('button', { class: 'btn small primary', onclick: () => send({ type: 'install_ollama' }) }, 'Install (free)') : null)),
        pulling || oi.status === 'running'
            ? h('div', { class: 'g-row col' },
                h('div', { class: 'progress' }, h('i', { style: `width:${(pulling && m.pulling.pct) || oi.pct || 0}%` })))
            : null,
        h('div', { class: 'g-row col' },
            h('div', { class: 'caption' }, `This PC: ${hw.ram_total || '?'} GB RAM (${hw.ram_free || '?'} GB free) · ${hw.cores || '?'} threads · ${hw.gpu_vram ? hw.gpu_vram + ' GB GPU' : 'no dedicated GPU'} → models up to ${cat.max_params ? Math.round(cat.max_params) + 'B' : '?'} run smoothly.`),
            h('div', { class: 'row', style: 'gap:8px;margin-top:8px' }, sel, action),
            h('div', { class: 'm-note', style: 'margin-top:6px' }, picked.compatible === false ? picked.reason : (picked.note || ''))),
        h('div', { class: 'g-row' }, h('span', {}, 'Free memory when idle', h('span', { class: 'sub' }, 'Unloads the local model from RAM after this long')),
            settingControl({ key: 'llm_keep_alive', type: 'select', options: [['5m', '5 minutes'], ['15m', '15 minutes'], ['1h', '1 hour'], ['-1', 'Never']] })),
    ];

    // cloud
    // The provider you picked updates S at once; the engine's status (cl) catches up a moment later.
    // Show engine-reported key/model/status only once it describes the provider shown, and always
    // save keys under the provider shown, never a stale one.
    const prov = S.cloud_provider || cl.provider;
    const cs = cl.provider === prov ? cl : {};
    const provSel = h('select', { class: 'select' }, ...Object.entries(cl.providers || {}).map(([k, v]) => {
        const o = h('option', { value: k }, v.label);
        if (k === prov) o.selected = true;
        return o;
    }));
    provSel.onchange = () => {
        updateSetting('cloud_provider', provSel.value);
        renderModelSection();
    };
    const currentProvInfo = (cl.providers && cl.providers[prov]) || {};
    const defModel = currentProvInfo.model || (currentProvInfo.custom ? 'enter a Model ID below' : '');
    const keyIn = h('input', {
        type: 'password',
        placeholder: cs.key ? `Saved (${cs.key}) — paste to replace` : `Paste your ${currentProvInfo.label || ''} API key`,
        autocomplete: 'off'
    });

    const keyGuide = currentProvInfo.key_url ? `Get an API key at ${currentProvInfo.key_url}`
        : (currentProvInfo.custom ? 'Enter the API key for your endpoint' : 'Paste your API key to activate.');

    const cloudRows = [
        h('div', { class: 'g-row' }, h('span', {}, 'Provider'), provSel),
        h('div', { class: 'g-row col' }, h('div', { class: 'm-note' },
            'Model: ', h('strong', { style: 'color:var(--text)' }, cs.model || defModel),
            ' · picked automatically for this provider (a fast, low-cost one)')),
        prov === 'compatible' ? h('div', { class: 'g-row' }, h('span', {}, 'Base URL'),
            settingControl({ key: 'cloud_base_url', type: 'text', placeholder: cs.base_url || currentProvInfo.base_url || 'https://…/v1' })) : null,
        prov === 'compatible' ? h('div', { class: 'g-row' }, h('span', {}, 'Model ID', h('span', { class: 'sub' }, 'Required for a custom endpoint')),
            settingControl({ key: 'cloud_model', type: 'text', placeholder: cs.model || 'e.g. llama-3.1-8b-instruct' })) : null,
        h('div', { class: 'g-row col' },
            h('div', { class: 'row', style: 'gap:8px' }, keyIn,
                h('button', { class: 'btn small primary', onclick: () => {
                    const keyVal = keyIn.value.trim();
                    if (keyVal) {
                        send({ type: 'set_api_key', provider: prov, key: keyVal });   // engine tests it and reports back
                    } else {
                        showToast('Please enter an API key', false);
                    }
                    keyIn.value = '';
                } }, 'Save'),
                h('button', { class: 'btn small', disabled: !cs.configured, onclick: () => send({ type: 'cloud_test' }) }, 'Test'),
                cs.key ? h('button', { class: 'mini', onclick: () => {
                    send({ type: 'set_api_key', provider: prov, key: '' });
                } }, 'Remove') : null),
            h('div', { class: 'm-note', style: 'margin-top:6px' },
                (cs.configured ? `Key saved, encrypted with Windows DPAPI. ${cs.active ? '🟢 Live Cloud brain is active.' : ''}`
                    : keyGuide) + (cs.error ? '  ⚠ ' + cs.error : ''))),
        h('div', { class: 'g-row' }, h('span', {}, 'Let the cloud help learn memories', h('span', { class: 'sub' }, 'Off = memory learning stays on this PC')),
            settingControl({ key: 'cloud_for_memory', type: 'switch' })),
    ];

    box.replaceChildren(h('div', { class: 'grouped' },
        h('div', { class: 'g-row col' }, seg, h('div', { class: 'm-note', style: 'margin-top:6px' }, modeHelp)),
        ...(mode !== 'cloud' ? localRows : []),
        ...(mode !== 'local' ? cloudRows : []),
        h('div', { class: 'g-row' }, h('span', {}, 'Speech', h('span', { class: 'sub' }, `Recognition: Whisper ${m.whisper || ''} · Voice: ${m.tts_engine === 'kokoro' ? 'Kokoro (natural)' : 'Windows'}`)))));
}
let pickedModel = null;

function privacySection() {
    return h('div', { class: 'grouped' },
        h('div', { class: 'g-row' }, h('span', {}, 'Everything stays on this laptop', h('span', { class: 'sub' }, dataDir || '%APPDATA%\\SnapAir')), h('button', { class: 'btn small', onclick: () => send({ type: 'open_data_folder' }) }, 'Open folder')),
        h('div', { class: 'g-row' }, h('span', {}, 'Export my data (JSON)'), h('button', { class: 'btn small', onclick: () => send({ type: 'export_data' }) }, 'Export')),
        h('div', { class: 'g-row' }, h('span', { class: 'danger-text' }, 'Delete all my data', h('span', { class: 'sub' }, 'Memories, notes, tasks, activity and conversations')),
            h('button', { class: 'btn small danger', onclick: () => confirmDo('Delete all your data?', `${NAME()} will forget everything: memories, notes, tasks, activity history and conversations. This can't be undone.`, () => send({ type: 'delete_all_data' })) }, 'Delete')));
}

function helpSection() {
    const keys = [['Ctrl+Alt+Space', 'Talk / interrupt'], ['Ctrl+Alt+K', 'Type a request'], ['Ctrl+Alt+J', 'Assistant'], ['Ctrl+Alt+T', 'Today'], ['Ctrl+Alt+N', 'Start/stop meeting notes'], ['Ctrl+Alt+G', 'Pause hand gestures'], ['Ctrl+Alt+S', 'Settings'], ['Ctrl+Alt+H', 'Hide the HUD']];
    return h('div', { class: 'grouped' },
        ...keys.map(([k, d]) => h('div', { class: 'g-row' }, h('span', {}, d), h('span', { class: 'kbd' }, k))),
        h('div', { class: 'g-row col' }, h('div', { class: 'help-cat' }, 'Try saying'),
            h('div', { class: 'help-items' }, `“${NAME()}, start my day” · “remind me at 5 to push the PR” · “kal subah gym yaad dilana” · “set a timer for 10 minutes” · “take meeting notes” … “mark that” … “stop taking notes” · “what notes did we create today?” · “prepare my standup” · “focus for 45 minutes” · “park this as login bug” / “resume login bug” · “explain my clipboard” · “summarise this page” · “what do you know about me?” · “forget that I …” · “youtube kholo” · “awaaz badhao” · “press windows h” · “open clipboard history” · “wrap up my day”`)),
        ...catalogue.map(([cat, items]) => h('div', { class: 'g-row col' }, h('div', { class: 'help-cat' }, cat), h('div', { class: 'help-items' }, items.map((i) => `“${i}”`).join(' · ')))));
}

function renderHelp() {
    const root = $('help-root');
    root.replaceChildren(h('p', { class: 'caption intro' }, `Talk to ${NAME()} like a person — in English, Hindi or Hinglish. Say “${NAME()}, …”, press Ctrl+Alt+Space, or type.`),
        helpSection(),
        h('div', { class: 'group-title' }, 'Read your browser tab'),
        h('div', { class: 'grouped' }, h('div', { class: 'g-row col' }, h('div', { class: 'help-items' },
            'To let Snapy read the page you\'re on (“summarise this page”), start Chrome with remote debugging: chrome.exe --remote-debugging-port=9222. Without it, Snapy can still read any link you give it.'))));
}

function highlightSetting(key) {
    setTimeout(() => {
        const row = document.querySelector(`[data-key="${key}"]`);
        if (row) { row.scrollIntoView({ block: 'center', behavior: 'smooth' }); row.classList.add('highlight'); setTimeout(() => row.classList.remove('highlight'), 2500); }
    }, 150);
}

// static [data-setting] controls (memory & activity tabs)
function bindSettings() {
    document.querySelectorAll('[data-setting]').forEach((el) => {
        const k = el.dataset.setting;
        if (el.type === 'checkbox') el.checked = !!S[k]; else el.value = String(S[k] ?? '');
        if (!el._bound) {
            el._bound = true;
            el.addEventListener('change', () => updateSetting(k, el.type === 'checkbox' ? el.checked : (el.dataset.num ? +el.value : el.value)));
        }
    });
}
function updateMeters() {
    const m = $('mic-meter');
    if (m) m.style.width = `${Math.min(100, Math.sqrt(eng.mic_level || 0) * 400)}%`;
}

// ---------------------------------------------------------------- banners
const BANNER_STYLE = { problem: ['mic', '#ff3b30'], reminder: ['bell', '#ff9f0a'], call: ['phone', '#30d158'], break: ['coffee', '#64d2ff'], wrapup: ['moon', '#5e5ce6'], info: ['info', '#0a84ff'], nudge: ['leaf', '#64d2ff'], weekly: ['chart', '#5e5ce6'] };
function showBanner(b) {
    const [icon, color] = BANNER_STYLE[b.kind] || BANNER_STYLE.info;
    // a nudge reports how it ended once: a button, the close (dismiss) or the timeout (ignored)
    let answered = false;
    const answer = (action) => { if (b.kind === 'nudge' && !answered) { answered = true; send({ type: 'nudge_action', id: b.id, action }); } };
    const close = (why) => { answer(why === 'timeout' ? 'ignored' : 'dismiss'); el.style.opacity = '0'; setTimeout(() => el.remove(), 200); };
    const actions = [];
    if (b.kind === 'nudge') {
        (b.actions || []).forEach((a, i) => actions.push(h('button', { class: 'btn small' + (i === 0 ? ' primary' : ''), onclick: () => {
            answer(a.id);
            if (a.id === 'reset') showReset(b.reset);
            close();
        } }, a.label)));
    } else if (b.kind === 'reminder' && b.task) {
        actions.push(h('button', { class: 'btn small primary', onclick: () => { send({ type: 'task_update', id: b.task.id, done: true }); close(); } }, 'Done'),
            h('button', { class: 'btn small', onclick: () => { send({ type: 'task_snooze', id: b.task.id, minutes: 10 }); close(); } }, 'Snooze 10m'));
        ipcRenderer.send('notify', { title: b.title === 'Timer done' ? 'Timer done' : `${NAME()} reminder`, body: b.text });
    } else if (b.kind === 'call') {
        actions.push(h('button', { class: 'btn small primary', onclick: () => { send({ type: 'meeting_start' }); close(); } }, 'Take notes'),
            h('button', { class: 'btn small', onclick: close }, 'No thanks'));
    } else if (b.kind === 'wrapup') {
        actions.push(h('button', { class: 'btn small primary', onclick: () => { send({ type: 'chat', text: 'wrap up my day' }); openDrawer('assistant'); close(); } }, 'Show summary'),
            h('button', { class: 'btn small', onclick: close }, 'Later'));
    } else if (b.action) {
        actions.push(h('button', { class: 'btn small primary', onclick: () => { send({ type: b.action.type }); close(); } }, b.action.label),
            h('button', { class: 'btn small', onclick: close }, 'Later'));
    } else {
        actions.push(h('button', { class: 'btn small', onclick: close }, 'OK'));
    }
    const el = h('div', { class: 'banner interactive' + (b.kind === 'nudge' ? ' nudge' : '') },
        h('div', { class: 'banner-head' }, h('div', { class: 'banner-icon', style: `background:${color}`, html: svg(icon, 13) }), h('div', { class: 'banner-title' }, b.title), h('button', { class: 'icon-btn', style: 'width:22px;height:22px', 'aria-label': 'Dismiss', onclick: () => close('dismiss') }, '✕')),
        h('div', { class: 'banner-text' }, b.text), h('div', { class: 'banner-actions' }, ...actions));
    $('banners').prepend(el);
    if (!['reminder', 'call', 'problem'].includes(b.kind)) setTimeout(() => { if (el.isConnected) close('timeout'); }, b.kind === 'weekly' ? 60000 : 20000);
}

// ------------------------------------------------------- attention chip
// "▶ 42" in the island: Shorts/Reels counted today on this PC. Amber at the soft limit, never red.
function renderAttention() {
    const a = attention;
    const show = !!(a && a.enabled && (a.today > 0 || a.videos > 0));
    $('island-att').classList.toggle('hidden', !show);
    if (!show) return;
    $('att-count').textContent = String(a.today);
    $('island-att').classList.toggle('amber', a.level === 'amber');
    const by = (a.by || []).map((x) => `${x.label} ${x.count}`).join(' · ');
    const vids = a.videos ? ` · ${a.videos} video${a.videos === 1 ? '' : 's'} (${Math.round((a.video_ms || 0) / 60000)} min)` : '';
    $('island-att').title = `Today on this PC: ${a.today} shorts & reels${by ? ' — ' + by : ''}${vids}` + (a.paused ? ' · counting paused' : '');
}

// ------------------------------------------------------- 2-minute reset
// Breathe / stand / water, then it closes itself. Steps and timings come from the engine.
let resetTimer = null;
const RESET_CIRC = 2 * Math.PI * 52;
function showReset(r) {
    r = r || (attention && attention.reset) || { seconds: 120, steps: [], title: '2-minute reset', done: 'Done' };
    const total = Math.max(10, r.seconds || 120), steps = r.steps || [], start = Date.now();
    $('reset-title').textContent = r.title || '2-minute reset';
    $('reset-done').textContent = r.done || 'Done';
    $('reset-dots').replaceChildren(...steps.map(() => h('i')));
    $('reset-arc').style.strokeDasharray = String(RESET_CIRC);
    $('reset').classList.remove('hidden');
    const tick = () => {
        const el = (Date.now() - start) / 1000, left = Math.max(0, Math.ceil(total - el));
        $('reset-time').textContent = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
        let acc = 0, idx = steps.length - 1;
        for (let i = 0; i < steps.length; i++) { acc += steps[i].seconds || 0; if (el < acc) { idx = i; break; } }
        if (steps[idx]) $('reset-step').textContent = steps[idx].text;
        [...$('reset-dots').children].forEach((d, i) => d.classList.toggle('on', i <= idx));
        $('reset-arc').style.strokeDashoffset = String(RESET_CIRC * (1 - Math.min(1, el / total)));
        if (left <= 0) hideReset();
    };
    clearInterval(resetTimer);
    tick();
    resetTimer = setInterval(tick, 250);
}
function hideReset() { clearInterval(resetTimer); resetTimer = null; $('reset').classList.add('hidden'); }
$('reset-done').onclick = hideReset;
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && resetTimer) hideReset(); });

// --------------------------------------------------------------- greeting
let greetTimer = null;
function showGreeting(b) {
    $('greeting-title').textContent = b.title;
    $('greeting-lines').replaceChildren(...b.lines.map((l) => h('p', {}, l)), h('p', {}, b.question));
    $('greeting-weather').replaceChildren(...(b.weather ? [h('span', { class: 'chip static' }, `${b.weather.temp}° · ${b.weather.desc}`)] : []));
    $('greeting-plan').replaceChildren(...(b.plan || []).map((p) => h('li', {}, p.label)));
    $('greeting-go').classList.toggle('hidden', !(b.plan && b.plan.length));
    $('greeting-later').textContent = b.plan && b.plan.length ? 'Not now' : 'Thanks';
    $('greeting').classList.remove('hidden');
    clearTimeout(greetTimer);
    greetTimer = setTimeout(hideGreeting, 90000);
}
function hideGreeting() { $('greeting').classList.add('hidden'); }
$('greeting-go').onclick = () => { send({ type: 'start_my_day' }); hideGreeting(); };
$('greeting-later').onclick = () => { send({ type: 'dismiss_briefing' }); hideGreeting(); };

// ------------------------------------------------------------- onboarding
let obOpen = false, obStep = 0, obAutoPulled = false;
let SETUP = null, setupHidden = false;
let videoCapture = null;

// "Show some emojis on the screen": a short, light burst that floats up and fades (never blocks clicks)
function emojiBurst(list) {
    if (!list.length) return;
    const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const layer = h('div', { class: 'emoji-layer', 'aria-hidden': 'true' });
    document.body.appendChild(layer);
    const count = reduce ? 6 : 28;
    for (let i = 0; i < count; i++) {
        const e = h('span', { class: 'emoji-pop' }, list[i % list.length]);
        e.style.left = (4 + Math.random() * 92) + 'vw';
        e.style.fontSize = (28 + Math.random() * 34) + 'px';
        e.style.animationDelay = (Math.random() * 1.2) + 's';
        e.style.animationDuration = (2.6 + Math.random() * 1.8) + 's';
        e.style.setProperty('--drift', (Math.random() * 120 - 60) + 'px');
        layer.appendChild(e);
    }
    setTimeout(() => layer.remove(), 5500);
}
const fmtMB = (b) => b >= 1e9 ? (b / 1e9).toFixed(2) + ' GB' : Math.round((b || 0) / 1e6) + ' MB';
function setupPct(st) { return st && st.total ? Math.min(100, Math.round(st.done * 100 / st.total)) : 0; }
function setupItemEl(it) {
    const pct = it.total ? Math.min(100, it.done * 100 / it.total) : 0;
    let meta;
    if (it.state === 'done') meta = 'Done';
    else if (it.state === 'skipped') meta = 'Not needed';
    else if (it.state === 'installing') meta = 'Installing…';
    else if (it.state === 'error') meta = 'Failed';
    else if (it.state === 'cancelled') meta = 'Cancelled';
    else if (it.state === 'downloading') {
        const left = it.speed > 0 ? Math.max(1, Math.round((it.total - it.done) / it.speed)) : 0;
        meta = `${fmtMB(it.done)} of ${fmtMB(it.total)}` + (it.speed > 0 ? ` · ${(it.speed / 1e6).toFixed(1)} MB/s · ${left >= 60 ? Math.round(left / 60) + ' min' : left + ' s'} left` : '');
    } else meta = `Waiting · ${fmtMB(it.total)}`;
    return h('div', { class: `setup-item ${it.state}` },
        h('div', { class: 'setup-row' }, h('span', { class: 'setup-icon' }, it.state === 'done' ? '✓' : it.state === 'error' ? '!' : ''),
            h('span', { class: 'name' }, it.label), h('span', { class: 'meta' }, meta)),
        h('div', { class: 'setup-desc' }, it.desc),
        h('div', { class: 'setup-bar' }, h('i', { style: `width:${it.state === 'done' ? 100 : pct}%` })),
        it.error && it.state !== 'done' ? h('div', { class: 'setup-err' }, it.error) : null);
}
function renderSetup() {
    const st = SETUP;
    const active = st && st.items && st.items.length && !st.complete;
    const failed = st && (st.items || []).some((i) => i.state === 'error' || i.state === 'cancelled');
    // onboarding shows a compact version inside its own sheet
    const box = document.getElementById('ob-setup');
    if (box) {
        box.classList.toggle('hidden', !active && !failed);
        if (active || failed) box.replaceChildren(h('div', { class: 'caption', style: 'margin-bottom:6px;font-weight:600' },
            failed && !st.running ? 'Some downloads failed — retry from Settings or the setup window.' : `Getting ${NAME()} ready · ${setupPct(st)}%`),
            ...st.items.map(setupItemEl));
    }
    const sheet = $('setup-sheet');
    const show = !obOpen && !setupHidden && (active || failed);
    sheet.classList.toggle('hidden', !show);
    if (!st || !st.items) return;
    $('setup-list').replaceChildren(...st.items.map(setupItemEl));
    $('setup-total').textContent = st.complete ? 'All set' : `${fmtMB(st.done)} of ${fmtMB(st.total)} · ${setupPct(st)}%`;
    $('setup-retry').classList.toggle('hidden', !(failed && !st.running));
    $('setup-cancel').classList.toggle('hidden', !(st.running && !st.complete && !st.cancelled));
    $('setup-lead').textContent = failed && !st.running
        ? (st.cancelled ? 'Setup was cancelled. Press Try again whenever you’re ready — finished parts are kept.'
            : 'Some downloads didn’t finish. Check your internet connection and try again — finished parts are kept.')
        : `Downloading what ${NAME()} needs to run on this PC. You can keep working — this continues in the background.`;
    if (st.complete && !sheet.classList.contains('hidden')) setTimeout(() => sheet.classList.add('hidden'), 1500);
    renderIsland();
}
$('setup-hide').onclick = () => { setupHidden = true; $('setup-sheet').classList.add('hidden'); };
$('setup-cancel').onclick = () => send({ type: 'cancel_setup' });
$('setup-retry').onclick = () => { setupHidden = false; send({ type: 'setup_retry' }); };
$('island-status').addEventListener('click', () => { if (SETUP && !SETUP.complete && (SETUP.items || []).length) { setupHidden = false; renderSetup(); } });
const ob = { name: '', role: '', work_start: '09:00', work_end: '18:00', city: '', languages: ['English'],
             voice: true, activity: false, gestures: false, login: true, greeting_voice: false, editor: '', projects: {}, main: '' };
const OB_STEPS = ['welcome', 'about', 'language', 'permissions', 'setup', 'brain', 'done'];
function openOnboarding() {
    obOpen = true; obStep = 0;
    ob.name = profile.name || '';
    $('onboarding').classList.remove('hidden');
    send({ type: 'scan_system' });
    renderObStep();
}
function closeOnboarding() { obOpen = false; $('onboarding').classList.add('hidden'); renderSetup(); }
function chipGroup(options, selected, multi, onChange) {
    return h('div', { class: 'chip-row' }, ...options.map((o) => h('button', {
        class: 'chip' + ((multi ? selected.includes(o) : selected === o) ? ' selected' : ''),
        onclick: () => { onChange(o); renderObStep(); },
    }, o)));
}
function obField(label, input) { return h('div', { class: 'field' }, h('label', {}, label), input); }
function obInput(key, placeholder, type = 'text') {
    const i = h('input', { type, value: ob[key] || '', placeholder });
    i.addEventListener('input', () => (ob[key] = i.value));
    return i;
}
function perm(icon, color, title, text, key) {
    const c = h('input', { type: 'checkbox', class: 'switch' }); c.checked = !!ob[key];
    c.onchange = () => (ob[key] = c.checked);
    return h('div', { class: 'perm' }, h('div', { class: 'p-icon', style: `background:${color}`, html: svg(icon, 16) }), h('div', { class: 'p-body' }, h('b', {}, title), h('span', { class: 'caption' }, text)), c);
}
let obOrb = null;
function renderObStep() {
    setTimeout(() => { const b = $('ob-body'); if (b && !document.getElementById('ob-setup')) b.appendChild(h('div', { id: 'ob-setup', class: 'ob-setup hidden' })); renderSetup(); }, 0);
    const step = OB_STEPS[obStep];
    $('ob-steps').replaceChildren(...OB_STEPS.map((_, i) => h('i', { class: i === obStep ? 'on' : '' })));
    $('ob-back').classList.toggle('hidden', obStep === 0);
    $('ob-next').textContent = step === 'done' ? `Start using ${ob.agent || NAME()}` : step === 'welcome' ? 'Get started' : 'Continue';
    const body = $('ob-body');
    if (step === 'welcome') {
        const c = h('canvas', { width: 96, height: 96, class: 'orb-canvas hidden' });
        const logo = h('picture', { class: 'logo hero', html: '<source srcset="assets/snapy-white.svg" media="(prefers-color-scheme: dark)"><img src="assets/snapy-black.svg" alt="Snapy" width="88" height="88">' });
        body.replaceChildren(h('div', { class: 'ob-hero' }, logo, c, h('h2', {}, `Hi, I’m ${NAME()}.`),
            h('p', { class: 'lead' }, 'Your personal assistant for this laptop. I can greet you in the morning, open your work, take your meeting notes, remember what matters to you and keep your reminders — just by talking.'),
            h('p', { class: 'caption' }, 'Everything I hear and learn stays on this computer. No account, no cloud.'),
            h('button', { class: 'btn', style: 'margin-top:14px', onclick: () => { send({ type: 'voice_onboarding' }); closeOnboarding(); openDrawer('assistant'); } }, 'Set up by voice instead')));
        obOrb = new Orb(c);
    } else if (step === 'about') {
        body.replaceChildren(h('h2', {}, 'A little about you'), h('p', { class: 'lead' }, 'So I can personalise things. You can change this anytime in Memory.'),
            obField('What should I call you?', obInput('name', 'Your name')),
            obField('And what would you like to call me?', obInput('agent', 'Snapy')),
            obField('What do you do?', chipGroup(['Developer', 'Designer', 'Student', 'Manager', 'Writer', 'Other'], ob.role, false, (o) => (ob.role = o))),
            h('div', { class: 'two' }, obField('Work usually starts', obInput('work_start', '09:00', 'time')), obField('and ends', obInput('work_end', '18:00', 'time'))),
            obField('City (optional — for weather in your briefing)', obInput('city', 'e.g. Bengaluru')));
    } else if (step === 'language') {
        body.replaceChildren(h('h2', {}, 'Which languages do you speak?'), h('p', { class: 'lead' }, 'Talk to me in any of them — I’ll reply in the same language. Mixing Hindi and English is fine.'),
            chipGroup(['English', 'Hindi', 'Hinglish', 'Spanish', 'French', 'German', 'Portuguese', 'Japanese', 'Chinese', 'Arabic', 'Tamil', 'Bengali'], ob.languages, true,
                (o) => { ob.languages = ob.languages.includes(o) ? ob.languages.filter((x) => x !== o) : [...ob.languages, o]; if (!ob.languages.length) ob.languages = ['English']; }),
            h('p', { class: 'fine' }, 'English-only is fastest. With more languages I detect what you’re speaking each time.'));
    } else if (step === 'permissions') {
        body.replaceChildren(h('h2', {}, 'What should I help with?'), h('p', { class: 'lead' }, 'Turn things on now or later in Settings.'),
            perm('mic', '#0a84ff', `Listen for “${ob.agent || NAME()}”`, 'I only act when you start with my name. Audio is processed on this laptop and never stored.', 'voice'),
            perm('chart', '#30d158', 'Learn my routine', 'I note which apps and projects you use and when — never keystrokes, screen contents or private windows — so I can set up your day.', 'activity'),
            perm('rocket', '#ff9f0a', 'Start when I sign in', 'So I can greet you and get your work ready each morning.', 'login'),
            perm('voice', '#bf5af2', 'Speak my morning greeting', 'Otherwise I show it as a quiet card.', 'greeting_voice'),
            perm('hand', '#ff375f', 'Hand gestures', 'Control the mouse with your hand using the camera. Great for accessibility.', 'gestures'));
    } else if (step === 'setup') {
        const editors = (scan && scan.apps && scan.apps.editors) || [];
        if (!ob.editor && editors.length) ob.editor = editors[0];
        const projects = (scan && scan.projects) || [];
        if (!ob.main && projects.length) ob.main = projects[0].path;
        body.replaceChildren(h('h2', {}, 'Your setup'), h('p', { class: 'lead' }, scan ? `I looked around (locally): ${scan.apps.app_count} apps installed.` : 'Looking at your apps and projects…'),
            editors.length ? obField('Which editor do you use most?', chipGroup(editors, ob.editor, false, (o) => (ob.editor = o))) : null,
            projects.length ? obField('Your main project (I can open & run it for you)', h('div', { class: 'scan-list' }, ...projects.slice(0, 12).map((p) => {
                const r = h('input', { type: 'radio', name: 'mainproj' }); r.checked = ob.main === p.path; r.onchange = () => (ob.main = p.path);
                return h('label', {}, r, h('div', { style: 'min-width:0' }, h('div', {}, p.name + (p.kind.length ? ` · ${p.kind.join(', ')}` : '')), h('div', { class: 'path' }, p.path)));
            }))) : (scan ? h('p', { class: 'caption' }, 'No code projects found — you can pick a folder later in Settings.') : null));
    } else if (step === 'brain') {
        const m = models || {};
        const cat = m.catalog || {};
        const hw = cat.hardware || {};
        const rec = cat.recommended || m.recommended_model || 'qwen3:1.7b';
        const info = (cat.models || []).find((r) => r.name === rec) || {};
        const oi = m.installing_ollama || {};
        const pulling = m.pulling && m.pulling.status !== 'error';
        const hwLine = h('p', { class: 'caption' }, `This PC: ${hw.ram_total || '?'} GB RAM · ${hw.gpu_vram ? hw.gpu_vram + ' GB GPU' : 'no dedicated GPU'} → the best model that runs smoothly here is ${info.label || rec} (${info.size || ''}). Bigger models are blocked so your laptop stays fast.`);
        let inner;
        if (oi.status === 'running' || oi.status === 'installing') {
            inner = [h('p', { class: 'lead' }, oi.status === 'running' ? 'Downloading the local AI engine…' : 'Installing the local AI engine…'),
                h('div', { class: 'progress' }, h('i', { style: `width:${oi.pct || 0}%` }))];
        } else if (!m.ollama_installed) {
            inner = [h('p', { class: 'lead' }, 'My AI brain runs on Ollama, a free engine that keeps the model on your laptop. I can install it for you.'),
                h('button', { class: 'btn primary', onclick: () => send({ type: 'install_ollama' }) }, 'Install local AI (free)')];
        } else if (m.ready) {
            inner = [h('p', { class: 'lead' }, `Ready — ${m.current} is installed and runs fully offline.`)];
        } else if (pulling) {
            inner = [h('p', { class: 'lead' }, `Installing ${m.pulling.name} for this PC… you can continue meanwhile.`),
                h('div', { class: 'progress' }, h('i', { style: `width:${m.pulling.pct || 0}%` })),
                h('div', { class: 'row', style: 'justify-content:space-between;align-items:center;margin-top:6px' },
                    h('p', { class: 'fine', style: 'margin:0' }, `${Math.round(m.pulling.pct || 0)}%`),
                    h('button', { class: 'btn small', onclick: () => send({ type: 'cancel_pull' }) }, 'Cancel'))];
        } else {
            // first-run setup downloads it (progress below); only start a pull if setup isn't handling it
            const handled = SETUP && (SETUP.items || []).some((i) => i.id === 'brain' && i.state !== 'error');
            if (!handled && !obAutoPulled) { obAutoPulled = true; send({ type: 'update_settings', settings: { llm_model: rec } }); send({ type: 'model_pull', name: rec }); }
            inner = [h('p', { class: 'lead' }, `Installing ${info.label || rec} automatically — you can continue meanwhile.`)];
        }
        const keyIn = h('input', { type: 'password', placeholder: 'Optional: paste any Cloud AI API key', style: 'flex:1;height:34px;padding:0 10px;border-radius:8px;border:1px solid var(--hair-strong);background:var(--card)' });
        const cloudProvList = (m.cloud && m.cloud.providers) ? Object.entries(m.cloud.providers) : [
            ['gemini', { label: 'Google Gemini' }],
            ['openai', { label: 'OpenAI' }],
            ['anthropic', { label: 'Anthropic Claude' }],
            ['grok', { label: 'xAI Grok' }],
            ['groq', { label: 'Groq (Ultra-fast LPU)' }],
            ['mistral', { label: 'Mistral AI' }],
            ['deepseek', { label: 'DeepSeek' }],
            ['openrouter', { label: 'OpenRouter' }],
            ['perplexity', { label: 'Perplexity' }]
        ];
        const provSel = h('select', { class: 'select' }, ...cloudProvList.map(([k, v]) => h('option', { value: k }, v.label)));
        body.replaceChildren(h('h2', {}, 'My AI brain'), hwLine, ...inner,
            h('div', { class: 'group-title', style: 'margin-top:20px' }, 'Want instant answers? (optional)'),
            h('p', { class: 'caption' }, 'Add any cloud API key (Google Gemini, OpenAI, Claude, Grok, Groq, Mistral, DeepSeek, OpenRouter, Perplexity) and answers respond in ~0.5s with zero load on your laptop. Commands, reminders, memory and activity always stay on this PC.'),
            h('div', { class: 'row', style: 'gap:8px;margin-top:8px' }, provSel, keyIn,
                h('button', { class: 'btn', onclick: () => {
                    if (keyIn.value.trim()) {
                        send({ type: 'set_api_key', provider: provSel.value, key: keyIn.value.trim() });
                        keyIn.value = '';
                    }
                } }, 'Save')));
    } else if (step === 'done') {
        body.replaceChildren(h('div', { class: 'ob-hero' }, h('h2', {}, `You're all set${ob.name ? ', ' + ob.name : ''}!`),
            h('p', { class: 'lead' }, 'Try one of these:'),
            h('div', { class: 'chip-row center' }, ...['start my day', 'remind me at 5 to push the PR', 'take meeting notes', 'remember that I prefer Slack'].map((x) => `“${ob.agent || NAME()}, ${x}”`).map((t) => h('span', { class: 'chip static' }, t))),
            h('p', { class: 'caption', style: 'margin-top:12px' }, `Click the pill at the top of your screen any time to open ${ob.agent || NAME()}.`)));
    }
}
$('ob-back').onclick = () => { if (obStep > 0) { obStep--; renderObStep(); } };
$('ob-next').onclick = () => {
    if (obStep < OB_STEPS.length - 1) { obStep++; renderObStep(); return; }
    const projects = ((scan && scan.projects) || []).slice(0, 15).map((p) => ({ name: p.name, path: p.path }));
    const onlyEnglish = ob.languages.length === 1 && ob.languages[0] === 'English';
    const agentName = (ob.agent || '').trim() || 'Snapy';
    send({ type: 'onboarding_complete', scan,
        profile: { name: ob.name, preferred_name: ob.name, role: ob.role, work_start: ob.work_start, work_end: ob.work_end, city: ob.city,
                   languages: ob.languages, editor: ob.editor, projects },
        settings: { voice_mode: ob.voice ? 'wake' : 'push', activity_tracking: ob.activity, gestures_enabled: ob.gestures,
                    start_at_login: ob.login, greeting_voice: ob.greeting_voice, voice_language: onlyEnglish ? 'en' : 'auto',
                    project_dir: ob.main || '', agent_name: agentName } });
    ipcRenderer.send('set-login-item', ob.login);
    closeOnboarding();
    openDrawer('assistant');
};

// ------------------------------------------------------------ cloud preview
// Shown once, before the first request ever goes to a cloud provider: what would be
// sent (already masked by the engine) and a clear choice. Until "Allow", the engine
// keeps every request on this PC.
function showCloudPreview(sample) {
    if (!sample) return;
    $('cp-provider').textContent = (sample.provider || 'your cloud provider') + (sample.model ? ` (${sample.model})` : '');
    $('cp-redacted').textContent = sample.redacted
        ? 'Emails, phone and card numbers, API keys and your Windows user name are replaced with placeholders like [email] before anything is sent.'
        : 'Masking of personal details is turned off.';
    const msgs = (sample.messages || []).filter((m) => m.role !== 'system').slice(-3);
    $('cp-sample').textContent = msgs.map((m) => `${m.role}: ${m.content}`).join('\n\n') || '(your message)';
    $('cloud-preview').classList.remove('hidden');
    const answer = (allow) => { $('cloud-preview').classList.add('hidden'); send({ type: 'cloud_preview_ack', allow }); };
    $('cp-allow').onclick = () => answer(true);
    $('cp-local').onclick = () => answer(false);
}

// ------------------------------------------------------------ confirm/toast
function confirmDo(title, text, fn) {
    $('confirm-title').textContent = title; $('confirm-text').textContent = text;
    $('confirm').classList.remove('hidden');
    $('confirm-yes').onclick = () => { $('confirm').classList.add('hidden'); fn(); };
    $('confirm-no').onclick = () => $('confirm').classList.add('hidden');
}
let toastT = null;
function showToast(msg, ok = true) {
    if (!msg) return;
    $('toast-text').textContent = msg; $('toast-icon').textContent = ok ? '✓' : '!';
    $('toast').classList.toggle('error', !ok); $('toast').classList.remove('hidden');
    clearTimeout(toastT); toastT = setTimeout(() => $('toast').classList.add('hidden'), ok ? 2600 : 4500);
}

// ------------------------------------------------------------ cursor ring
function renderCursor() {
    const ring = $('cursor-ring');
    if (eng.hand_visible && !eng.gestures_paused && S.pointer_enabled !== false && eng.camera === 'ok') {
        const dpr = window.devicePixelRatio || 1;
        ring.style.left = `${eng.cursor[0] / dpr - window.screenX}px`;
        ring.style.top = `${eng.cursor[1] / dpr - window.screenY}px`;
        ring.className = 'cursor-ring' + (eng.dragging ? ' drag' : '') + (eng.gesture === 'SCROLL' ? ' scroll' : '') +
            (eng.gesture === 'PINCH_INDEX' && !eng.dragging ? ' pinch' : '') + (eng.gesture === 'FIST' ? ' frozen' : '') + (Date.now() < flashUntil ? ' flash' : '');
    } else ring.classList.add('hidden');
}

// ----------------------------------------------------------------- hotkeys
ipcRenderer.on('hotkey', (_e, name) => {
    if (name === 'push_to_talk') talk();
    else if (name === 'command' || name === 'assistant') { openDrawer('assistant'); setTimeout(() => $('chat-input').focus(), 150); }
    else if (name === 'today') toggleDrawer('today');
    else if (name === 'toggle_gestures') send({ type: 'toggle_gestures' });
    else if (name === 'settings') toggleDrawer('settings');
    else if (name === 'toggle_hud') document.body.classList.toggle('hud-hidden');
    else if (name === 'meeting') send({ type: meeting.recording ? 'meeting_stop' : 'meeting_start' });
});

// ------------------------------------------------------------------ boot
function renderName() {
    const h1 = document.querySelector('.drawer-title h1');
    if (h1) h1.textContent = NAME();
    // window title stays "Snapy HUD": the engine uses it to ignore its own window
}
function renderAll() {
    renderName();
    bindSettings(); renderIsland(); renderSuggestions(); renderTasks(); renderNotes(); renderMemory(); renderFocus(); renderContexts();
    renderMeeting(); renderGlance(); renderActivity(); renderBriefingCard();
    if (activeTab === 'settings') renderSettings();
}
applyIcons();
connect();
renderIsland();
renderSuggestions();
