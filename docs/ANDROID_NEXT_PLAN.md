# Snapy Android — Next Generation: Implementation Plan

Builds on `docs/ANDROID_PLAN.md` (phases 0–5) and the shared `core/` + Dart runtime architecture.
**Principle:** everything stays on the phone. Memory, notes, meeting audio and transcripts, reel statistics and API keys never leave it, except when the user's own cloud key is used for AI, which goes directly to their provider and is disclosed.

---

## 0. Decisions and limits (read first)

| Request | Decision | Why |
|---|---|---|
| Store the phone PIN/password so Snapy can unlock the phone | **Not built** | Android has no API for apps to unlock the keyguard. Typing the PIN via Accessibility is a security bypass that Google Play bans, and storing the PIN would hand the whole phone to anyone who gets into Snapy. **Instead:** lock-screen-safe actions run while locked (voice replies, torch, notes, meeting recording, timers, reminders, alarms). For actions that need the phone unlocked ("open YouTube"), Snapy calls `KeyguardManager.requestDismissKeyguard`. The user authenticates once (fingerprint/face/PIN, entered by them) and Snapy then finishes the task automatically. We also suggest Android Smart Lock (trusted places/devices) for people who want fewer unlocks. |
| API key in the APK | **Never hardcoded** | It can be extracted with jadx/apktool in minutes. **Bring your own key**, entered in **Profile → Settings** only (never in onboarding). Stored AES-256-GCM with an Android Keystore key, sent directly to the provider. Validated with clear errors and a "Get a new key" link. A later option for users without a key is a serverless proxy we control (Cloudflare Worker / Cloud Run) issuing short-lived session tokens, with no user data stored. |
| Reels lock | **Built, opt-in per app** | Per-app limit plus a mode: **Soft nudge** (default) or **Hard lock**. A hard lock bounces only the *short-video feed* (Back) and keeps DMs, profile and photo feed usable. This is deterministic, rule-based and disclosed, which the Play accessibility policy allows. |
| Works with the app closed / phone locked / offline | **Built, within Android's rules** | Android only lets a microphone foreground service start while the app is visible. So "Hey <name>" runs as one long-lived mic service started from the app/onboarding. Meeting recording happens *inside that same service*, so it works when Snapy is closed or the phone is locked. After a reboot Android 14+ requires one tap on a notification to resume listening. Offline: wake word (Vosk), on-device speech recognition where the phone has offline packs, the intent engine, TTS and device actions all work. Chat and summaries need the user's key and the internet. |
| Volume Up + Down for 3 s | **Built** | Use Android's **accessibility shortcut** (system-wide "hold both volume keys"), with our service as the shortcut target via the accessibility button callback. Also an explicit `onKeyEvent` combo detector (`flagRequestFilterKeyEvents`; only volume keys are inspected, never other keys; disclosed). Works on the lock screen while the screen is on. |
| Power-button long-press | **Built (user opt-in)** | Snapy offers to become the phone's **digital assistant** (`ROLE_ASSISTANT` via an `ACTION_ASSIST` activity). Power/home long-press then opens Snapy listening. |
| "Take a video" automatically | **Built** | Background camera use is blocked by Android, so Snapy opens its own camera screen (CameraX, `setShowWhenLocked`). It starts recording front/back automatically, saves to the gallery (MediaStore), and stops on "stop recording". |

---

## 1. Navigation: 3 tabs

`HomePage` / `ToolsPage` / `ProfilePage` in a bottom `NavigationBar`, with the chip preview at the top and the existing design tokens.

**Home:** screen time + reels today (same numbers as the chip), per-app breakdown with **real app icons** (`PackageManager.getApplicationIcon` → PNG bytes over the channel, cached), opens and minutes, daily three, upcoming reminders, latest meeting note, memory highlights, and an "Ask Snapy" entry (bottom sheet).

**Tools:**
- **Reel limits manager.**
  - Auto-detects installed short-video apps: installed packages ∩ `core/rules/social.json` short-video catalogue (≥ 17 apps).
  - Per-app limit (stepper/slider, 0 = off) and a mode switch **Soft nudge | Hard lock**.
  - Shows today's progress per app.
- **Focus mode** (25 min, optional soft app pause during focus).
- **Meeting assistant:** start/stop, timer, live transcript preview, recent notes.
- **Quick actions test panel:** torch, front/back video, screenshot, lock screen.
- **Phone-free focus / sync entry** (when paired with the laptop).

**Profile:**
- **Identity:** your name, assistant name (default "Snapy").
- **Activation modes** (checkboxes): Wake word "Hey <name>", Volume Up+Down 3 s, Power-button long-press (digital-assistant role).
- **Settings:**
  - **AI brain:** provider (Gemini default), API key paste field with **Test**, model, mode (on-device / auto / cloud), offline actions toggle.
  - Voice language, chip style/size, nudges, big-text mode, permissions dashboard, battery guide.
