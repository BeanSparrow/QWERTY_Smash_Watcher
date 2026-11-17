# The main window: Run, Detection, Stats and Setup tabs, plus the once-a-second watch loop.

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$UI = @{}
$script:State = @{
    Mode = 'idle'; Busy = $false; Streak = 0; Loading = $true
    Sources = @(); Rec = $null; LastErr = ''; ErrCount = 0
}

function New-Ctl($type, $x, $y, $w, $h, $text) {
    $c = New-Object $type
    $c.SetBounds($x, $y, $w, $h)
    if ($text -ne $null) { $c.Text = $text }
    return $c
}
function Set-Status([string]$text, [string]$color) { $UI.Status.Text = $text; $UI.Status.ForeColor = [System.Drawing.Color]::FromName($color) }

# ---------------------------------------------------------------- layout
function Build-MainWindow {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Smash Watcher v$AppVersion"; $form.ClientSize = New-Object System.Drawing.Size(464, 681); $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $UI.Form = $form

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.SetBounds(8, 8, 448, 665)
    $UI.TabRun = New-Object System.Windows.Forms.TabPage 'Run'
    $UI.TabDet = New-Object System.Windows.Forms.TabPage 'Detection'
    $UI.TabStats = New-Object System.Windows.Forms.TabPage 'Stats'
    $UI.TabSetup = New-Object System.Windows.Forms.TabPage 'Setup'
    foreach ($t in @($UI.TabRun, $UI.TabDet, $UI.TabStats, $UI.TabSetup)) { $tabs.TabPages.Add($t) }
    $form.Controls.Add($tabs)

    # ----- Run
    $UI.Status = New-Ctl System.Windows.Forms.Label 8 8 425 40 'Idle'
    $UI.Status.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold); $UI.Status.TextAlign = 'MiddleCenter'
    $UI.Detail = New-Ctl System.Windows.Forms.Label 8 48 425 34 ''
    $UI.Detail.ForeColor = [System.Drawing.Color]::Gray; $UI.Detail.Font = New-Object System.Drawing.Font('Segoe UI', 8.5); $UI.Detail.TextAlign = 'MiddleCenter'
    $UI.Start = New-Ctl System.Windows.Forms.Button 75 88 140 42 'Start'
    $UI.Start.BackColor = [System.Drawing.Color]::SeaGreen; $UI.Start.ForeColor = [System.Drawing.Color]::White; $UI.Start.FlatStyle = 'Flat'
    $UI.Stop = New-Ctl System.Windows.Forms.Button 225 88 140 42 'Stop'; $UI.Stop.Enabled = $false
    $UI.Stop.BackColor = [System.Drawing.Color]::Firebrick; $UI.Stop.ForeColor = [System.Drawing.Color]::White; $UI.Stop.FlatStyle = 'Flat'
    $lblSrc = New-Ctl System.Windows.Forms.Label 8 142 55 22 'Source'
    $UI.Source = New-Ctl System.Windows.Forms.ComboBox 62 138 212 26 $null; $UI.Source.DropDownStyle = 'DropDownList'; $UI.Source.DropDownWidth = 420
    $UI.Refresh = New-Ctl System.Windows.Forms.Button 280 137 68 28 'Refresh'
    $UI.Region = New-Ctl System.Windows.Forms.Button 352 137 82 28 'Set region'
    $UI.Preview = New-Ctl System.Windows.Forms.PictureBox 8 172 425 236 $null
    $UI.Preview.SizeMode = 'Zoom'; $UI.Preview.BackColor = [System.Drawing.Color]::Black
    $UI.Log = New-Ctl System.Windows.Forms.TextBox 8 416 425 210 $null
    $UI.Log.Multiline = $true; $UI.Log.ReadOnly = $true; $UI.Log.ScrollBars = 'Vertical'
    $UI.Log.Font = New-Object System.Drawing.Font('Consolas', 9)
    $UI.TabRun.Controls.AddRange(@($UI.Status, $UI.Detail, $UI.Start, $UI.Stop, $lblSrc, $UI.Source, $UI.Refresh, $UI.Region, $UI.Preview, $UI.Log))

    # ----- Detection
    $gTrig = New-Ctl System.Windows.Forms.GroupBox 8 6 425 268 'When to start recording'
    $UI.UseLabels = New-Ctl System.Windows.Forms.CheckBox 12 22 400 22 'Start when stat names (from the Stats tab) are on screen'
    $lblExtra = New-Ctl System.Windows.Forms.Label 12 50 400 18 'Extra trigger words (optional, one per line):'
    $UI.Extra = New-Ctl System.Windows.Forms.TextBox 12 70 400 70 $null; $UI.Extra.Multiline = $true; $UI.Extra.ScrollBars = 'Vertical'
    $lblNeed = New-Ctl System.Windows.Forms.Label 12 152 250 22 'Different names/words needed at once:'
    $UI.Need = New-Ctl System.Windows.Forms.NumericUpDown 270 148 60 26 $null; $UI.Need.Minimum = 1; $UI.Need.Maximum = 20
    $lblRow = New-Ctl System.Windows.Forms.Label 12 184 250 22 'Checks in a row before starting:'
    $UI.Row = New-Ctl System.Windows.Forms.NumericUpDown 270 180 60 26 $null; $UI.Row.Minimum = 1; $UI.Row.Maximum = 10
    $UI.Hits = New-Ctl System.Windows.Forms.Label 12 214 400 46 'Live: -'; $UI.Hits.ForeColor = [System.Drawing.Color]::DimGray
    $gTrig.Controls.AddRange(@($UI.UseLabels, $lblExtra, $UI.Extra, $lblNeed, $UI.Need, $lblRow, $UI.Row, $UI.Hits))

    $gRead = New-Ctl System.Windows.Forms.GroupBox 8 282 425 92 'Reading'
    $UI.Enhance = New-Ctl System.Windows.Forms.CheckBox 12 22 400 22 'Enlarge and boost contrast before reading (recommended)'
    $lblDur = New-Ctl System.Windows.Forms.Label 12 56 200 22 'Keep reading for (seconds):'
    $UI.Dur = New-Ctl System.Windows.Forms.NumericUpDown 210 52 70 26 $null; $UI.Dur.Minimum = 3; $UI.Dur.Maximum = 120
    $gRead.Controls.AddRange(@($UI.Enhance, $lblDur, $UI.Dur))

    $UI.Test = New-Ctl System.Windows.Forms.Button 8 384 205 34 'Test now (read this frame)'
    $UI.Sample = New-Ctl System.Windows.Forms.Button 219 384 214 34 'Save sample (image + text)'
    $lblTip = New-Ctl System.Windows.Forms.Label 8 426 425 60 'Tip: put the game on the stats screen and press Test now. It shows which stat names it can see and what it read for each player. Save sample writes the picture and the text it read to local\samples, which is the best thing to send when something reads wrong.'
    $lblTip.ForeColor = [System.Drawing.Color]::DimGray; $lblTip.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $UI.TabDet.Controls.AddRange(@($gTrig, $gRead, $UI.Test, $UI.Sample, $lblTip))

    # ----- Stats
    $lblStat = New-Ctl System.Windows.Forms.Label 8 8 425 36 'Tick the stats to record. Unticked stats stay blank in the sheet, so the columns never move. The list is config\stats.txt, in on-screen order.'
    $UI.StatList = New-Ctl System.Windows.Forms.CheckedListBox 8 48 425 470 $null; $UI.StatList.CheckOnClick = $true
    $UI.AllOn = New-Ctl System.Windows.Forms.Button 8 528 80 28 'All on'
    $UI.AllOff = New-Ctl System.Windows.Forms.Button 94 528 80 28 'All off'
    $UI.TabStats.Controls.AddRange(@($lblStat, $UI.StatList, $UI.AllOn, $UI.AllOff))

    # ----- Setup
    $gSheet = New-Ctl System.Windows.Forms.GroupBox 8 6 425 150 'Google Sheets'
    $lblUrl = New-Ctl System.Windows.Forms.Label 12 22 400 36 'Apps Script web app link (ends in /exec). See README.md, section "Google Sheets", for how to get it.'
    $UI.Url = New-Ctl System.Windows.Forms.TextBox 12 60 400 26 $null
    $UI.TestSheet = New-Ctl System.Windows.Forms.Button 12 94 200 30 'Test connection'
    $UI.OpenScript = New-Ctl System.Windows.Forms.Button 218 94 194 30 'Show the script to paste'
    $gSheet.Controls.AddRange(@($lblUrl, $UI.Url, $UI.TestSheet, $UI.OpenScript))

    $gUpd = New-Ctl System.Windows.Forms.GroupBox 8 164 425 112 'Updates'
    $UI.VerLabel = New-Ctl System.Windows.Forms.Label 12 24 400 22 "You have version $AppVersion."
    $UI.Update = New-Ctl System.Windows.Forms.Button 12 50 200 32 'Check for updates'
    $UI.UpdLabel = New-Ctl System.Windows.Forms.Label 12 86 400 20 ''; $UI.UpdLabel.ForeColor = [System.Drawing.Color]::DimGray
    $gUpd.Controls.AddRange(@($UI.VerLabel, $UI.Update, $UI.UpdLabel))

    $gFiles = New-Ctl System.Windows.Forms.GroupBox 8 284 425 70 'Your files'
    $UI.OpenLocal = New-Ctl System.Windows.Forms.Button 12 24 260 32 'Open my data folder (results, samples)'
    $gFiles.Controls.Add($UI.OpenLocal)
    $UI.TabSetup.Controls.AddRange(@($gSheet, $gUpd, $gFiles))
}

