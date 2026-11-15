# PyInstaller spec for the Snapy engine (one folder, no Python install needed).
# Build:  .venv\Scripts\python -m PyInstaller snapy-engine.spec --noconfirm
import os
from PyInstaller.utils.hooks import collect_all, collect_submodules

datas, binaries, hiddenimports = [], [], []
for pkg in ("mediapipe", "faster_whisper", "ctranslate2", "onnxruntime", "kokoro_onnx", "espeakng_loader",
            "phonemizer", "language_tags", "segments", "csvw", "sounddevice", "_sounddevice_data", "soundcard",
            "tokenizers", "cv2"):
    try:
        d, b, h = collect_all(pkg)
        datas += d
        binaries += b
        hiddenimports += h
    except Exception as e:
        print("skip", pkg, e)

hiddenimports += collect_submodules("src") + ["pyautogui", "pyperclip", "pygetwindow", "pymsgbox", "pytweening",
                                              "pyscreeze", "mouseinfo", "websockets.legacy", "winreg"]
datas += [("src/vision/hand_landmarker.task", "src/vision")]

a = Analysis(
    ["main.py"],
    pathex=["."],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=["playwright", "tkinter", "IPython", "pytest", "PyInstaller"],   # mediapipe needs matplotlib
    noarchive=False,
)
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
