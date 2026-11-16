@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0smash_watcher.ps1"
if errorlevel 1 pause