# ---------------------------------------------------------------- state <-> controls
function Read-Controls {
    if ($script:State.Loading) { return }
    $Cfg.trigger_on_labels = [bool]$UI.UseLabels.Checked
    $Cfg.extra_keywords = @(Get-ExtraKeywords)
    $Cfg.trigger_labels_needed = [int]$UI.Need.Value
    $Cfg.checks_in_row = [int]$UI.Row.Value
    $Cfg.read_duration_s = [int]$UI.Dur.Value
    $Cfg.enhance = [bool]$UI.Enhance.Checked
    $Cfg.webhook_url = $UI.Url.Text.Trim()
    $Cfg.stats_checked = @($UI.StatList.CheckedItems | ForEach-Object { [string]$_ })
    $src = Get-SelectedSource
    if ($src -ne $null) { $Cfg.source_id = $src.Id }
    Save-Settings
}

function Write-Controls {
    $UI.UseLabels.Checked = [bool]$Cfg.trigger_on_labels
    $UI.Extra.Text = (@($Cfg.extra_keywords) -join "`r`n")
    $UI.Need.Value = [Math]::Max(1, [Math]::Min(20, [int]$Cfg.trigger_labels_needed))
    $UI.Row.Value = [Math]::Max(1, [Math]::Min(10, [int]$Cfg.checks_in_row))
    $UI.Dur.Value = [Math]::Max(3, [Math]::Min(120, [int]$Cfg.read_duration_s))
    $UI.Enhance.Checked = [bool]$Cfg.enhance
    $UI.Url.Text = [string]$Cfg.webhook_url
}

