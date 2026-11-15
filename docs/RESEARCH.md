# Snap Air — Product & Technical Research

_Date: 2026-11-15 · Scope: turning Snap Air from a gesture/voice utility into a sellable, private, personal desktop assistant._

Measured numbers in this document come from the target dev laptop:
**AMD Ryzen 7 7730U (8C/16T, Zen 3), 15.3 GB RAM, integrated Radeon (512 MB), no NVIDIA GPU, Windows 11.**
That machine is representative of the mid-range laptops our customers own, so every design decision below is made for **CPU-only** inference.

---

## 1. Customer research (multi-persona panel)

Four perspectives were simulated independently: a senior product engineer, a developer customer ("Rahul", Bengaluru, 9:00–18:30 office, Antigravity/VS Code, 3–4 Meet calls/day, speaks Hinglish), an operations manager with 6 h of calls/day ("Priya"), an accountant with severe RSI ("Daniel"), and a bilingual college student on a budget laptop ("Ananya").

### What people would pay for (ranked across personas)
| # | Capability | Who | Exact phrasing they used |
|---|---|---|---|
| 1 | **Meeting notes with action items → reminders** | Rahul, Priya | "Snap, start meeting notes", "what did we agree on in that call?" |
| 2 | **Morning briefing + "start my day"** (open IDE, run project) | Rahul, Priya | "Snap, start my day" |
| 3 | **Tasks & reminders by voice** | everyone | "remind me to push the PR at 5", "10 minute baad padhai ka reminder lagao" |
| 4 | **Conversational AI in their language (Hinglish)** | Rahul, Ananya | "ye error samjhao", "explain this in simple Hindi" |
| 5 | **Personal memory** | Rahul, Priya | "yaad rakhna, staging password rotation is on Friday", "what did I promise Arun?" |
| 6 | Reliable app/tab/volume control | everyone | "switch to Slack", "volume kam karo" |
| 7 | Hands-free mouse + dictation (accessibility) | Daniel | "click", "type invoice two four seven", "undo that" |
| 8 | Usage insight / focus nudges (non-judgmental) | Ananya, Rahul | "kitna time YouTube pe gaya?" |

### Deal-breakers (would uninstall within a week)
- Any cloud upload of audio, code or screen content; telemetry.
- Heavy RAM/CPU: "16 GB with an IDE, Chrome and Docker is already tight. If the LLM eats 6 GB constantly, I'm gone."
- Wake word misfiring in meetings or conversations; mic/camera on with no visible indicator.
- Auto-launching things without asking; a chatty, motivational, or repeated greeting; greeting during a meeting.
- Tracking without showing exactly what is stored and an easy delete.
- Wrong destructive actions (closing an unsaved window).

### Product-lead guidance adopted
- Value prop: **"Your private desktop assistant: it controls your PC by voice and gesture, remembers how you work, and nothing leaves your laptop."**
- Route to deterministic commands first; the LLM handles what the grammar can't. LLM proposes only whitelisted actions.
- Trust affordances are product features, not settings: always-visible listening/recording/camera state, global kill switch, "What Snap knows" memory viewer with per-item delete, activity tracking that stores **app names and durations, not keystrokes or screen content**, retention limits, confirmations for risky actions, action log.
- Greeting rules: **once per day, ≤ 2 sentences, text card first (voice optional), one tap "Start my day", never during a call.**
- Pricing: one-time licence (₹2,000–3,000 / ~$29) with a free tier of basic voice commands. Local inference has no per-user cost, so a monthly subscription is hard to justify.
- Quality bar: command p50 < 1 s; false wake < 1/day of normal use; idle < 5 % CPU and < 600 MB RAM; LLM < 5 GB and unloaded after idle; 8-hour soak without crash.

**Disagreement resolved:** the product lead suggested deferring meeting notes (consent + summary quality); every customer persona ranked it #1. Decision: ship it, with a persistent red "Recording" indicator, an explicit start/stop, a consent reminder on first use, and audio never written to disk (only the transcript).

---

## 2. Voice: true speech-to-speech vs. a streaming pipeline

The request was a "real-time, voice-to-voice" assistant rather than speech→text→speech.

