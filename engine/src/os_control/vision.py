"""Screen understanding, layers 2-4 (used only when the accessibility tree can't answer).

  2. Windows OCR      built into Windows 10/11; free, local, ~0.3 s. Finds any visible text.
  3. Local vision AI  a small vision-language model in Ollama (Qwen3.5 4B / Qwen2.5-VL 3B /
                      Gemma 3 4B…), only installed when this PC can run it. Finds icons,
                      thumbnails and anything without text; answers "what's in this picture".
  4. Cloud vision     Gemini / OpenAI with the user's own key, only when they chose cloud/auto.

Screenshots never leave the PC unless tier 4 is enabled. All tiers return screen
coordinates, so the same click/type actions work on whatever they find.
"""
import base64
import io
import json
import re
import time

import requests

from src import appdata
from src.os_control.screen import Element

OLLAMA = appdata.get("ollama.host")
# Vision-capable Ollama models, best first (from src/data/app.json)
LOCAL_VISION_MODELS = appdata.get("vision.local_models", [])
MAX_SIDE = int(appdata.get("vision.max_image_side", 1024))
POINT_PROMPT = ("You are a GUI grounding model. Find the UI element the user means in this screenshot and "
                "answer ONLY JSON {\"found\": true|false, \"x\": 0-1000, \"y\": 0-1000, \"label\": \"short name\"} "
                "where x,y is the element's centre as a fraction of image width/height times 1000.")


# ------------------------------------------------------------------ capture
def capture(rect=None, max_side=None):
    """Screenshot of `rect` (screen coords; whole virtual desktop if None).
    Returns (PIL image, (left, top, scale)) so model coords map back to the screen."""
    from PIL import ImageGrab
    img = ImageGrab.grab(bbox=tuple(rect) if rect else None, all_screens=rect is None)
    left, top = (rect[0], rect[1]) if rect else (0, 0)
    scale = 1.0
    if max_side and max(img.size) > max_side:
        scale = max_side / max(img.size)
        img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))))
    return img, (left, top, scale)


def _png(img):
    b = io.BytesIO()
    img.convert("RGB").save(b, "PNG", optimize=True)
    return b.getvalue()


# ------------------------------------------------------------------ tier 2: OCR
def ocr_available():
    try:
        from winrt.windows.media.ocr import OcrEngine
        return OcrEngine.try_create_from_user_profile_languages() is not None
    except Exception:
        return False


def ocr(rect=None, img=None, origin=(0, 0, 1.0)):
    """Text on screen as Elements (one per line, plus single words for short labels)."""
    import asyncio
    from winrt.windows.graphics.imaging import BitmapPixelFormat, SoftwareBitmap
    from winrt.windows.media.ocr import OcrEngine
    from winrt.windows.storage.streams import DataWriter

    if img is None:
        img, origin = capture(rect)
    left, top, scale = origin
    rgba = img.convert("RGBA")
    # OCR is most accurate around 1-2x; upscale small captures
    up = 2 if max(rgba.size) < 1200 else 1
    if up > 1:
        rgba = rgba.resize((rgba.width * up, rgba.height * up))
    r, g, b, a = rgba.split()
    from PIL import Image
    bgra = Image.merge("RGBA", (b, g, r, a)).tobytes()
    writer = DataWriter()
    writer.write_bytes(bgra)
    bmp = SoftwareBitmap(BitmapPixelFormat.BGRA8, rgba.width, rgba.height)
    bmp.copy_from_buffer(writer.detach_buffer())
    engine = OcrEngine.try_create_from_user_profile_languages()
    if engine is None:
        return []

    async def run():
        return await engine.recognize_async(bmp)

    result = asyncio.run(run())
    f = 1.0 / (scale * up)
    out = []
    for line in result.lines:
        words = list(line.words)
        if not words:
            continue
        xs = [w.bounding_rect.x for w in words]
        ys = [w.bounding_rect.y for w in words]
        x2 = [w.bounding_rect.x + w.bounding_rect.width for w in words]
        y2 = [w.bounding_rect.y + w.bounding_rect.height for w in words]
        box = (int(left + min(xs) * f), int(top + min(ys) * f), int(left + max(x2) * f), int(top + max(y2) * f))
        out.append(Element(line.text, "TextControl", box, None, 0))
        if len(words) > 1:
            for w in words:
                br = w.bounding_rect
                out.append(Element(w.text, "TextControl", (int(left + br.x * f), int(top + br.y * f),
                                                           int(left + (br.x + br.width) * f),
                                                           int(top + (br.y + br.height) * f)), None, 1))
    return out


# ------------------------------------------------------------------ tier 3/4: vision models
def _parse_point(text):
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    if d.get("found") is False or d.get("x") is None or d.get("y") is None:
        return None
    x, y = float(d["x"]), float(d["y"])
    if x <= 1.0 and y <= 1.0:          # some models answer 0-1
        x, y = x * 1000, y * 1000
    if not (0 <= x <= 1000 and 0 <= y <= 1000):
        return None
    return x / 1000.0, y / 1000.0, str(d.get("label") or "")


def installed_local_model(settings=None):
    """The best vision model already in Ollama (never downloads by itself)."""
    want = (settings.get("vision_model") if settings else None) or ""
    try:
        names = [m["name"] for m in requests.get(OLLAMA + "/api/tags", timeout=2).json().get("models", [])]
    except Exception:
        return None
    for n in ([want] if want else []) + LOCAL_VISION_MODELS:
        if n and n in names:
            return n
    return None


