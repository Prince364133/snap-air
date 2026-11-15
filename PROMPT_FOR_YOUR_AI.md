# Prompt: upgrade Snap Air into a personal AI companion

> Paste everything below into your AI coding assistant, with your Snap Air project open.
> Attach `RESEARCH.md` too: it has the sources and the reasons behind the choices below.

---

## Your role

Act as a **senior product engineer** who is turning an existing app into a product people will pay for. Before you build anything, check it from three viewpoints:

1. **A customer** who uses it every day.
2. **The personas below.**
3. **A buyer** who cares about privacy.

Build features that are valuable, not features that only show off technology. Keep the code simple, tested and robust.

## The existing project (read it before changing anything)

Snap Air is a Windows desktop app:

- **`app/`**: an Electron app. `main.js` creates a transparent overlay window that lets clicks pass through. It starts the Python engine and registers global hotkeys. `renderer.js`, `index.html` and `styles.css` draw the heads-up display (HUD) overlay.
- **`engine/`**: the Python engine. `main.py` runs a WebSocket server on `ws://localhost:8765` that talks to the HUD.
  - Camera hand tracking (MediaPipe) moves the mouse with gestures (`src/vision`, `src/core`).
  - `src/voice/voice_listener.py` uses faster-whisper with a wake word ("Snap, …") and energy-based end-of-speech detection.
  - `src/ai/agent_controller.py` is a regex command grammar that does OS actions: apps, windows, tabs, media, typing, "open project", "run project" and so on.
  - It has a simple `notes.json` and settings in `%APPDATA%\SnapAir\settings.json`.
  - Existing tests are in `engine/tests` (gestures, agent, voice).
- **Keep everything that works.** Gestures and the fast command grammar remain the instant, offline control layer. All existing tests must keep passing.

## Goal

Snap Air should feel like a **friend on your desktop who remembers**:

- It starts at login and greets you.
- It knows what you did yesterday and offers to set up your workday.
- You talk to it naturally, by voice and in your own language. It answers out loud and can be interrupted.
- It *does things*: opens apps, runs your project, takes meeting notes, and keeps tasks and reminders.
- It learns your routine and remembers you in local JSON files that you can view, edit and delete.

Everything runs on the user's device.

## Personas (check every feature against these)

- **Arjun, senior developer.** Starts at 9 AM. Uses the Antigravity IDE, Chrome, the terminal and stand-up meetings. Context-switches all day. Hates being interrupted and confirming things over and over.
- **Priya, product manager.** Has back-to-back calls. Needs reliable meeting notes and action items, and needs to trust that nothing records secretly.
- **Rahul, student.** Speaks Hinglish and Hindi. Has an 8 GB laptop with no GPU.
- **Meera, user with RSI.** Must be able to do everything hands-free, including first-time setup.
- **Buyer / IT.** Asks "where does the data go?"

## Key technical decisions (from the research; follow them)

1. **Voice architecture.** Fully end-to-end speech-to-speech models (Moshi, NVIDIA PersonaPlex, MiniCPM-o, Qwen3-Omni) need a strong GPU, mostly can't call tools, and are weak outside English. Build a **streaming duplex pipeline** instead:
   - The microphone stays open while Snap speaks.
   - **Barge-in:** if the user speaks, playback stops immediately and the current answer is cancelled.
   - The first sentence is spoken while the LLM is still generating the rest, so speech is fed sentence by sentence.
   - After Snap answers, it keeps listening for about 8 seconds without needing the wake word.
   - An echo guard raises the voice threshold while Snap is speaking.
   - Make the voice engine **pluggable**, so a speech-to-speech server can be added later for GPU users.
   - Target latency: under 800 ms from the end of the user's speech to the first audio. Humans leave about 200 ms between turns.
2. **Speech recognition (STT).** Switch from `tiny.en` to a multilingual faster-whisper model: `base` by default, with `small` or `large-v3-turbo` as options. Detect the language of each utterance (`language="auto"`). Return `(text, language)`. Later upgrade path: Silero VAD plus Smart Turn v3 (ONNX, CPU) for better end-of-turn detection.
3. **Text-to-speech (TTS).** Build a speaker abstraction that picks a voice engine per language:
   - **Kokoro-82M** (`kokoro-onnx`): supports EN, HI, ES, FR, IT, PT, JA and ZH. Hindi matters for these users.
   - **Kyutai Pocket TTS**: CPU only, supports EN, FR, DE, ES, PT and IT.
   - **Windows built-in voices**: use one persistent PowerShell process running `System.Speech`. Interrupt it by killing the process, then respawn it.
   - **Captions only**, as the last fallback.
   - Strip markdown, URLs and emoji before speaking.
