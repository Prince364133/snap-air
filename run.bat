@echo off
rem Starts the Snap Air HUD. The HUD launches the Python engine itself
rem (logs: %APPDATA%\SnapAir\engine.log) and stops it when you quit.
rem Debug mode: "run.bat debug" runs the engine in its own console window.
set ELECTRON_RUN_AS_NODE=
if /I "%1"=="debug" (
    set SNAP_AIR_EXTERNAL_ENGINE=1
    start "Snap-Air Engine" /D "%~dp0engine" .venv\Scripts\python.exe main.py
)
start "Snap-Air App" /D "%~dp0app" /MIN cmd /c npm start
