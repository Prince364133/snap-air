# Snapy for Android — Implementation Plan

*Flutter app for Google Play. Covers feature parity with Windows, the new **Real Count** header (screen time + reels/shorts counter), the AI bottom sheet, voice control of the phone, and the Play Store policy work needed to get approved.*

---

## Decisions (15 Nov 2026)
- **Company developer account.** No 12-tester / 14-day closed-test gate. We still run an internal and closed test before production.
- **App ID:** `live.snapy.app` (permanent after the first upload).
- **Wake word:** "Hey Snapy" by default; users can customise it later (custom phrases need their own wake-word model).
- **Price:** free at launch; low-cost paid plans to be discussed later.
- **Social apps:** every major one. The list lives in `engine/src/data/app.json → android.social_apps`, with no code change needed to add more.
- **One brain, two platforms:** the Windows engine's Python package (`engine/src`) runs **inside the Android app via Chaquopy** (MIT, Python 3.13). Command understanding, Hinglish, ordinals ("the 4th video"), memory, tasks and app data are written **once**. Each platform only implements the "hands":
  - Windows: `OSActions`
  - Android: `src/platform/android.py`, which records ops that `OpExecutor.kt` carries out
- **UI:** Windows keeps its Electron HUD unchanged. Android is Flutter with the same design tokens (`mobile/lib/core/theme.dart` mirrors `app/styles.css`).
- **No installation-free option:** reading screen time, counting reels, overlays and phone control all need an installed app. After onboarding, the Real Count pill starts automatically (and after reboot), placed beside the camera cutout via an accessibility overlay.

## 0. The rule that shapes everything (read first)

Google Play's **AccessibilityService policy** (updated 2025–2026; the latest clarification was announced on 29 Oct 2026) is the only way for an app to read other apps' screens and tap or type in them. It says:

- The Accessibility API **must not power autonomous decision-making agents**. **Deterministic, rule-based automation** ("behaviour follows a static, human-defined script") **is allowed**.
- Only apps whose core purpose is helping people with disabilities may set `isAccessibilityTool=true`. Snapy is not one of these, so it must:
  - set `isAccessibilityTool=false`
  - show an in-app **prominent disclosure** and get consent
  - file the **Permission Declaration Form** in Play Console, with a short video of the service being enabled and used
- Android 17's Advanced Protection mode can block accessibility services entirely for non-accessibility apps. Every feature needs a fallback.

**Consequence for Snapy's design:**

> **The AI only *chooses* an action from a fixed catalog, and fills in its parameters. Every action is executed by a hand-written, deterministic script.** The LLM never decides taps in a loop on Android.

This is the same "intent → tool" design the Windows engine already uses (`desktop`, `add_task`, … tools). On Android, the open-ended "on screen, …" multi-step loop is **not shipped**. Every script, such as "send WhatsApp message", is a fixed sequence that we wrote and tested.

---

## 1. What we're building

