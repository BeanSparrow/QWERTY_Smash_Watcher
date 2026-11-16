# Smash Watcher v4 (no installs)

Needs only Windows 10/11. It reads a video source (webcam, OBS Virtual Camera, capture card), waits for the end screen, reads the stats table, and shows it to you in a review window. **Nothing is sent anywhere until you click Send.**

## 1. Run

Double-click `run_watcher.bat`, or run `make_exe.bat` once to build `SmashWatcher.exe` (keep it in this folder).

## 2. Pick the video source (Run tab)

The dropdown lists your cameras, a **Screen region**, and your monitors, and shows one preview frame when you pick one. Nothing is captured or kept open until you press Start (or Test now / Save sample), and the source is released again when you stop.
- **Camera** entries use Windows' camera API. Only one app can use a capture card or webcam at a time, and some virtual cameras (notably OBS Virtual Camera, which is DirectShow-only) can't be opened this way.
- **Screen region** (works with anything): show your video on screen, for example in an OBS projector window (right-click the OBS preview > Windowed Projector or Fullscreen Projector). Press **Set region**, keep the mouse on that monitor, wait for the beep, and drag a box around just the video. The app then reads that box, and doesn't care where the video comes from.
- If Windows blocks a camera: **Settings > Privacy > Camera > Let desktop apps access your camera**.

## 3. Detection tab

Two triggers, either can fire it:
- **Text:** words on the end/stats screen (one per line). Fires when N of them are on screen at once. The stat labels themselves (Damage Given, Falls...) work well here.
- **Images:** snip any number of reference images from the live video. Any one matching fires it.
- **Test now** reports what the current frame matches and how the stats table reads (players found, names, placements, values). **Save sample** writes the frame and an OCR dump to `samples\`.

## 4. Stats tab

Tick the stats to record. `stats.txt` lists them in on-screen order, top to bottom, one per line, with an optional unit after a `|` (for example `Damage Given|%`). The reader uses that order: if a label is misread or missed, its row is found by its position between the labels that were read.

Every stat always keeps its own column in the sheet. Unticked stats stay blank, so your columns never shift. If you add or remove lines in `stats.txt`, start a new sheet tab (or clear the header row), because the columns change.

## 5. How a match is read

- Each **column on screen is a player**, left to right (P1, P2, ...).
- From the top of each column it reads **name, placement (1st, 2nd...), and player number**, plus the time they were knocked out.
- **Survival time** is the seconds until that player was out. A player showing `---` (never out) gets the longest time anyone was out, which is when the match ended. That way the stat is a number for everybody. Placement still tells you who won.
- The KOs, Falls and SDs rows are read once from the number screen. The icon screen has no numbers, so it's ignored.
- Values are stored as plain numbers without % or units (the units are in the column headers).

## 6. Review window

When the recording ends, a window shows a grid like the game screen: rows are Name, Placement, Player number, Survival time, then each ticked stat, with a column per player, plus the frame it was read from. Click any cell to fix it. Rows that couldn't be read are pink. Then:
- **Send to Google Sheets:** one sheet row per player. If it fails, the window stays open so nothing is lost.
- **Copy:** copies the rows so you can paste them straight into the sheet (no Google setup needed).
- **Save to CSV file only:** appends to `results_matches.csv`.
- **Discard:** throws them away.

## 7. Google Sheets (optional if you use Copy)

1. Open your Google Sheet. Click **Extensions > Apps Script**.
2. Select everything in the editor, delete it, paste in all of `apps_script.gs`, and click save.
3. Click **Deploy > New deployment**. Click the gear next to "Select type" and choose **Web app**.
4. Set **Execute as: Me** and **Who has access: Anyone**. Click **Deploy**.
5. Click **Authorize access**, choose your account, then **Advanced > Go to (project name) > Allow**.
6. Copy the **Web app URL** (ends in `/exec`) into `settings.json` as `webhook_url`.
7. Check it: open the URL in a browser. You should see "Smash Watcher script is live." Then press **Test Google Sheets connection** on the Stats tab. A `Smash Matches` tab with headers appears.

Common problems:
- Browser shows a sign-in page: access isn't set to **Anyone**. Redeploy with it set.
- URL ends in `/dev`: use the `/exec` URL from **Deploy > Manage deployments**.
- You edited the script after deploying: **Deploy > Manage deployments > pencil > Version: New version > Deploy**.
- Open the editor from the sheet itself (Extensions > Apps Script), not as a separate project.

## Sheet columns (tab `Smash Matches`)

`detected_at` (same for every player in a match), `player_no`, `name`, `placement`, `survival_time_s`, then all 25 stats with units in the headers.

## If something goes wrong

Errors go to `error.log`. App settings save automatically to `settings.json`. If a stat reads wrong, press **Save sample** on the stats screen and send me the `.png` and `.txt`.