4. **Brain: a local LLM through Ollama.**
   - Use streaming chat with tool calling. Set `num_ctx` explicitly and `keep_alive`.
   - Some Ollama streaming paths drop tool calls, so keep a non-streaming fallback.
   - Hide `<think>` blocks, including when they are split across streamed chunks.
   - Recommend a model by RAM: about 8 GB → `qwen3:1.7b`; 8–14 GB → `qwen3:4b`; 16 GB → `qwen3:8b`; more → `qwen3:14b`.
   - Build a model manager: detect Ollama and the installed models, pull a model with a progress bar, and switch models live. "Improve the model" means a bigger model, or a LoRA fine-tune in a later phase. The persona and prompt stay in our code.
   - Expose about 16–20 tools, no more, because small models pick tools better from a short list:
     - computer_command (wraps the existing grammar)
     - start_workday
     - add / list / complete task
     - set_reminder
     - save / find notes
     - meeting_notes (start / stop / bookmark)
     - remember
     - forget
     - day_summary
     - focus
     - standup_draft
     - work_context (park / resume)
     - web_search
     - read_page
     - clipboard
     - open_panel
5. **Routing order for every utterance:**
   1. Voice onboarding, if it is in progress.
   2. A pending offer plus a yes/no answer ("Want me to open Antigravity?" → "yes").
   3. Fast intents handled with regex and no LLM: tasks, reminders, timers, remember, forget, "what do you know about me", meeting notes, start my day, recap, standup, focus, park/resume, "what did I do yesterday", open a drawer, time and date.
   4. The existing desktop command grammar, plus a **Hinglish normaliser** that rewrites phrases like "youtube kholo", "neeche scroll karo" and "awaaz badhao" (including Devanagari) into English commands. Skip this step for questions and requests like "write me…", "explain…", or anything ending in "?". Otherwise "write me a poem" would *type* text.
   5. The LLM.
   6. If no LLM is running, helpful built-in replies. Explain once how to enable the model.

## Memory design (the most important part)

Combine three proven designs and store everything in `%APPDATA%\SnapAir\memory.json`, with optional embeddings in `memory_vectors.json`.

- **Profile, or core block** (MemGPT/Letta style). It is always in the prompt and kept small: name, preferred name, role, company, languages, usual start time, editor and a short "about".
- **Facts.** Each fact is `{id, text, kind, importance 1–10, created, updated, last_access, access_count, source: chat|user|observed|reflection, pinned, key?}`.
  - Kinds: preference, personal, work, project, routine, goal, relationship, skill, insight.
  - Write each fact in the third person, e.g. "Prefers dark mode".
- **Episodes.** One short summary per day, used for "what did I do yesterday?".
- **Write path:**
  - (a) **Rule-based extraction** that works without an LLM: "my name is", "call me", "I work as", "I love/prefer…", "I usually…", "I start work at…", "I use Antigravity", "remember that…", "mera naam…".
  - (b) **LLM extraction plus consolidation** (Mem0 style), run in a background queue. Show the model the latest exchange and the ~10 most similar existing memories, and have it return JSON operations: ADD / UPDATE / DELETE / NOOP. Only keep durable facts *about the user*. Never store small talk, facts about colleagues, or anything secret.
  - (c) **Dedupe by similarity.**
  - (d) **Observed facts** from routine learning, upserted by key so each one is replaced, not duplicated.
  - (e) **Reflection:** when accumulated importance is 40 or more, write up to 3 insights.
- **Read path** (Generative Agents style): score = `0.25·recency + 0.25·importance/10 + 0.5·relevance`, plus 0.3 if pinned. Recency = `0.995^hours since last access`. Relevance = cosine similarity on Ollama `/api/embed` vectors (`nomic-embed-text`), with keyword overlap as the fallback. Update `last_access` when a fact is retrieved.
- **Privacy:**
  - Regex-block passwords, OTPs, PINs, card and account numbers, and API keys from ever being stored.
  - Add a "memory on/off" switch.
  - Support "forget that…" by voice.
  - Provide a Memory drawer to view, edit, pin and delete facts, plus export everything and delete everything.
  - The prompt tells the model: "use memories only when relevant, never recite them".

## Features to build (priority order)