| Area | Windows today | Android plan | Feasible on Play? |
|---|---|---|---|
| Voice assistant | Wake word, push-to-talk, barge-in | Wake word ("Hey Snapy") in a microphone foreground service. Tap the chip or assistant gesture to talk. Barge-in. | ✅ (foreground service type `microphone`, started while visible) |
| Default assistant | — | Snapy can be set as the phone's **digital assistant** (`VoiceInteractionService`): long-press home / power or the corner swipe opens Snapy. | ✅ (strongly recommended) |
| AI brain | Local LLM + cloud fallback | On-device LLM (LiteRT-LM / MediaPipe LLM Inference: **Gemma 3 1B** or **Gemma 3n E2B**, or llama.cpp with **Qwen3 1.7B** GGUF). RAM check → cloud fallback (Gemini / OpenAI key in Android Keystore). | ✅ |
| Hindi / Hinglish | Whisper + native voices | **Android on-device SpeechRecognizer** (offline Hindi and English packs on Android 13+), whisper.cpp as fallback. **Android TextToSpeech** (Google's native Hindi, Tamil, Telugu… voices). | ✅ and commercially clean (no Piper/espeak licensing problem) |
| Memory, notes, tasks, reminders | JSON files | SQLite (drift), the same data model as desktop | ✅ |
| Morning briefing / Start my day | ✅ | Notification and spoken greeting at the first unlock of the day | ✅ |
| Activity / routine | Window tracking | **UsageStatsManager**: per-app time, unlocks, first and last use | ✅ (`PACKAGE_USAGE_STATS`, special access) |
| **Real Count** (new) | — | Header chip: **screen time today** + **reels / shorts watched** + social-app time | ✅ (Accessibility for counting, with declaration) |
| Phone control | Keyboard, UIA, OCR | Action catalog: Android intents first, deterministic accessibility scripts only where intents can't reach | ✅ within the rule in §0 |
| "Message X on WhatsApp" | — | Contacts → `wa.me` deep link with prefilled text → spoken confirmation → scripted tap on **Send** | ✅ (deterministic script + user confirmation) |
| Meeting notes | Mic + system audio | **Microphone only** | ⚠️ Recording phone-call audio is prohibited by Play |
| "Record this video" | System loopback | `MediaProjection` + `AudioPlaybackCapture` (Android 10+, with the user's screen-capture consent each time). Some apps (often YouTube) **opt out** of capture, so the fallback is "listen through the mic". | ⚠️ partly |
| Screen understanding | UIA → OCR → VLM | As default assistant: `AssistStructure` + screenshot of the current app when the **user invokes** Snapy. On-device ML Kit text recognition for OCR. Vision via cloud key. | ✅ (user-invoked only) |
| Hand gestures | Webcam | Not ported (phones don't need it) | — |
| Keyboard shortcuts | ✅ | Replaced by Android global actions (back, home, recents, notifications, screenshot, lock) | ✅ |
| Rename assistant | ✅ | Same (`agent_name` + wake-word model per name, see §6.2) | ⚠️ custom wake words need an on-device model |

---

## 2. Real Count — the header chip

### 2.1 What the user sees
- A small **pill floating at the top of the screen**, over any app, in the same style as the Windows island (orb + text). It shows:
  - **Normally:** `⏱ 5h 16m` (phone time today)
  - **While in Instagram / YouTube / Facebook / Snapchat / Moj / Josh / ShareChat:** `▶ 37 reels · 42m` (this app today), and the orb tints amber after the user's limit
  - **While Snapy is listening or thinking:** the orb animates, like on desktop
- **Tap** → a **bottom sheet** slides up over the current app, with chat, voice, today's counts and quick actions. Swipe down to close.
- **Long-press / drag** → move the pill (left, centre or right; it remembers the position). Hide it for 1 hour, or in full-screen video.
- **On opening a social app:** a short, friendly card: *"Welcome back to Instagram — 23 reels (31 min) so far today. Want a 10-minute timer?"* Snapy can also say it out loud if voice is on. The tone is non-judgemental and dismissible, and it shows at most once per app session.

### 2.2 How it's built
| Piece | Android API | Notes |
|---|---|---|
| Floating pill + bottom sheet | `SYSTEM_ALERT_WINDOW` ("Display over other apps") hosting a **second FlutterEngine** in a `TYPE_APPLICATION_OVERLAY` window (the `flutter_overlay_window` plugin, or our own Kotlin service) | The pill window is small and not focusable. When opened it becomes a focusable full-width sheet window. Respect display cutouts and gesture insets. |
| Screen time today | `UsageStatsManager.queryEvents()`: sum `ACTIVITY_RESUMED → ACTIVITY_PAUSED` per package since midnight | The same source as Digital Wellbeing, so numbers match closely. Recompute every 60 s plus on screen-on. |
| Current foreground app | Accessibility `TYPE_WINDOW_STATE_CHANGED` (instant), falling back to `UsageEvents` polling | |
| **Reels / shorts count** | Accessibility events, **only for the listed packages** (`packageNames` in the service config): `TYPE_VIEW_SCROLLED` / `TYPE_WINDOW_CONTENT_CHANGED` from the short-video pager | See §2.3. Read-only, counted on-device, no screen content stored. |
| Storage | drift tables `usage_day(pkg, date, ms, opens)`, `reels_day(pkg, date, count, ms)` | Shared with the AI ("how many reels did I watch this week?") |
| Survive OEM battery killers | Foreground service (`specialUse` with justification, or `dataSync`), plus a guided screen for Xiaomi / Oppo / Vivo / Realme "Autostart" and battery settings | Critical in India. Test on MIUI/HyperOS, ColorOS, Funtouch, OneUI. |

### 2.3 Counting reels reliably
1. **Per-app selectors in a remote JSON**, not in code. Each entry covers the package, the view-ID or class of the vertical video pager, and the minimum dwell time. Instagram, YouTube and Facebook change their view IDs, so `snapy.live/config/reels.json` is fetched daily and cached, with a bundled default. This matches the "nothing hardcoded" rule from the desktop app.
2. **Count a reel when** the pager's item index changes (`fromIndex/toIndex` on scroll events), or the visible video node changes, **and** the previous item stayed ≥ 700 ms. Accidental flicks don't count. Debounce duplicate events.
3. **Time** = time the reel viewer was the foreground surface, not total app time. Show both.
4. **Fallback when accessibility is off or blocked:** show app time only, labelled "Turn on Real Count for reel numbers".
5. **Accuracy check:** a test script scrolls 50 reels per app on 3 devices. The target is ±2%. Re-run whenever an app updates (Play Console pre-launch report + our device farm).

### 2.4 Limits and nudges (optional, user-set)
- Daily reel or time limit per app → gentle card at 80% and 100%. Optional "pause" overlay with a 10-second breathing countdown. It is **never blocking by default**; users opt in.
- Weekly summary every Sunday: "You watched 412 reels (5h 10m) — 18% less than last week."

---

## 3. Phone control — the action catalog

The LLM (or a fast rule matcher, as on desktop) turns speech into **one action from this catalog** with parameters. Each action is a deterministic script. Anything that sends, calls, pays or deletes **always asks for a spoken or on-screen confirmation**.

| Action | Example | How (intents first) |
|---|---|---|
| `open_app {app}` | "open WhatsApp" | `PackageManager.getLaunchIntentForPackage`, fuzzy name match on installed apps (`<queries>` for launcher intents — no `QUERY_ALL_PACKAGES`) |
| `whatsapp_message {contact, text}` | "WhatsApp Rahul: running 10 minutes late" | Contacts (`READ_CONTACTS`) → number → `https://wa.me/<num>?text=<text>` → **"Send to Rahul: 'running 10 min late'?"** → scripted accessibility tap on the Send button (selector from remote JSON) |
| `call {contact}` | "call mom" | `ACTION_DIAL` (no permission), or `ACTION_CALL` with `CALL_PHONE` after confirmation |
| `sms {contact, text}` | "text Priya I'm home" | `ACTION_SENDTO smsto:` prefilled (Play restricts `SEND_SMS` to default SMS apps) |
| `youtube_play {query, nth}` | "play Arijit songs, the 4th video" | Search deep link → scripted accessibility tap on result *n* (same ordinal logic as desktop `_ordinal`) |
| `music_play {query}` | "play lofi on Spotify" | `MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH` |
| `media {play/pause/next}` | "pause" | `AudioManager.dispatchMediaKeyEvent` |
| `volume`, `brightness`, `torch`, `dnd` | "volume up", "torch on" | `AudioManager`, `Settings.System` (with `WRITE_SETTINGS` grant), `CameraManager.setTorchMode`, `NotificationManager` (DND access) |
| `settings_panel {wifi/internet/volume/nfc}` | "turn on wifi" | `Settings.Panel.*`: Android doesn't let apps toggle Wi-Fi directly, so the panel opens and the user taps |
| `alarm`, `timer` | "wake me at 6" | `AlarmClock.ACTION_SET_ALARM / SET_TIMER` (no exact-alarm permission needed) |
| `reminder {text, time}` | "remind me at 5 to push the PR" | Own notification. `setExactAndAllowWhileIdle` only if the user grants exact alarms, otherwise windowed. |
| `navigate {place}` | "take me home" | `google.navigation:` / `geo:` intent |
| `global {back/home/recents/notifications/screenshot/lock}` | "go back", "take a screenshot" | `AccessibilityService.performGlobalAction` |
| `type {text}` | "type I'll be there soon" | Accessibility `ACTION_SET_TEXT` on the focused field |
| `click {target}` | "tap the second video" | Accessibility node tree → the same `find()` algorithm as desktop `screen.py` (name, type, ordinal, corner) → `ACTION_CLICK`. User-invoked, single step. |
| `screen_read` | "what's on my screen?" | As default assistant: `AssistStructure` text + optional ML Kit OCR |
| `snapy {quit/hide/emoji}` | "close yourself", "show some emojis" | In-app |

**Not allowed / not built:** autonomous multi-step browsing, reading or sending messages without being asked, call recording, bypassing lock screen or permission prompts.

---

## 4. Architecture

```
mobile/                                   Flutter app (Dart)
├─ lib/
│  ├─ main.dart                           app entry (onboarding, home dashboard, settings)
│  ├─ overlay_main.dart                   2nd entry point: header pill + bottom sheet (overlay engine)
│  ├─ core/        appdata.dart (bundled app.json + remote config), theme (tokens = desktop HUD), i18n
│  ├─ brain/       router (rules → LLM → tool), local_llm.dart, cloud_llm.dart, prompts, memory.dart
│  ├─ voice/       stt.dart, tts.dart, wakeword.dart, turn_taking.dart (pause-merge, barge-in)
│  ├─ actions/     catalog.dart (schema), executors/* (one file per action), confirm.dart
│  ├─ realcount/   usage_repo.dart, reels_repo.dart, limits.dart, insights.dart
│  ├─ life/        tasks, notes, reminders, briefing, meetings (mic)
│  └─ data/        drift database + DAOs
└─ android/app/src/main/kotlin/live/snapy/
   ├─ SnapyAccessibilityService.kt        reels counting + scripted actions (allow-listed packages)
   ├─ OverlayService.kt                   pill/sheet windows hosting the overlay FlutterEngine
   ├─ ListenService.kt                    foreground service (microphone) for wake word
   ├─ SnapyVoiceInteractionService.kt     default-assistant entry + AssistStructure
   ├─ UsageTracker.kt                     UsageStatsManager aggregation
   └─ Bridge.kt                           Pigeon-generated typed channels Dart ⇄ Kotlin
```

- **Dart ⇄ Kotlin:** **Pigeon** (typed, generated) — no stringly-typed method channels.
- **State:** Riverpod. **Navigation:** go_router. **DB:** drift (SQLite). **Notifications:** flutter_local_notifications. **Permissions:** permission_handler plus native intents for special access (usage, overlay, accessibility, assistant role).
- **Shared with desktop:**
  - `engine/src/data/app.json` (catalogs, ordinals, emoji sets, URLs) is copied into `mobile/assets/` at build time
  - the prompts and the action schema
  - the test phrase lists, so both platforms understand the same sentences
- **On-device LLM choice:**
  - Gemma 3 1B (int4, about 0.5–0.7 GB) for phones with ≥ 6 GB RAM
  - Gemma 3n E2B for ≥ 8 GB RAM
  - otherwise cloud
  - Same compatibility rule as desktop: never install a model the phone can't run smoothly. Model downloads use the same "Setting up Snapy" progress screen.
- **Wake word:** **openWakeWord** (Apache-2.0) ONNX model for "Hey Snapy", run with ONNX Runtime Mobile at about 1–2% CPU. A custom assistant name falls back to "Hey Snapy" plus the push button (training a model per name happens later, server-side). Picovoice Porcupine is the paid alternative, with instant custom words.
- **Speech:** `SpeechRecognizer.createOnDeviceSpeechRecognizer` (Android 13+, offline packs), else the default recognizer. whisper.cpp tiny/base is an optional download for older phones.
- **Voice output:** Android `TextToSpeech` with the user's language voice. Natural Hindi comes with Google TTS, which removes the desktop's Piper/espeak licensing issue.

---

## 5. Permissions, disclosures and the Play listing

| Permission / access | Why | Play requirement |
|---|---|---|
| Accessibility service | Reel counting + scripted actions | `isAccessibilityTool=false`, **prominent disclosure screen**, **Permission Declaration Form + demo video**, explained in the listing description |
| Display over other apps | Header pill + bottom sheet | Explain in onboarding; the user grants it in Settings |
| Usage access | Screen time | Special access; explain in onboarding |
| Microphone + FGS `microphone` | Voice / wake word | Foreground service started while the app is visible; persistent notification; the user can turn wake word off |
| Contacts | "Message Rahul" | Runtime permission; requested only when first needed |
| Notifications (Android 13+) | Reminders, nudges | Runtime permission |
| Exact alarms | On-time reminders | Optional (`SCHEDULE_EXACT_ALARM` user grant); fall back to windowed |
| Default assistant role | Assist gesture + screen context | `RoleManager.ROLE_ASSISTANT` request |
| Media projection | "Record this video" | Per-use system consent dialog |

**Play Console checklist:**
- **Data safety form:** everything is on-device by default; cloud AI is optional and goes to the user's own provider.
- **Privacy policy:** update `snapy.live/privacy` for the Android permissions.
- **Accessibility declaration + video.**
- **Foreground service types declaration.**
- **Content rating:** target audience 13+.
- **Testing requirement:** a **new personal developer account must run a closed test with at least 12 opted-in testers for 14 days** before it can publish to production. Plan it into the schedule, or publish under an organisation account.

---

## 6. Hard problems and how we handle them

1. **App updates break selectors** (Instagram, WhatsApp, YouTube): remote `selectors.json` with per-app versions, a daily fetch, and a silent fallback to "app time only". Telemetry is opt-in only, counting failures, never content.
2. **Custom assistant names:** wake-word models are per-phrase. v1 always wakes on "Hey Snapy" (plus the chip and the assistant gesture); the custom name is used in replies and in follow-up turns.
3. **OEM background killing:** a foreground service, a one-time guided "Allow autostart" screen with deep links per OEM, and a self-check that warns if the counter stopped.
4. **Battery:** wake word only while the screen is on (default). Accessibility events are filtered to the allow-listed packages and event types. Usage stats are recomputed at most once a minute.
5. **Privacy perception:** a big, clear dashboard of what is counted, an on-device badge, one-tap pause, and export/delete like desktop.
6. **Android 17 Advanced Protection:** detect it, explain it, and run in "app time only" mode.

---

## 7. Phases (each ends with a working, testable build)

| Phase | Scope | Done when | Est. |
|---|---|---|---|
| **P0 Foundation** | `flutter create`, package `live.snapy.app`, theme tokens from the desktop HUD, drift DB, Pigeon bridge, CI (`flutter analyze` + tests), app.json in assets | App runs on Android 10–16 emulators; CI green | 1 wk |
| **P1 Real Count** | UsageTracker, overlay pill, accessibility service (counting only), selectors JSON, onboarding with disclosures, home dashboard | Pill shows screen time within ±2 min of Digital Wellbeing; reel count ±2% on Instagram / YouTube / Facebook across 3 devices | 2–3 wk |
| **P2 AI bottom sheet** | Tap pill → sheet; chat UI; cloud brain; on-device LLM with compatibility check + setup progress; memory | Same answers as desktop on the shared phrase list; model never installed on an incompatible phone | 2 wk |
| **P3 Voice** | Push-to-talk, wake word service, on-device STT (en/hi), TTS, pause-merging and barge-in (port from desktop) | 50-phrase spoken test: ≥ 90% correct actions in a quiet room, ≥ 80% with a video playing | 2 wk |
| **P4 Phone control** | Action catalog + executors; WhatsApp / YouTube scripts; confirmations; default-assistant role | Every catalog action has an automated test on emulator + 2 real phones; nothing sends without confirmation | 3 wk |
| **P5 Life parity** | Tasks, reminders, notes, briefing, meeting notes (mic), nudges and limits, weekly summary | Desktop feature table (§1) all ✅ or explicitly ⚠️ | 2 wk |
| **P6 Play release** | Data safety, declarations + video, store listing, closed test (12 × 14 days), pre-launch report fixes | Approved for production | 2–3 wk |

---

## 8. Decisions needed before P0

1. **Developer account:** personal (needs the 12-tester / 14-day closed test) or organisation?
2. **Package name:** `live.snapy.app`?
3. **Wake word:** openWakeWord (free, "Hey Snapy" only at first) or Porcupine (paid, any name)?
4. **Pricing:** free, or a paid tier (e.g. cloud brain included)? This affects the Data safety form and the listing.
5. **Social apps to support in v1:** Instagram, YouTube, Facebook. Add Snapchat, Moj, Josh, ShareChat?

---

### Sources
- Google Play — [Use of the AccessibilityService API](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en)
- [Policy announcement, 29 Oct 2026](https://support.google.com/googleplay/android-developer/answer/18100766?hl=en)
- [Permissions and APIs that access sensitive information](https://support.google.com/googleplay/android-developer/answer/16558241?hl=en)
- [Android 17 blocks non-accessibility apps from the Accessibility API (Advanced Protection)](https://thehackernews.com/2026/03/android-17-blocks-non-accessibility.html)
- Precedent apps that count reels with Accessibility: [ScrollTracker](https://appgoblin.info/apps/com.novabloom.scrolltracker), [ScrollMeter privacy policy](https://sites.google.com/view/scrollmeter-privacy-policy), [ScrollTrace privacy policy](https://badallalwani7.github.io/ScrollTracePrivacy/)
- [Developer experience with the accessibility review](https://dev.to/lui61140/why-i-removed-accessibilityservice-from-my-android-app-and-finally-got-into-play-store-4i52)
- [Call-recording ban (2022)](https://9to5google.com/2022/04/21/google-will-block-all-third-party-call-recording-apps-on-play-store-from-may-11/amp/)

---

## Progress log

### Phase 0: done (15 Nov 2026)
- `mobile/` Flutter app (`live.snapy.app`) with HUD design tokens, orb and assistant chat.
- **One brain:** `engine/src` runs inside the app via Chaquopy 17 / Python 3.13 (64-bit ABIs only: arm64-v8a, x86_64). It's copied into the build from the engine, never edited separately.
- `src/platform/android.py`: brain → ops, then `OpExecutor.kt` carries them out (apps open in their own app, media keys, volume).
- `engine/tests/test_android.py` covers the shared brain in Android mode.

### Phase 1 (Real Count): built, not yet verified on a device
- `SnapyAccessibilityService.kt`:
  - the pill in the status-bar row beside the camera cut-out (accessibility overlay)
  - reel/short counting: full-screen vertical page change + 700 ms dwell
  - the nudge card on opening a social app
  - Back / Home / Recents / Notifications / Lock / Screenshot for voice commands
- `UsageTracker.kt`: screen time from usage events, matching Digital Wellbeing's method (home screen excluded).
- `RealCountStore.kt`: daily JSON in the app's `snapy/realcount/`, readable by the Python brain.
- `SheetActivity.kt` + `lib/ui/sheet_page.dart`: tap the pill → bottom sheet over the current app.
- Onboarding with the Play-required prominent disclosure (`lib/ui/realcount.dart`).
- **Verified:** `flutter analyze` clean, widget tests pass, the debug APK builds (173 MB), and it installs on an Android 14 emulator with the activity and service registered.
- **Not verified yet:**
  - The app hasn't been seen running: the emulator's system restarted under host memory pressure and then exited.
  - Reel-count accuracy needs real devices with Instagram/YouTube installed (target ±2%).
  - The pill position beside the camera needs checking on real punch-hole and notch phones.

### Phase 2 (AI brain on the phone): built, not yet run on a device
- **The full Windows Assistant runs on Android** (`src/platform/android.py → SnapyCore`):
  - memory (remember, recall, forget, background learning)
  - tasks and reminders, notes
  - Hinglish, the AI router (on this phone / auto / cloud)
  - agent commands, emojis, quit
- **Events, not callbacks:** the brain emits events that `CoreBridge.kt` pumps and routes:
  - `op` → `OpExecutor` (phone actions)
  - `speak` → Android TextToSpeech (native Hindi and other Indian voices)
  - `reminders` → `Reminders.kt` (AlarmManager + notification; exact only if the user allows it)
  - everything → the Flutter UI over the `snapy/events` stream
- **API keys:** encrypted with an Android Keystore AES-256-GCM key (`KeyCipher.kt`), plugged into the shared `secrets_store` in place of Windows DPAPI.
- **Flutter:**
  - streaming chat (`assistant_panel.dart`) with a Stop button
  - Settings with the three AI-brain modes, provider + key and permissions (`settings_page.dart`)
  - tasks and memory lists (`life_section.dart`)
  - emoji burst
- **Honest limits in code:**
  - "take meeting notes" replies that it isn't available on this device yet
  - on-screen clicking is off on Android until the Phase 4 scripts
- **Shared fix for Windows too:** "play X, the 4th video" now always searches YouTube instead of trying to click a video on the current screen.
- **Verified:**
  - `engine/tests/test_android.py` (6): apps, Hinglish, media, back, nth video, reminder → alarm event, memory recall, the honest meeting reply, Keystore-style key encryption round-trip
  - all 146 Windows tests
  - `flutter analyze` clean, 3 widget tests, and the debug APK builds
- **Not verified yet:** the app on a device or emulator (host memory), and an on-device LLM. "On this phone" currently falls back to the cloud key. Next step: LiteRT-LM (Gemma) or llama.cpp behind the same `LLM` interface.

### Phase 3 (voice): built, not yet run on a device
- **Push-to-talk** (`VoiceController.kt`): mic button in the chat and sheet.
  - Android `SpeechRecognizer`, on-device/offline when the phone supports it (Android 13+).
  - Live words while you speak.
  - Locale from Settings (English/Hinglish → en-IN, Hindi → hi-IN, Marathi, Bengali, Telugu, Tamil; table in `app.json → android.speech_locales`).
- **Pauses:** after a final result, the shared brain's `sounds_unfinished` (the same rule as Windows) decides whether to keep listening with a longer silence window and join the phrases into one command.
- **Barge-in:** starting to talk stops Snapy's voice (Android TTS) and interrupts its current answer.
- **Spoken replies:** voice turns are sent with `source="voice"`, so the brain answers out loud through Android TextToSpeech.
- **"Hey Snapy"** (`WakeWordService.kt`, opt-in in Settings → Voice):
  - Runs in a foreground microphone service with **Vosk 0.3.75 (Apache-2.0)** in grammar mode, so only the wake phrases can match.
  - Phrases follow `agent_name` (rename → new wake word, no training).
  - The 36 MB model downloads once, with progress shown in Settings.
  - Wake → the pill shows "Listening…" and live words over any app, then Snapy answers by voice.
  - Restarted when Snapy is opened, so the foreground service always starts from the foreground.
- **Verified:**
  - shared voice logic tests: 7 Android-mode tests in total
  - all 146 Windows tests
  - `flutter analyze` clean, 3 widget tests
  - the debug APK builds (198 MB debug)
  - **all 12 native libraries (Vosk, JNA, Python, Flutter) use 16 KB ELF LOAD alignment**, as Google Play requires
- **Not verified yet:**
  - speech on a real device
  - wake-word accuracy and false wakes (a custom name only works if it's in the Vosk model's vocabulary; otherwise "Hey Snapy" stays the wake word)
  - whether Android lets the speech recognizer use the mic after a background wake on every OEM
  - Play declaration for the microphone foreground service

### Phase 4 (phone control): built, not yet run on a device
- **Understanding (shared, `engine/src/brain/phone_intents.py`):** English and Hinglish phrases → one action from a fixed catalog:
  - `whatsapp` "WhatsApp Rahul I'm late" / "Rahul ko whatsapp karo ki…"
  - `sms` "text Priya I'm home"
  - `call` "call mom" / "Rahul ko call karo" / "video call Anjali"
  - `alarm` "wake me up at 6 am" / "7 baje ka alarm laga do"
  - `timer` "10 minute ka timer laga do"
  - `navigate` "take me to the airport" / "airport ka rasta batao"
  - `torch`, `panel` (Wi-Fi, internet, Bluetooth, NFC, volume), `type` "type I'll be there soon"
  - `tap` "tap the second video" / "click subscribe"
  - "go to settings", "open WhatsApp", "play…", "volume up", "go back" and reminders are explicitly **not** phone intents (tested).
- **Confirmation:** WhatsApp, SMS and calls always ask first ("Send to Rahul Sharma: '…'? Say yes to send."). Yes/no works in English and Hindi ("haan bhej do", "nahi").
- **Contacts** (`Contacts.kt`, read-only, on device): exact > starts-with > word > close spelling. Family words from `app.json → android.contact_aliases` ("mom" also finds "Mummy", "Maa"…).
- **Scripts** (`OpExecutor.kt`):
  - WhatsApp: `wa.me` deep link with the text filled in, then one scripted tap on Send. The selector list lives in `app.json → android.selectors`, so it can be updated without code changes.
  - SMS: opens Messages with the text ready. The user taps Send, because Play restricts `SEND_SMS` to default SMS apps.
  - Calls: direct if the user allowed calls, otherwise the dialler.
  - Clock: alarm and timer intents. Maps: navigation intent. Torch: CameraManager.
  - Wi-Fi/Bluetooth: opens the settings panel, because Android doesn't let apps switch them.
- **Screen taps:** the accessibility node tree is converted to the same element model as Windows UI Automation (class map in `app.json → android.view_types`; unlabelled cards are named from their children, e.g. video titles). The shared `screen.find()` picks the target, then one click. These are user-invoked, single-step actions, and they never act on Snapy's own window.
- **Verified:** 9 Android-mode tests, all 146 Windows tests, `flutter analyze` clean, 3 widget tests, and the debug APK builds.
- **Not verified yet:** everything on a real phone, including the WhatsApp Send selector on the current WhatsApp version, screen-tap accuracy on YouTube/Instagram layouts, and the OEM dialler/clock apps that handle the intents.

### Phase 5 – nudges & chip: built, not yet run on a device
- **Logic in Dart first and tested; Kotlin mirrors it.** No Gradle could run on the build machine, so every decision is pure Dart under `mobile/lib/realcount/` with `flutter test` coverage. The phone runs line-by-line Kotlin ports that use the same keys and order:
  - `nudges.dart` → `NudgeEngine.kt`
  - `chip_logic.dart` + `rules.dart` → `CounterLogic.kt`
- **Rules:** every threshold sits under the config key `android.realcount`. Values are merged in this order, each overriding the one before:
  1. safety-net defaults
  2. `mobile/assets/rules/realcount.json`
  3. shared config
  4. the weekly signed rules file, verified with Ed25519 (`signed_rules.dart`, RFC 8032 vectors in the tests) and cached at `snapy/rules/realcount.json`
- **Chip:** shows `[orb] 5h 16m · ▶ 42`.
  - It turns amber with a ring at the soft limit and is never red.
  - It is centred on the camera cut-out, with a gap for the lens. With no cut-out it sits top-centre.
  - Drag, size and hide choices are remembered.
  - Tap opens the sheet, long-press opens quick actions, and swiping down shows today's apps.
  - It hides over full-screen video, games, the lock screen and calls.
  - `RealCountController.kt` hosts it either way: in the accessibility service, or in `ChipService.kt` (Display over other apps, a specialUse foreground service).
  - The repo owner's orb pill (commits 7f3d83c..873c532) stays the default (`chip_style = "orb"`). The camera-centred chip is the `chip_style = "island"` option.
- **Nudges:**
  - 30 reels in a session
  - the same app opened 10× in an hour
  - soft limit reached, with an opt-in 10-second pause
  - bedtime
  - focus guard
  - intention reminder
- **Global nudge rules:** at most 1 nudge every 20 min, never during calls or navigation, and softer wording after 2 dismissals.
- **Other screens:**
  - intention prompt and 2-minute Reset
  - creator mode
  - weekly report, daily three and streaks with forgiveness
  - privacy receipts
  - big-text mode
  - per-OEM battery guide
  - boot restore
  - "counter paused" health check
  - opt-in anonymous counter report: prepared locally only, no endpoint yet
  - permission flow in the plan's order
  - i18n from `assets/i18n` (`tool/sync_core.dart` copies `core/i18n` and `core/rules`)
- **Not verified yet:** everything on a device. In particular:
  - chip placement on punch-hole and notch phones
  - status-bar inset events reaching an overlay window (full-screen auto-hide)
  - the creator-mode view IDs
  - the OEM deep links
  - the specialUse foreground-service declaration in Play review