### State of the art (Nov 2026)
| Model | Type | Size | Languages | Hardware |
|---|---|---|---|---|
| NVIDIA Nemotron VoiceChat | full-duplex S2S, tool calling, ~450 ms turn-taking | 11B | primarily English | datacenter GPU |
| NVIDIA PersonaPlex | full-duplex S2S (Moshi architecture) | 7B | not confirmed multilingual | GPU |
| MiniCPM-o 4.5 | real-time voice, experimental full duplex | 9B | English + Chinese | GPU |
| Kyutai Moshi | full-duplex S2S, ~200 ms (vendor claim) | 7B | English (+French) | GPU / Apple MLX |

**Finding:** every open full-duplex model needs a dedicated GPU and none covers Hindi/Hinglish. On a CPU laptop they cannot run in real time at all. A cloud speech-to-speech API would break the core privacy promise.

### Decision: streaming cascade engineered to *feel* real-time
```
mic → VAD endpointing → Whisper (multilingual, auto language) → LLM (streaming tokens)
    → sentence splitter → Kokoro TTS (sentence 1 plays while sentence 2 is generated) → speaker
```
Techniques that make a cascade feel conversational:
1. **Streaming overlap** — speak the first clause as soon as it is generated; never wait for the full reply.
2. **Short first chunk** — split the first sentence at a comma so audio starts sooner.
3. **Conversation (follow-up) mode** — after Snap answers, the mic stays open ~8 s for a follow-up without the wake word.
4. **Interrupt** — hotkey/click/"stop" cuts playback instantly. Voice barge-in is enabled when the user declares headphones (no echo); on laptop speakers the assistant's own voice would otherwise be transcribed, because Windows' communications echo-cancellation isn't exposed to PortAudio.
5. **Fast path** — deterministic commands ("scroll down") skip the LLM entirely (~1 s total).

**Upgrade path:** the voice engine is a pluggable backend. When a machine has a capable GPU (or an NPU runtime matures), a full-duplex S2S model can replace the cascade without touching the rest of the product.

### Latency budget (measured on target laptop)
| Stage | Measured |
|---|---|
| Endpointing (silence to end of phrase) | 0.6 s |
| Whisper tiny.en (English-only, command mode) | 0.8–1.2 s / utterance |
| Whisper base (multilingual, auto language) | 1.4–2.1 s / utterance |
| Whisper small.en | 5–9.5 s (rejected) |
| Kokoro int8 TTS, warm | real-time factor 0.83 (faster than playback) |
| Kokoro fp32 | RTF 1.39 (rejected on this CPU) |
| `cpu_threads=8` for Whisper | 2.5× slower than 2–4 threads (contention) |

### Speech recognition choice
- **Moonshine** streams natively on CPU but is English-only (plus a few non-Indic languages); **Parakeet TDT** is ~4× faster than Whisper on CPU but has no Hindi.
- **Whisper multilingual (faster-whisper, int8)** is the only CPU-viable option that covers Hindi/Hinglish and auto-detects language. Default: `base` multilingual for auto-language, `tiny.en` when the user picks "English only" for speed.

### Text-to-speech choice
| Engine | Licence | Languages | Notes |
|---|---|---|---|
| **Kokoro-82M (ONNX)** | Apache-2.0 (commercial OK) | 8: en-US/GB, es, fr, **hi**, it, ja, pt-BR, zh — 54 voices | natural; Hindi voices graded "C" (1–10 h data) |
| Piper | MIT engine, per-voice licences | 47 languages | robotic but tiny; candidate fallback |
| Indic Parler-TTS | Apache-2.0 | 21 Indic languages | 0.94B params — too slow for CPU real time |
| MMS-TTS Hindi | CC BY-NC | Hindi | non-commercial, rejected |
| Windows SAPI | built in | installed language packs | instant fallback, robotic |

Decision: **Kokoro int8 by default; SAPI fallback**; language-matched voice chosen automatically.

---

## 3. Local language model

