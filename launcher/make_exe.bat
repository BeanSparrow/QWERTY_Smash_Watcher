@echo off
rem Builds SmashWatcher.exe in the app's top folder, using the C# compiler that ships with Windows.
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /out:..\SmashWatcher.exe launcher.cs
if exist ..\SmashWatcher.exe (echo Built SmashWatcher.exe in the Smash Watcher folder.) else (echo Build failed. Use "Start Smash Watcher.bat" in this folder instead.)
pause