function Get-ExtraKeywords { return @($UI.Extra.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Get-StatNames { return @($script:StatList | ForEach-Object { $_.Name }) }
function Get-WantedStats { return @($UI.StatList.CheckedItems | ForEach-Object { [string]$_ }) }

function Fill-StatList {
    $script:StatList = @(Get-StatList)
    $UI.StatList.Items.Clear()
    foreach ($s in $script:StatList) {
        $on = ($Cfg.stats_checked -eq $null) -or (@($Cfg.stats_checked) -contains $s.Name)
        [void]$UI.StatList.Items.Add($s.Name, $on)
    }
}

function Fill-Sources {
    $was = $script:State.Loading; $script:State.Loading = $true
    try {
        $script:State.Sources = @(Find-Sources)
        $UI.Source.Items.Clear()
        foreach ($s in $script:State.Sources) { [void]$UI.Source.Items.Add($s.Name) }
        $idx = -1
        for ($i = 0; $i -lt $script:State.Sources.Count; $i++) { if ($script:State.Sources[$i].Id -eq $Cfg.source_id) { $idx = $i } }
        if ($idx -lt 0 -and $Cfg.source_id -like 'win:*') { Log ("The window you used last time isn't open: " + $Cfg.source_id.Substring(4)) }
        if ($idx -ge 0) { $UI.Source.SelectedIndex = $idx }
    } finally { $script:State.Loading = $was }
}

function Get-SelectedSource {
    $i = $UI.Source.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:State.Sources.Count) { return $null }
    return $script:State.Sources[$i]
}

function Show-Preview($bmp) {
    $h = [int](320 * $bmp.Height / [Math]::Max(1, $bmp.Width))
    $thumb = New-Object System.Drawing.Bitmap $bmp, 320, ([Math]::Max(1, $h))
    $old = $UI.Preview.Image; $UI.Preview.Image = $thumb
    if ($old -ne $null) { $old.Dispose() }
}

# Grabs a frame from the selected source and runs OCR. Returns @{ Frame; Ocr; Width } (caller disposes Frame).
function Get-ReadFrame {
    $src = Get-SelectedSource
    if ($src -eq $null) { throw 'Pick a video source on the Run tab first.' }
    $frame = Get-Frame $src
    $img = Get-OcrImage $frame ([bool]$UI.Enhance.Checked)
    try { $ocr = @(Read-Ocr $img); $w = $img.Width }
    finally { if (-not [object]::ReferenceEquals($img, $frame)) { $img.Dispose() } }
    return @{ Frame = $frame; Ocr = $ocr; Width = [double]$w }
}

function Set-Busy([bool]$running) {
    $UI.Start.Enabled = -not $running; $UI.Stop.Enabled = $running
    foreach ($c in @($UI.Test, $UI.Sample, $UI.Source, $UI.Refresh, $UI.Region, $UI.Update)) { $c.Enabled = -not $running }
}

function Set-Idle { $script:State.Mode = 'idle'; Set-Busy $false; $UI.Detail.Text = '' }

# ---------------------------------------------------------------- watching and recording
function Start-Watching {
    if ($OcrEngine -eq $null) { [void][System.Windows.Forms.MessageBox]::Show('Windows has no OCR language installed. Add English in Settings > Time and language > Language and region.', 'Smash Watcher'); return }
    if (-not $UI.UseLabels.Checked -and (Get-ExtraKeywords).Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Turn on stat-name detection or add extra trigger words (Detection tab).', 'Smash Watcher'); return }
    if ((Get-WantedStats).Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Tick at least one stat on the Stats tab.', 'Smash Watcher'); return }
    $src = Get-SelectedSource
    if ($src -eq $null) { [void][System.Windows.Forms.MessageBox]::Show('Pick a video source first.', 'Smash Watcher'); return }
    try { $f = Get-Frame $src; Show-Preview $f; $f.Dispose() }
    catch { Log ("Can't read the source: " + $_.Exception.Message); return }
    Read-Controls
    $script:State.Streak = 0; $script:State.ErrCount = 0; $script:State.LastErr = ''; $script:State.Rec = $null
    $script:State.Mode = 'watching'; Set-Busy $true
    Set-Status 'Watching for the stats screen...' 'RoyalBlue'; Log 'Started watching.'
}

function Start-Recording($read) {
    Log 'Stats screen detected. Recording...'
    $script:State.Rec = New-Recording (Get-StatNames) (Get-WantedStats) $SampleDir
    $script:State.Mode = 'recording'
    [void](Add-RecordingFrame $script:State.Rec $read.Ocr $read.Frame $read.Width)
}

# Ends a recording (timer ran out, or Stop was pressed) and opens the review window with whatever was read.
function Complete-Recording([bool]$stoppedEarly) {
    $rec = $script:State.Rec; $script:State.Rec = $null
    Set-Idle
    if ($rec -eq $null) { return }
    if ($stoppedEarly) { Log ('Stopped early; reviewing the {0} frame(s) read so far.' -f $rec.Frames.Count) }
    $match = Build-MatchTable $rec $script:StatList
    if ($match.Error) {
        if ($rec.Thumb -ne $null) { $rec.Thumb.Dispose() }
        if ($rec.SampleDir) { Set-Content -Path (Join-Path $rec.SampleDir 'review.txt') -Value $match.Error -Encoding UTF8 }
        Set-Status 'Done: no stats could be read.' 'DarkOrange'; Log $match.Error; return
    }
    Save-MatchReport $match 'review.txt' (Format-MatchTable $match)
    Set-Status ('Review: {0} of {1} stats read.' -f $match.Found, $match.Wanted) 'RoyalBlue'
    Log ('Recording finished: {0} player(s). Review the stats, then send or discard.' -f $match.N)
    if ($rec.SampleDir) { Log ('Saved {0} frame(s) from this match to local\samples\{1}' -f $rec.Saved, (Split-Path $rec.SampleDir -Leaf)) }
    $script:PendingReview = $match
    [void]$UI.Form.BeginInvoke([Action] { Show-ReviewWindow $script:PendingReview $script:StatList })
}

function Invoke-Tick {
    if ($script:State.Busy -or $script:State.Mode -eq 'idle') { return }
    $script:State.Busy = $true
    $read = $null
    try {
        $read = Get-ReadFrame
        Show-Preview $read.Frame
        $script:State.ErrCount = 0; $script:State.LastErr = ''
        if ($script:State.Mode -eq 'watching') {
            $hits = @(Get-TriggerHits $read.Ocr (Get-StatNames) (Get-ExtraKeywords) ([bool]$UI.UseLabels.Checked))
            $need = [int]$UI.Need.Value
            $UI.Hits.Text = ('Live: {0} seen: {1}' -f $hits.Count, ($hits -join ', '))
            $UI.Detail.Text = ('{0} of {1} trigger names seen' -f $hits.Count, $need)
            if ($hits.Count -ge $need) { $script:State.Streak++ } else { $script:State.Streak = 0 }
            if ($script:State.Streak -ge [int]$UI.Row.Value) { Start-Recording $read }
        }
        elseif ($script:State.Mode -eq 'recording') {
            $rec = $script:State.Rec
            $got = Add-RecordingFrame $rec $read.Ocr $read.Frame $read.Width
            $elapsed = ((Get-Date) - $rec.Started).TotalSeconds
            Set-Status ('Recording... {0}s left' -f [Math]::Max(0, [int]([double]$UI.Dur.Value - $elapsed))) 'Firebrick'
            $UI.Detail.Text = ('{0} values on this frame, {1} frame(s) with stats' -f $got, $rec.Frames.Count)
            if ($elapsed -ge [double]$UI.Dur.Value) { Complete-Recording $false }
        }
    } catch {
        $script:State.ErrCount++
        $em = $_.Exception.Message
        if ($em -ne $script:State.LastErr) { Log ('Error: ' + $em); $script:State.LastErr = $em }
        if ($script:State.ErrCount -ge 5) {
            if ($script:State.Mode -eq 'recording') { Complete-Recording $true }
            else { Set-Idle }
            Set-Status 'Stopped: the source keeps failing.' 'DarkOrange'
        }
    } finally {
        if ($read -ne $null) { $read.Frame.Dispose() }
        $script:State.Busy = $false
    }
}

# ---------------------------------------------------------------- tools
function Invoke-TestNow {
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $read = Get-ReadFrame
        Show-Preview $read.Frame
        Log ('Test: read {0} line(s) of text in {1:N1}s.' -f @($read.Ocr).Count, $sw.Elapsed.TotalSeconds)
        $hits = @(Get-TriggerHits $read.Ocr (Get-StatNames) (Get-ExtraKeywords) ([bool]$UI.UseLabels.Checked))
        Log ('Trigger names seen: {0} (need {1}) [{2}]' -f $hits.Count, $UI.Need.Value, ($hits -join ', '))
        $m = Read-StatsFrame $read.Ocr (Get-StatNames) $read.Width $read.Frame (New-DigitStore)
        if ($m -eq $null) { Log 'No stats panels found on this frame.' }
        else {
            Log ('Found {0} player panel(s): {1} value(s) read, {2} hard to read (marked ?), {3} assumed 0.' -f $m.N, $m.Cells.Count, $m.Rechecks.Count, $m.Guesses.Count)
            for ($c = 0; $c -lt $m.N; $c++) {
                $h = @(); foreach ($f in @('character', 'player', 'place', 'num', 'out')) { $h += ('{0}={1}' -f $f, $m.Head["$c|$f"]) }
                Log ('  P{0}: {1}' -f ($c + 1), ($h -join ', '))
                $vals = @($m.Cells.Keys | Where-Object { $_ -like "$c|*" } | ForEach-Object { '{0}={1}' -f $_.Substring($_.IndexOf('|') + 1), $m.Cells[$_] })
                $vals += @($m.Rechecks.Keys | Where-Object { $_ -like "$c|*" } | ForEach-Object { '{0}={1}?' -f $_.Substring($_.IndexOf('|') + 1), $m.Rechecks[$_] })
                $vals += @($m.Guesses.Keys | Where-Object { $_ -like "$c|*" } | ForEach-Object { '{0}=0?' -f $_.Substring($_.IndexOf('|') + 1) })
                if ($vals.Count -gt 0) { Log ('      ' + ($vals -join ', ')) }
            }
        }
        $read.Frame.Dispose()
    } catch { Log ('Test failed: ' + $_.Exception.Message) }
}

function Invoke-SaveSample {
    try {
        $read = Get-ReadFrame
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $png = Join-Path $SampleDir "sample_$stamp.png"
        $read.Frame.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        Set-Content -Path (Join-Path $SampleDir "sample_$stamp.txt") -Value (Format-OcrDump $read.Ocr) -Encoding UTF8
        $read.Frame.Dispose()
        Log "Saved sample_$stamp (.png and .txt) in local\samples."
    } catch { Log ('Sample failed: ' + $_.Exception.Message) }
}

function Invoke-UpdateCheck([bool]$quiet) {
    try {
        $rel = Get-LatestRelease
        if (-not $rel.Newer) {
            $UI.UpdLabel.Text = ('Up to date (latest is {0}).' -f $rel.Tag)
            if (-not $quiet) { Log 'You have the latest version.' }
            return
        }
        $UI.UpdLabel.Text = ('Version {0} is available.' -f $rel.Tag)
        $UI.Update.Text = ('Update to {0}' -f $rel.Tag); $UI.Update.BackColor = [System.Drawing.Color]::SeaGreen; $UI.Update.ForeColor = [System.Drawing.Color]::White
        if ($quiet) { Log ('An update is available ({0}). Setup tab > Update.' -f $rel.Tag); return }
        $notes = $rel.Notes; if ($notes.Length -gt 800) { $notes = $notes.Substring(0, 800) + '...' }
        $ans = [System.Windows.Forms.MessageBox]::Show($UI.Form, ("Update from {0} to {1}?`r`n`r`n{2}`r`n`r`nYour settings, results and samples are kept. Smash Watcher restarts afterwards." -f $AppVersion, $rel.Tag, $notes), 'Smash Watcher update', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        $UI.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $after = @(Install-Update $rel)
        $UI.Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $msg = "Updated to $($rel.Tag). Smash Watcher will now restart."
        if ($after.Count -gt 0) { $msg += "`r`n`r`n" + ($after -join "`r`n`r`n") }
        [void][System.Windows.Forms.MessageBox]::Show($UI.Form, $msg, 'Smash Watcher update')
        Restart-App
        $UI.Form.Close()
    } catch {
        $UI.Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $UI.UpdLabel.Text = 'Update check failed (see log).'
        if (-not $quiet) { Log ('Update failed: ' + $_.Exception.Message) }
    }
}

# ---------------------------------------------------------------- wiring
function Connect-Events {
    $UI.Start.Add_Click({ Start-Watching })
    $UI.Stop.Add_Click({
        if ($script:State.Mode -eq 'recording') { Complete-Recording $true; return }
        Log 'Stopped.'; Set-Idle; Set-Status 'Stopped.' 'DimGray'
    })
    $UI.Refresh.Add_Click({ Fill-Sources; Fill-StatList; Log 'Refreshed the source list and stats.txt.' })
    $UI.Region.Add_Click({
        if (Invoke-RegionPicker $UI.Form) {
            Fill-Sources
            try { $f = Get-Frame (Get-SelectedSource); Show-Preview $f; $f.Dispose() } catch { Log ('Preview failed: ' + $_.Exception.Message) }
        }
    })
    $UI.Source.Add_SelectedIndexChanged({
        if ($script:State.Loading) { return }
        Read-Controls
        $src = Get-SelectedSource
        try { $f = Get-Frame $src; Show-Preview $f; $f.Dispose(); Log ('Source works: ' + $src.Name) }
        catch { Log ("Can't read that source: " + $_.Exception.Message) }
    })
    $UI.Test.Add_Click({ Invoke-TestNow })
    $UI.Sample.Add_Click({ Invoke-SaveSample })
    $UI.AllOn.Add_Click({ for ($i = 0; $i -lt $UI.StatList.Items.Count; $i++) { $UI.StatList.SetItemChecked($i, $true) }; Read-Controls })
    $UI.AllOff.Add_Click({ for ($i = 0; $i -lt $UI.StatList.Items.Count; $i++) { $UI.StatList.SetItemChecked($i, $false) }; Read-Controls })
    $UI.StatList.Add_ItemCheck({ if (-not $script:State.Loading -and $UI.Form.IsHandleCreated) { [void]$UI.Form.BeginInvoke([Action] { Read-Controls }) } })
    foreach ($c in @($UI.UseLabels, $UI.Enhance)) { $c.Add_CheckedChanged({ Read-Controls }) }
    foreach ($c in @($UI.Need, $UI.Row, $UI.Dur)) { $c.Add_ValueChanged({ Read-Controls }) }
    foreach ($c in @($UI.Extra, $UI.Url)) { $c.Add_Leave({ Read-Controls }) }
    $UI.TestSheet.Add_Click({
        Read-Controls
        try { Send-Sheet ([string]$Cfg.webhook_url) $SheetTab (Get-SheetHeader $script:StatList) @(); Log "Google Sheets connection OK. A '$SheetTab' tab with headers now exists in your sheet." }
        catch { Log ('Google Sheets test failed: ' + $_.Exception.Message) }
    })
    $UI.OpenScript.Add_Click({ Start-Process notepad.exe $AppsScript })
    $UI.OpenLocal.Add_Click({ Start-Process explorer.exe $LocalDir })
    $UI.Update.Add_Click({ Invoke-UpdateCheck $false })
    $UI.Form.Add_Shown({ if (-not (Test-DeveloperCopy)) { Invoke-UpdateCheck $true } })
    $UI.Form.Add_FormClosing({ $script:Timer.Stop(); Read-Controls })

    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 1000
    $script:Timer.Add_Tick({ Invoke-Tick })
}

function Show-MainWindow {
    Build-MainWindow
    $script:LogSink = { param($line) $UI.Log.AppendText($line + "`r`n") }
    Import-Settings
    $script:State.Loading = $true
    Write-Controls
    Fill-StatList
    Fill-Sources
    Connect-Events
    $script:State.Loading = $false

    Log ("Smash Watcher $AppVersion ready. Pick a source (an OBS or Streamlabs projector window works best), then press Start.")
    if ($OcrEngine -eq $null) { Log 'Windows has no OCR language installed (Settings > Time and language > Language and region).' }
    if (-not $Cfg.webhook_url) { Log 'Google Sheets is not set up yet (Setup tab). You can still Copy or save to CSV from the review window.' }
    $script:Timer.Start()
    [void]$UI.Form.ShowDialog()
}