### Candidates (CPU-only, 16 GB RAM, Ollama)
| Model | Download (Q4) | Notes |
|---|---|---|
| Qwen3.5 0.8B | ~1.0 GB | "lite" tier; weak reasoning |
| Qwen3.5 2B | ~2.7 GB | lite tier for 8 GB machines |
| **Qwen3.5 4B** | **~3.4 GB** | most-recommended CPU-only model in 2026 guides; multilingual (Hindi), tool calling, thinking/non-thinking modes |
| Qwen3.5 9B | ~6.5 GB | "quality" tier for 32 GB machines |
| Phi-4-mini 3.8B | ~2.5 GB | strong at function calling; weaker multilingual |
| Gemma 4 E2B / E4B | — | fast on CPU; E4B wants 12 GB+ free |

**Decision:** default **`qwen3.5:4b`** via **Ollama** (MIT-licensed runtime, model management, `keep_alive` unloading), with model choice exposed in Settings so users can **upgrade** (9B) or **downgrade** (2B "lite") with one click. Embeddings: **`embeddinggemma`** (308M, multilingual, 100+ languages).

### Known issues and how the design avoids them
- Ollama + Qwen3.5 has open reports of think-blocks leaking when `think=false` is combined with native `tools`, and of Hermes-format mismatches in multi-turn tool prompts.
- Native tool schemas also inflate every prompt, and on CPU **prompt evaluation dominates latency**.
- Therefore Snap Air does **not** use native tool calling. It uses **structured output** (`format` = JSON schema, `think: false`) with a compact action vocabulary: the model returns `{"tool": ..., "args": ..., "say": ...}`. That gives deterministic parsing and a small prompt. The system prompt is ordered *static-first* so Ollama's KV-cache prefix reuse makes follow-up turns cheap.
- The LLM can only call whitelisted tools; risky ones (closing windows, running shell commands) require confirmation; text from web pages is passed as quoted data, never as instructions.

---

## 4. Memory: how assistants remember people

### Literature
| System | Core idea | What we take |
|---|---|---|
| **Generative Agents** (Park et al., 2023) | A memory stream of observations; retrieval score = **recency + importance + relevance**; periodic **reflection** writes higher-level insights | weighted retrieval; nightly reflection into routine insights |
| **MemGPT / Letta** | OS-like tiers: **core memory** (always in context: persona + human), **recall** (conversation history), **archival** (searchable long-term) | always-in-prompt profile; searchable memories; conversation log |
| **Mem0** (Chhikara et al., 2025) | two phases: **extract** salient facts, then **update** against similar memories with **ADD / UPDATE / DELETE / NOOP**; reported +26 % over OpenAI memory, > 90 % token savings | fact extraction + consolidation, in one LLM call to suit CPU budgets |
| **Zep / Graphiti** | temporal knowledge graph; facts have **validity windows** | memories carry `created/updated/valid_until`; contradictions supersede rather than erase |
| Critiques (2026) | LLM rewrites silently lose information (timestamps, event collapse); memory quality depends on model judgment | never hard-delete on UPDATE — keep `history`; user-visible memory list; explicit "remember/forget" bypasses the model's judgment |

### Snap Air memory design (all local JSON under `%APPDATA%\SnapAir\memory\`)
1. **Profile (core memory)** — `profile.json`: name, role, languages, work hours, city, editors, known projects, routine facts. Always in the prompt (compact).
2. **Memories (semantic)** — `memories.json`: atomic items `{text, category, importance 1–5, created, updated, last_used, uses, source, history[]}`; categories: preference, fact, person, project, routine, goal, instruction.
3. **Episodes** — `journal/YYYY-MM-DD.json`: what happened today (conversation summaries, actions, meetings, notes, activity summary, end-of-day reflection).
4. **Conversation log (recall)** — `conversations/YYYY-MM-DD.jsonl`, 30-day retention.
5. **Vectors** — `vectors.json`: embeddings keyed by memory id (kept separate so `memories.json` stays human-readable).

**Write policy:**
- Explicit "remember …" is saved immediately at importance 5.
- Otherwise a background job extracts *durable* facts about the user (not chit-chat, not one-off commands) and decides ADD / UPDATE / NOOP against the top similar memories.
- "Forget …" deletes; the user can edit or delete anything in the Memory drawer.

**Read policy:**
- Profile + top-k memories by `0.55·relevance + 0.25·importance + 0.20·recency` (30-day half-life), plus today's tasks/notes when relevant.
- Embeddings via `embeddinggemma`; keyword-overlap fallback when unavailable.

