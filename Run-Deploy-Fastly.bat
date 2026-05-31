@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy-Fastly-Windows.ps1"
pause
