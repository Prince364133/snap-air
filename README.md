# Snapy

**A private personal assistant for your Windows laptop.** It greets you in the morning, sets up your work, takes your meeting notes, keeps your reminders, remembers what matters to you, and controls your PC by voice or hand gestures. Everything runs on your laptop.

- Research & decisions: [docs/RESEARCH.md](docs/RESEARCH.md)
- Plan, architecture, the 24 updates and their status: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## Install (for anyone)
Run `Snapy-Setup-2.0.0.exe` (built into `app/dist/`). No Python, Node or Ollama setup is needed: the engine is bundled, the English speech model and natural voice are included, and first-run setup installs the right local AI model for that PC automatically. You can also paste a Gemini or OpenAI key for instant cloud answers.

The installer isn't code-signed yet, so Windows SmartScreen shows "Windows protected your PC". Click **More info → Run anyway**. A code-signing certificate removes this.

## Build the installer
```
cd app
npm install
npm run dist          # = build:engine (PyInstaller) + build:installer (electron-builder NSIS)
```
Output: `app/dist/Snapy-Setup-<version>.exe`.

## Run from source
```
run.bat            # starts the HUD; it starts/stops the Python engine (log: %APPDATA%\SnapAir\engine.log)
run.bat debug      # engine in a visible console
```
First-time setup: `cd engine && python -m venv .venv && .venv\Scripts\pip install -r requirements.txt`, then `cd app && npm install`, and install [Ollama](https://ollama.com). On first launch, onboarding asks a few questions, scans your apps and projects locally, and downloads the AI model (1.4 GB) and the voice (120 MB).

## What it does
| | Say or do | |
|---|---|---|
| Morning | open your laptop | One greeting a day: yesterday's work, today's tasks, a **Start my day** button that opens your editor + project and runs it |
| Tasks | "Snap, remind me at 5 to push the PR" · "10 minute baad padhai ka reminder lagao" | Spoken + banner + Windows notification, snooze/done |
| Meetings | "Snap, start taking notes" … "mark that" … "stop taking notes" (or Ctrl+Alt+N) | You (mic) + Others (system audio) → summary, key points, decisions, action items that you review before they become tasks. Offers itself when a call starts; auto-stops after 20 min of silence. Audio is never saved |
| Memory | "remember that my manager is Arun" · "forget …" · just talking | Learns lasting facts in the background; **Memory** tab shows, edits, pins and deletes everything |
| Your day | "what notes did we create today?" · "what are my tasks?" · "wrap up my day" · "how much time on YouTube today?" | From local notes, tasks and activity |
| Conversation | anything, in English, Hindi or Hinglish | Local LLM (Qwen3 1.7B by default, upgradeable in Settings), streamed into a natural voice |
| Workday | "prepare my standup" · "focus for 45 minutes" · "park this as login bug" / "resume login bug" · "set a timer for 10 minutes" · "explain my clipboard" · "summarise this page" | Stand-up from git log + tasks, quiet focus timer, saved work contexts |
| PC control | "switch to Chrome", "next tab", "play lofi on YouTube", "youtube kholo", "awaaz badhao", "type …" | 60+ instant commands, Hinglish and Devanagari too |
| Gestures (optional) | point · pinch · two-finger scroll · fist | Camera off until you turn it on |

**Keyboard by voice:** any shortcut — "press windows h", "control shift t", "alt f4", "press f5 three times", "windows v" — plus Windows actions like "open voice typing", "clipboard history", "emoji panel", "task manager", "snap layouts", "new desktop". Misheard letters are corrected ("window plus edge" → Win+H). Ctrl+Alt+Delete can't be pressed by any app (Windows security).

**AI brain:** *Settings → AI brain* has three modes: **On this PC**, **Auto**, and **Cloud** (Gemini, OpenAI or any OpenAI-compatible endpoint; the key is encrypted with Windows DPAPI). Local models range from 1B to 14B. Snapy checks this PC's RAM, CPU and GPU, installs the best model that runs smoothly, and blocks ones that won't ("Your system isn't compatible").

**Screen control:** "click the subscribe button", "click the second video", "click the video on the top left", "type hello in the search box", "what's on my screen?", "play the best video on React hooks". Snapy reads the Windows accessibility tree (exact, local, free; no screenshots), works in Chrome, Edge and most apps, and never clicks window controls unless you name them. Design and roadmap (OCR, local vision model, multi-step plans): [docs/COMPUTER_USE.md](docs/COMPUTER_USE.md).

**Native Indian voices:** Telugu, Marathi, Bengali, Nepali and Urdu use native-speaker Piper voices (about 63 MB each, downloaded on first use; about 10× faster than real time on CPU). Hindi, Tamil and others use Windows' own voices once added in *Settings → Voice → Add voices*. Extra personal-use Hindi voices can be turned on separately (see Licensing). Spoken Hindi replies are written in Devanagari so they're pronounced natively. Compare samples in `docs/voice-samples/`.

**Screen vision:** when a window has no accessibility info, Snapy falls back to Windows text recognition, then a vision model (local with a GPU, or cloud with your key). "On screen, …" runs multi-step goals and asks before anything irreversible.

**Your assistant's name:** Snapy by default; rename it in onboarding or *Settings → General* ("Hey Meera, …"). Similar spellings from speech recognition are matched, and "Snapy" always works too.

**Hotkeys:**
- Ctrl+Alt+Space: talk / interrupt
- Ctrl+Alt+K: type a request
- Ctrl+Alt+J: assistant
- Ctrl+Alt+T: today
- Ctrl+Alt+N: meeting notes
- Ctrl+Alt+G: pause gestures
- Ctrl+Alt+S: settings
- Ctrl+Alt+H: hide

## Privacy
All data is plain JSON in `%APPDATA%\SnapAir\` (profile, memories, journal, notes, tasks, activity). Activity tracking stores app, project and site names with durations. It never stores keystrokes, screen contents, URLs, or private windows. The internet is used only when you ask for a web search or weather. Settings has **Open folder**, **Export**, and **Delete all my data**.

## Licensing notes (read before selling)
**Voices: handled in code.** Each voice carries the licence from its model card (`src/voice/piper_voice.py`). By default Snapy only uses voices that allow commercial use:

| Language | Default native voice | Licence |
|---|---|---|
| Telugu | Piper Padmavathi / Venkatesh | CC-BY-4.0 (attribution) |
| Marathi, Bengali | Piper Google voices | CC-BY-SA 4.0 (attribution) |
| Nepali | Piper Chitwan | CC0 |
| Urdu | Piper Fasih | MIT |
| Hindi, Tamil, others | Windows' own voices (e.g. Microsoft Hemant / Kalpana), added in *Settings → Voice → Add voices* | Licensed with Windows |

The Hindi Piper voices (priyamvada, pratham, rohan), Telugu Maya and Malayalam use CC BY-NC-SA / IIT Madras data. They are **personal use only**. Snapy uses them only if the user turns on *Personal-use voices*. They are downloaded by the user from Hugging Face and are **never shipped in the installer**. Credit the CC-BY voices in your About page or EULA.

**espeak-ng / phonemizer (GPL-3.0): still needs a decision.** Kokoro and Piper use them for pronunciation, and the installer bundles them. Before selling, choose one:
1. Get a legal opinion on shipping espeak-ng as a separate dynamically loaded library (aggregation).
2. Move pronunciation into a separate helper process (the cleanest GPL boundary).
3. Replace it with a permissive G2P: misaki (Apache) for English, plus licensed Indic voices.

AI4Bharat's FastPitch/HiFi-GAN Indic-TTS models appear to be MIT-licensed. They would give commercial Hindi/Tamil/Kannada/Gujarati voices, but check the official LICENSE before relying on them.

## Tests
```
cd engine
.venv\Scripts\python -m unittest tests.test_gestures tests.test_agent tests.test_life tests.test_brain   # fast
.venv\Scripts\python -m unittest tests.test_voice   # real speech → Whisper → actions
```
