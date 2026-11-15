"""Minimal Piper (VITS) voice runner: espeak-ng phonemes -> ids -> ONNX -> audio.

Uses the onnxruntime + espeak-ng (via phonemizer/espeakng_loader) that Kokoro
already ships, so no extra runtime. Piper voices are native-speaker recordings,
which is why they sound far more native for Indian languages than a multilingual
English-first model.

License note: each *voice* has its own license (taken from its MODEL_CARD).
COMMERCIAL=True voices (CC0 / CC-BY / CC-BY-SA / MIT data) may be used in a sold
product with attribution. COMMERCIAL=False voices (CC BY-NC-SA, IIT Madras
IndicTTS licence) are for personal use only: Snapy never uses them unless the
user turns on "personal-use voices", and they are downloaded by the user from
Hugging Face, never shipped in the installer.
"""
import json
import os
import threading

import numpy as np

_lock = threading.Lock()
_backends = {}

# Piper voices in rhasspy/piper-voices: (name, path, label, commercial_ok, data licence)
CATALOG = {
    "hi": [("hi_IN-priyamvada-medium", "hi/hi_IN/priyamvada/medium", "Priyamvada (female)", False, "CC BY-NC-SA 4.0"),
           ("hi_IN-pratham-medium", "hi/hi_IN/pratham/medium", "Pratham (male)", False, "CC BY-NC-SA 4.0"),
           ("hi_IN-rohan-medium", "hi/hi_IN/rohan/medium", "Rohan (male)", False, "IIT Madras IndicTTS (non-commercial)")],
    "te": [("te_IN-padmavathi-medium", "te/te_IN/padmavathi/medium", "Padmavathi (female)", True, "CC-BY-4.0 (AI4Bharat IndicVoices-R)"),
           ("te_IN-venkatesh-medium", "te/te_IN/venkatesh/medium", "Venkatesh (male)", True, "CC-BY-4.0 (AI4Bharat IndicVoices-R)"),
           ("te_IN-maya-medium", "te/te_IN/maya/medium", "Maya (female)", False, "IIT Madras IndicTTS (non-commercial)")],
    "ml": [("ml_IN-meera-medium", "ml/ml_IN/meera/medium", "Meera (female)", False, "IndicTTS corpus (non-commercial)"),
           ("ml_IN-arjun-medium", "ml/ml_IN/arjun/medium", "Arjun (male)", False, "IndicTTS corpus (non-commercial)")],
    "mr": [("mr_IN-google-medium", "mr/mr_IN/google/medium", "Marathi (Google)", True, "CC-BY-SA 4.0 (OpenSLR 64)")],
    "bn": [("bn_BD-google-medium", "bn/bn_BD/google/medium", "Bengali (Google)", True, "CC-BY-SA 4.0 (OpenSLR 37) + CMU")],
    "ne": [("ne_NP-chitwan-medium", "ne/ne_NP/chitwan/medium", "Chitwan", True, "CC0"),
           ("ne_NP-google-medium", "ne/ne_NP/google/medium", "Nepali (Google)", True, "CC-BY-SA 4.0 (OpenSLR 43)")],
    "ur": [("ur_PK-fasih-medium", "ur/ur_PK/fasih/medium", "Fasih (male)", True, "MIT")],
}


def entry(lang, name):
    return next((e for e in CATALOG.get(lang, []) if e[0] == name), None)
from src import appdata  # noqa: E402

BASE_URL = appdata.get("native_voices.base_url")


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
