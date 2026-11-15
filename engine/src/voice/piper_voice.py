"""Minimal Piper (VITS) voice runner: espeak-ng phonemes -> ids -> ONNX -> audio.

Uses the onnxruntime + espeak-ng (via phonemizer/espeakng_loader) that Kokoro
already ships, so no extra runtime. Piper voices are native-speaker recordings,
which is why they sound far more native for Indian languages than a multilingual
English-first model.

License note: the Piper *engine* is MIT, but each *voice* has its own license.
The hi_IN voices are trained on non-commercial datasets (CC BY-NC-SA 4.0 /
IITM IndicTTS) — fine for personal use, not for a sold product.
"""
import json
import os
import threading

import numpy as np

_lock = threading.Lock()
_backends = {}

# Piper voices available in rhasspy/piper-voices (verified via the HF API)
CATALOG = {
    "hi": [("hi_IN-priyamvada-medium", "hi/hi_IN/priyamvada/medium", "Priyamvada (female)"),
           ("hi_IN-pratham-medium", "hi/hi_IN/pratham/medium", "Pratham (male)"),
           ("hi_IN-rohan-medium", "hi/hi_IN/rohan/medium", "Rohan (male)")],
    "te": [("te_IN-padmavathi-medium", "te/te_IN/padmavathi/medium", "Padmavathi (female)"),
           ("te_IN-venkatesh-medium", "te/te_IN/venkatesh/medium", "Venkatesh (male)"),
           ("te_IN-maya-medium", "te/te_IN/maya/medium", "Maya (female)")],
    "ml": [("ml_IN-meera-medium", "ml/ml_IN/meera/medium", "Meera (female)"),
           ("ml_IN-arjun-medium", "ml/ml_IN/arjun/medium", "Arjun (male)")],
    "mr": [("mr_IN-google-medium", "mr/mr_IN/google/medium", "Marathi (Google)")],
    "bn": [("bn_BD-google-medium", "bn/bn_BD/google/medium", "Bengali (Google)")],
    "ne": [("ne_NP-chitwan-medium", "ne/ne_NP/chitwan/medium", "Chitwan")],
    "ur": [("ur_PK-fasih-medium", "ur/ur_PK/fasih/medium", "Fasih (male)")],
}
BASE_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/main/"


def _espeak_backend(lang):
    with _lock:
        if lang in _backends:
            return _backends[lang]
        import espeakng_loader
        from phonemizer.backend import EspeakBackend
        from phonemizer.backend.espeak.wrapper import EspeakWrapper
        EspeakWrapper.set_library(espeakng_loader.get_library_path())
        os.environ.setdefault("ESPEAK_DATA_PATH", espeakng_loader.get_data_path())
        try:
            EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
        except AttributeError:
            pass
        b = EspeakBackend(lang, preserve_punctuation=True, with_stress=True, language_switch="remove-flags")
        _backends[lang] = b
        return b


class PiperVoice:
    def __init__(self, onnx_path):
        import onnxruntime as ort
        with open(onnx_path + ".json", encoding="utf-8") as f:
            self.config = json.load(f)
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = max(1, min(4, (os.cpu_count() or 4) // 4))
        self.session = ort.InferenceSession(onnx_path, sess_options=opts, providers=["CPUExecutionProvider"])
        self.sample_rate = self.config["audio"]["sample_rate"]
        self.id_map = self.config["phoneme_id_map"]
        self.lang = self.config["espeak"]["voice"]
        inf = self.config.get("inference", {})
        self.scales = [inf.get("noise_scale", 0.667), inf.get("length_scale", 1.0), inf.get("noise_w", 0.8)]

    def _ids(self, phonemes):
        pad = self.id_map["_"][0]
        ids = [self.id_map["^"][0], pad]
        for ch in phonemes:
            if ch in self.id_map:
                ids.append(self.id_map[ch][0])
                ids.append(pad)
        ids.append(self.id_map["$"][0])
        return ids

    def synthesize(self, text, speed=1.0):
        backend = _espeak_backend(self.lang)
        phon = backend.phonemize([text], strip=True)[0]
        ids = self._ids(phon)
        if len(ids) < 4:
            return np.zeros(0, np.float32), self.sample_rate
        scales = np.array([self.scales[0], self.scales[1] / max(0.5, speed), self.scales[2]], dtype=np.float32)
        audio = self.session.run(None, {
            "input": np.array([ids], dtype=np.int64),
            "input_lengths": np.array([len(ids)], dtype=np.int64),
            "scales": scales,
        })[0].squeeze().astype(np.float32)
        peak = float(np.max(np.abs(audio))) or 1.0
        return audio * min(1.0, 0.9 / peak), self.sample_rate


def voice_path(folder, name):
    return os.path.join(folder, f"{name}.onnx")


def download(folder, name, rel):
    import requests
    os.makedirs(folder, exist_ok=True)
    for ext in (".onnx", ".onnx.json"):
        dest = os.path.join(folder, name + ext)
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            continue
        with requests.get(BASE_URL + rel + "/" + name + ext, stream=True, timeout=(10, 300)) as r:
            r.raise_for_status()
            with open(dest + ".part", "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
        os.replace(dest + ".part", dest)
    return voice_path(folder, name)
