@echo off
rem Starts Smash Watcher with a console window, so any startup error stays visible.
rem SmashWatcher.exe does the same without the console.
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0..\SmashWatcher.ps1"
if errorlevel 1 pause
