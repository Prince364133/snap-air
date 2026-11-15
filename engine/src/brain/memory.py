"""Snap Air long-term memory (all local JSON, see docs/RESEARCH.md §4).

Tiers (MemGPT-style):
  profile.json        core memory, always in the prompt
  memories.json       semantic memories: atomic facts with importance & history
  vectors.json        embeddings for memories (embeddinggemma via Ollama)
  journal/DAY.json    episodic: what happened each day
  conversations/DAY.jsonl  recall: raw conversation turns (30-day retention)

Write path (Mem0-style): explicit "remember" saves immediately; otherwise a
background pass extracts durable facts and consolidates them against similar
existing memories (ADD / UPDATE / skip) in a single LLM call.
Read path (Generative-Agents-style): relevance + importance + recency.
"""
import datetime as dt
import math
import os
import re
import threading
import time
import uuid

from src import core_loader as core
from src import storage
from src import diag  # noqa: E402

# Memory categories: the single list is core/schemas/memory_fact.schema.json
CATEGORIES = list(core.schema("memory_fact")["properties"]["category"]["enum"])

PROFILE_DEFAULTS = {
    "name": "", "preferred_name": "", "role": "", "about": "",
    "languages": ["English"], "work_start": "09:00", "work_end": "18:00", "city": "",
    "editor": "", "browser": "", "projects": [], "routine": {}, "onboarded": False,
}



class _AnyOf:
    """Pattern list from core/intents (any matches -> truthy), used like a compiled regex."""

    def __init__(self, domain):
        self.domain = domain

    def search(self, text):
        return core.any_match(self.domain, text or "")


# Cheap pre-filter so we don't spend CPU on "scroll down" or "what time is it"
SELF_SIGNALS = _AnyOf("memory_self")

STOP = set("the a an and or but to of in on at for with is are was were be been it this that these those "
           "i you he she they we my your his her their our me him them us do does did have has had not no "
           "so as by from about into over than then there here what when where which who whom why how "
           "can could would should will shall may might must just also very really please snap".split())

# Never store secrets, whatever their source (rule-based, LLM, manual). core/intents: memory_secret
SECRET = _AnyOf("memory_secret")


def is_secret(text):
    return bool(SECRET.search(text or ""))


# Rule-based extraction: works with no LLM at all. core/intents: memory_extract
# (compiled pattern, template, category, importance, key)
def _rules():
    return [(e["rx"], e["template"], e["category"], e["importance"], e.get("key"))
            for e in core.domain("memory_extract")]


EXTRACT_SYSTEM = core.prompt("extract_memory")


def _extract_schema():
    import copy
    s = copy.deepcopy(core.prompt_json("extract_memory.schema"))
    cat = s["properties"]["memories"]["items"]["properties"]["category"]
    cat.pop("description", None)
    cat["enum"] = CATEGORIES
    return s


EXTRACT_SCHEMA = _extract_schema()


def _tokens(text):
    words = re.findall(r"[a-z0-9ऀ-ॿ]+", text.lower())
    out = set()
    for w in words:
        if w in STOP or len(w) < 2:
            continue
        for suf in ("ing", "ed", "es", "s"):
            if len(w) > 4 and w.endswith(suf):
                w = w[: -len(suf)]
                break
        out.add(w)
    return out


def _cos(a, b):
    if not a or not b or len(a) != len(b):
        return None
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else None


def _now_iso():
    return dt.datetime.now().isoformat(timespec="seconds")


