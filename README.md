# Snap Air

**A private personal assistant for your Windows laptop.** It greets you in the morning, sets up your work, takes your meeting notes, keeps your reminders, remembers what matters to you, and controls your PC by voice or hand gestures. Everything runs on your laptop.

- Research & decisions: [docs/RESEARCH.md](docs/RESEARCH.md)
- Plan, architecture, the 24 updates and their status: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## Run
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
| Meetings | "Snap, start taking notes" … "stop taking notes" (or Ctrl+Alt+N) | System audio + mic → summary, decisions, action items → your tasks. Offers itself when a call starts. Audio is never saved |
| Memory | "remember that my manager is Arun" · "forget …" · just talking | Learns lasting facts in the background; **Memory** tab shows, edits, pins and deletes everything |
| Your day | "what notes did we create today?" · "what are my tasks?" · "wrap up my day" · "how much time on YouTube today?" | From local notes, tasks and activity |
| Conversation | anything, in English, Hindi or Hinglish | Local LLM (Qwen3 1.7B by default, upgradeable in Settings), streamed into a natural voice |
| PC control | "switch to Chrome", "next tab", "play lofi on YouTube", "volume up", "type …" | 60+ instant commands |
| Gestures (optional) | point · pinch · two-finger scroll · fist | Camera off until you turn it on |

**Hotkeys:**
- Ctrl+Alt+Space: talk
- Ctrl+Alt+K: open the assistant
- Ctrl+Alt+N: meeting notes
- Ctrl+Alt+G: pause gestures
- Ctrl+Alt+S: settings
- Ctrl+Alt+H: hide

## Privacy
All data is plain JSON in `%APPDATA%\SnapAir\` (profile, memories, journal, notes, tasks, activity). Activity tracking stores app, project and site names with durations. It never stores keystrokes, screen contents, URLs, or private windows. The internet is used only when you ask for a web search or weather. Settings has **Open folder**, **Export**, and **Delete all my data**.

## Tests
```
cd engine
.venv\Scripts\python -m unittest tests.test_gestures tests.test_agent tests.test_life tests.test_brain   # fast
.venv\Scripts\python -m unittest tests.test_voice   # real speech → Whisper → actions
```
