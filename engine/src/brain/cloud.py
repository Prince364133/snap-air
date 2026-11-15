"""Optional cloud brain (hybrid architecture).

Daily automation (commands, tasks, reminders, notes, memory, gestures) always
runs locally. When the user adds an API key, conversation and meeting
summaries go to a cloud model for sub-second answers and zero laptop load.
Providers: Google Gemini, OpenAI, Anthropic Claude, xAI Grok, Groq, Mistral,
DeepSeek, OpenRouter, Perplexity, and custom OpenAI-compatible endpoints.
"""
import json
import re
import threading
import time

import requests

from src import appdata, secrets_store
from src.brain.llm import LLM, ThinkFilter



def _load_providers():
    """Provider table from src/data/app.json ("cloud.providers"); see the comment there.
    Each model entry is normalised to a dict, and "model" is the first choice (shown in the UI)."""
    out = {}
    for name, p in (appdata.get("cloud.providers") or {}).items():
        models = [m if isinstance(m, dict) else {"id": m} for m in p.get("models") or []]
        out[name] = {**p, "models": models, "model": models[0]["id"] if models else ""}
    return out


PROVIDERS = _load_providers()

# Some providers (Gemini, xAI) answer a bad key with HTTP 400 rather than 401/403
_KEY_BAD = re.compile(r"api[ _-]?key.{0,30}(not valid|invalid|incorrect)|(invalid|incorrect).{0,20}api[ _-]?key", re.I)