- **Memory vault:** facts, preferences, notes, meetings; Markdown view, export (Markdown/JSON) and clear.

### API key validation copy (exact)

| Result | Message | Action |
|---|---|---|
| 200 OK | "Connected — Snapy's AI brain is ready." | — |
| 400 `API_KEY_INVALID` / 401 / 403 | "This key isn't valid. Copy it again, or create a new one." | Get a new key → https://aistudio.google.com/apikey |
| 403 `PERMISSION_DENIED` (API not enabled / restricted) | "This key can't use the Gemini API. Enable it or create a new key." | Get a new key |
| 429 `RESOURCE_EXHAUSTED` | "This key's free quota is used up. Wait, or use another key." | Get a new key |
| 400 `FAILED_PRECONDITION` (region) | "Gemini isn't available for this key's region." | Help |
| Network error | "No internet — try again when you're online." | Retry |

---

## 2. Onboarding (cute and guided, no API key)

1. "Hey! What's your name?" (one field, friendly orb animation)
2. "Nice to meet you, {name}! What would you like to call me?" (default Snapy)
3. **Permission cards**, each with an illustration, a one-line why, a privacy badge ("Never reads your messages or passwords"), a big **Allow** button and **an animated how-to** showing exactly what to tap in Settings (per OEM where the screens differ: Xiaomi/HyperOS "restricted settings", OneUI, ColorOS, OxygenOS, Nothing OS):
   1. Reel counter (Accessibility, with the prominent disclosure)
   2. Chip by the camera (Display over other apps)
   3. Screen time (Usage access)
   4. "Hey {assistant}" and buttons (Microphone, plus the activation-mode picker: wake word / volume keys / power long-press)
   5. Notifications
   Every card can be skipped, and Snapy keeps working with less.
4. Confetti → Home. The microphone service starts here, while the app is visible, as Android requires.

---

## 3. Reel limits and hard lock

- Count source: the existing accessibility counter (full-screen vertical feed page change + minimum dwell).
- Feed detection, per-app rules in `core/rules/social.json` (`feed` block): view IDs / class names / content descriptions for the short-video container (e.g. Instagram `clips_viewer`, YouTube `reel_recycler` / shorts container), plus the generic full-screen vertical pager heuristic. These are remote-updatable through the signed rules file (Phase 5).
- At `reels(pkg) >= limit` with mode **hard**:
  1. While the feed is on screen, `performGlobalAction(GLOBAL_ACTION_BACK)` within ≤ 150 ms of a feed window/scroll event. If the feed is still visible after 2 Backs, launch the app's main activity or go Home.
  2. A capsule under the camera reads: "🔒 {App} {Kind} locked for today ({n}/{limit}). Everything else in {App} still works."
  3. A persistent bounce on re-entry to the feed (window change/click) also fires within 150 ms.
  4. The lock resets at local midnight. **Unlock options:** "5 more" once a day (configurable) after a 10-second breath, or turn off the limit in Tools.
- **80% "Dopamine deflector":** the chip turns amber, plus a 3-second breathing bubble over the next reel: "{n} {kind} so far. Take a breath."
- Logic lives in shared Dart + mirrored Kotlin (as in Phase 5), with unit tests for the limit state machine (soft / near / locked / unlocked-5-more / midnight reset).

---

## 4. Activation

