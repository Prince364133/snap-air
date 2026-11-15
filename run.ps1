# Starts the Snap Air HUD; the HUD launches and stops the Python engine.
# Use  .\run.ps1 -Debug  to run the engine in a visible console instead.
param([switch]$Debug)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Remove-Item env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
if ($Debug) {
    $env:SNAP_AIR_EXTERNAL_ENGINE = "1"
    Start-Process -FilePath "$ScriptDir\engine\.venv\Scripts\python.exe" -ArgumentList "main.py" -WorkingDirectory "$ScriptDir\engine"
}
Start-Process -FilePath "cmd.exe" -ArgumentList "/c npm start" -WorkingDirectory "$ScriptDir\app" -WindowStyle Minimized