**Reflection:** once a day the activity log is summarized into routine facts ("usually starts around 9:10", "opens Antigravity first", "main project this week: snap-air") and yesterday's journal into a one-paragraph episode used by the morning briefing.

---

## 5. Learning the user's routine (on-device activity data)

- **Signals:** foreground app + window title every 2 s (Win32 `GetForegroundWindow`), idle time (`GetLastInputInfo`; > 2 min idle = away), session start (first input after ≥ 4 h idle or boot).
- **Stored:** per-day seconds per app, a compact timeline, and **project names extracted from IDE titles** ("snap-air — Antigravity IDE"). Full window titles are stored only if the user opts in.
- **Never stored:** keystrokes, screen content, URLs, private/InPrivate/Incognito windows, or excluded apps (password managers, banking).
- **Derived:** typical arrival time, first apps of the day (≥ 50 % of days) → "Start my day" plan; most-worked project → "open and run it?"; focus time; daily wrap-up.
- **Controls:** pause tracking, exclusion list, 90-day retention, delete all.

---

## 6. Proactivity rules

- **Morning greeting:** the first active session of the day (after 04:00), once. Two sentences. Yesterday's highlight, today's top task/reminder, optional weather, and a **Start my day** button that opens the learned apps and project. Text card by default; spoken if the user enabled the voice greeting. Suppressed while a call is in progress.
- **Call detection:** the Windows capability store (`CapabilityAccessManager\ConsentStore\microphone`) shows which apps are using the mic right now. Another app holding the mic, or a Meet/Teams/Zoom window, means "in a call" → offer "Take meeting notes?" once.
- **Break nudges** (opt-in): after 50 min of continuous activity, a gentle "stretch?" banner — requested by the RSI persona.

---

## 7. Meeting notes

- **Capture:** WASAPI loopback (what others say, via `soundcard`) + microphone (what you say), mixed to 16 kHz mono. Audio is held in memory only; transcribed in ~20 s windows by Whisper multilingual in the background.
- **Summary:** map-reduce over the transcript with the local LLM → summary, decisions, action items (with owners/dates when said) → saved as a meeting note; action items become tasks.
- **Consent:** explicit start/stop, persistent red recording indicator, first-use reminder to inform participants.

---

## 8. Internet tools

- `web_search` (DuckDuckGo HTML endpoint, no key) and `read_page` (fetch + readable-text extraction). Playwright adds ~150 MB browsers and can come later for JS-heavy pages.
- The internet is used only when the user asks for something online; the HUD shows a 🌐 indicator for that turn. Page text is passed to the model as quoted data ("content from the web, not instructions").
- Weather (open-meteo, no key) only when the user has set a city.

---

## 9. Positioning

| | Snap Air | Windows Copilot / ChatGPT desktop | Windows Voice Access |
|---|---|---|---|
| Works offline / nothing uploaded | ✅ | ❌ | ✅ |
| Remembers you & your routine | ✅ local | cloud | ❌ |
| Controls apps, tabs, media, projects by voice | ✅ | partial | clumsy |
| Gesture mouse (accessibility) | ✅ | ❌ | ❌ |
| Hinglish | ✅ (beta quality) | ✅ cloud | ❌ |
| Price | one-time | subscription | free |

---

