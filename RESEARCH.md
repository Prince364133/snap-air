# Snap Air → Personal AI Companion: Research

*Research date: 15 Nov 2026. Scope: what it takes to turn Snap Air (gesture + voice control for Windows) into a local-first desktop companion that talks back in real time, remembers the user, learns their routine and helps them run their day.*

---

## 1. Real-time voice: end-to-end speech models vs. a streaming pipeline

**What the user asked for:** voice-to-voice, no "speech → text → speech" lag, many languages, automatic language switching.

### 1.1 End-to-end ("speech-to-speech", full-duplex) models — state of play

| Model | Size | What it does well | Blocker for Snap Air |
|---|---|---|---|
| Kyutai **Moshi** | 7B | Listens and talks at the same time, sub-200 ms on an RTX 4090 | ~13 GB weights, needs a strong GPU; English-centric |
| NVIDIA **PersonaPlex-7B** (Jan 2026, built on Moshi) | 7B | ~200 ms responses, role + voice prompts | English only, **no tool calling** |
| NVIDIA **Nemotron VoiceChat** (Sep 2026) | 11–12B | Full-duplex, open weights | GPU-class hardware |
| OpenBMB **MiniCPM-o 4.5** (May 2026) | 9B | Full-duplex omni model, demoed on a MacBook with <12 GB RAM | Young tooling; tool use and memory hooks are immature |
| **Qwen3-Omni** 30B-A3B | 30B MoE | Best open audio benchmarks, ~234 ms first audio | Practitioners still report no reproducible local real-time loop |

**Conclusion.** End-to-end models are the future, and on a high-end GPU they really do feel like a phone call. But today they (a) need hardware most laptops don't have, (b) mostly can't call tools — so they can't open your IDE, add a task or read your memory — and (c) are weak outside English. A companion that *does things* needs a text "brain" in the loop.

### 1.2 The streaming cascade that actually ships

Kyutai's own product, **Unmute**, wraps a *text* LLM with streaming STT and streaming TTS rather than using Moshi directly. Two things make it feel real-time:

1. **Semantic end-of-turn detection** — predicts whether you've finished or are just pausing, so it answers fast without cutting you off.
2. **TTS that streams *text in*** — speech starts after the LLM's first few words, not after the full answer.

Pipecat (the most used open voice-agent framework) does the same locally: **Silero VAD** (<1 ms per 30 ms frame on one CPU thread) + **Smart Turn v3** (an ONNX turn-completion model with fast CPU inference) + barge-in handling that ignores backchannels like "ok", "uh-huh".

### 1.3 Latency budget

Human turn-taking gaps cluster around **200 ms** across languages; past ~800 ms a voice agent feels slow, past ~1.5 s it feels broken. The budget covers end-of-speech detection, final STT, LLM first token, tool calls and TTS first audio. The two biggest costs are **the LLM** and **end-of-turn detection**, so the design attacks those: speak sentence-by-sentence as tokens stream, keep the model warm, and answer fast commands without the LLM at all.

### 1.4 Decision

- **Default (any laptop): streaming duplex cascade.** Mic stays open while Snap speaks; user speech interrupts playback immediately (barge-in); first sentence is spoken while the rest is still being generated; follow-up turns don't need the wake word.
- **Pluggable "voice engine" interface** so a GPU user can switch to a full-duplex model server (Moshi/PersonaPlex/MiniCPM-o) for chit-chat, while actions still route through the text brain.
- **Upgrade path** for end-of-turn: energy endpointing now → Silero VAD + Smart Turn v3 (ONNX, CPU) when the package is present.

---

## 2. Speech recognition and languages

- Current app ships `tiny.en` (English only). **Whisper large-v3-turbo** prunes the decoder from 32 to 4 layers, keeps 99-language coverage and is ~8× faster than large-v3; faster-whisper supports it and has better language detection (VAD-filtered, multi-segment, threshold).
- One source notes turbo loses a little accuracy for non-English; large-v3 stays the most accurate.
- Fixing the language skips detection and is ~10–15 % faster.

**Decision.** Default to multilingual `base` (fast on CPU), offer `small` / `large-v3-turbo` in a model picker. Language setting is `auto` by default: detect per utterance, remember the user's languages in memory, reply in the language they spoke (including Hinglish). Fast command grammar stays English; any other language goes to the LLM, which maps it onto the same tools.

## 3. Text-to-speech (local, multilingual)

| Engine | Languages | CPU | Notes |
|---|---|---|---|
| **Kokoro-82M** (Apache-2.0) | EN, JA, ZH, FR, IT, PT, ES, **HI** | yes | Tiny, natural, streaming-friendly; Hindi matters for Indian users |
| **Kyutai Pocket TTS** (MIT, Jan 2026) | EN, FR, DE, ES, PT, IT | yes, 2 cores, ~6× real-time, ~200 ms first audio | Voice cloning from one sample |
| **Windows SAPI** (built in) | whatever voices are installed | yes | Zero install; robotic but always there |

