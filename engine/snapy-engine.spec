# PyInstaller spec for the Snapy engine (one folder, no Python install needed).
# Build:  .venv\Scripts\python -m PyInstaller snapy-engine.spec --noconfirm
import os
from PyInstaller.utils.hooks import collect_all, collect_submodules

datas, binaries, hiddenimports = [], [], []
for pkg in ("mediapipe", "faster_whisper", "ctranslate2", "onnxruntime", "kokoro_onnx", "espeakng_loader",
            "phonemizer", "language_tags", "segments", "csvw", "sounddevice", "_sounddevice_data", "soundcard",
            "tokenizers", "cv2", "winrt", "uiautomation", "comtypes"):
    try:
        d, b, h = collect_all(pkg)
        datas += d
        binaries += b
        hiddenimports += h
    except Exception as e:
        print("skip", pkg, e)

hiddenimports += collect_submodules("src") + ["pyautogui", "pyperclip", "pygetwindow", "pymsgbox", "pytweening",
                                              "pyscreeze", "mouseinfo", "websockets.legacy", "winreg"]
datas += [("src/vision/hand_landmarker.task", "src/vision"), ("src/data/app.json", "src/data")]
# Shared core (prompts, intents, rules, i18n...) -> <bundle>/core, found by src/core_loader.py via sys._MEIPASS.
# Conformance goldens are test data, not needed at runtime.
_CORE = os.path.join("..", "core")
for _dir, _subdirs, _files in os.walk(_CORE):
    _rel = os.path.relpath(_dir, _CORE)
    if _rel.split(os.sep)[0] == "conformance":
        continue
    for _f in _files:
        datas.append((os.path.join(_dir, _f), os.path.normpath(os.path.join("core", _rel))))

a = Analysis(
    ["main.py"],
    pathex=["."],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    # "av" (PyAV/FFmpeg, 65 MB) is only used by faster-whisper to open audio files; Snapy passes
    # microphone samples directly and installs a stub at runtime (voice_listener.py)
    excludes=["playwright", "tkinter", "IPython", "pytest", "PyInstaller", "comtypes.test", "av"],   # mediapipe needs matplotlib
    noarchive=False,
)
# OpenCV's FFmpeg plugin (31 MB) is only for video files/streams; the webcam uses DirectShow/MSMF
a.binaries = [b for b in a.binaries if "opencv_videoio_ffmpeg" not in b[0]]
a.datas = [d for d in a.datas if "opencv_videoio_ffmpeg" not in d[0] and not d[0].startswith("av.libs")]
a.binaries = [b for b in a.binaries if not b[0].startswith("av.libs")]
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="snapy-engine",
    console=True,              # stdout goes to %APPDATA%\SnapAir\engine.log (Electron hides the window)
    icon=os.path.join("..", "app", "build", "icon.ico"),
    upx=False,
)
coll = COLLECT(exe, a.binaries, a.datas, name="snapy-engine", upx=False)
