# Snap Air — Implementation Plan (v2: personal assistant)

Companion to [RESEARCH.md](RESEARCH.md). Goal: a private, on-device assistant a person would pay for. It greets you, remembers you, talks with you in your language, takes your meeting notes, keeps your tasks, learns your routine, and controls your PC. All data stays on the laptop.

## Guiding principles
1. **Local-first & legible.** Every byte of personal data lives in `%APPDATA%\SnapAir\` as readable JSON. The user can see and delete all of it from the UI.
2. **Deterministic first, AI second.** Known commands run instantly without the LLM. The LLM handles language, memory and judgment, and can only act through whitelisted tools.
3. **Calm by default.** One greeting a day, two sentences, never during a call, never auto-launches without a tap or a "yes".
4. **Honest real-time.** On CPU laptops we build a streaming voice pipeline that starts talking within ~1–2 s (see RESEARCH §2). The voice backend is pluggable so full-duplex S2S can replace it on GPU machines.
5. **Budget.** Idle < 5 % CPU / < 600 MB RAM (engine without LLM). The LLM loads on demand and unloads after 5 min idle.

---

## The 24 updates

| # | Update | Value (persona) | This iteration |
|---|---|---|---|
| 1 | **Local AI brain** — Ollama + Qwen3.5-4B with structured JSON actions (no cloud) | everyone | ✅ build |
| 2 | **Model manager** — pick/upgrade/downgrade models in Settings, in-app download with progress, auto-unload when idle | sellability, low RAM | ✅ build |
| 3 | **Two-way voice conversation** — streaming replies (speak sentence 1 while sentence 2 is generated) + follow-up mode (no wake word for 8 s) | Rahul, Priya | ✅ build |
| 4 | **Interrupt anytime** — "stop", Esc/hotkey, click the orb; voice barge-in when using headphones | everyone | ✅ build |
| 5 | **Multilingual** — Whisper auto language detection, replies in the user's language (incl. Hinglish), language-matched Kokoro voice | Ananya, Rahul | ✅ build |
| 6 | **Long-term memory engine** — profile (core), memories (semantic), journal (episodic), conversation log (recall); retrieval = relevance + importance + recency | Rahul, Priya | ✅ build |
| 7 | **Automatic memory formation** — background extract → ADD/UPDATE/NOOP consolidation; explicit "remember …" / "forget …" | Rahul, Priya | ✅ build |
| 8 | **"What Snap knows" drawer** — view/edit/delete/pin memories and profile, pause learning, export, forget everything | trust (all) | ✅ build |
| 9 | **First-run onboarding** — name, role, work start, languages, permissions (mic, camera, activity, start at login), model setup; < 2 min | sellability | ✅ build |
| 10 | **System understanding** — scan installed editors/browsers/apps and project folders → seeds profile & memories | Rahul | ✅ build |
| 11 | **Start at login** (toggle) | product must-have | ✅ build |
| 12 | **Morning greeting & briefing** — first session of the day: yesterday recap, today's tasks/reminders, weather (if city set) | Rahul, Priya | ✅ build |
| 13 | **"Start my day"** — opens the learned apps + last project, offers to run it; one tap or "yes" | Rahul | ✅ build |
| 14 | **Routine learning** — local app-usage tracking (app + duration, idle-aware, project names from IDE titles), exclusions, private-window skip, 90-day retention, pause | Rahul, Ananya | ✅ build |
| 15 | **Activity insights** — today timeline, top apps, focus time, arrival time, 7-day trend; voice: "how much time on YouTube today?" | Ananya | ✅ build |
| 16 | **Tasks & reminders** — natural-language times ("at 5", "in 10 minutes", "tomorrow 9am"), spoken + banner reminder, snooze/done | everyone | ✅ build |
| 17 | **Meeting notes** — system audio + mic, live transcript, summary, decisions, action items → tasks; consent indicator | Rahul, Priya | ✅ build |
| 18 | **Call awareness** — detects calls (mic in use by Meet/Teams/Zoom) → offers notes, suppresses greeting | Rahul, Priya | ✅ build |
| 19 | **Ask about your day** — "what notes did we create today / what's left?" over notes, tasks, activity, journal; end-of-day wrap-up | Rahul, Priya | ✅ build |
| 20 | **Internet tools** — web search, read a page, weather; 🌐 indicator; page text treated as data | Rahul | ✅ build |
| 21 | **Apple-inspired HUD** — Dynamic-Island pill + right side drawer (Assistant · Today · Notes · Memory · Activity · Settings), light/dark, hairline borders | sellability | ✅ build |
| 22 | **Living orb** — animated assistant presence: idle / listening (reacts to mic level) / thinking / speaking (reacts to voice) | delight | ✅ build |
| 23 | **Trust center** — local-only badge, mic/camera/recording indicators, kill switch, pause tracking, action log, open data folder, delete all data | trust (all) | ✅ build |
| 24 | **Ship-ready packaging** — single installer bundling Python + models, code signing, auto-update, custom-trained "Hey Snap" wake-word model | sellability | ⏭ next phase (needs a signing certificate and build infrastructure) |

Also carried forward: gesture mouse (camera **off by default** until enabled in onboarding, per the product review), 60+ deterministic voice commands, break nudges (opt-in, part of #14/#16).

---

## Architecture

```
┌──────────────────────── Electron HUD (app/) ─────────────────────────┐
│ Island pill (orb · status · indicators)   Side drawer (6 tabs)       │
│ Greeting / reminder / call banners        Onboarding sheet           │
└───────────────▲──────────────────────────────────────┬───────────────┘
                │ WebSocket JSON (ws://localhost:8765)  │
┌───────────────┴──────────────────────────────────────▼───────────────┐
│ engine/main.py — event hub, threads                                  │
│                                                                      │
│  voice/listener  ─▶ brain/assistant ─▶ ai/agent_controller (commands) │
│  (VAD+Whisper)      │  fast path ─────┘                              │
│                     │  LLM (brain/llm: Ollama, JSON schema, stream)   │
│                     │  tools (brain/tools) ─▶ life/*, web/*, desktop  │
│                     └▶ voice/tts (Kokoro/SAPI, sentence queue, level) │
│  brain/memory  (profile, memories, vectors, journal, conversations)   │
│  life/tasks (scheduler) · life/notes · life/activity (tracker, calls) │
│  life/meeting (loopback+mic → transcript → summary)                   │
│  brain/briefing (greeting, start-my-day plan, wrap-up, reflection)    │
│  core/gestures (camera, optional)                                     │
└──────────────────────────────────────────────────────────────────────┘
        Ollama (localhost:11434): qwen3.5:4b · embeddinggemma
```

### Engine modules
| File | Responsibility |
|---|---|
| `src/storage.py` | data dir, atomic JSON read/write, JSONL append, day keys |
| `src/brain/llm.py` | Ollama client: `chat_json` (schema, think=false), `stream_chat` (token stream), `embed`, `list_models`, `pull` (progress), `ensure_server`, idle unload |
| `src/brain/memory.py` | profile, memory CRUD, embeddings, scored retrieval, extraction + consolidation, reflection helpers, export/forget-all |
| `src/brain/tools.py` | tool registry for the LLM: `desktop`, `add_task`, `list_tasks`, `complete_task`, `add_note`, `search_notes`, `remember`, `forget`, `web_search`, `read_page`, `weather`, `start_meeting_notes`, `stop_meeting_notes`, `activity_summary`, `daily_briefing`, `start_my_day`, `open_project`, `run_project` |
| `src/brain/assistant.py` | turn handling: wake/fast path → LLM plan (tool + say) → execute → optional follow-up narration; conversation window; streaming `say` to TTS; language handling; risky-action confirmation |
| `src/brain/briefing.py` | greeting trigger rules, briefing data assembly + phrasing, start-my-day plan, end-of-day wrap-up, nightly reflection into routine facts |
| `src/life/tasks.py` | tasks store, NL time parser, reminder scheduler (snooze/done) |
| `src/life/notes.py` | notes store (plain + meeting notes with summary/action items), today's notes |
| `src/life/activity.py` | foreground/idle sampler, per-day aggregation, project extraction, routine stats, call detection |
| `src/life/meeting.py` | loopback + mic capture, rolling transcription, map-reduce summary |
| `src/life/system_scan.py` | installed editors/browsers, project discovery (git/package.json/pyproject within depth 3 of common folders) |
| `src/web/tools.py` | DuckDuckGo search, readable page text, open-meteo weather |
| `src/voice/tts.py` | Kokoro int8 (multilingual voices) → SAPI fallback; sentence queue; interrupt; output level for the orb |
| `src/voice/voice_listener.py` | + multilingual model, language in callback, "speaking" suppression, follow-up window |

### Data files (`%APPDATA%\SnapAir\`)
```
settings.json                 # user settings (existing)
memory/profile.json           # {name, preferred_name, role, languages[], work_start, work_end, city, editor, browser, projects[{name,path,run}], routine{...}, updated}
memory/memories.json          # [{id, text, category, importance, created, updated, last_used, uses, source, pinned, history[]}]
memory/vectors.json           # {id: [float...]}  (embeddinggemma)
memory/journal/2026-11-15.json# {events:[{ts,type,text}], summary, wrapup}
memory/conversations/2026-11-15.jsonl
tasks.json                    # [{id, title, due, remind_at, done, created, source, snoozed}]
notes.json                    # [{id, text, ts, kind:"note"|"meeting", title?, summary?, decisions?, actions?, transcript?}]
activity/2026-11-15.json      # {apps:{exe:{seconds,title?}}, projects:{name:seconds}, timeline:[[start,end,exe,project]], first_active, last_active}
actions.log.jsonl             # what Snap did (trust center)
```

### WebSocket protocol additions
Engine → HUD: `assistant_state {state: idle|listening|thinking|speaking, level}`, `chat_message {id, role, text, final, lang, tool, web}`, `briefing {title, lines[], plan[], weather}`, `tasks`, `notes`, `memory {profile, memories}`, `activity {day, summary}`, `meeting {recording, elapsed, live, title}`, `banner {kind: reminder|call|break, ...}`, `models {installed[], current, pulling{name,pct}}`, `onboarding {needed, scan}`, `action_log`.

HUD → Engine: `chat {text}`, `interrupt`, `task_add|task_update|task_delete`, `memory_update|memory_delete|memory_add|memory_forget_all`, `profile_update`, `meeting_start|meeting_stop`, `start_my_day`, `request {what: briefing|tasks|notes|memory|activity|models}`, `onboarding_complete {profile, settings}`, `model_pull {name}`, `model_select {name}`, `scan_system`, `open_data_folder`, `delete_all_data`.

---

## UI design system (Apple-inspired)
- **Type:** Segoe UI Variable (Windows' SF equivalent). 13 px body, 11 px captions, 17 px titles, 600 weight headings.
- **Surfaces:** light `rgba(250,250,252,.86)` / dark `rgba(28,28,30,.86)` with 30 px backdrop blur; **1 px hairline borders** (`rgba(0,0,0,.08)` light / `rgba(255,255,255,.10)` dark); radius 14 (cards 12, controls 8); soft shadow `0 10px 40px rgba(0,0,0,.18)`.
- **Color:** system accent blue `#0A84FF`, green `#30D158`, red `#FF453A` (recording), orange `#FF9F0A`; follows `prefers-color-scheme`.
- **Layout:** island pill top-center (orb 22 px + one-line status + indicators). The drawer slides from the right (380 px), with a segmented control for its 6 tabs. Banners slide in top-right. Onboarding is a centered sheet. Everything outside widgets stays click-through.
- **Motion:** 200–280 ms ease-out; the orb is a canvas with layered gradients driven by state and audio level; reduced-motion respected.
- **Controls:** iOS-style switches, segmented controls, grouped settings lists with inset separators, sliders with value labels.

---

## Quality bar (ship gate) & how we test it
| Area | Target | Test |
|---|---|---|
| Command latency | p50 < 1.2 s end-of-speech → action | `tests/test_voice.py` (TTS speech → Whisper → agent) |
| Assistant first audio | < 4 s on target laptop for short replies | live benchmark script against Ollama |
| Command accuracy | 100 % on the command test set | `tests/test_agent.py` |
| Memory | extraction ignores chit-chat; dedupes; retrieval ranks relevant first; forget works | `tests/test_memory.py` (fake LLM + live smoke) |
| Reminders | NL time parsing correctness; fires once; snooze | `tests/test_tasks.py` |
| Briefing | once per day; never during call; correct recap from fixtures | `tests/test_briefing.py` |
| Activity | aggregation, idle exclusion, private windows skipped, project extraction | `tests/test_activity.py` |
| Meeting | chunk transcription + summary pipeline produces notes + tasks | `tests/test_meeting.py` (TTS audio, fake LLM) + live run |
| Gestures | existing 19 tests | `tests/test_gestures.py` |
| HUD | renders all tabs, no console errors, round-trip chat | hidden-window Electron harness + screenshots |
| Resources | engine idle CPU/RAM, LLM unload after idle | measured during integration run |

## Phases (this iteration)
1. Storage + memory + tasks + notes + activity (pure Python, unit-tested)
2. LLM client + tools + assistant orchestrator (fake-LLM tests + live Ollama smoke)
3. TTS + conversation mode + multilingual listener
4. Briefing / start-my-day / call detection / meeting notes / web tools
5. HUD rebuild (pill, drawer, orb, onboarding, banners) + auto-start
6. Integration run, measurements, screenshots, docs update

---

## Status (2026-11-15)
Updates 1–23 are implemented and tested. Update 24 (installer, code signing, auto-update, custom wake-word model) is the next phase.
- **Tests:** 86 automated tests (`engine/tests`): gestures 19, commands 25, tasks/notes/activity 11, memory/assistant/briefing/meeting/streaming/wake-safety 26, speech-to-action pipeline 2 (real Whisper on synthesized speech), plus a hidden-window HUD render check.
- **Live integration:** the real engine + Ollama + Kokoro were driven over WebSocket with an isolated data folder: onboarding scan → greeting with a learned plan → reminders, notes, memory, LLM Q&A, meeting capture (WASAPI loopback + mic), activity summary.
- **Known limits:**
  - On CPU the 1.7B model is good at personal Q&A and Hinglish, but can answer time-sensitive questions from stale knowledge instead of searching.
  - Voice barge-in needs headphones; on speakers, interrupt with the hotkey or the orb.
  - The wake word is detected by transcribing speech (CPU while people talk nearby). A dedicated keyword-spotting model is part of update 24.
