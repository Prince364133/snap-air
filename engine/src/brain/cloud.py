"""Optional cloud brain (hybrid architecture).

Daily automation (commands, tasks, reminders, notes, memory, gestures) always
runs locally. When the user adds an API key, conversation and meeting
summaries can go to a cloud model for sub-second answers and zero laptop load.
Providers: Google Gemini, OpenAI, and any OpenAI-compatible endpoint
(OpenRouter, Groq, Together, a self-hosted GPU server...).
"""
import json
import re
import threading
import time

import requests

from src import secrets_store
from src.brain.llm import LLM, ThinkFilter

PROVIDERS = {
    "gemini": {"label": "Google Gemini", "model": "gemini-2.5-flash"},
    "openai": {"label": "OpenAI", "model": "gpt-4o-mini", "base_url": "https://api.openai.com/v1"},
    "compatible": {"label": "OpenAI-compatible (OpenRouter, Groq, own server…)", "model": "",
                   "base_url": "https://openrouter.ai/api/v1"},
}
JSON_HINT = ('\nRespond with a JSON object whose keys appear in this order: "say", "tool", "args". '
             'No text outside the JSON.')


class CloudLLM:
    def __init__(self, settings=None):
        self.settings = settings
        self.busy = threading.Event()
        self.fg_lock = threading.Lock()
        self.last_stats = {}
        self.last_error = None
        self._online = (0.0, False)

    def _s(self, k, d=""):
        v = self.settings.get(k) if self.settings else None
        return d if v in (None, "") else v

    @property
    def provider(self):
        return self._s("cloud_provider", "gemini")

    @property
    def model(self):
        return self._s("cloud_model", PROVIDERS.get(self.provider, {}).get("model", ""))

    @property
    def base_url(self):
        return self._s("cloud_base_url", PROVIDERS.get(self.provider, {}).get("base_url", "")).rstrip("/")

    def key(self):
        return secrets_store.get_key(f"cloud_{self.provider}")

    def configured(self):
        return bool(self.key() and self.model)

    def online(self):
        t, ok = self._online
        if time.time() - t < 60:
            return ok
        try:
            requests.head("https://www.google.com", timeout=2)
            ok = True
        except requests.RequestException:
            ok = False
        self._online = (time.time(), ok)
        return ok

    def ready(self):
        return self.configured() and self.online()

    # ------------------------------------------------------------ requests
    def _openai_req(self, messages, json_mode, max_tokens, temperature, stream):
        body = {"model": self.model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature,
                "stream": stream}
        if json_mode:
            body["response_format"] = {"type": "json_object"}
        return requests.post(self.base_url + "/chat/completions", json=body, stream=stream, timeout=(6, 120),
                             headers={"Authorization": f"Bearer {self.key()}", "Content-Type": "application/json"})

    def _gemini_req(self, messages, json_mode, max_tokens, temperature, stream):
        system = "\n\n".join(m["content"] for m in messages if m["role"] == "system")
        contents = [{"role": "model" if m["role"] == "assistant" else "user", "parts": [{"text": m["content"]}]}
                    for m in messages if m["role"] != "system"]
        body = {"contents": contents, "generationConfig": {"maxOutputTokens": max_tokens, "temperature": temperature}}
        if system:
            body["systemInstruction"] = {"parts": [{"text": system}]}
        if json_mode:
            body["generationConfig"]["responseMimeType"] = "application/json"
        verb = "streamGenerateContent?alt=sse" if stream else "generateContent"
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:{verb}"
        return requests.post(url, json=body, stream=stream, timeout=(6, 120),
                             headers={"x-goog-api-key": self.key(), "Content-Type": "application/json"})

    def _request(self, messages, json_mode, max_tokens, temperature, stream):
        if json_mode:
            messages = [dict(m) for m in messages]
            messages[0] = {**messages[0], "content": messages[0]["content"] + JSON_HINT}
        fn = self._gemini_req if self.provider == "gemini" else self._openai_req
        r = fn(messages, json_mode, max_tokens, temperature, stream)
        if r.status_code >= 400:
            try:
                detail = r.json()
                detail = (detail.get("error") or {}).get("message") or str(detail)[:200]
            except ValueError:
                detail = r.text[:200]
            self.last_error = f"{PROVIDERS.get(self.provider, {}).get('label', self.provider)}: {detail}"
            raise RuntimeError(self.last_error)
        return r

    @staticmethod
    def _sse_texts(r, provider):
        for line in r.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                d = json.loads(data)
            except ValueError:
                continue
            if provider == "gemini":
                for c in d.get("candidates", [])[:1]:
                    for part in (c.get("content") or {}).get("parts", []):
                        if part.get("text"):
                            yield part["text"]
            else:
                for c in d.get("choices", [])[:1]:
                    t = (c.get("delta") or {}).get("content")
                    if t:
                        yield t

    @staticmethod
    def _full_text(r, provider):
        d = r.json()
        if provider == "gemini":
            parts = d["candidates"][0]["content"]["parts"]
            return "".join(p.get("text", "") for p in parts)
        return d["choices"][0]["message"]["content"]

    # ------------------------------------------------------- LLM interface
    def stream(self, messages, schema=None, max_tokens=300, temperature=0.4, cancel=None):
        with self.fg_lock:
            self.busy.set()
            t0 = time.time()
            think = ThinkFilter()
            try:
                with self._request(messages, schema is not None, max_tokens, temperature, True) as r:
                    for chunk in self._sse_texts(r, self.provider):
                        if cancel is not None and cancel.is_set():
                            break
                        out = think.feed(chunk)
                        if out:
                            yield out
                self.last_stats = {"cloud": self.provider, "seconds": round(time.time() - t0, 2)}
            finally:
                self.busy.clear()

    def chat_json(self, messages, schema, max_tokens=256, temperature=0.2, background=True):
        r = self._request(messages, True, max_tokens, temperature, False)
        text = LLM._clean(self._full_text(r, self.provider))
        text = re.sub(r"^```(?:json)?|```$", "", text.strip()).strip()
        try:
            return json.loads(text)
        except ValueError:
            m = re.search(r"\{.*\}", text, re.S)
            return json.loads(m.group()) if m else {}

    def chat_text(self, messages, max_tokens=300, temperature=0.4, background=True):
        r = self._request(messages, False, max_tokens, temperature, False)
        return LLM._clean(self._full_text(r, self.provider))

    def embed(self, texts):
        return None      # embeddings stay local (privacy)

    def test(self):
        t0 = time.time()
        out = self.chat_text([{"role": "system", "content": "Reply with exactly: OK"},
                              {"role": "user", "content": "ping"}], max_tokens=5, temperature=0)
        return round(time.time() - t0, 2), out.strip()


