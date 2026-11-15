"""Copy offline models into the frozen engine so voice works on first launch
without a download: Whisper tiny.en (~75 MB) and the Kokoro voice (~120 MB)."""
import glob
import os
import shutil
import sys

import requests

DIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dist", "snapy-engine")
KOKORO_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"


def main():
    if not os.path.isdir(DIST):
        sys.exit("Build the engine first (PyInstaller).")
    # Whisper tiny.en from the Hugging Face cache (download it if missing)
    dest = os.path.join(DIST, "models", "faster-whisper-tiny.en")
    os.makedirs(dest, exist_ok=True)
    snap = glob.glob(os.path.expanduser("~/.cache/huggingface/hub/models--Systran--faster-whisper-tiny.en/snapshots/*"))
    if not snap:
        from faster_whisper import download_model
        src = download_model("tiny.en")
    else:
        src = snap[0]
    for f in os.listdir(src):
        shutil.copy(os.path.join(src, f), dest)
    # Kokoro voice
    kdest = os.path.join(DIST, "models", "kokoro")
    os.makedirs(kdest, exist_ok=True)
    local = os.path.join(os.environ.get("APPDATA", ""), "SnapAir", "models", "kokoro")
    for name in ("kokoro-v1.0.int8.onnx", "voices-v1.0.bin"):
        target = os.path.join(kdest, name)
        if os.path.exists(os.path.join(local, name)):
            shutil.copy(os.path.join(local, name), target)
        else:
            with requests.get(KOKORO_URL + name, stream=True, timeout=(10, 300)) as r:
                r.raise_for_status()
                with open(target, "wb") as fh:
                    for chunk in r.iter_content(1 << 20):
                        fh.write(chunk)
    print("models bundled into", os.path.join(DIST, "models"))


if __name__ == "__main__":
    main()
