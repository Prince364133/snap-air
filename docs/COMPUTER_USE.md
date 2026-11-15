# Snapy computer use: how the assistant sees and operates the screen

*Architecture proposal. Phase 1 is implemented in `engine/src/os_control/screen.py`.*

## Goal

Snapy should use the laptop the way a person does:

- "type hello in the search box"
- "go to Chrome, open YouTube, find the best video on X and play it"
- "click the video on the top left"
- "what's on my screen?"

It should work across every app and window and keep learning from the user. It must also be **cheap and mostly local**.

## The key insight: don't start with pixels

Most "AI computer use" demos screenshot the screen and send every step to a large vision model. That is slow (2–10 s per step), expensive, and sends your screen to the cloud.

Windows already exposes a structured, exact description of almost everything on screen: the **UI Automation (UIA) accessibility tree**. Screen readers use the same data. Chrome, Edge, Electron, Office, File Explorer, Settings and most native apps all publish it. Each element comes with:

- its name ("Subscribe", the video title)
- its type (button, link, text field, tab)
- its exact on-screen rectangle
- actions such as Invoke, SetValue and Select

That covers 80–90% of everyday commands with **no model, no screenshot, about 0.1–2 s, and zero cost**. Microsoft's own agent, UFO2, and most of the strong open-source desktop agents use this as their primary perception layer. Vision is the fallback, not the foundation.

## Tiered perception (cheapest first)

| Tier | What | When it's used | Cost / latency | Status |
|---|---|---|---|---|
| 1 | **UIA tree.** Names, types and rectangles of controls in the foreground window, including web pages in Chrome/Edge. | Every command | Free, about 0.05–2.5 s | ✅ implemented |
| 2 | **Windows OCR** (`Windows.Media.Ocr`, built into Windows 10/11). Text plus boxes from a screenshot. | Canvas apps, games, remote desktop, images of text, apps with no accessibility | Free, local, about 0.2–0.5 s | next |
| 3 | **Small local vision model for grounding.** It answers "point at the play button" with x,y coordinates. Candidates: **Moondream 2B / 0.5B** (`point` skill, CPU-friendly), **OmniParser v2** (detects icons and labels in screenshots), **UI-TARS-1.5-7B** / **AgentCPM-GUI** / **ShowUI-2B** (GUI-specialist models), **Qwen2.5-VL 3B/7B** via Ollama. | Icon-only buttons, thumbnails with no title, visual layout questions | Local, about 1–5 s on CPU, under 1 s on GPU | planned, gated by the device-compatibility check |
| 4 | **Cloud vision fallback.** Gemini / GPT / Claude with a screenshot, using the user's API key. | The device can't run tier 3, or tiers 1–3 failed | Paid, about 2–6 s; opt-in only | planned; reuses the existing cloud brain |

The router always tries the cheapest tier first and only escalates when it can't find a confident match. The screenshot never leaves the PC unless the user has chosen cloud mode.

## Action layer

| Action | Preferred method | Fallback |
|---|---|---|
| Click | UIA **Invoke** / LegacyIAccessible **DoDefaultAction**. This works even if another window covers the element and doesn't move the mouse. | Real mouse click on a point of the element that isn't covered (checked with `WindowFromPoint`) |
| Type in a field | Focus the element, select all, type. Non-ASCII text such as Hindi is pasted through the clipboard, which is then restored. | Click the field's centre, then type |
| Keys / shortcuts | `keys.py`: any combo (Win+H, Ctrl+Shift+Esc, F-keys…) | — |
| Windows | `windows.py`: focus, snap, minimise, and move to monitor N | — |
| Browser | UIA covers the page. For deep tasks (forms, reading pages) use the Chrome DevTools Protocol, which the "summarise this page" feature already uses. | Tier 2/3 vision |

## Planning loop for multi-step goals

For a goal like "find the best video on React hooks and play it", the loop is:

1. **Plan.** The local LLM breaks the goal into steps: open YouTube search for the topic → read the results → pick one → click it.
2. **Observe.** Take a compact text snapshot of the screen: about 25 elements as `{id, type, name, rect}`. Text costs about 20× fewer tokens than an image, so even a 1.7B model can choose from it.
3. **Act.** The LLM returns `{"action":"click","id":7}` via the `screen` tool.
4. **Verify.** Take a new snapshot. Did the title change or the expected element appear? If not, retry once, then escalate one perception tier.
5. **Safety.** Stop at a step budget of 8. Ask for confirmation before sending messages, deleting, buying or submitting forms. Never type into password fields. Never act while the screen is locked.

Phase 1 already does a single-shot version of this for "play the best video on X". It searches YouTube and reads the real titles from UIA, then the local LLM picks the most relevant non-clickbait title and Snapy clicks it.

## Spatial language

"Top left", "second", "last", "bottom right" and the Hinglish forms ("doosra video", "upar wala") are resolved geometrically. Elements are sorted in reading order (rows bucketed by y, then left to right), filtered by type ("video" means large content links), then the ordinal or corner is applied. Window caption buttons such as Minimize and Close are excluded unless the user names them, so a vague "click the first one" can never close the window.

## Multiple windows and monitors

