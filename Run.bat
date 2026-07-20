@echo off
REM Double-click launcher. Runs the PowerShell script next to this file with
REM ExecutionPolicy bypassed (so a downloaded script isn't blocked). The script
REM elevates itself to Administrator via UAC.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0msi-mode-utility.ps1"
pause