1. **Start at login and a daily greeting.** Use `app.setLoginItemSettings({openAtLogin, args:['--autostart']})`, and ship an NSIS installer because this doesn't work for APPX. Greet once per day, and again with "welcome back" after more than 3 hours away. The greeting covers yesterday's active time and top apps, tasks finished, open tasks, today's reminders and pending meeting reviews. It ends with an offer.
2. **"Start my day" workspace launcher.** It opens the learned morning apps and any extra apps from settings, opens the project in the preferred or learned editor (Antigravity, VS Code, Cursor…), and runs the dev server using the existing auto-detect. **Skip anything that is already open; don't start duplicates.** One "yes" runs the whole thing.
3. **Two-way conversation**, barge-in, follow-up listening and automatic language mirroring. Reply in the user's language and script. Hinglish gets a Hinglish reply. A Hindi voice is picked when one is available.
4. **Tasks, reminders and timers with a natural-language time parser.** Handle "in 10 minutes", "at 4" (ambiguous 1–6 means PM, and times already past roll to tomorrow), "at 4:30 pm", "tomorrow at 9", "on friday", "tonight", "kal subah", "10 minute baad". Speak reminders and send a Windows notification.
5. **Meeting notes.**
   - Your microphone is labelled "You". **System audio from WASAPI loopback (PyAudioWPatch)** is labelled "Others", so calls on headphones work.
   - While notes are running, ordinary speech becomes transcript; wake-word commands still work.
   - Support "mark that" bookmarks.
   - Auto-stop after 20 minutes of silence.
   - On stop, the LLM writes JSON: title, summary, key points, decisions, action items with owner and `mine`. Without an LLM, fall back to heuristics.
   - **Action items wait for review ("mine" / "not mine" / dismiss) before they become tasks.**
   - Show a consent reminder ("let everyone know notes are being taken") and a visible recording state. Never record silently.
6. **Call awareness.** Detect a Teams, Zoom or Meet call from the foreground window title. During a call Snap stays silent: it stops speaking, sends reminders as notifications only and doesn't talk proactively. It offers to take notes as a banner.
7. **Opt-in activity timeline and routine learning.**
   - Record only the foreground app plus idle time, using `GetForegroundWindow`, the process name and `GetLastInputInfo`. **No screenshots and no keystrokes.**
   - Store app names only by default; window titles are optional.
   - Use an exclude list (password managers, banking, private browsing windows) and auto-delete after 30 days. *Lesson from Microsoft Recall: opt-in, visible and deletable.*
   - Learn the typical weekday start time, the apps opened in the first 45 minutes, top apps and the main editor.
8. **End-of-day recap**, when asked or at a time the user chooses. It covers active time, tasks done, meetings and what is still open, then offers to carry tasks over to tomorrow. Save it as a day episode.
9. **Stand-up draft** (Yesterday / Today / Blockers) from `git log --since=yesterday` in the project folder plus finished and open tasks. Save it to notes and copy it to the clipboard.
10. **Park and resume a work context.** Save the open windows, project folder and git branch under a name. "Resume login bug" brings them back.
11. **Focus mode.** "Focus for 45 minutes" shows a timer and keeps Snap quiet. Add optional wellbeing break nudges, **off by default**.
12. **Context helpers.** Explain, summarise or translate the clipboard. Web search (DuckDuckGo HTML). Read the current Chrome tab with Playwright `connect_over_cdp("http://127.0.0.1:9222")`, with a plain fetch as fallback.
13. **First run.**
    - Scan the system for installed editors, browsers and meeting apps, recent project folders, RAM and the recommended model.
    - Add a welcome drawer.
    - Add **hands-free voice onboarding**: name → start time → "may I learn your routine?" → "start at login?", answered with yes/no, "haan" or "nahi".
14. **Reliability.** Electron restarts the engine if it crashes, with backoff, and gives up after 4 crashes in 2 minutes. Errors are spoken or shown with a single fix.

## UI: Apple-inspired, simple and usable (not a "hacker" look)

- **Look:** follow the system light/dark mode. Translucent materials (`backdrop-filter: blur(28px) saturate(180%)`), hairline borders, soft shadows. Use the system font stack (Segoe UI Variable / SF). Line icons, no emoji icons.
- **Dynamic island** at the top centre:
  - A mini orb, a status line ("Listening…", "Thinking…", or a live caption) and chips for gesture, meeting timer and focus timer.
  - Buttons for Today, Assistant, Notes, Tasks, Memory and Settings.
  - It expands to show captions while Snap speaks.