class Brain:
    """Routes LLM work: 'local' (Ollama), 'cloud' (API key), or 'auto' (cloud when
    a key is set and the PC is online, otherwise local). Memory learning stays
    local unless the user allows it ('cloud_for_memory')."""

    def __init__(self, local, cloud, settings, purpose="chat"):
        self.local, self.cloud, self.settings, self.purpose = local, cloud, settings, purpose

    def for_purpose(self, purpose):
        return Brain(self.local, self.cloud, self.settings, purpose)

    def _mode(self):
        v = self.settings.get("ai_provider") if self.settings else None
        return v or "auto"

    def active(self):
        mode = self._mode()
        cloud_ok = self.purpose != "memory" or bool(self.settings.get("cloud_for_memory"))
        if mode == "cloud" and cloud_ok and self.cloud.configured():
            return self.cloud
        if mode == "auto" and cloud_ok and self.cloud.ready():
            return self.cloud
        return self.local

    @property
    def is_cloud(self):
        return self.active() is self.cloud

    # same interface as LLM
    @property
    def busy(self):
        return self.active().busy

    @property
    def last_stats(self):
        return getattr(self.active(), "last_stats", {})

    def ready(self):
        a = self.active()
        return a.ready() or (a is self.cloud and self.local.ready())

    def stream(self, *a, **k):
        target = self.active()
        if target is self.cloud:
            try:
                yield from self.cloud.stream(*a, **k)
                return
            except Exception as e:
                print("[Brain] cloud failed, falling back to local:", e)
                if not self.local.ready():
                    raise
        yield from self.local.stream(*a, **k)

    def chat_json(self, *a, **k):
        target = self.active()
        try:
            return target.chat_json(*a, **k)
        except Exception:
            if target is self.cloud and self.local.ready():
                return self.local.chat_json(*a, **k)
            raise

    def chat_text(self, *a, **k):
        target = self.active()
        try:
            return target.chat_text(*a, **k)
        except Exception:
            if target is self.cloud and self.local.ready():
                return self.local.chat_text(*a, **k)
            raise

    def embed(self, texts):
        return self.local.embed(texts)