# Phrases providers use when a model ID is retired or not available to this key
_MODEL_GONE = re.compile(r"not[ _]found|does not exist|decommission|deprecat|retired|no longer|"
                         r"unknown model|invalid model|model.{0,40}(not supported|unsupported|not available)", re.I)
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
        self._rejected = None                # (provider, key) the provider answered 401/403 for
        self._model_idx = {}                 # provider -> index of the model in use (see _advance_model)

    def _s(self, k, d=""):
        v = self.settings.get(k) if self.settings else None
        return d if v in (None, "") else v

    @property
    def provider(self):
        return self._s("cloud_provider", "gemini")

    @property
    def _info(self):
        return PROVIDERS.get(self.provider, {})

    def _candidates(self):
        """Models to try for this provider, best first. A custom endpoint uses the user's model."""
        if self._info.get("custom"):
            custom = self._s("cloud_model", "")
            return [{"id": custom}] if custom else []
        return self._info.get("models") or []

    def _spec(self):
        c = self._candidates()
        if not c:
            return {"id": ""}
        return c[min(self._model_idx.get(self.provider, 0), len(c) - 1)]

    def _advance_model(self):
        """Move to the next model after the provider said the current one doesn't exist."""
        c, i = self._candidates(), self._model_idx.get(self.provider, 0)
        if i + 1 >= len(c):
            return False
        self._model_idx[self.provider] = i + 1
        print(f"[Cloud] {c[i]['id']} unavailable on {self.provider}; using {c[i + 1]['id']}")
        return True

    @property
    def model(self):
        return self._spec()["id"]

    @property
    def base_url(self):
        prov_base = self._info.get("base_url", "")
        if self._info.get("custom"):
            return self._s("cloud_base_url", prov_base).rstrip("/")
        return prov_base.rstrip("/")

    def key(self):
        return secrets_store.get_key(f"cloud_{self.provider}")

    def configured(self):
        return bool(self.key() and self.model)

    def key_rejected(self):
        """True when the provider refused the current key (wrong or revoked), until it is replaced."""
        return self._rejected is not None and self._rejected == (self.provider, self.key())

    def online(self):
        t, ok = self._online
        if time.time() - t < 60:
            return ok
        try:
            url = appdata.get("web.connectivity_check") or "https://www.google.com"
            requests.head(url, timeout=2)
            ok = True
        except requests.RequestException:
            try:
                requests.head("https://1.1.1.1", timeout=2)
                ok = True
            except Exception:
                ok = False
        self._online = (time.time(), ok)
        return ok

    def ready(self):
        return self.configured() and not self.key_rejected() and self.online()

    # ------------------------------------------------------------ requests
    def _gen(self, max_tokens, temperature):
        """Per-model generation settings from app.json: (spec, max_tokens, temperature or None)."""
        spec = self._spec()
        n = max(int(max_tokens), int(spec.get("min_max_tokens", 0)))
        temp = temperature if spec.get("sampling", True) else None
        return spec, n, temp

    def _openai_req(self, messages, json_mode, max_tokens, temperature, stream):
        spec, n, temp = self._gen(max_tokens, temperature)
        body = {"model": spec["id"], "messages": messages, "stream": stream,
                spec.get("token_param", "max_tokens"): n}
        if temp is not None:
            body["temperature"] = temp
        if json_mode and self._info.get("json_mode"):
            body["response_format"] = {"type": "json_object"}
        body.update(spec.get("extra") or {})
        headers = {"Authorization": f"Bearer {self.key()}", "Content-Type": "application/json",
                   **(self._info.get("headers") or {})}
        return requests.post(self.base_url + "/chat/completions", json=body, stream=stream, timeout=(6, 120),
                             headers=headers)

    def _anthropic_req(self, messages, json_mode, max_tokens, temperature, stream):
        spec, n, temp = self._gen(max_tokens, temperature)
        system_prompt = "\n\n".join(m["content"] for m in messages if m["role"] == "system")
        chat_msgs = [{"role": "assistant" if m["role"] == "assistant" else "user", "content": m["content"]}
                     for m in messages if m["role"] != "system"] or [{"role": "user", "content": "Hello"}]
        body = {"model": spec["id"], "max_tokens": n, "messages": chat_msgs, "stream": stream}
        if temp is not None:
            body["temperature"] = temp
        if system_prompt:
            body["system"] = system_prompt
        body.update(spec.get("extra") or {})
        headers = {"x-api-key": self.key(), "anthropic-version": "2023-06-01", "content-type": "application/json"}
        return requests.post(self.base_url + "/messages", json=body, stream=stream, timeout=(6, 120), headers=headers)

    def _gemini_req(self, messages, json_mode, max_tokens, temperature, stream):
        spec, n, temp = self._gen(max_tokens, temperature)
        system = "\n\n".join(m["content"] for m in messages if m["role"] == "system")
        contents = [{"role": "model" if m["role"] == "assistant" else "user", "parts": [{"text": m["content"]}]}
                    for m in messages if m["role"] != "system"]
        gen = {"maxOutputTokens": n}
        if temp is not None:
            gen["temperature"] = temp
        if json_mode:
            gen["responseMimeType"] = "application/json"
        gen.update(spec.get("extra") or {})
        body = {"contents": contents, "generationConfig": gen}
        if system:
            body["systemInstruction"] = {"parts": [{"text": system}]}
        verb = "streamGenerateContent?alt=sse" if stream else "generateContent"
        url = f"{self.base_url}/models/{spec['id']}:{verb}"
        return requests.post(url, json=body, stream=stream, timeout=(6, 120),
                             headers={"x-goog-api-key": self.key(), "Content-Type": "application/json"})

    @staticmethod
    def _error_detail(r):
        try:
            d = r.json()
        except ValueError:
            return r.text[:200]
        if isinstance(d, list) and d:              # Gemini can wrap errors in a list
            d = d[0]
        if not isinstance(d, dict):
            return str(d)[:200]
        err = d.get("error")
        if isinstance(err, dict):
            return err.get("message") or str(err)[:200]
        detail = err or d.get("message") or d.get("detail")        # Mistral: {"detail": "..."}
        return str(detail if isinstance(detail, str) else d)[:200]

    def _request(self, messages, json_mode, max_tokens, temperature, stream):
        if json_mode:
            messages = [dict(m) for m in messages]
            messages[0] = {**messages[0], "content": messages[0]["content"] + JSON_HINT}
        fn = {"gemini": self._gemini_req, "anthropic": self._anthropic_req}.get(self.provider, self._openai_req)
        while True:
            r = fn(messages, json_mode, max_tokens, temperature, stream)
            if r.status_code < 400:
                self._rejected = None
                return r
            detail = self._error_detail(r)
            r.close()
            if r.status_code in (400, 404) and _MODEL_GONE.search(detail) and self._advance_model():
                continue
            self.last_error = f"{self._info.get('label', self.provider)}: {detail}"
            if r.status_code in (401, 403) or (r.status_code == 400 and _KEY_BAD.search(detail)):
                self._rejected = (self.provider, self.key())
            raise RuntimeError(self.last_error)

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
            elif provider == "anthropic":
                if d.get("type") == "error":                 # e.g. overloaded mid-stream
                    raise RuntimeError("Anthropic Claude: " + ((d.get("error") or {}).get("message") or "stream error"))
                delta = d.get("delta") or {}
                if d.get("type") == "content_block_delta" and delta.get("type") == "text_delta" and delta.get("text"):
                    yield delta["text"]
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
        if provider == "anthropic":
            contents = d.get("content") or []
            return "".join(c.get("text", "") for c in contents if c.get("type") == "text")
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
        if mode == "cloud" and cloud_ok and self.cloud.configured() and not self.cloud.key_rejected():
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
