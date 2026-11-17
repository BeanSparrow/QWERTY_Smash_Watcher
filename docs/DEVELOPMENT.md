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
    Digits.ps1              Reads short numbers by digit shape; learns shapes from values the OCR reads.
    StatsReader.ps1         Trigger detection, per-frame parsing of the stats panels, and the first page.
    Recorder.ps1            Combines frames by voting; builds the review table (survival, placement).
    Output.ps1              Sheet rows, CSV, and the POST to the Apps Script web app.
    Updater.ps1             GitHub Releases check, download, install, restart.
  UI\
    MainWindow.ps1          Tabs, settings binding, the 1-second watch/record loop.
    ReviewWindow.ps1        Post-match approval grid.
    RegionPicker.ps1        Snipping-Tool-style "Set region".
config\stats.txt            Stat labels in on-screen order ("Label" or "Label|unit").
config\characters.txt       Fighter names as the results screen shows them.
config\digits.txt           Digit-shape starter set (built by tools\learn_digits.ps1).
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

`test_reader.ps1` also takes real screenshots or `local\samples\*.png` from Ken, and several images separated by commas (combined like one recording). Add `-Dump` to see every word the OCR read with its position. In its output, `?` marks cells the review window shows in yellow.

Real captures from Ken live in `local\samples\ken\` (not in git). Screenshots pasted in chat arrive as WebP; convert them with:

```bash
powershell -ExecutionPolicy Bypass -File tools/convert_image.ps1 -In shot.webp -Out local/samples/ken/shot.png
```

### Scoring against real matches

Each `local\samples\match_*` folder can hold a `truth.json`: the true values, typed by hand from that match's frames. Then this replays the saved frames through the reader and grades every cell:

```bash
powershell -ExecutionPolicy Bypass -File tools/score_match.ps1 -Detail
```

The grades are `right`, `flagged-right` (yellow but correct), `WRONG` (wrong and not yellow, the one that must stay at 0), `flagged-wrong` and `missed`. Run it before every release. Use `-Starter <file>` to score with a digit starter set built *without* that match, for an honest number.

| Release | right | yellow-right | WRONG | yellow-wrong | missed |
|---|---|---|---|---|---|
| 5.0.4 | 90 | 10 | 2 | 6 | 30 |
| 5.0.5 (cross-tested) | 127 | 9 | 0 | 0 | 2 |

### Digit shapes

`config\digits.txt` is the starter set of digit shapes (`src\Core\Digits.ps1`, `Native.FindGlyphs`). Rebuild it after adding real matches:

```bash
powershell -ExecutionPolicy Bypass -File tools/learn_digits.ps1
```

On 168 known values, shape reading was 167 right and 0 wrong (with 1 not read). Very clear matches count as read; likely ones are shown yellow.

### What the real stats screen looks like (from Ken's samples)

- One panel per player, edge to edge with 4 players and with a gap with 2. Labels sit on dark bars, and each **value is on the line below its label**, right-aligned.
- KOs and Falls are stock icons on this screen, not numbers.
- Above the list: the character name (large, may wrap to two lines), "P1" plus the player tag ("Player 4"), and a big placement digit, which the OCR doesn't read.
- Each panel ends in an "(A) OK" button. Replays add "Next Replay", a countdown and "(B) Quit" down the middle.
- Windows OCR skips short lone numbers. For a visible but empty value line the reader tries digit shapes, then OCR on an enlarged crop. It never guesses.
- **First page** (real end screens, not replays): "Out at" (`---` or `m:ss`), KOs, Falls and SDs as large numbers on the label's row. Only the left panel has labels, and Falls/SDs are negative. The recorder keeps these frames and reads them at the end, using panel positions from the list pages (`Read-SummaryPage`). The time digits are bolder, so shape-read times are yellow.
- Character names snap to `config\characters.txt`.

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
