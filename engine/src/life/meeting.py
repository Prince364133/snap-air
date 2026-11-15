"""Meeting notes: capture system audio (what others say, via WASAPI loopback)
+ microphone (what you say), transcribe in ~20 s windows in the background,
then summarize into a meeting note with decisions and action items.
Audio is never written to disk — only the transcript and the notes."""
import datetime as dt
import queue
import re
import threading
import time

import numpy as np

SR = 16000
WINDOW_S = 20

SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        "summary": {"type": "array", "items": {"type": "string"}},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "action_items": {"type": "array", "items": {"type": "object", "properties": {
            "task": {"type": "string"}, "owner": {"type": "string"}, "due": {"type": "string"}},
            "required": ["task", "owner", "due"]}},
    },
    "required": ["title", "summary", "decisions", "action_items"],
}

SUMMARY_SYSTEM = """You write meeting notes from a raw, imperfect speech transcript.
Return: a short title (max 6 words); 3-6 summary bullets of what was discussed; decisions that were made;
action items with owner (a person's name, "me" if the speaker committed to it, or "unassigned") and due
(as said, e.g. "Friday", "tomorrow 5pm", or ""). Only include things actually in the transcript.
Write in the language the meeting was held in."""


class MeetingRecorder:
    def __init__(self, transcribe_fn=None, llm=None, notes=None, tasks=None, memory=None, on_update=None):
        self.transcribe_fn = transcribe_fn      # fn(np.float32 audio) -> text
        self.llm = llm
        self.notes = notes
        self.tasks = tasks
        self.memory = memory
        self.on_update = on_update or (lambda state: None)
        self.recording = False
        self.started = None
        self.title = None
        self.segments = []
        self._bufs = {}
        self._buf_lock = threading.Lock()
        self._jobs = queue.Queue()
        self._threads = []
        self._windower_thread = None
        self._pending = 0
        self.capture_devices = True    # False in tests: audio arrives via feed()
        self.error = None
        threading.Thread(target=self._worker, daemon=True).start()

    # ------------------------------------------------------------ state
    def state(self):
        return {"recording": self.recording, "title": self.title,
                "elapsed": int(time.time() - self.started) if self.started and self.recording else 0,
                "live": self.segments[-1]["text"] if self.segments else "",
                "words": sum(len(s["text"].split()) for s in self.segments), "error": self.error}

    # ---------------------------------------------------------- capture
    def start(self, title=None, sources=("system", "mic")):
        if self.recording:
            return False
        self.recording, self.started, self.title = True, time.time(), title
        self.segments, self._bufs, self.error = [], {s: [] for s in sources}, None
        self._threads = []
        for s in (sources if self.capture_devices else ()):
            t = threading.Thread(target=self._capture, args=(s,), daemon=True)
            t.start()
            self._threads.append(t)
        self._windower_thread = threading.Thread(target=self._windower, daemon=True)
        self._windower_thread.start()
        self.on_update(self.state())
        return True

    def feed(self, source, audio):
        """Push 16 kHz mono float32 audio (used by capture threads and tests)."""
        with self._buf_lock:
            if source in self._bufs:
                self._bufs[source].append(np.asarray(audio, dtype=np.float32).reshape(-1))

    def _capture(self, source):
        try:
            import soundcard as sc
            if source == "system":
                dev = sc.get_microphone(id=str(sc.default_speaker().name), include_loopback=True)
            else:
                dev = sc.default_microphone()
            with dev.recorder(samplerate=SR, channels=1, blocksize=SR // 10) as rec:
                while self.recording:
                    data = rec.record(numframes=SR // 2)
                    self.feed(source, data[:, 0] if data.ndim > 1 else data)
        except Exception as e:
            self.error = f"{source} audio unavailable: {e}"
            print("[Meeting]", self.error)

    def _take_window(self, final=False):
        with self._buf_lock:
            parts = {s: (np.concatenate(b) if b else np.zeros(0, np.float32)) for s, b in self._bufs.items()}
            for s in self._bufs:
                self._bufs[s] = []
        if not parts:
            return None
        n = max(len(a) for a in parts.values())
        if n == 0:
            return None
        mix = np.zeros(n, np.float32)
        for a in parts.values():
            if len(a):
                # normalise each source so a quiet mic isn't drowned by loud speakers
                peak = float(np.max(np.abs(a))) or 1.0
                mix[:len(a)] += a * min(4.0, 0.6 / peak)
        return np.clip(mix, -1, 1)

    def _windower(self):
        offset = 0.0
        while self.recording:
            time.sleep(0.5)
            with self._buf_lock:
                n = max((sum(len(c) for c in b) for b in self._bufs.values()), default=0)
            if n >= SR * WINDOW_S:
                audio = self._take_window()
                if audio is not None:
                    self._pending += 1
                    self._jobs.put((offset, audio))
                    offset += len(audio) / SR
        audio = self._take_window(final=True)
        if audio is not None and len(audio) > SR:
            self._pending += 1
            self._jobs.put((offset, audio))

    def _worker(self):
        while True:
            offset, audio = self._jobs.get()
            try:
                if float(np.sqrt(np.mean(audio ** 2))) < 0.004:
                    continue   # silence: skip transcription
                try:
                    text = self.transcribe_fn(audio) if self.transcribe_fn else ""
                except Exception as e:
                    print("[Meeting] transcription error:", e)
                    text = ""
                if re.search(r"[^\W_]{2,}", text or ""):     # ignore "..." / noise-only output
                    self.segments.append({"t": round(offset), "text": text.strip()})
                    self.on_update(self.state())
            finally:
                self._pending -= 1

    # ------------------------------------------------------------- stop
    def stop(self, wait=True):
        if not self.recording:
            return None
        self.recording = False
        for t in self._threads:
            t.join(timeout=2)
        if self._windower_thread:
            self._windower_thread.join(timeout=3)
        if wait:
            # let queued windows finish transcribing
            deadline = time.time() + 180
            while self._pending > 0 and time.time() < deadline:
                time.sleep(0.2)
        self.on_update(self.state())
        return self.finish()

    def transcript(self):
        out = []
        for s in self.segments:
            m, sec = divmod(s["t"], 60)
            out.append(f"[{m:02d}:{sec:02d}] {s['text']}")
        return "\n".join(out)

    def summarize(self, transcript):
        if not self.llm or len(transcript.split()) < 12:
            return None
        words = transcript.split()
        chunks = [" ".join(words[i:i + 1100]) for i in range(0, len(words), 1100)]
        if len(chunks) > 1:
            # map: compress each part, reduce: summarize the compressed parts
            partials = []
            for c in chunks:
                partials.append(self.llm.chat_text([
                    {"role": "system", "content": "Compress this meeting transcript part into terse factual bullet "
                                                  "points, keeping names, numbers, decisions and commitments."},
                    {"role": "user", "content": c}], max_tokens=300))
            transcript = "\n".join(partials)
        return self.llm.chat_json([{"role": "system", "content": SUMMARY_SYSTEM},
                                   {"role": "user", "content": transcript[:9000]}], SUMMARY_SCHEMA, max_tokens=600)

    def finish(self):
        started = dt.datetime.fromtimestamp(self.started or time.time())
        duration = int(time.time() - (self.started or time.time()))
        transcript = self.transcript()
        result = None
        try:
            result = self.summarize(transcript)
        except Exception as e:
            print("[Meeting] summary failed:", e)
        title = (result or {}).get("title") or self.title or f"Meeting {started.strftime('%H:%M')}"
        summary = (result or {}).get("summary") or []
        decisions = (result or {}).get("decisions") or []
        actions = (result or {}).get("action_items") or []
        if not transcript:
            text = "No speech was captured."
        elif not result:
            text = "Transcript saved (summary unavailable — the AI model isn't ready)."
        else:
            text = " ".join(summary[:2])
        note = None
        if not transcript:
            self.started = None
            return {"note": None, "tasks": [], "title": title, "summary": [], "decisions": [], "actions": [],
                    "empty": True}
        if self.notes is not None:
            note = self.notes.add(text, kind="meeting", title=title, summary=summary, decisions=decisions,
                                  actions=actions, transcript=transcript, duration=duration,
                                  started=started.isoformat(timespec="minutes"))
        created = []
        if self.tasks is not None:
            for a in actions:
                owner = (a.get("owner") or "").lower()
                if owner in ("me", "i", "myself", "unassigned", "") or owner in self._user_names():
                    task = (a.get("task") or "").strip()
                    if task:
                        when_text = f"{task} {a.get('due', '')}".strip()
                        t = self.tasks.add_from_text(when_text, source="meeting")
                        created.append(t)
        if self.memory is not None:
            self.memory.journal_add("meeting", f"Meeting '{title}' ({duration // 60} min): {text[:200]}")
        self.started = None
        return {"note": note, "tasks": created, "title": title, "summary": summary, "decisions": decisions,
                "actions": actions}

    def _user_names(self):
        if not self.memory:
            return set()
        p = self.memory.profile
        return {n.lower() for n in (p.get("name"), p.get("preferred_name")) if n}