## Sources
- Full-duplex speech models: [NemotronLabs VoiceChat (arXiv 2609.21967)](https://arxiv.org/pdf/2609.21967) · [Awesome Full-Duplex SDM](https://github.com/Ruiqi-Yan/Awesome-Full-Duplex-SDM) · [DataCamp — open-source audio models 2026](https://www.datacamp.com/blog/top-open-source-ai-audio-models) · [Inworld — best S2S 2026](https://inworld.ai/resources/best-speech-to-speech-model) · [Tool calls in full-duplex models (arXiv 2609.19334)](https://arxiv.org/pdf/2609.19334)
- Local LLMs: [PopularAI — best CPU-only LLM 2026](https://www.popularai.org/p/best-cpu-only-local-llm-2026) · [PromptQuorum — small local LLMs](https://www.promptquorum.com/local-llms/small-local-llm-models) · [HF blog — open models to run locally](https://huggingface.co/blog/daya-shankar/open-source-llm-models-to-run-locally) · [Qwen3.5 small models](https://insiderllm.com/guides/qwen-3-5-small-models-9b-beats-30b/) · [Ollama tool calling docs](https://docs.ollama.com/capabilities/tool-calling) · [ollama-python #529 (think + tools)](https://github.com/ollama/ollama-python/issues/529) · [ollama #14493 (Qwen3.5 tool format)](https://github.com/ollama/ollama/issues/14493) · [EmbeddingGemma](https://ai.google.dev/gemma/docs/embeddinggemma?hl=en)
- ASR: [AssemblyAI — open-source STT 2026](https://www.assemblyai.com/blog/top-open-source-stt-options-for-voice-applications) · [Moonshine vs Whisper](https://modelslab.com/blog/audio-generation/moonshine-vs-whisper-asr-real-time-speech-2026) · [Whisper vs Parakeet on CPU](https://snailtext.app/blog/whisper-vs-parakeet-tdt/) · [Local STT models compared](https://www.infina.so/local-speech-to-text-models-compared)
- TTS: [Kokoro on CPU (ariya.io)](https://ariya.io/2026/03/local-cpu-friendly-high-quality-tts-text-to-speech-with-kokoro) · [Open-source Hindi TTS licences](https://www.sonexlabs.com/blog/best-open-source-hindi-tts) · [Best local TTS 2026](https://localaimaster.com/blog/best-local-tts-models) · [OpenVox — free local TTS](https://openvoxai.com/blog/best-free-local-tts-models-2026)
- Memory: [Mem0 paper review](https://www.themoonlight.io/review/mem0-building-production-ready-ai-agents-with-scalable-long-term-memory) · [Mem0 (emergentmind)](https://www.emergentmind.com/papers/2504.19413) · [Mem0 vs Letta](https://vectorize.io/articles/mem0-vs-letta) · [Agent memory frameworks 2026](https://atlan.com/know/best-ai-agent-memory-frameworks-2026/) · [Mi-Memory lifecycle framework (arXiv 2607.18975)](https://arxiv.org/pdf/2607.18975) · Park et al., *Generative Agents* (UIST 2023) · Packer et al., *MemGPT* (2023)

---

## 10. Measured results after implementation (2026-11-15, target laptop under real load)

The laptop was running an Android emulator, Gradle, Flutter and Antigravity during testing (0.8–1.7 GB RAM free, 15–60 % CPU busy). That is the realistic condition for our developer persona.

| Measurement | Result | Decision |
|---|---|---|
| `qwen3.5:4b`, real assistant prompt | 3 tok/s, **no prompt-cache reuse** (23 s prompt eval every turn), ~35 s/turn | not usable on CPU → "needs GPU" tier |
| `qwen3.5:2b` | also no cache reuse, 17–27 s/turn | removed |
| `qwen3:1.7b` | cache reuse works (prompt 0.6–1.9 s), 7–9 tok/s | **default model** |
| Native tool order `tool,args,say` → `say` first | first word 5–6 s → **1.5–2.4 s** | `say` first in the schema |
| 5 few-shot examples in the cached system prompt | fixed wrong tool picks (manager question, today's tasks in Hinglish) | kept (cached, free after first turn) |
| `requests` to `localhost` vs `127.0.0.1` on Windows | **2.09 s vs 0.01 s per request** (IPv6 fallback) | always use 127.0.0.1 |
| Query embedding (embeddinggemma) on a busy CPU | 3–6 s per query | live turns use keyword+importance+recency; vectors only for background consolidation |
| Background memory extraction during conversation | blocked the next answer by ~10 s | runs only after 30 s of silence |
| Whisper prompt containing "Snap, …" | **11/12 clips of room noise became fake commands** | wake word removed from the prompt → 0/12; loop-hallucination filter |
| Kokoro int8 TTS | RTF 0.83 (faster than playback) | default voice; auto-downloads |
| End-to-end typed question → first word (warm) | **1.5–2.4 s** | voice adds ~0.4–1 s of recognition |
| Personal intents (reminders, notes, tasks, remember, briefing) | **< 0.1 s** (no LLM) | deterministic layer first |