def ask_local(model, prompt, img, max_tokens=120, timeout=120):
    import os
    r = requests.post(OLLAMA + "/api/chat", timeout=(5, timeout), json={
        "model": model, "stream": False, "think": False, "format": "json", "keep_alive": "2m",
        "options": {"temperature": 0, "num_predict": max_tokens, "num_thread": max(2, (os.cpu_count() or 4) // 2 - 1)},
        "messages": [{"role": "user", "content": prompt, "images": [base64.b64encode(_png(img)).decode()]}]})
    r.raise_for_status()
    return r.json()["message"]["content"]


def ask_cloud(cloud, prompt, img, max_tokens=200):
    """Gemini or OpenAI(-compatible) vision request with the user's key."""
    data = base64.b64encode(_png(img)).decode()
    if cloud.provider == "gemini":
        body = {"contents": [{"role": "user", "parts": [{"inline_data": {"mime_type": "image/png", "data": data}},
                                                        {"text": prompt}]}],
                "generationConfig": {"maxOutputTokens": max_tokens, "temperature": 0,
                                     "responseMimeType": "application/json"}}
        r = requests.post(f"https://generativelanguage.googleapis.com/v1beta/models/{cloud.model}:generateContent",
                          json=body, timeout=(6, 60), headers={"x-goog-api-key": cloud.key()})
        r.raise_for_status()
        return "".join(p.get("text", "") for p in r.json()["candidates"][0]["content"]["parts"])
    body = {"model": cloud.model, "max_tokens": max_tokens, "temperature": 0,
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64," + data}}]}]}
    r = requests.post(cloud.base_url + "/chat/completions", json=body, timeout=(6, 60),
                      headers={"Authorization": f"Bearer {cloud.key()}"})
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


class Vision:
    """Picks the cheapest available tier for each question."""

    def __init__(self, settings=None, cloud=None):
        self.settings = settings
        self.cloud = cloud
        self.last_tier = None

    def _s(self, k, d):
        v = self.settings.get(k) if self.settings else None
        return d if v is None else v

    def mode(self):
        return self._s("vision_mode", "auto")            # auto | local | off

    def cloud_ok(self):
        return (self.mode() == "auto" and self.cloud is not None and self._s("ai_provider", "auto") in ("auto", "cloud")
                and self.cloud.configured())

    def local_model(self):
        """Local vision runs automatically only with a GPU: on CPU a 4B vision model needs
        ~90 s per screenshot (measured). 'vision_local': auto | on (private but slow) | off."""
        if self.mode() == "off":
            return None
        pref = self._s("vision_local", "auto")
        if pref == "off":
            return None
        if pref == "auto":
            from src.brain.llm import hardware
            if hardware().get("gpu_vram", 0) < float(appdata.get("vision.min_gpu_vram_gb", 4)):
                return None
        return installed_local_model(self.settings)

    def status(self):
        local = installed_local_model(self.settings)
        return {"mode": self.mode(), "local_pref": self._s("vision_local", "auto"), "local_model": local,
                "local_active": bool(self.local_model()), "cloud": bool(self.cloud_ok()), "ocr": ocr_available()}

    def locate(self, query, rect):
        """Find `query` inside screen `rect` with OCR, then a vision model. Returns (Element, tier) or (None, why)."""
        from src.os_control import screen
        if self.mode() == "off":
            return None, "Screen vision is turned off in Settings."
        img, origin = capture(rect)
        # tier 2: OCR (text the accessibility tree didn't expose)
        try:
            words = ocr(img=img, origin=origin)
            el, why = screen.find(query, words)
            if el is not None and why == "name":
                self.last_tier = "ocr"
                return el, "ocr"
        except Exception as e:
            print("[Vision] OCR failed:", e)
        # tier 3/4: vision model pointing
        small, (left, top, scale) = capture(rect, max_side=MAX_SIDE)
        prompt = POINT_PROMPT + f"\nThe user wants: {query}"
        for tier, fn in (("local", lambda: ask_local(self.local_model(), prompt, small) if self.local_model() else None),
                         ("cloud", lambda: ask_cloud(self.cloud, prompt, small) if self.cloud_ok() else None)):
            try:
                t = time.time()
                answer = fn()
                if answer is None:
                    continue
                pt = _parse_point(answer)
                print(f"[Vision] {tier} answered in {time.time() - t:.1f}s: {answer[:120]}")
                if pt:
                    x = int(left + pt[0] * small.width / scale)
                    y = int(top + pt[1] * small.height / scale)
                    self.last_tier = tier
                    return Element(pt[2] or query, "VisionPoint", (x - 3, y - 3, x + 3, y + 3), None, 0), tier
            except Exception as e:
                print(f"[Vision] {tier} failed:", e)
        if not self.local_model() and not self.cloud_ok():
            return None, ("I couldn't find that. For icons and pictures I need a vision model: "
                          "install one in Settings → Screen vision, or add a cloud key.")
        return None, f"I couldn't find “{query}” on this screen."

    def describe(self, rect, question="Describe what is on this screen in 2 short sentences."):
        img, _ = capture(rect, max_side=MAX_SIDE)
        for tier, fn in (("local", lambda: ask_local(self.local_model(), question + ' Answer JSON {"answer": "..."}', img,
                                                     max_tokens=200) if self.local_model() else None),
                         ("cloud", lambda: ask_cloud(self.cloud, question + ' Answer JSON {"answer": "..."}', img)
                          if self.cloud_ok() else None)):
            try:
                a = fn()
                if a:
                    m = re.search(r"\{.*\}", a, re.S)
                    self.last_tier = tier
                    return (json.loads(m.group(0)).get("answer") if m else a).strip()
            except Exception as e:
                print(f"[Vision] describe via {tier} failed:", e)
        return None
