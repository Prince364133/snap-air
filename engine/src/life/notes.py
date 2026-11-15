"""Notes (quick notes and meeting notes) in notes.json."""
import datetime as dt
import re
import threading
import time
import uuid

from src import storage


def transcript_text(value):
    """A meeting note's transcript as readable lines. The stored shape is the schema's
    (core/schemas/note: [{"t", "who", "text"}]); notes written before 2026-11 hold one string."""
    if isinstance(value, str):
        return value
    lines = []
    for s in value or []:
        if isinstance(s, dict):
            m, sec = divmod(int(s.get("t") or 0), 60)
            lines.append(f"[{m:02d}:{sec:02d}] {s.get('who', '')}: {s.get('text', '')}")
    return "\n".join(lines)


class NoteStore:
    def __init__(self, file=None):
        self.file = file or storage.path("notes.json")
        self.lock = threading.RLock()
        items = storage.read_json(self.file, None)
        if items is None:
            # migrate notes saved by the previous version (settings folder)
            items = storage.read_json(storage.path("notes.legacy.json"), []) or []
        for n in items:
            n.setdefault("kind", "note")
        self.items = items

    def _save(self):
        storage.write_json(self.file, self.items)

    def add(self, text, kind="note", **extra):
        with self.lock:
            note = {"id": uuid.uuid4().hex[:10], "text": text.strip(), "ts": time.time(), "kind": kind, **extra}
            self.items.insert(0, note)
            self._save()
            return note

    def update(self, note_id, **changes):
        with self.lock:
            for n in self.items:
                if n["id"] == note_id:
                    n.update({k: v for k, v in changes.items() if k != "id"})
                    self._save()
                    return n
        return None

    def delete(self, note_id):
        with self.lock:
            self.items = [n for n in self.items if n["id"] != note_id]
            self._save()

    def on_day(self, day):
        return [n for n in self.items if dt.datetime.fromtimestamp(n["ts"]).strftime("%Y-%m-%d") == day]

    def search(self, query, limit=8):
        words = [w for w in re.findall(r"\w+", query.lower()) if len(w) > 2]
        if not words:
            return self.items[:limit]
        scored = []
        for n in self.items:
            summary = n.get("summary") or ""
            if isinstance(summary, list):
                summary = " ".join(summary)
            hay = (n.get("title", "") + " " + n["text"] + " " + summary).lower()
            s = sum(hay.count(w) for w in words)
            if s:
                scored.append((s, n))
        return [n for _, n in sorted(scored, key=lambda x: -x[0])[:limit]]
