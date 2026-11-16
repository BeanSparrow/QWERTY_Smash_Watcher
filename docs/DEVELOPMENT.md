# Development notes

## Layout

```
SmashWatcher.ps1            Entry point. Loads src\ and opens the main window.
VERSION                     App version; the updater compares it to the latest GitHub release tag.
src\
  Bootstrap.ps1             Loads Native.cs and every Core module. Shared by the app and tools\.
  Native\Native.cs          C# helpers compiled at startup: window list/capture, OCR image prep, edit distance.
  Core\                     No UI code. Safe to load headless.
    Paths.ps1               Folder and file locations; moves pre-v5 user files into local\.
    Log.ps1                 Log() goes to the window's log box, or the console in tools.
    Config.ps1              $Cfg settings (local\settings.json) and the stat list (config\stats.txt).
    Ocr.ps1                 Windows OCR wrapper; Get-OcrImage enlarges + contrast-stretches frames.
    Capture.ps1             Sources: app window (PrintWindow), screen region, whole screen.
    StatsReader.ps1         Trigger detection and per-frame parsing of the stats panels.
    Recorder.ps1            Combines frames by voting; builds the review table (survival, placement).
    Output.ps1              Sheet rows, CSV, and the POST to the Apps Script web app.
    Updater.ps1             GitHub Releases check, download, install, restart.
  UI\
    MainWindow.ps1          Tabs, settings binding, the 1-second watch/record loop.
    ReviewWindow.ps1        Post-match approval grid.
    RegionPicker.ps1        Snipping-Tool-style "Set region".
config\stats.txt            Stat labels in on-screen order ("Label" or "Label|unit").
google\apps_script.gs       Receiver pasted into the Google Sheet.
launcher\                   SmashWatcher.exe source, make_exe.bat, and "Start Smash Watcher.bat" (console start, for errors).
tools\                      Developer scripts (not shipped).
local\                      User data. Gitignored, never shipped, never touched by updates.
```

## Conventions

- PowerShell 5.1 (what ships with Windows). C# in `Native.cs` must compile with the built-in C# 5 compiler, so it can't use `$"..."`, `?.` or `=>` members.
- Functions that return lists return them plainly (`return $list`), and callers always wrap with `@(...)`. Never use `return , $x`. Mixing the two styles nests arrays, which caused the old "System.Object[]" bug.
- Core modules must not touch UI controls, so `tools\test_reader.ps1` can run them headless.
- Everything the user owns lives in `local\`.

## Testing without the game

```bash
powershell -ExecutionPolicy Bypass -File tools/make_fake_stats_screen.ps1 -Out local/fake_0.png -FirstRow 0
powershell -ExecutionPolicy Bypass -File tools/test_reader.ps1 -Image local/fake_0.png
```

`test_reader.ps1` also takes real screenshots or `local\samples\*.png` from Ken, and several images separated by commas (combined like one recording). Add `-Dump` to see every word the OCR read with its position.

## Releasing an update to Ken

1. Bump `VERSION` (for example `5.0.1`) and commit.
2. Build the zip. The script parse-checks every `.ps1` first.
   ```bash
   powershell -ExecutionPolicy Bypass -File tools/make_release.ps1
   ```
3. Tag and publish. The tag must match `VERSION`, with a leading `v`.
   ```bash
   gh release create v5.0.1 dist/SmashWatcher_v5.0.1.zip --title "v5.0.1" --notes "What changed"
   ```
4. Ken's app sees it the next time it starts (or when he clicks Check for updates). The release notes are shown to him before he updates.

The updater only reads published releases, so pushing commits never reaches Ken by itself. It refuses to run in a folder that has `.git`, so it can't overwrite your checkout.
