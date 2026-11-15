"""Meeting notes.

Microphone = "You", system audio (WASAPI loopback) = "Others", so calls on
headphones work. Each source is transcribed separately in ~20 s windows. "Mark
that" adds a bookmark. Auto-stops after 20 minutes of silence. On stop the LLM
writes title / summary / key points / decisions / action items (owner + mine);
without an LLM a heuristic fallback is used. Action items wait for the user's
review ("mine" / "not mine" / dismiss) before they become tasks. Audio is never
written to disk — only the transcript and the notes.
"""
import datetime as dt
import queue
import re
import threading
import time

import numpy as np

SR = 16000
WINDOW_S = 20
SILENCE_STOP_S = 20 * 60
LABELS = {"mic": "You", "system": "Others"}

SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        "summary": {"type": "array", "items": {"type": "string"}},
        "key_points": {"type": "array", "items": {"type": "string"}},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "action_items": {"type": "array", "items": {"type": "object", "properties": {
            "task": {"type": "string"}, "owner": {"type": "string"}, "due": {"type": "string"},
            "mine": {"type": "boolean"}}, "required": ["task", "owner", "due", "mine"]}},
    },
    "required": ["title", "summary", "key_points", "decisions", "action_items"],
}

SUMMARY_SYSTEM = """You write meeting notes from a raw, imperfect speech transcript.
Lines with "You:" are the user; "Others:" are other participants.
Return: a short title (max 6 words); 2-4 summary bullets; key points; decisions made; action items with
owner (a name, "me" for the user, or "unassigned"), due (as said, or "") and mine=true when the user
committed to it or it was assigned to them. Only include things actually in the transcript.
Write in the language the meeting was held in."""

ACTION_HINT = re.compile(
    r"\b(i'll|i will|i can|let me|i'm going to|we need to|we should|can you|could you|action item|todo|"
    r"follow up|by (monday|tuesday|wednesday|thursday|friday|tomorrow|tonight|eod|end of day)|deadline)\b", re.I)
DECISION_HINT = re.compile(r"\b(we decided|we agreed|agreed|decision|let's go with|we'll go with)\b", re.I)


def heuristic_notes(segments):
    """No-LLM fallback: pull likely action items and decisions out of the transcript."""
    actions, decisions = [], []
    for s in segments:
        for sent in re.split(r"(?<=[.!?])\s+", s["text"]):
            sent = sent.strip()
            if len(sent) < 8:
                continue
            if DECISION_HINT.search(sent):
                decisions.append(sent)
            elif ACTION_HINT.search(sent):
                mine = s["who"] == "You" and re.search(r"\b(i'll|i will|i can|let me|i'm going to)\b", sent, re.I)
                actions.append({"task": sent, "owner": "me" if mine else "unassigned", "due": "", "mine": bool(mine)})
    words = sum(len(s["text"].split()) for s in segments)
    return {"title": "", "summary": [f"{len(segments)} transcript segments, {words} words (AI summary unavailable)."],
            "key_points": [], "decisions": decisions[:6], "action_items": actions[:8]}


