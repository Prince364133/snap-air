# Snap Air — Windows + Android Master Plan

Nov 15, 2026 · @AdhocX

## Summary

Snapy becomes one product on two platforms: the Windows app you have today, unchanged, and a new Flutter Android app (`ai.snapy.app`, free, wake word "Hey Snapy") that shares one core of data, rules, prompts and tests with Windows. The Android launch wedge is **attention control**: a chip by the camera that shows today's screen time and the live count of Reels and Shorts, plus an AI bottom sheet. Voice control of the phone and meeting notes ride on the same app.

Three findings shape the plan:

- **Play now bans AI agents built on the Accessibility API.** Any use of it that lets an app "autonomously initiate, plan, and execute actions" is prohibited ([Play policy, Jan 2026](https://developer.android.com/newsletter/play-monthly/2026/content/january)), and voice assistants are explicitly not "accessibility tools" ([Play Help](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en)). So phone actions run through Android intents, and every message is confirmed by the user before it is sent.
- **Reel counting is allowed and proven.** Several Play apps count Reels and Shorts with an accessibility service, with a prominent disclosure, keeping counts on the device ([Thumbo](https://play.google.com/store/apps/details?id=app.thumbo), [ScrollMeter](https://sites.google.com/view/scrollmeter-privacy-policy)). NoScroll does this at 1.3M installs ([AppGoblin](https://appgoblin.info/apps/com.newswarajya.noswipe.reelshortblocker)).
- **Phone calls can't be recorded.** Play bans call recording through accessibility ([The Register](https://www.theregister.com/2022/04/22/google_banning_thirdparty_callrecording_apps/)). Phone meeting notes cover in-person meetings through the mic; calls are captured on the laptop.

### Can people use Snapy on Android without installing an app?

No, not for what you want. A web app or PWA can't:

- read screen time (UsageStatsManager),
- draw a chip over other apps (overlay or accessibility window),
- count Reels inside Instagram,
- listen for "Hey Snapy" in the background, or
- open WhatsApp from a voice command.

These all need a native app installed from the Play Store. The website ([snapy.live](https://snapy.live)) can still be the free, no-install entry point: a demo and a link to Play.

**Install flow:** install from Play → open Snapy → three permission screens, each with a clear reason (usage access, display over apps, the Reel counter) → the chip appears by the camera at once. The mic and wake word come later, as an opt-in.

## Code audit

The Windows product is far along: 23 of the 24 planned updates are built, and the suite runs 144 tests with 143 passing. The main risk is one security hole. The main blocker for Android is that all the logic is Windows-only Python. Audited commit `1936627` (15 Nov 2026), about 15,500 lines across `app/` (Electron), `engine/` (Python) and `website/` (Astro).

| Area | Finding | Severity | Fix |
| --- | --- | --- | --- |
| Engine WebSocket | `ws://localhost:8765` accepts `chat` / `execute_command` from any connection. There is no Origin check and no token, so any web page the user visits can send "type …" or "run project" | Critical | Check Origin (allow only the Electron page) and add a per-launch random token passed from Electron to the engine |
| `engine/main.py` (1,148 lines) | Wiring, settings, setup, model install, scheduler and 40 message types in one file | High | Split into `server/`, `setup/` and `scheduler/` modules; one message router table |
| `brain/assistant.py` (1,274 lines) | `_personal()` is a \~200-line chain of regexes; intent rules are mixed with UI and OS calls | High | Move intents to a data file (`core/intents/*.json`) that both platforms load |
| Error handling | 46 `except Exception: pass` blocks hide failures | Medium | Log with a code, surface in the trust centre, count in local diagnostics |
| Tests | 1 failing: `test_v3 … builds_without_starting` expects brain `local` or `cloud` but gets `none` on a machine with no Ollama and no key | Low | Accept `none` as a valid state, or stub the probe |
| Cloud brain (`brain/cloud.py`) | 10 providers; keys encrypted with DPAPI (good); no per-request data minimisation (memory and context go to the cloud as written) | Medium | A redaction pass and a "what's sent" preview before the first cloud call |
| Data | Plain JSON in `%APPDATA%\SnapAir\`: transparent, but no schema versions and no encryption at rest | Medium | Versioned shared schemas; optional encryption with DPAPI on Windows and Keystore on Android |
| Licensing | espeak-ng (GPL-3.0) is bundled in the installer; the README flags it as undecided | High before selling | Decide before the paid launch; on Android use the system TTS, so it doesn't apply there |
| Packaging | 358 MB installer, not code-signed (SmartScreen warning) | Medium | Buy a code-signing certificate; download models on first run to shrink the installer |

**What to keep as it is:** the Electron HUD and its UX, gesture control, the accessibility-tree screen control, Hinglish and Devanagari handling, the memory design (profile, memories, journal), meeting review before tasks, and call-awareness. These are the product's moat; Android should copy their behaviour, not their code.

## Who buys it: 14 simulated users

The buyer is a distracted person who wants an honest friend in their pocket and on their laptop. That friend notices when they're slipping, helps them recover, and handles the boring parts of the day. Each user below was walked through a day with Snapy. The last column is what made them keep it, or what would make them uninstall it.

| # | User | Day | What wins them | What loses them |
| --- | --- | --- | --- | --- |
| 1 | Arjun, 29, developer, Bengaluru | Laptop at 9, 3 stand-ups a week, 2 h of Reels at night | Stand-up draft, "start my day", nightly Reel count with a soft stop at 30 | Nudges while he's coding; nags that repeat |
| 2 | Priya, 34, product manager | 6 calls a day, phone in hand between calls | Laptop meeting notes, action items in the phone chip | It speaking during a call; wrong task owners |
| 3 | Rahul, 20, student, Hinglish | 8 GB phone, YouTube Shorts 3 h a day | Shorts counter, "padhai" focus mode, Hinglish voice | Battery drain; English-only replies |
| 4 | Meera, 41, RSI | Needs hands-free on both devices | "Hey Snapy" on phone and PC, WhatsApp by voice | Setup that needs many taps; wake word misses |
| 5 | Sana, 26, content creator | Instagram is work and also the trap | Separate "creating" vs "consuming" time (Reels watched vs posts made) | Being told she's addicted while working |
| 6 | Vikram, 38, sales lead | Lives in WhatsApp, drives a lot | "Message Amit I'm 10 min late" with a read-back first | Sending to the wrong Amit |
| 7 | Neha, 31, new mother | Night scrolling at 2 am | Gentle bedtime wind-down, no guilt language | Red counters and shame |
| 8 | Karan, 17, Class 12 | Exam year, parents worried | Self-set limits, streaks, study timer | Parental spying framing (and it's a minor: no data upsell) |
| 9 | Dr. Iyer, 52, doctor | Back-to-back patients | Reminders, voice notes, "what's next?" | Anything cloud by default (privacy) |
| 10 | Fatima, 45, small-shop owner | WhatsApp orders all day | Voice tasks from WhatsApp messages, end-of-day recap | Complex settings |
| 11 | Rohit, 33, remote engineer | Laptop + phone, context switching | Phone tells laptop "resume login bug"; one memory across both | Two separate apps that don't know each other |
| 12 | Ananya, 24, analyst | Doomscrolls when stuck on hard work | "You opened Instagram 14 times in an hour — stuck on something?" with a 2-minute reset | Blocking apps outright |
| 13 | James, 47, team lead (buyer for 20 people) | Evaluates privacy | Local-first, export and delete, data map | Any hidden recording |
| 14 | Lakshmi, 60, retired | Learning smartphones | Simple voice help, big chip text, Tamil | English-only and tiny UI |

Patterns across all 14:

- **Counting beats blocking.** People keep apps that make them aware; they uninstall apps that block. Make hard limits opt-in and soft by default.
- **Never shame.** The chip and the nudges say what is happening, never "you're addicted".
- **Trust is the product.** Read-back before sending, local by default, a visible mic state.
- **One Snapy across devices.** Users expect the laptop and phone to share memory, tasks and notes.

## Feature parity: Windows and Android

Every feature exists on both platforms. The mechanics differ only where the OS forces it, and the user sees the same names, chips, drawers and voice phrases everywhere. "Shared" means it comes from the common core, so the behaviour is identical and it's tested once.

| Feature | Windows (today) | Android (new) | Shared from core |
| --- | --- | --- | --- |
| Status chip | Dynamic-island pill (AI state, timers) | Pill by the camera cutout: AI state, screen time, Reel/Short count | Chip states, labels, colours |
| Screen time | Foreground-window tracker | UsageStatsManager (usage access) | Day summary, routine model, wording |
| Reels / Shorts / video count | New: count YouTube Shorts and Instagram in Chrome by tab title | Accessibility event counter per app | Counting rules, limits, nudge copy |
| Scroll / attention nudges | New: "14 switches to YouTube in an hour" | "You've watched 40 Reels — 2-minute reset?" | Nudge engine (thresholds, cooldowns, tone) |
| AI chat | Assistant drawer | Bottom sheet from the chip | Prompts, tool schemas, conversation store |
| Wake word | "Snapy" (Whisper match) | "Hey Snapy" (on-device keyword model, opt-in, foreground service) | Wake word list, user rename |
| Voice commands | 60+ instant commands + LLM | Intents: open app, call, WhatsApp message, alarm, timer, search, navigate, play media | One intent grammar (English, Hinglish, Devanagari) |
| Message someone | Not today | WhatsApp / SMS / Telegram via intents, read-back, then the user sends | Contact matching, confirmation copy |
| Meeting notes | Mic + system audio, review before tasks | Mic only (in-room meetings); calls can't be captured | Summary prompt, action-item review |
| Tasks and reminders | Yes | Yes (exact alarms + notifications) | Time parser, stores |
| Memory | Profile, memories, journal | Same | Schema, extraction rules, retrieval |
| Morning greeting | At login | First unlock of the day | Briefing builder |
| Start my day | Opens editor, runs project | Sends "start my day" to the paired laptop; opens the phone's work apps | Workday plan |
| Focus mode | Quiet timer | Quiet timer + optional Do Not Disturb + soft app pause | Focus rules |
| Screen control | Accessibility tree, click and type on screen | Not offered (Play bans agent-style accessibility automation) | n/a |
| Hand gestures | Camera gestures | Not offered (battery, low value on phone) | n/a |
| Local AI | Ollama | Gemini Nano via ML Kit where supported, else a small on-device model or the user's cloud key | Model router, prompts |
| Privacy centre | Export, delete, trust centre | Same + permission dashboard | Data map, copy |
| Cross-device | n/a | Pair with the laptop by QR: shared memory, tasks, notes; "send to laptop" | Sync protocol |

## Architecture: one core, two thin runtimes

Decision: keep one repository with a shared `core/` folder of data and rules that both apps load. On top sit two thin runtimes: the existing Python engine on Windows and a new Dart runtime on Android. A single conformance test suite proves they behave the same. Windows UX stays exactly as it is.

&#91;embedded content: architecture · shared core, two runtimes, encrypted sync\]

What goes in `core/` is everything that decides *behaviour*. That is about 70% of what makes Snapy feel like Snapy, so a rule or prompt change ships to both apps from one edit.

### Why not literally one codebase for everything

| Option | Verdict | Reason |
| --- | --- | --- |
| **Shared `core/` + Python and Dart runtimes + one conformance suite** | **Chosen** | Behaviour comes from one source; each runtime stays native and fast; tests catch drift |
| Run the Python engine on Android (serious\_python) | Rejected for now | It works, but it unpacks a Python runtime on first launch ([pub.dev](https://pub.dev/packages/serious_python)); faster-whisper, Ollama and UI Automation don't exist on Android anyway; slower start, bigger APK |
| Flutter on Windows too (one UI) | Later option | Windows UX is already polished; revisit after Android ships, so you get one UI codebase in v3 |
| Kotlin-only Android | Rejected | You asked for Flutter; a Kotlin-only app shares no UI with a future Flutter desktop |

### Repository layout

```text
snap-air/
  core/                      # shared; versioned with core/VERSION
    schemas/                 # JSON Schema: memory, task, reminder, note, activity_day, counts
    intents/                 # en.json, hinglish.json, devanagari.json (patterns -> intent + slots)
    prompts/                 # system.md, extract_memory.md, meeting_summary.md, nudge_tone.md
    tools/                   # tools.json (names, args) used by both brains
    rules/                   # social.json (per-app detection), nudges.json, limits.json
    i18n/                    # UI strings: en, hi, ta, te, mr, bn
    conformance/             # golden cases: input -> expected intent/reply/state
  engine/                    # Python (Windows) - loads core/
  app/                       # Electron HUD (Windows) - unchanged
  mobile/                    # Flutter app (Android)
    lib/core_runtime/        # Dart port: intent matcher, time parser, memory, briefing, nudges
    lib/ui/                  # chip, bottom sheet, drawers, onboarding
    android/app/src/main/kotlin/ai/snapy/app/
      overlay/ChipOverlayService.kt
      usage/UsageCollector.kt
      counter/ReelCounterService.kt   # AccessibilityService, counting only
      voice/WakeWordService.kt        # mic foreground service
      actions/IntentActions.kt        # WhatsApp, SMS, call, alarm, maps, media
  website/
```

### Data model (shared schemas, v1)

| Record | Key fields | Synced |
| --- | --- | --- |
| `memory_fact` | id, text, kind, importance, created, updated, source, pinned, device | Yes |
| `task` / `reminder` | id, text, due, done, source, owner, device | Yes |
| `note` | id, kind (note/meeting/standup/recap), title, text, action\_items, device | Yes |
| `activity_day` | date, device, apps\[{id, seconds}\], pickups, focus\_minutes | Summary only |
| `attention_day` | date, device, per\_app{reels, videos, opens, seconds}, nudges | Summary only |
| `settings` | per device, plus a shared `profile` block | Profile only |

Sync is last-writer-wins per record with a tombstone for deletes. Each record carries `device` and `updated`; that's enough for single-user data without a CRDT library.

## Android app spec (Flutter, `ai.snapy.app`)

The app is a Flutter UI on top of five small native Kotlin services, because overlays, usage stats, accessibility and foreground services are Android APIs Flutter can't reach on its own. It is free, needs Android 8.0+ (API 26), and targets the current Play target API.

### 1. The chip by the camera

- **What it shows:** `[orb] 5h 16m · ▶ 42` = the AI state, today's screen time, and Reels/Shorts/videos watched today. The count turns amber at the user's soft limit and the ring fills toward it. No red, no shame.
- **Placement:** read the camera cutout with the DisplayCutout API and centre the pill on it. If there is no cutout, place it top-centre. Users can drag it, resize it or hide it.
- **How it's drawn:** an overlay window. Use `TYPE_ACCESSIBILITY_OVERLAY` while the Reel counter service is on (no extra permission), else `TYPE_APPLICATION_OVERLAY` with "Display over other apps". This is the approach other notch apps on Play use ([Androxus](https://androxus.com/blogs/turn-notch-into-shortcut-bar)).
- **Tap:** opens the AI bottom sheet. **Long-press:** quick actions (focus 25 min, pause counting 1 h, hide for today). **Swipe down:** today's breakdown.
- **Hidden automatically** over full-screen video, in games, on the lock screen and during calls.

### 2. Screen time

- `UsageStatsManager` + `UsageEvents` (special "Usage access" permission). Poll every 60 s, and refresh live from foreground events while the chip is visible.
- The total matches Android Digital Wellbeing's definition (time with the screen on, per foreground app), so the user's number agrees with Settings. Doubt about the number destroys trust.
- Per app, per hour, pickups (first unlock and screen-on events), and the longest session.

### 3. Reel / Shorts / video counter

- An **AccessibilityService** limited to `packageNames` of the supported apps, listening only to `TYPE_WINDOW_STATE_CHANGED`, `TYPE_VIEW_SCROLLED` and `TYPE_WINDOW_CONTENT_CHANGED`. It counts a new item when the short-video viewer is on screen and a full-page vertical scroll lands.
- It is processed in memory and never reads messages, posts or typed text. It stores only `{app, count, seconds}` per hour.
- Proven on Play by Thumbo, ScrollMeter and NoScroll ([Thumbo](https://play.google.com/store/apps/details?id=app.thumbo), [ScrollMeter](https://sites.google.com/view/scrollmeter-privacy-policy)).
- **Apps at launch (17):**
  - Short-video feeds: Instagram (Reels), YouTube (Shorts + videos), Facebook (Reels + Watch), Snapchat (Spotlight), Moj, Josh, ShareChat, MX TakaTak, Chingari, Roposo.
  - Feeds counted by sessions and time: X, Threads, Reddit, Pinterest, LinkedIn.
  - Where available: TikTok, YouTube Kids (outside India).
- **Detection rules are data, not code.** A signed `core/rules/social.json` (view IDs, content descriptions, scroll heuristics per app version) is fetched weekly, so a broken counter is fixed in hours without an app release.
- **Long videos:** YouTube long-form counts videos started plus minutes watched, not scrolls.

### 4. Nudges: the moral assistant

| Trigger (defaults, user-tunable) | What Snapy does |
| --- | --- |
| 30 Reels in one session | Chip pulses; a small card: "30 Reels in 12 min. Keep going or take a 2-min reset?" |
| Social app opened 10× in an hour | "You keep coming back to Instagram. Stuck on something? I can start a 25-min focus." |
| Daily soft limit reached | Spoken (if voice is on) + card; optional 10-second pause screen before the app opens again |
| 11 pm+ and scrolling | Bedtime wind-down: dims the chip, suggests tomorrow's first task |
| A focus session is running and a social app opens | "You're in focus until 4:30. Open anyway?" (one tap to continue) |

Rules: at most 1 nudge per 20 minutes, never during calls or navigation, and softer wording after the user dismisses twice. A weekly review ("you watched 31% fewer Reels") builds the habit.

### 5. AI bottom sheet

- Chat, voice (hold-to-talk or "Hey Snapy"), today (tasks, reminders, screen time), notes, memory, settings. The same sections and copy as the Windows drawer.
- **Brain router:**
  1. Gemini Nano via ML Kit's Prompt API where the device supports it. Inference is allowed only from the top foreground app, so it's fine inside the sheet but not in the background ([AI Engineer talk notes](https://www.ai.engineer/talks/owH1f0N-keY-gemini-nano-on-device)).
  2. Else a small on-device model.
  3. Else the user's own cloud key (same providers as Windows).
  4. Else the paired laptop's local model over the LAN.

### 6. Voice control of the phone

- **Wake word "Hey Snapy" (opt-in):** openWakeWord (Apache-2.0, has a Flutter plugin, [pub.dev](https://pub.dev/packages/open_wake_word)) with a custom-trained model; Porcupine is the paid fallback. It runs in a microphone foreground service with a visible notification. Android won't start a mic service from the background, so it starts from the app or a user action ([Android docs](https://developer.android.com/develop/background-work/services/fgs/changes)).
- **Speech to text:** Android on-device `SpeechRecognizer` (Hindi and Indian languages included); Whisper over LAN to the laptop as an option.
- **Actions are Android intents, not screen automation:**
  - Open an app: package launch intent.
  - Call: `ACTION_CALL`, after a read-back.
  - WhatsApp: `https://wa.me/<number>?text=<message>` or `ACTION_SEND` with WhatsApp's package. The chat opens with the message typed in, and **the user taps Send**.
  - SMS: `smsto:`. Telegram: `tg://` links.
  - Alarms and timers: `AlarmClock` intents. Navigation: `geo:` / Maps URLs. Media: `MediaSession` controls. Search: web intent.
- **Contacts:** `READ_CONTACTS` + fuzzy match. Two "Amits" means Snapy asks "Amit Sharma or Amit Patel?". It always reads back: "Message Amit Sharma: I'm 10 minutes late. Send?"
- **Why not tap-through automation:** Play prohibits accessibility use that lets an app autonomously plan and execute actions ([Play policy](https://developer.android.com/newsletter/play-monthly/2026/content/january)). It would also trip Android's Advanced Protection Mode, which disables non-tool accessibility services ([Android Authority](https://www.androidauthority.com/p-3640742/)). Intents give 90% of the value at no policy risk.

### 7. Meeting notes on the phone

- "Hey Snapy, take notes": a mic foreground service with a red recording chip, live transcript, and the same summary and action-item review as Windows.
- It covers in-room meetings and lectures. Phone and VoIP calls can't be captured: Play bans accessibility call recording, and apps can block playback capture ([Android docs](https://developer.android.com/media/platform/av-capture)). When a call app is active, the chip offers "Take notes on your laptop?" if the laptop is paired.

### 8. Permissions, asked in order of value

| Step | Permission | Why we say it's needed |
| --- | --- | --- |
| 1 | Usage access | "See your screen time in the chip" |
| 2 | Display over other apps | "Show the chip by your camera" |
| 3 | Accessibility (Reel counter) | "Count Reels and Shorts. Never reads messages or what you type" (prominent disclosure screen + Play declaration) |
| 4 | Notifications | Reminders and nudges |
| 5 (opt-in) | Microphone + foreground service | "Hey Snapy" and meeting notes |
| 6 (on first use) | Contacts, Phone | Only when the user first asks to message or call someone |

Every permission can be declined and the app still works with less. Play requires respecting declines and not forcing consent ([Play policy preview](https://support.google.com/googleplay/android-developer/answer/16585319)).

### 9. Battery and performance budget

| Item | Budget |
| --- | --- |
| Chip overlay | <1% battery a day |
| Accessibility counter | Event-driven only; no tree scans outside the supported apps |
| Wake word | <3% a day, and only when enabled |
| Cold start | <1.5 s |
| APK size | <40 MB (models downloaded on demand) |

## 16 high-value suggestions

Each one solves a problem the simulated users actually hit, and each works on both platforms unless marked. They are ranked by value for a distracted user against effort; S/M/L = about 1 / 2–3 / 4+ weeks for one engineer.

| # | Suggestion | Problem it solves | Platforms | Effort |
| --- | --- | --- | --- | --- |
| 1 | **Intention prompt:** when a social app opens, the chip asks "What are you here for?" (one tap: reply to DMs / post / just browsing 10 min) and reminds you when that's done | Mindless opening; the pause itself is the intervention | Android (Windows: for social sites in the browser) | S |
| 2 | **Reset, not block:** a 2-minute guided reset (breathe, stand, glass of water) instead of a hard block, unlocking the app afterwards | People uninstall blockers; soft friction keeps them | Both | S |
| 3 | **One Snapy across devices:** QR pairing over the home or office Wi-Fi, end-to-end encrypted sync of memory, tasks, notes and counts; no Snapy server holds data | Two apps that don't know each other feel fake | Both | L |
| 4 | **"Send to laptop" / "send to phone":** a link, a note, or "start my day" from the phone runs on the laptop | Context switching between devices | Both | M |
| 5 | **Phone-free focus:** focus on the laptop puts the phone into focus too (Do Not Disturb + chip timer) | The phone breaks laptop focus | Both | M |
| 6 | **Weekly attention report:** a Sunday card with Reels watched, screen time, focus hours, best day, and one suggestion; it compares you only to yourself | No feedback loop, no habit | Both | S |
| 7 | **Creator mode:** posting, editing and DMs don't count as consuming; only feeds count | Creators and marketers get false alarms (Sana) | Android | M |
| 8 | **Bedtime wind-down:** after a chosen time the chip dims, nudges get gentler, and it offers tomorrow's first task; the morning greeting reports sleep-window scrolling | Night scrolling ruins mornings (Neha) | Both | S |
| 9 | **Read-back on every outgoing action:** messages, calls and emails are always confirmed by voice and screen; plus an undo window for reminders and tasks | Fear of sending to the wrong person (Vikram) | Both | S |
| 10 | **WhatsApp to tasks:** share a WhatsApp message to Snapy and it becomes a task or reminder with a due time ("send invoice to Ravi by Friday") | Orders and asks get lost in chats (Fatima) | Android (Windows via the WhatsApp desktop share menu) | S |
| 11 | **Daily three:** each morning Snapy asks for the 3 things that matter today, pins them in the chip, and the recap scores them | Busy days with no progress | Both | S |
| 12 | **Streaks with forgiveness:** a streak survives one miss a week; no losing 40 days for one bad night | Streak anxiety drives quitting | Both | S |
| 13 | **Accountability buddy (opt-in):** share only your weekly score with one friend; no details | Social motivation without surveillance | Both | M |
| 14 | **Privacy receipts:** a monthly "what Snapy stored and sent" summary, with one-tap delete per item | Trust is the product (James, Dr. Iyer) | Both | S |
| 15 | **Big-text and simple mode:** larger chip text, fewer options, Tamil/Hindi/Telugu UI | Older and non-English users (Lakshmi) | Both | M |
| 16 | **Self-healing counters:** detection rules update weekly from a signed file; a "counter looks wrong" button sends an anonymous app-version fingerprint, opt-in | Instagram updates silently break counting; that kills ratings | Android | M |

**Not recommended:** hard app blocking by default, parental-monitoring framing, auto-sending messages, screen automation on Android, and any cloud storage of activity. Each one cost trust in the simulations, or Play policy forbids it.

## Ordered roadmap

First make Windows safe and pull the shared core out. Then ship the attention chip, the wedge that sells. Voice, sync and the long tail follow, each phase passing a measurable gate.

&#91;embedded content: roadmap · 5 phases, 4 exit gates\]

The chip MVP comes before voice on purpose. It is the feature users see every minute, it needs no microphone trust, and it proves the Play accessibility review early.

### P0 Foundation (weeks 1–2)

- [ ] WebSocket: Origin allow-list + per-launch token (Electron passes `SNAPY_WS_TOKEN` to the engine)
- [ ] Create `core/` and move intents, prompts, tool schemas and the nudge/limit rules out of `assistant.py` and `main.py`
- [ ] JSON Schemas for all records, with a `schema_version` on every file
- [ ] Conformance suite: \~300 golden cases (intents in EN/Hinglish/Devanagari, time parsing, memory extraction, briefing text) run by pytest; Dart runs the same files in P1
- [ ] Fix the failing `test_v3` case; replace silent `except: pass` with logged error codes

### P1 Chip MVP (weeks 3–8)

- [ ] Flutter app shell, onboarding, permission flow with disclosure screens
- [ ] Kotlin: `ChipOverlayService` (cutout-aware), `UsageCollector`, `ReelCounterService` (Instagram + YouTube first)
- [ ] Dart core runtime: intent matcher, time parser, stores, briefing; passes the conformance suite
- [ ] AI bottom sheet: chat + today; brain router (Gemini Nano → cloud key → offline replies)
- [ ] Play internal testing track; accessibility declaration submitted

### P2 Voice (weeks 9–12)

- [ ] "Hey Snapy" custom openWakeWord model; opt-in mic foreground service
- [ ] Intents: open app, call, WhatsApp/SMS/Telegram with read-back, alarms, timers, maps, media, search
- [ ] Tasks, reminders, memory and notes on the phone (same schemas)
- [ ] Closed beta: 100 users across Pixel, Samsung, Xiaomi, Vivo, Oppo, Realme

### P3 Sync (weeks 13–16)

- [ ] QR pairing (Noise or X25519 key exchange), LAN discovery (mDNS), encrypted record sync
- [ ] Full nudge engine (intention prompt, reset, bedtime, focus guard) + weekly report
- [ ] Phone meeting notes (mic) + "take notes on your laptop" handoff during calls

### P4 Launch (weeks 17–20)

- [ ] All 17 social apps in `rules/social.json`, signed remote updates
- [ ] Hindi, Tamil, Telugu, Marathi, Bengali UI; big-text mode
- [ ] Play production release; snapy.live Android page; privacy policy update
- [ ] Pricing stays free; add usage analytics (opt-in, aggregate) to choose the paid tier later

## Risks, compliance and next steps

The biggest launch risk is Play review of the accessibility service. It is managed by keeping that service to one narrow, disclosed job (counting), and by doing every action through intents.

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Play rejects the accessibility declaration | Medium | Launch blocked | Service limited to the supported social packages and to counting; disclosure screen before the system toggle; Play listing explains it; video for the declaration form. Fallback: ship with screen time only (UsageStats), counter in an update |
| Instagram/YouTube UI changes break counting | High (monthly) | Bad ratings | Remote signed rules (suggestion 16), daily canary test on real app versions, "counter paused" state instead of wrong numbers |
| Advanced Protection Mode disables the service | Low (few users) | Counter off | Detect it and explain; screen time still works |
| OEM battery killers (Xiaomi, Oppo, Vivo) stop services | High in India | Chip disappears | Battery-optimisation exemption guide per OEM; restart on boot; a health check in the chip |
| Wake-word false triggers drain trust and battery | Medium | Uninstalls | Off by default; sensitivity slider; speaker check on first use |
| Minors (Karan) | Medium | Policy/legal | No ads, no data sale, age-neutral design; follow Play's Families rules if targeting under-18s |
| Cloud keys leak | Low | High | Android Keystore / Windows DPAPI; never logged |
| GPL espeak-ng in the Windows installer | Known | Blocks paid sales | Decide before any paid plan (README already flags it) |

**Play listing must-haves:**

- Data safety form: usage data and audio processed on the device, nothing sold.
- Accessibility declaration and prominent disclosure.
- Foreground service types declared: microphone, and specialUse only if needed.
- `QUERY_ALL_PACKAGES` avoided; a `<queries>` list of supported apps is used instead.
- A privacy policy at snapy.live/privacy that covers Android.

**Next steps this week:**

- [ ] Fix the WebSocket Origin and token hole on Windows (critical, half a day)
- [ ] Create the `core/` folder and move intents, prompts and schemas into it
- [ ] Scaffold `mobile/` (Flutter) with the chip overlay + UsageStats screen time
- [ ] Register the Play developer account under the company and reserve `ai.snapy.app`
- [ ] Build the Instagram + YouTube counter spike on 3 phones (Pixel, Samsung, Xiaomi)