- **Wake word:** existing `WakeWordService` (Vosk grammar of the assistant's name). Reply on wake: "Yes {name}, tell me!" (TTS; copy in `core/i18n`). On the lock screen: a lightweight `ListenActivity` with `setShowWhenLocked(true)` / `setTurnScreenOn(true)` shows the listening capsule and live captions.
- **Volume keys:**
  - The service config adds `flagRequestFilterKeyEvents` + `canRequestFilterKeyEvents`, and `flagRequestAccessibilityButton`.
  - `onKeyEvent`: track `KEYCODE_VOLUME_UP` and `KEYCODE_VOLUME_DOWN` both down; at 2800 ms trigger listening and consume the events. Never consume them otherwise, so volume works normally.
  - The accessibility button/shortcut callback triggers listening too.
- **Power long-press:** `AssistActivity` (intent-filter `android.intent.action.ASSIST`) plus a `RoleManager.ROLE_ASSISTANT` request button in Profile → Activation.
- All triggers go through one `Activation.trigger(source)` → `VoiceController.start()`. Each mode can be switched on or off in Profile.

---

## 5. Meeting notes with the app closed

- "Hey Snapy, I'm in a meeting, take notes" → intent `meeting.start` → `WakeWordService` switches to **recording mode** (same foreground service, notification "Recording meeting notes", red capsule under the camera).
- Audio: `AudioRecord` → AAC/M4A file in app-private storage `snapy/meetings/<id>.m4a` (never shared). Live captions use on-device `SpeechRecognizer` chunks where available (transcript lines go to the meeting recorder as text segments).
- "Meeting is over, save the notes" → stop. Summarise with the shared meeting prompt (`core/prompts/meeting_summary.md`):
  - With a key: transcript + optionally the audio to Gemini (BYOK, disclosed).
  - Without a key or offline: keep the transcript + audio and summarise later.
- Save as a note **and** Markdown in the vault: `snapy/vault/meetings/YYYY-MM-DD_<topic>.md` (title, participants, discussion, decisions, action items with owners).
- **Meeting → tasks:** action items "for me" become tasks with reminders (due parsed by the shared time parser). The others need review, as on Windows.

---

## 6. Captions under the camera

- A `CaptionCapsule` overlay (the chip window family): a 28 dp capsule directly under the cut-out, 11.5 sp text, showing the user's live words while listening and Snapy's reply while speaking. It fades out 2 s after speech ends. The same channel events (`voice`, `speak`) drive it.
- **Soundwave halo:** while recording or listening, the chip ring animates with the mic level.

---

## 7. Device automation (offline)

| Command | Behaviour |
|---|---|
| Torch on/off | existing (CameraManager) |
| "Take a video with the front/back camera" / "stop recording" | `CaptureActivity` (CameraX, auto-start, show-when-locked) |
| "Take a photo" | same, photo |
| Open app | existing (needs unlock → requestDismissKeyguard flow) |
| Lock phone / screenshot | existing global actions |
| "Emergency" | Offline SOS: strobe torch + loud alert tone + an ICE card on screen (medical notes from Profile, stored locally); "Call emergency number?" with confirmation |

---

## 8. Five strategic suggestions (adopted)

1. **Dopamine deflector** (80% breathing bubble), §3.
2. **Meeting → tasks pipeline** with reminders, §5.
3. **Ghost mode vault:** memory, notes and meeting transcripts encrypted with a Keystore key that requires biometric auth (`setUserAuthenticationRequired`). The vault opens with fingerprint/face.
4. **Soundwave halo** while recording/listening, §6.
5. **Offline SOS and life vault**, §7.

---

## 9. Dart ↔ Kotlin contract (new methods on `snapy/core`)

| Method | Args | Returns |
|---|---|---|
| `shortVideoApps` | — | `[{package,label,kind,installed:true}]` (installed ∩ catalogue) |
| `appIcon` | package, size | PNG bytes (cached) |
| `reelLimits` / `setReelLimit` | package, limit, mode(`soft`/`hard`) | `{package:{limit,mode,used,state}}` |
| `activationModes` / `setActivationMode` | mode(`wake`/`volume`/`power`), on | `{wake,volume,power,assistantRole}` |
| `requestAssistantRole` | — | bool |
| `testApiKey` | provider, key | `{ok, code, message, help_url}` |
| `meetingStart` / `meetingStop` / `meetingState` | — | `{recording, elapsed, live}` |
| `vaultList` / `vaultExport` / `vaultClear` | kind | list / path / ok |
| `captureVideo` | camera(`front`/`back`) | bool |
| `sosStart` / `sosStop` | — | bool |
| `profile` / `setProfile` | name, assistant_name, ice_notes | profile |

Events on `snapy/events`:
- `{"type":"voice", state, text}` and `{"type":"speak", text}` (captions)
- `{"type":"reel_lock", package, n, limit}`
- `{"type":"meeting", recording, elapsed, live}`
- `{"type":"activation", source}`

---

## 10. Milestones (each ends tested; device checks listed)

| # | Scope | Done when |
|---|---|---|
| M1 | 3-tab navigation; Tools reel-limit manager with auto-detected apps and icons; hard-lock state machine + Kotlin bounce | Unit tests for detection, limits and the lock state machine; widget tests for the tabs. Device check: Instagram/YouTube bounce ≤ 150 ms, DMs still usable. |
| M2 | Cute onboarding (name → assistant name → permission cards with OEM how-tos → confetti); no key in onboarding | Widget tests for every step and skip path |
| M3 | Activation: wake word with name greeting, volume combo + accessibility shortcut, assistant role, lock-screen listen activity | Unit tests for the combo detector timing. Device check on a locked phone. |
| M4 | Meeting recorder in the mic service, M4A, live captions, summary, Markdown vault, meeting → tasks; Profile vault UI; API key test with error mapping | Tests for the summary pipeline (fake LLM), vault files and key-error mapping |
| M5 | Caption capsule, soundwave halo, CaptureActivity (video/photo), SOS, Ghost-mode vault | Tests for caption timing logic and the SOS state machine. Device check: camera on the lock screen. |

## 11. Policy checklist additions
- **Accessibility declaration:** add key-event filtering (volume keys only) and the feed bounce (Back action) to the disclosure text and the declaration video.
- **Foreground services:** `microphone` (wake word + meeting recording), `camera` only while CaptureActivity is visible (no background camera).
- **Data safety:** meeting audio is stored locally and sent to the user's own AI provider only if they use summaries with their key.
- No credential collection of any kind (no device PIN).
