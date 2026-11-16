@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SmashWatcher.ps1"
if errorlevel 1 pause