class MemoryStore:
    def __init__(self, folder=None, llm=None, settings=None):
        self.folder = folder or os.path.join(storage.data_dir(), "memory")
        os.makedirs(os.path.join(self.folder, "journal"), exist_ok=True)
        os.makedirs(os.path.join(self.folder, "conversations"), exist_ok=True)
        self.llm = llm
        self.settings = settings
        self.lock = threading.RLock()
        self.profile = {**PROFILE_DEFAULTS, **(storage.read_json(self._p("profile.json"), {}) or {})}
        self.memories = storage.read_json(self._p("memories.json"), []) or []
        self.vectors = storage.read_json(self._p("vectors.json"), {}) or {}
        self.on_change = None   # callback for the HUD

    def _p(self, *parts):
        return os.path.join(self.folder, *parts)

    def _s(self, k, d):
        if self.settings is None:
            return d
        v = self.settings.get(k)
        return d if v is None else v

    @property
    def learning_enabled(self):
        return bool(self._s("memory_learning", True))

    # ----------------------------------------------------------- persist
    def _save(self, vectors=False):
        storage.write_json(self._p("memories.json"), self.memories)
        if vectors:
            storage.write_json(self._p("vectors.json"), self.vectors)
        if self.on_change:
            try:
                self.on_change()
            except Exception as e:
                diag.record("memory.on_change", e, quiet=True)

    def save_profile(self):
        self.profile["updated"] = _now_iso()
        storage.write_json(self._p("profile.json"), self.profile)
        if self.on_change:
            try:
                self.on_change()
            except Exception as e:
                diag.record("memory.on_change", e, quiet=True)

    def update_profile(self, changes):
        with self.lock:
            for k, v in (changes or {}).items():
                if k in PROFILE_DEFAULTS or k in ("updated",):
                    self.profile[k] = v
            self.save_profile()
            return self.profile

    # ----------------------------------------------------------- vectors
    def _embed(self, items):
        if not self.llm or not items:
            return
        try:
            vecs = self.llm.embed([m["text"] for m in items])
        except Exception:
            vecs = None
        if vecs and len(vecs) == len(items):
            for m, v in zip(items, vecs):
                self.vectors[m["id"]] = [round(x, 5) for x in v]

    def _embed_later(self, items):
        """Compute embeddings in the background (loading the embedding model can take seconds)."""
        def go():
            with self.lock:
                self._embed(items)
                storage.write_json(self._p("vectors.json"), self.vectors)
        threading.Thread(target=go, daemon=True).start()

    def ensure_vectors(self):
        missing = [m for m in self.memories if m["id"] not in self.vectors]
        if missing:
            self._embed(missing)
            storage.write_json(self._p("vectors.json"), self.vectors)

    # -------------------------------------------------------------- CRUD
    def get(self, mem_id):
        return next((m for m in self.memories if m["id"] == mem_id), None)

    def add(self, text, category="fact", importance=3, source="conversation", pinned=False, dedupe=True, key=None):
        text = text.strip().rstrip(".")
        if not text or is_secret(text):
            return None
        with self.lock:
            if dedupe:
                dup = self._near_duplicate(text)
                if dup:
                    # Same fact again: reinforce instead of duplicating
                    dup["importance"] = max(dup["importance"], int(importance))
                    dup["updated"] = _now_iso()
                    dup["uses"] = dup.get("uses", 0) + 1
                    self._save()
                    return dup
            m = {"id": uuid.uuid4().hex[:10], "text": text, "category": category if category in CATEGORIES else "fact",
                 "importance": max(1, min(5, int(importance))), "created": _now_iso(), "updated": _now_iso(),
                 "last_used": None, "uses": 0, "source": source, "pinned": bool(pinned), "history": []}
            if key:
                m["key"] = key
            self.memories.append(m)
            self._save()
            self._embed_later([m])
            self.journal_add("memory", f"Learned: {text}")
            return m

    def update(self, mem_id, **changes):
        with self.lock:
            m = self.get(mem_id)
            if not m:
                return None
            if "text" in changes and changes["text"].strip() and changes["text"].strip() != m["text"]:
                # keep what it used to say (no silent information loss)
                m["history"].append({"text": m["text"], "until": _now_iso()})
                m["history"] = m["history"][-5:]
                m["text"] = changes["text"].strip().rstrip(".")
                self.vectors.pop(m["id"], None)
                self._embed_later([m])
            for k in ("category", "importance", "pinned"):
                if k in changes:
                    m[k] = changes[k]
            m["updated"] = _now_iso()
            self._save(vectors=True)
            return m

    def delete(self, mem_id):
        with self.lock:
            before = len(self.memories)
            self.memories = [m for m in self.memories if m["id"] != mem_id]
            self.vectors.pop(mem_id, None)
            self._save(vectors=True)
            return len(self.memories) < before

    def forget(self, query):
        """Delete the memory that best matches a spoken description. Returns it or None."""
        hits = self.retrieve(query, k=1, min_relevance=0.35, touch=False)
        if not hits:
            return None
        m = hits[0]["memory"]
        self.delete(m["id"])
        return m

    def forget_all(self):
        with self.lock:
            self.memories, self.vectors = [], {}
            self._save(vectors=True)
            self.profile = {**PROFILE_DEFAULTS, "onboarded": self.profile.get("onboarded", False)}
            self.save_profile()

    def _near_duplicate(self, text):
        tt = _tokens(text)
        for m in self.memories:
            mt = _tokens(m["text"])
            if not tt or not mt:
                continue
            jacc = len(tt & mt) / len(tt | mt)
            contained = len(tt & mt) / min(len(tt), len(mt))
            if jacc >= 0.8 or contained >= 0.85 or m["text"].lower() == text.lower():
                return m
        return None

    # --------------------------------------------------------- retrieval
    def retrieve(self, query, k=6, min_relevance=0.2, touch=True, use_vectors=True):
        with self.lock:
            if not self.memories:
                return []
            qvec = None
            if use_vectors and self.llm and query.strip():
                try:
                    v = self.llm.embed([query])
                    qvec = v[0] if v else None
                except Exception:
                    qvec = None
            qt = _tokens(query)
            now = time.time()
            scored = []
            for m in self.memories:
                rel = None
                if qvec is not None:
                    rel = _cos(qvec, self.vectors.get(m["id"]))
                    if rel is not None:
                        rel = max(0.0, (rel - 0.3) / 0.6)    # embeddinggemma cosines sit ~0.3-0.9
                if rel is None:
                    mt = _tokens(m["text"])
                    rel = len(qt & mt) / max(1, min(len(qt), len(mt))) if qt and mt else 0.0
                ts = m.get("last_used") or m.get("updated") or m["created"]
                try:
                    age_days = (now - dt.datetime.fromisoformat(ts).timestamp()) / 86400
                except ValueError:
                    age_days = 30
                recency = 0.995 ** (age_days * 24)          # spec: 0.995^hours since last access
                score = 0.5 * rel + 0.25 * (m["importance"] / 5) + 0.25 * recency + (0.3 if m.get("pinned") else 0)
                scored.append({"memory": m, "score": round(score, 3), "relevance": round(rel, 3)})
            scored.sort(key=lambda x: -x["score"])
            hits = [s for s in scored if s["relevance"] >= min_relevance][:k]
            if touch and hits:
                for h in hits:
                    h["memory"]["last_used"] = _now_iso()
                    h["memory"]["uses"] = h["memory"].get("uses", 0) + 1
                storage.write_json(self._p("memories.json"), self.memories)
            return hits

    def core_memories(self):
        """Always-on memories: pinned, behaviour instructions, identity-level facts."""
        return [m for m in self.memories
                if m.get("pinned") or m["category"] == "instruction" or m["importance"] >= 5][:8]

    def profile_text(self):
        p = self.profile
        bits = []
        name = p.get("preferred_name") or p.get("name")
        if name:
            bits.append(f"Name: {name}")
        if p.get("role"):
            bits.append(f"Role: {p['role']}")
        if p.get("about"):
            bits.append(f"About: {p['about']}")
        if p.get("languages"):
            bits.append("Languages: " + ", ".join(p["languages"]))
        if p.get("work_start"):
            bits.append(f"Work hours: {p.get('work_start')}–{p.get('work_end', '')}")
        if p.get("city"):
            bits.append(f"City: {p['city']}")
        if p.get("editor"):
            bits.append(f"Editor/IDE: {p['editor']}")
        if p.get("projects"):
            bits.append("Projects: " + ", ".join(pr["name"] for pr in p["projects"][:6]))
        r = p.get("routine") or {}
        if r.get("typical_start"):
            bits.append(f"Usually starts work around {r['typical_start']}")
        if r.get("usual_first_apps"):
            bits.append("Usually opens first: " + ", ".join(a["name"] for a in r["usual_first_apps"]))
        if r.get("last_project"):
            bits.append(f"Most recent project: {r['last_project']}")
        return "\n".join(bits)

    def context_block(self, query, k=6):
        core = self.core_memories()
        core_ids = {m["id"] for m in core}
        # Live turns use keyword relevance only: embedding the query costs 3-6 s on a busy
        # laptop CPU (measured). Vectors are still used by background consolidation.
        hits = [h["memory"] for h in self.retrieve(query, k=k, use_vectors=False) if h["memory"]["id"] not in core_ids]
        lines = [f"- {m['text']}" for m in core + hits]
        return self.profile_text(), "\n".join(lines)

    # ------------------------------------------------------ write policy
    EXPLICIT = core.domain("memory_explicit")[0]["rx"]

    def explicit_remember(self, text):
        m = self.EXPLICIT.match(text.strip())
        fact = (m.group(1) if m else text).strip().rstrip(".")
        fact = re.sub(r"^(that\s+)", "", fact, flags=re.I)
        # first person -> third person for readability ("my manager is Arun" -> "User's manager is Arun")
        fact = re.sub(r"\bmy\b", "User's", fact, flags=re.I)
        fact = re.sub(r"\bI am\b|\bI'm\b", "User is", fact, flags=re.I)
        fact = re.sub(r"\bI\b", "User", fact)
        fact = re.sub(r"\bme\b", "the user", fact, flags=re.I)
        return self.add(fact[0].upper() + fact[1:] if fact else fact, category="fact", importance=5, source="explicit")

    def extract_rules(self, user_text, source="chat"):
        """Deterministic extraction (no LLM). Keyed facts are replaced, not duplicated."""
        if not self.learning_enabled or is_secret(user_text):
            return []
        out = []
        for rx, tmpl, cat, imp, key in _rules():
            m = rx.search(user_text)
            if not m:
                continue
            groups = [g.strip().rstrip(".") for g in m.groups() if g]
            if not groups:
                continue
            text = tmpl.format(*groups)
            if key == "name":
                self.update_profile({"name": groups[0].title(),
                                     "preferred_name": self.profile.get("preferred_name") or groups[0].title()})
            elif key == "call_me":
                self.update_profile({"preferred_name": groups[0]})
            elif key == "role":
                self.update_profile({"role": groups[0]})
            elif key == "editor":
                self.update_profile({"editor": groups[0].title()})
            mem = self.upsert(key, text, cat, imp, source=source) if key else self.add(text, cat, imp, source=source)
            if mem:
                out.append(mem)
        return out

    def upsert(self, key, text, category="routine", importance=3, source="observed"):
        """Facts with a stable key (e.g. 'start_time') are replaced instead of duplicated."""
        with self.lock:
            existing = next((m for m in self.memories if m.get("key") == key), None)
            if existing:
                if existing["text"] != text:
                    return self.update(existing["id"], text=text, importance=max(existing["importance"], importance))
                return existing
        return self.add(text, category, importance, source=source, key=key, dedupe=False)

    def reflect(self, threshold=20):
        """Generative-Agents reflection: after enough new importance accumulates (1-5 scale,
        20 here = 40 on the 1-10 scale), write up to 3 insights. Needs the LLM."""
        if not self.llm or not self.learning_enabled:
            return []
        since = self.profile.get("last_reflection") or ""
        fresh = [m for m in self.memories if m["updated"] > since and m.get("category") != "insight"]
        if sum(m["importance"] for m in fresh) < threshold:
            return []
        facts = "\n".join(f"- {m['text']}" for m in fresh[-25:])
        schema = {"type": "object", "properties": {"insights": {"type": "array", "items": {"type": "string"}}},
                  "required": ["insights"]}
        try:
            out = self.llm.chat_json([
                {"role": "system", "content": "From these facts about one person, write at most 3 short third-person "
                                              "insights that would help a personal assistant (patterns, priorities, "
                                              "working style). No secrets, nothing about other people."},
                {"role": "user", "content": facts}], schema, max_tokens=160)
        except Exception as e:
            diag.record("memory.insights", e, quiet=True)
            return []
        made = [self.add(t, "insight", 3, source="reflection") for t in (out or {}).get("insights", [])[:3]]
        self.profile["last_reflection"] = _now_iso()
        self.save_profile()
        return [m for m in made if m]

    def about_me(self):
        """Plain-language answer to 'what do you know about me?' (never a raw dump)."""
        p = self.profile
        bits = []
        name = p.get("preferred_name") or p.get("name")
        if name:
            bits.append(f"you're {name}")
        if p.get("role"):
            bits.append(f"you work as {p['role']}")
        if p.get("editor"):
            bits.append(f"you code in {p['editor']}")
        skip = ("name is", "works as", "prefers to be called", "uses ")
        top = [m for m in sorted(self.memories, key=lambda m: (not m.get("pinned"), -m["importance"]))
               if not m["text"].lower().startswith(skip)][:3]
        if not bits and not top:
            return "I don't know much about you yet. Tell me things like “remember that I start work at 9”."
        out = ("I know " + ", ".join(bits)) if bits else "I know a few things"
        if top:
            out += ". I also remember: " + "; ".join(m["text"] for m in top)
        return out + f". That's {len(self.memories)} things in total — you can see, edit or delete all of them in the Memory tab."

    def worth_extracting(self, user_text):
        words = user_text.split()
        return self.learning_enabled and len(words) >= 4 and bool(SELF_SIGNALS.search(user_text))

    def extract_and_consolidate(self, user_text, assistant_text=""):
        """Background: learn durable facts from one exchange. Returns applied ops."""
        if not self.llm or not self.worth_extracting(user_text):
            return []
        similar = [h["memory"] for h in self.retrieve(user_text, k=6, min_relevance=0.15, touch=False)]
        existing = "\n".join(f"[{m['id']}] {m['text']}" for m in similar) or "(none)"
        prompt = (f"EXISTING MEMORIES:\n{existing}\n\nLATEST EXCHANGE:\nUser: {user_text}\n"
                  f"Assistant: {assistant_text[:300]}")
        try:
            out = self.llm.chat_json([{"role": "system", "content": EXTRACT_SYSTEM},
                                      {"role": "user", "content": prompt}], EXTRACT_SCHEMA, max_tokens=220)
        except Exception as e:
            print("[Memory] extraction failed:", e)
            return []
        applied = []
        for item in (out or {}).get("memories", [])[:4]:
            text = (item.get("text") or "").strip()
            if item.get("op") == "delete" and item.get("id") and self.get(item["id"]):
                gone = self.get(item["id"])          # deletes don't need text
                self.delete(item["id"])
                applied.append(("delete", gone))
                continue
            if len(text) < 4:
                continue
            if is_secret(text):
                continue
            if item.get("op") == "update" and item.get("id") and self.get(item["id"]):
                applied.append(("update", self.update(item["id"], text=text,
                                                      importance=item.get("importance", 3))))
            else:
                applied.append(("add", self.add(text, item.get("category", "fact"), item.get("importance", 3))))
        return applied

    # --------------------------------------------------------- episodic
    def journal_add(self, kind, text, day=None):
        p = self._p("journal", f"{day or storage.today()}.json")
        j = storage.read_json(p, None) or {"events": [], "summary": ""}
        j["events"].append({"ts": time.time(), "type": kind, "text": text[:400]})
        j["events"] = j["events"][-300:]
        storage.write_json(p, j)

    def journal(self, day=None):
        return storage.read_json(self._p("journal", f"{day or storage.today()}.json"), None) or {"events": [], "summary": ""}

    def set_journal_summary(self, day, summary, field="summary"):
        p = self._p("journal", f"{day}.json")
        j = storage.read_json(p, None) or {"events": [], "summary": ""}
        j[field] = summary
        storage.write_json(p, j)

    def record_turn(self, role, text, lang=None):
        storage.append_jsonl(self._p("conversations", f"{storage.today()}.jsonl"),
                             {"ts": time.time(), "role": role, "text": text, "lang": lang})

    def recent_turns(self, n=8):
        return storage.read_jsonl(self._p("conversations", f"{storage.today()}.jsonl"), limit=n)

    def prune(self, keep_conversation_days=30):
        storage.prune_dated_files(self._p("conversations"), keep_conversation_days)

    def export(self):
        return {"profile": self.profile, "memories": self.memories}
