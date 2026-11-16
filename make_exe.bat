@echo off
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /out:SmashWatcher.exe launcher.cs
if exist SmashWatcher.exe (echo Built SmashWatcher.exe. Keep it in this folder.) else (echo Build failed. Use run_watcher.bat instead.)
pause