- Every top-level window is enumerated with its title, process and monitor. Commands can name a window ("in Chrome, click…"); otherwise the foreground window is used. Snapy's own HUD is excluded.
- Multiple monitors: UIA rectangles are in virtual-desktop coordinates, so "the left screen" and "the right screen" simply filter by monitor bounds.

## Learning from the user (user context)

Everything stays on-device, in the same memory store as the rest of Snapy:

- **Macros from repetition.** Record each successful command → step sequence (app, element names, not pixels). After the same sequence happens about 3 times, offer it as a named routine ("Want me to do this when you say 'start standup'?").
- **Element aliases.** If the user says "click the bell" and then corrects to "Notifications", store `bell → Notifications` for that app.
- **App habits.** The existing activity tracker already knows which apps and sites are used when. That becomes a prior for ambiguous commands ("open my project" means the repo opened most mornings).
- **Corrections become memory.** "No, the other one" or an undo within 5 s counts as negative feedback for that choice.
- The secret filter applies. Contents of password fields and banking windows are never stored, and the user can see and delete everything in the Memory panel.

## Other operating systems

The same design maps 1:1:

| OS | Accessibility tree | OCR | Input |
|---|---|---|---|
| Windows | UI Automation | Windows.Media.Ocr | SendInput |
| macOS | AXUIElement (Accessibility API, needs permission) | Vision framework `VNRecognizeTextRequest` | CGEvent |
| Linux | AT-SPI2 (GNOME/KDE) | Tesseract / PaddleOCR | xdotool / ydotool (Wayland) |

Only `screen.py` and `keys.py` need platform back-ends. The planner, memory and vision tiers are shared.

## Open-source projects worth borrowing from

- **Windows-Use** (MIT): Python, UIA-first Windows agent. Closest to our stack.
- **Microsoft UFO / UFO2** (MIT): UIA plus vision hybrid "Desktop AgentOS". Good reference for the planner/verify loop.
- **UI-TARS-desktop** (Apache-2.0) with the **UI-TARS-1.5-7B** model: strongest open GUI-grounding model; GPU-class.
- **Agent S / S2** (Simular): research agent with experience memory, a good model for the learning layer.
- **OmniParser v2** (Microsoft): screenshot → labelled interactive elements, the vision equivalent of the UIA tree.
- **Moondream** (2B / 0.5B): tiny VLM with a `point` skill, the best fit for tier 3 on CPU laptops.
- **ShowUI-2B**, **AgentCPM-GUI**: small GUI-specialist models to benchmark against Moondream.

Check each license before shipping. Moondream's newest weights and some GUI models have custom licenses.

## Measured results (this PC, Phase 1)

- Real YouTube tab in Chrome: 94 actionable elements read in **2.2 s**. Correct results for "the second video", "video on the top left" and "search box". All read-only.
- Controlled test window (an Electron page with a 3×2 video grid, a search box and a button), driven for real:
  - 5 commands, 5 correct elements.
  - Clicks registered: second video, bottom-right video, transformers video, Subscribe. The search box received "lofi beats".
  - The bottom-right video sat under the On-Screen Keyboard. The first version's mouse click hit the keyboard instead, so clicks now use UIA Invoke first and a visibility-checked point second.
- 132 unit tests pass, including the spatial, naming, safety and Hinglish-ordinal cases in `tests/test_v4.py`.

## Phase 2 results (tiers 2–4 + the task loop, implemented)

`src/os_control/vision.py`, `Assistant._locate()` and `Assistant.screen_task()`. All measured on this PC: CPU only, 16 GB RAM.

| Tier | Result |
|---|---|
| 2 · Windows OCR | 77 text items in the test window. First call is 8.7 s while WinRT loads, so it is warmed at startup; after that **0.5 s**. "Cooking the perfect biryani" was found and clicked. |
| 3 · Local VLM (Qwen3.5 4B via Ollama) | Pointed at "Subscribe" within **6 px** of its true centre, but took **94 s** on CPU. At 512/384 px it took 24/19 s and **missed**. The local vision model therefore runs automatically **only with a GPU** (≥4 GB VRAM); on CPU it's an opt-in "private but slow" setting. |
| 4 · Cloud vision | Gemini / OpenAI request builders are implemented and use the user's key, only in Auto/Cloud mode. **Not tested live: no key on this PC.** |
| Task loop | Chains such as "type lofi beats in the search box and then click the second video" run deterministically, with no AI: **3.6 s, correct**. Open-ended goals use the local 1.7B model with a text element list, relevance-ranked. It reaches the goal but can take a wrong step first, so a bigger or cloud model is recommended for long goals. |
| Safety | Snapy stops and asks before clicking anything named send / delete / buy / pay / submit / post… unless the user said it. Window caption buttons are never chosen implicitly. 8-step budget; it stops when the screen stops changing. |

## Roadmap

1. ✅ UIA snapshot, find (name, type, ordinal, corner), click / type / read, "play the best video on X".
2. ✅ Windows OCR tier (text with no accessibility info).
3. ✅ Local vision model tier (GPU-gated), ✅ cloud vision tier (untested without a key).
4. ✅ Multi-step plan/act/verify loop with a step budget and confirmations ("on screen, …").
5. Smaller, faster local grounding on CPU: crop around the likely region before asking the VLM, or use a dedicated small grounding model (Moondream 0.5B / ShowUI-2B via ONNX).
6. Macro learning and element aliases.
7. macOS (AX) back-end.