- **Side drawers:** every control opens in **one right-side drawer** (about 420 px, slides in, Esc closes it), with tabs for:
  - Today
  - Assistant (chat with streaming bubbles, tool chips and an input box with a mic)
  - Notes (Today / Meetings / All, search; a wide 720 px view for a full transcript, action-item review and bookmarks)
  - Tasks and reminders
  - Memory (editable profile, facts grouped by kind, pin / edit / delete, pause)
  - Activity (per-app bars, hourly chart, routine card, timeline, clear)
  - Settings (iOS-style grouped lists, real switches, segmented controls, sliders with value labels, plus a model manager and a privacy centre with export and delete-all)
  - Help
  - Welcome
- **Presence orb:** an animated canvas blob at the bottom centre with no external libraries. It breathes when idle, ripples with mic level while listening, swirls while thinking and pulses with speech level while speaking. A live caption sits under it, and it fades out when idle.
- **Banners** appear under the island for offers ("Looks like you're on a call — take notes?"), reminders and problems.
- **Click-through:** the overlay ignores the mouse except over visible UI.
- **Security:** move to `contextIsolation: true` with a `preload.js` bridge, and add a tray icon with a menu.
- **Hotkeys:** Ctrl+Alt+Space talk / interrupt, Ctrl+Alt+K type, Ctrl+Alt+J assistant, Ctrl+Alt+T today, Ctrl+Alt+G gestures, Ctrl+Alt+S settings, Ctrl+Alt+H hide.

## Data files (`%APPDATA%\SnapAir\`, human-readable, written atomically via temp file + rename)

`settings.json`, `memory.json`, `memory_vectors.json`, `notes.json` (with kinds note / meeting / standup / recap, plus transcript and action_items), `tasks.json`, `reminders.json`, `activity/YYYY-MM-DD.json`, `state.json` (greeted date, last language), `conversation.json` (last ~60 turns), `contexts.json`.

## How to work

1. Read the whole codebase first. Then write a short plan listing the files you'll add or change.
2. Build in phases. **Phase 1:** stores, memory, LLM client, brain, tools and routing, with tests. **Phase 2:** voice duplex (multilingual STT, TTS, barge-in). **Phase 3:** day features (activity, greeting, workday, reminders, meetings, recap, standup, focus). **Phase 4:** UI. **Phase 5:** installer with embedded Python, a model downloader and code signing.
3. Put new code in `engine/src/companion/` (e.g. `memory.py`, `llm.py`, `brain.py`, `tools.py`, `tasks.py`, `activity.py`, `briefing.py`, `meeting.py`, `notes.py`, `hinglish.py`, `lang.py`, `onboarding.py`, `web.py`, `core.py`) and `engine/src/voice/tts.py`.
4. Every optional dependency (Ollama, Kokoro, Pocket TTS, PyAudioWPatch, Playwright) must be **optional**. The app must start and stay useful without any of them.
5. Write unit tests with fakes, so no real OS, mic or LLM is needed:
   - Memory extraction, dedupe, forget, consolidation ops and the secret filter.
   - The time parser, including late-night rollover.
   - Brain flows: the greeting offer → "yes" → editor opens and the dev server runs; meeting stop → action items pending → approve → task.
   - The LLM tool loop with a scripted fake model, plus the think-tag filter split across chunks.
   - The no-LLM fallback.
   - Hinglish normalisation.
   - Activity sessions and the exclude list.
   - Routine learning from synthetic days.
   - Quiet during calls.
6. Watch for these pitfalls:
   - Don't name an event payload field `kind` if your `emit(kind, **payload)` uses `kind` as a parameter.
   - "start taking notes" must not fall into the grammar's generic `start (.+)` app launcher. Fast intents go first.
   - Run the brain on one worker thread so turns stay in order.
   - Never block the WebSocket loop.
7. At the end, report: what you built, how to run it, the test results, and what is left for the next phase.

## Acceptance checklist

- [ ] All old and new tests pass; the engine starts with no optional packages installed.
- [ ] Logging in leads to a greeting, then "yes", then Antigravity opens the project and the dev server starts, with no duplicate windows.
- [ ] "Snap, start taking notes … stop" produces a meeting note; action items wait for review.
- [ ] "Open the drawer and tell me what notes we created today" opens Notes filtered to today and speaks a summary.
- [ ] Hinglish in gets Hinglish out; "youtube kholo" runs instantly.
- [ ] While Snap is talking, speaking stops it at once.
- [ ] During a Teams or Zoom call, Snap stays silent.
- [ ] The Memory drawer shows exactly what is stored; "forget that…" removes it; export and delete-all work.
- [ ] On an 8 GB laptop, the recommended model is small and replies feel responsive.