class MeetingRecorder:
    def __init__(self, transcribe_fn=None, llm=None, notes=None, tasks=None, memory=None, on_update=None,
                 on_auto_stop=None):
        self.transcribe_fn = transcribe_fn      # fn(np.float32 audio) -> text
        self.llm = llm
        self.notes = notes
        self.tasks = tasks
        self.memory = memory
        self.on_update = on_update or (lambda state: None)
        self.on_auto_stop = on_auto_stop
        self.recording = False
        self.started = None
        self.title = None
        self.segments = []                      # {"t", "who", "text"}
        self.bookmarks = []                     # {"t", "label"}
        self.last_speech = 0.0
        self._bufs = {}
        self._offsets = {}
        self._buf_lock = threading.Lock()
        self._jobs = queue.Queue()
        self._threads = []
        self._windower_thread = None
        self._pending = 0
        self.capture_devices = True             # False in tests: audio arrives via feed()
        self.error = None
        threading.Thread(target=self._worker, daemon=True).start()

    # ------------------------------------------------------------ state
    def elapsed(self):
        return int(time.time() - self.started) if self.started and self.recording else 0

    def state(self):
        return {"recording": self.recording, "title": self.title, "elapsed": self.elapsed(),
                "live": (self.segments[-1]["who"] + ": " + self.segments[-1]["text"]) if self.segments else "",
                "words": sum(len(s["text"].split()) for s in self.segments),
                "bookmarks": len(self.bookmarks), "error": self.error}

    # ---------------------------------------------------------- capture
    def start(self, title=None, sources=("system", "mic")):
        if self.recording:
            return False
        self.recording, self.started, self.title = True, time.time(), title
        self.last_speech = time.time()
        self.segments, self.bookmarks, self.error = [], [], None
        self._bufs = {s: [] for s in sources}
        self._offsets = {s: 0.0 for s in sources}
        self._threads = []
        for s in (sources if self.capture_devices else ()):
            t = threading.Thread(target=self._capture, args=(s,), daemon=True)
            t.start()
            self._threads.append(t)
        self._windower_thread = threading.Thread(target=self._windower, daemon=True)
        self._windower_thread.start()
        self.on_update(self.state())
        return True

    def bookmark(self, label=""):
        if not self.recording:
            return None
        b = {"t": self.elapsed(), "label": label.strip() or "Bookmark"}
        self.bookmarks.append(b)
        self.on_update(self.state())
        return b

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
            self.error = f"{LABELS.get(source, source)} audio unavailable: {e}"
            print("[Meeting]", self.error)

    def _take(self, source):
        with self._buf_lock:
            chunks, self._bufs[source] = self._bufs.get(source, []), []
        if not chunks:
            return None
        return np.clip(np.concatenate(chunks), -1, 1)

    def _queue(self, source, audio):
        offset = self._offsets[source]
        self._offsets[source] += len(audio) / SR
        self._pending += 1
        self._jobs.put((source, offset, audio))

    def _windower(self):
        while self.recording:
            time.sleep(0.5)
            for source in list(self._bufs):
                with self._buf_lock:
                    n = sum(len(c) for c in self._bufs[source])
                if n >= SR * WINDOW_S:
                    audio = self._take(source)
                    if audio is not None:
                        self._queue(source, audio)
            if time.time() - self.last_speech > SILENCE_STOP_S and self.on_auto_stop:
                threading.Thread(target=self.on_auto_stop, daemon=True).start()
                return
        for source in list(self._bufs):
            audio = self._take(source)
            if audio is not None and len(audio) > SR:
                self._queue(source, audio)

    def _worker(self):
        while True:
            source, offset, audio = self._jobs.get()
            try:
                if float(np.sqrt(np.mean(audio ** 2))) < 0.004:
                    continue   # silence: skip transcription
                peak = float(np.max(np.abs(audio))) or 1.0
                audio = audio * min(4.0, 0.6 / peak)   # normalise quiet microphones
                try:
                    text = self.transcribe_fn(audio) if self.transcribe_fn else ""
                except Exception as e:
                    print("[Meeting] transcription error:", e)
                    text = ""
                if re.search(r"[^\W_]{2,}", text or ""):     # ignore "..." / noise-only output
                    self.last_speech = time.time()
                    self.segments.append({"t": round(offset), "who": LABELS.get(source, source), "text": text.strip()})
                    self.segments.sort(key=lambda s: s["t"])
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
        if self._windower_thread and self._windower_thread is not threading.current_thread():
            self._windower_thread.join(timeout=3)
        if wait:
            deadline = time.time() + 180
            while self._pending > 0 and time.time() < deadline:
                time.sleep(0.2)
        self.on_update(self.state())
        return self.finish()

    def transcript(self):
        lines = []
        marks = sorted(self.bookmarks, key=lambda b: b["t"])
        for s in self.segments:
            while marks and marks[0]["t"] <= s["t"] + WINDOW_S:
                b = marks.pop(0)
                lines.append(f"[{b['t'] // 60:02d}:{b['t'] % 60:02d}] ★ {b['label']}")
            m, sec = divmod(s["t"], 60)
            lines.append(f"[{m:02d}:{sec:02d}] {s['who']}: {s['text']}")
        for b in marks:
            lines.append(f"[{b['t'] // 60:02d}:{b['t'] % 60:02d}] ★ {b['label']}")
        return "\n".join(lines)

    def summarize(self, transcript):
        if not self.llm or len(transcript.split()) < 12:
            return None
        words = transcript.split()
        chunks = [" ".join(words[i:i + 1100]) for i in range(0, len(words), 1100)]
        if len(chunks) > 1:
            partials = [self.llm.chat_text([
                {"role": "system", "content": "Compress this meeting transcript part into terse factual bullet "
                                              "points, keeping who said what, names, numbers, decisions and commitments."},
                {"role": "user", "content": c}], max_tokens=300) for c in chunks]
            transcript = "\n".join(partials)
        return self.llm.chat_json([{"role": "system", "content": SUMMARY_SYSTEM},
                                   {"role": "user", "content": transcript[:9000]}], SUMMARY_SCHEMA, max_tokens=700)

    def finish(self):
        started = dt.datetime.fromtimestamp(self.started or time.time())
        duration = int(time.time() - (self.started or time.time()))
        transcript = self.transcript()
        if not self.segments:
            self.started = None
            return {"note": None, "actions": [], "title": self.title or "Meeting", "empty": True}
        result, used_ai = None, False
        try:
            result = self.summarize(transcript)
            used_ai = bool(result)
        except Exception as e:
            print("[Meeting] summary failed:", e)
        if not result:
            result = heuristic_notes(self.segments)
        title = result.get("title") or self.title or f"Meeting {started.strftime('%H:%M')}"
        names = self._user_names()
        actions = []
        for i, a in enumerate(result.get("action_items") or []):
            task = (a.get("task") or "").strip()
            if not task:
                continue
            owner = (a.get("owner") or "unassigned").strip()
            mine = bool(a.get("mine")) or owner.lower() in ({"me", "i", "myself"} | names)
            actions.append({"id": f"a{i}", "task": task, "owner": owner, "due": a.get("due", ""), "mine": mine,
                            "status": "pending"})      # waits for review: accept / not mine / dismiss
        summary = result.get("summary") or []
        note = None
        if self.notes is not None:
            note = self.notes.add(" ".join(summary[:2]) or "Meeting notes", kind="meeting", title=title,
                                  summary=summary, key_points=result.get("key_points") or [],
                                  decisions=result.get("decisions") or [], actions=actions,
                                  bookmarks=self.bookmarks, transcript=transcript, duration=duration,
                                  started=started.isoformat(timespec="minutes"), ai_summary=used_ai,
                                  review_pending=bool(actions))
        if self.memory is not None:
            self.memory.journal_add("meeting", f"Meeting '{title}' ({duration // 60} min): {' '.join(summary)[:200]}")
        self.started = None
        return {"note": note, "title": title, "actions": actions, "summary": summary}

    def review_action(self, note, action_id, decision):
        """decision: 'accept' (create a task), 'not_mine', 'dismiss'."""
        task = None
        for a in note.get("actions", []):
            if a.get("id") != action_id:
                continue
            if decision == "accept" and self.tasks is not None and a["status"] == "pending":
                task = self.tasks.add_from_text(f"{a['task']} {a.get('due', '')}".strip(), source="meeting")
            a["status"] = {"accept": "accepted", "not_mine": "not_mine", "dismiss": "dismissed"}.get(decision, "pending")
        note["review_pending"] = any(a["status"] == "pending" for a in note.get("actions", []))
        if self.notes is not None:
            self.notes.update(note["id"], actions=note["actions"], review_pending=note["review_pending"])
        return task

    def _user_names(self):
        if not self.memory:
            return set()
        p = self.memory.profile
        return {n.lower() for n in (p.get("name"), p.get("preferred_name")) if n}