**Decision.** Speaker abstraction with an automatic choice per language: Kokoro → Pocket TTS → Windows voices. Speech is queued per sentence so it can start early and be cut instantly on barge-in.

## 4. The local LLM ("brain")

- **Ollama** supports tool calling, and since v0.8 **streaming with tool calls**. A 2026 field report documents silent tool-call drops on some streaming paths and a too-small default context, so the client needs a non-streaming fallback and an explicit `num_ctx`.
- Recommended laptop models: **Qwen3 4B/8B** (Qwen3 4B trained on 119 languages; Qwen3 8B ≈ 8 GB at Q4 with native tool calling, a common "best for agents" pick), **Gemma 4 E4B** (~3 GB, laptop-class), Granite 4 / Phi-4-mini for small RAM.
- **"Make the model better later"** = a model manager: detect what's installed, recommend by RAM, one-click `ollama pull`, swap models live, and keep the persona/system prompt in our code so any model inherits it. Fine-tuning (LoRA on the user's own corrected transcripts) is a later-phase option.

## 5. Memory: how assistants remember people

Three reference designs, and what we take from each:

1. **Generative Agents (Park et al., 2023) — memory stream + scored retrieval + reflection.** Every memory has text, timestamp, last-access time and an LLM-rated importance (1–10). Retrieval ranks by `α·recency + β·importance + γ·relevance` (exponential decay, embedding similarity). When recent importance piles up, the agent **reflects** — writes higher-level insights ("seems passionate about his research") back into memory.
2. **MemGPT / Letta — tiered memory.** Small, always-in-prompt **core blocks** (`human` = facts about the user, `persona` = the agent's self) with size limits, plus **archival** storage searched on demand. The agent edits its own memory through tools.
3. **Mem0 — extract, then consolidate.** An extraction pass pulls salient facts out of the latest exchange; for each candidate, similar existing memories are fetched and an LLM routes it to **ADD / UPDATE / DELETE / NOOP**. This is what stops a memory store from filling with duplicates and stale facts ("vegetarian" → later "eats fish now"). Known weakness: multi-evidence and implicit facts get lost when extraction is too coarse; Mem0's newer design moves to ADD-only plus temporal reranking.

**Decision — Snap Air memory (all in local JSON):**

- `profile` — core blocks always in the prompt (name, how to address, languages, role, work pattern, preferences summary). Size-capped.
- `facts` — atomic memories `{text, kind, importance, created, updated, last_access, access_count, source, confidence}`. `kind` ∈ preference, personal, work, goal, relationship, routine, skill, insight.
- `episodes` — one summary per day/session ("Worked on snap-air auth bug, 2 meetings, finished 3 tasks").
- Write path: rule-based fast extraction (works without an LLM) + LLM extraction with Mem0-style ADD/UPDATE/DELETE/NOOP against the top similar memories.
- Read path: Generative-Agents scoring; relevance = cosine on Ollama embeddings (`/api/embed`, e.g. `nomic-embed-text`/`embeddinggemma`, 768-dim) when available, otherwise a keyword-overlap fallback.
- Reflection: periodic insight generation from accumulated important facts and activity.
- **Not everything is remembered.** A filter drops small talk and blocks secrets (passwords, OTPs, card numbers, keys) from ever being stored. The user can view, edit, pause, forget ("forget that I…") and export everything.

## 6. Routine learning and activity tracking

- On Windows, the foreground window + process name (already used by Snap Air) + `GetLastInputInfo` (idle time) are enough to build a timeline of which app was in focus and when — no screenshots.
- **Lesson from Microsoft Recall:** an always-recording activity feature caused a privacy backlash and was relaunched **opt-in**, gated by Windows Hello, with pause/filter/delete/retention controls; critics note "local only" still exposes data to anyone with the device. Snap Air takes that lesson: activity tracking is **opt-in during onboarding**, stores app names by default (window titles optional), has an exclude list, auto-deletes after N days, and is fully visible in an Activity drawer.
- Routine model: per weekday — typical first-activity time, apps opened in the first 30 minutes, top apps per hour, typical focus blocks. This powers "Good morning — want me to open Antigravity and run the project?"

## 7. Autostart and greeting

- Electron's `app.setLoginItemSettings({openAtLogin, args})` is the official Windows/macOS API (writes the Run registry key). Known issue: it doesn't work for APPX/MSIX packages, so ship an NSIS installer.
- The engine is told it was launched at login, greets once per day, and also greets after a long absence (lid closed > 3 h).

## 8. Meeting notes

- System audio (the other participants) can be captured via **WASAPI loopback**; `PyAudioWPatch` provides it in Python on Windows. Microphone = "you", loopback = "others".
- **Consent:** India, the UK, Germany, Canada and Australia are commonly listed as all-party-consent jurisdictions; US states differ; lawsuits against AI notetakers (e.g. *In re Otter.ai*) hinge on participants not knowing. Safest practice is disclosure plus affirmative consent. Snap Air therefore shows a consent reminder on start, shows a visible "Recording notes" state for the whole meeting, keeps everything on the device, and never joins calls as a hidden bot.

## 9. Browser helper

- Playwright `connect_over_cdp("http://127.0.0.1:9222")` attaches to an already-running Chrome with the user's cookies and sessions — the way to "read this page" or "summarise my open tab" without a new login. Chrome must be started with `--remote-debugging-port`. Fallback when Playwright isn't installed: fetch + readable-text extraction.

---

## Sources

- Speech-to-speech model review (Moshi → Qwen3-Omni): https://itzsid.github.io/speech-to-speech-review
- NVIDIA PersonaPlex-7B release: https://comfyui-wiki.com/en/news/2026-01-20-nvidia-personaplex-7b-v1-release · notes (English only, no tool calling): https://notes.nicolasdeville.com/github/personaplex/
- Full-duplex research update (Nemotron VoiceChat, Raon): https://kennethli319.github.io/audio-text-ml-course/lessons/full-duplex-speech-to-speech-research-update.html
- MiniCPM-o 4.5 coverage: https://gentic.news/lab/interaction
- Moshi hardware/latency guide: https://localaimaster.com/blog/moshi-realtime-speech-guide
- Ask HN: best local speech-to-speech setup (2026): https://hn.svelte.dev/item/46731068
- Qwen3-Omni technical report: https://arxiv.org/html/2509.17765v1
- Kyutai Unmute: https://kyutai.org/2025/05/22/unmute.html · STT: https://kyutai.org/stt · TTS: https://kyutai.org/next/tts
- Pipecat speech input / Smart Turn: https://docs.pipecat.ai/pipecat/learn/speech-input · https://docs.pipecat.ai/server/utilities/smart-turn
- Turn detection & barge-in (backchannels): https://docs.pinecall.io/concepts/turn-detection
- Latency budgets: https://www.twig.so/blog/voice-ai-agents-latency-budget-800ms · https://soniox.com/wiki/voice-agent-latency-budget · https://www.voiceaispace.com/knowledge/watch/voice-ai-latency-where-the-time-goes
- Whisper large-v3-turbo: https://www.mixpeek.com/model/openai/whisper-large-v3-turbo · faster-whisper 1.1.0 release: https://newreleases.io/project/pypi/faster-whisper/release/1.1.0 · language-detection trade-off: https://theneuralbase.com/faster-whisper/learn/intermediate/multilingual-true-option/ · CPU guide: https://cdn.localaimaster.com/blog/faster-whisper-guide
- Kokoro languages: https://tts.ai/voices/kokoro/?lang=hy · Pocket TTS: https://github.com/kyutai-labs/pocket-tts · https://dev.to/andrew-ooo/pocket-tts-review-kyutais-100m-cpu-voice-cloner-2026-40lb
- Ollama tool calling & streaming: https://docs.ollama.com/capabilities/tool-calling · https://registry.ollama.ai/blog/streaming-tool · silent tool-call failure report: https://navigator-3qw.pages.dev/findings/ollama-silent-tool-call-failures
- Ollama embeddings: https://docs.ollama.com/api/embed · https://techsy.io/en/blog/run-embedding-models-locally-ollama
- Local model picks: https://localaimaster.com/blog/best-ollama-models-for-agents · https://aiindigo.com/blog/qwen3-4b-review-the-practical-choice-for-local-ai-in-2026 · https://overchat.ai/ai-hub/best-local-llm · https://www.ertas.ai/best/best-small-llm-for-local-deployment
- Mem0 paper & pipeline: https://www.emergentmind.com/topics/mem0 · https://virtuslab.com/blog/ai/git-hub-all-stars-2/ · https://mem0.ai/research-5
- Generative Agents memory stream: https://www.alphaxiv.org/overview/2304.03442v2 · https://memx.app/glossary/generative-agents/
- Letta / MemGPT memory: https://docs.letta.com/guides/agents/architectures/memgpt · https://zby.github.io/commonplace/sources/letta-memgpt-stateful-agents
- Microsoft Recall privacy lessons: https://macmyths.com/in-depth-with-windows-11-recall-what-microsoft-has-and-hasnt-fixed/ · https://www.windows7forums.com/threads/microsoft-recall-the-future-of-ai-powered-desktop-memory-and-privacy-concerns.362830
- Electron login items: https://ayakael.net/mirrors/electron/commit/45e2f35effb1eb661cf1c1328fdfb818f980a1df · APPX limitation: https://www.github.com/electron/electron/issues/42016
- WASAPI loopback (PyAudioWPatch): https://pypi.org/project/PyAudioWPatch
- Recording consent: https://fellow.ai/blog/meetings/can-you-record-a-meeting-without-consent/ · https://news.bloomberglaw.com/financial-accounting/ai-notetaking-poses-wiretapping-discovery-and-ethical-pitfalls · https://reedsmith.com/our-insights/blogs/employment-law-watch/102ls2n/the-legality-of-ai-powered-recording-and-transcription/
- Playwright attach to existing Chrome: https://dev.to/rcsxplatform/how-ai-agents-can-intercept-chrome-downloads-using-playwright-cdp-1bii
