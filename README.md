# Smash Watcher

Watches your Super Smash Bros. Ultimate video. When the post-match stats screen comes up, it reads every player's stats, shows them to you in a review window, and, only after you approve them, adds them to a Google Sheet.

It needs nothing but Windows 10 or 11: no Python, no installs.

## First-time setup

1. **Unzip into a new folder.** If you had an older version, copy your old `settings.json` into this folder's `local` folder, or just paste your Google link again on the Setup tab.
2. **Make the app icon (optional).** Double-click `launcher\make_exe.bat`. It builds `SmashWatcher.exe` in the main folder. Otherwise, start it with `Start Smash Watcher.bat`.
3. **Show the game in a projector window.** In OBS or Streamlabs, right-click the game source (or the preview) and pick **Windowed Projector**. Make it at least about 1000 pixels wide. It can sit behind other windows, but it can't be minimized.
4. **Pick it as the source.** On the **Run** tab, choose `Window: ... Projector ...` from the **Source** list. A preview shows what the app sees.
5. **Connect Google Sheets** (see below), or skip it and use **Copy** or **Save to CSV** in the review window.

## Every match

1. Press **Start**. The app checks the video once a second.
2. When stat names (KOs, Falls, Damage Given...) show up, it records for 20 seconds. Scroll through the stats screen during that time so it sees every row.
3. A **review window** opens with a column per player. Fix anything that's wrong (pink rows weren't read), then:
   - **Send to Google Sheets**
   - **Copy** (paste into the sheet yourself)
   - **Save to CSV file only**
   - **Discard**
4. Pressing **Stop** during the recording ends it early and still opens the review window with what was read.

## Tabs

- **Run:** Start, Stop, source, preview, and the log.
- **Detection:** what starts a recording (stat names on screen, plus optional extra words), how long to record, and the image boost. **Test now** reads the current frame and says what it found. **Save sample** saves the picture and the text it read to `local\samples`. Send those when something reads wrong.
- **Stats:** tick the stats you want. Unticked stats stay blank, so sheet columns never move.
- **Setup:** Google Sheets link, updates, and a button to open your data folder.

## How the stats are read

- Each player panel is a column, left to right.
- **Character** is the big name at the top of each panel.
- **Survival time** is the seconds until that player was knocked out. A player who was never knocked out gets the longest time anyone lasted, which is the match length.
- **Placement** is read from the screen when possible. Otherwise it's worked out from survival time, with never knocked out counting as 1st.
- Values are stored as plain numbers. The units are in the column headers.

## Google Sheets

1. Open your Google Sheet and click **Extensions > Apps Script**. It has to be opened from the sheet; a project made at script.google.com won't work.
2. Delete everything in the editor and paste in all of `google\apps_script.gs`. The **Show the script to paste** button on the Setup tab opens it for you. Click save.
3. Click **Deploy > New deployment**, click the gear, and choose **Web app**.
4. Set **Execute as: Me** and **Who has access: Anyone**, then click **Deploy**.
5. Click **Authorize access**, choose your account, then **Advanced > Go to (project) > Allow**.
6. Copy the **Web app URL** (it ends in `/exec`) into the Setup tab and press **Test connection**. A `Smash Matches` tab with headers appears in your sheet.

If it fails, the log says what Google answered. Common fixes:
- **Access isn't "Anyone":** redeploy with it set.
- **Script edited after deploying:** go to **Deploy > Manage deployments > pencil > Version: New version > Deploy**.
- **URL ends in `/dev`:** use the `/exec` one.

## Updates

**Setup > Check for updates.** The app also checks quietly when it starts. Updating keeps your settings, results and samples (everything in `local`), backs up the old version to `local\backup`, and restarts. If an update changes the Google script, the app tells you to paste it again.

## Your files (`local` folder)

| File | What it is |
|---|---|
| `settings.json` | Your settings, including the Google link |
| `results_matches.csv` | Every match you sent or saved |
| `samples\` | Pictures and text from Save sample |
| `error.log` | Details if the app crashes |
