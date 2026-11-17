# Combines many frames of the stats screen into one table. Each value is the reading seen most often, which
# cancels out one-off OCR slips and fills in rows that only appear once the panel scrolls.

$FixedRows = @(
    @{ Key = 'player';    Label = 'Player' },
    @{ Key = 'character'; Label = 'Character' },
    @{ Key = 'place';     Label = 'Placement' },
    @{ Key = 'num';       Label = 'Player number' },
    @{ Key = 'surv';      Label = 'Survival time (s)' }
)

$MaxSavedFrames = 10      # frames saved per recording
$KeepMatchFolders = 25    # newest match sample folders kept in local\samples

# $sampleRoot (optional): when given, the recording saves frames and reports to <sampleRoot>\match_<time>\ so every
# match can be checked afterwards (Ken's direct capture vs. a Discord copy, OCR misses, etc.).
function New-Recording([string[]]$allLabels, [string[]]$wanted, [string]$sampleRoot = '') {
    $now = Get-Date
    $dir = ''
    if ($sampleRoot) {
        $dir = Join-Path $sampleRoot ('match_' + $now.ToString('yyyyMMdd_HHmmss'))
        [void](New-Item -ItemType Directory -Path $dir -Force)
        Remove-OldMatchFolders $sampleRoot
    }
    return [pscustomobject]@{
        Started    = $now
        Stamp      = $now.ToString('yyyy-MM-dd HH:mm:ss')
        AllLabels  = $allLabels
        Wanted     = $wanted
        Frames     = (New-Object System.Collections.ArrayList)
        Thumb      = $null
        ThumbScore = -1
        SampleDir  = $dir
        Saved      = 0
        SinceSave  = 0
        SeenViews  = @{}
    }
}

function Remove-OldMatchFolders([string]$sampleRoot) {
    $old = @(Get-ChildItem -Path $sampleRoot -Directory -Filter 'match_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip $KeepMatchFolders)
    foreach ($d in $old) { try { Remove-Item $d.FullName -Recurse -Force } catch { } }
}

function Add-RecordingFrame($rec, $ocr, $frame, [double]$ocrWidth) {
    $m = Read-StatsFrame $ocr $rec.AllLabels $ocrWidth $frame
    if ($m -eq $null) { return 0 }
    [void]$rec.Frames.Add($m)
    if ($m.Cells.Count -gt $rec.ThumbScore) {
        $rec.ThumbScore = $m.Cells.Count
        if ($rec.Thumb -ne $null) { $rec.Thumb.Dispose() }
        $h = [int](640 * $frame.Height / [Math]::Max(1, $frame.Width))
        $rec.Thumb = New-Object System.Drawing.Bitmap $frame, 640, $h
    }
    Save-RecordingFrame $rec $m $ocr $frame
    return $m.Cells.Count
}

# Saves a frame whenever the list shows a new set of stats (a new scroll position), and otherwise every few frames,
# up to $MaxSavedFrames. Each frame gets a .png and a .txt of everything the OCR read, like Save sample.
function Save-RecordingFrame($rec, $m, $ocr, $frame) {
    if (-not $rec.SampleDir -or $rec.Saved -ge $MaxSavedFrames) { return }
    $rec.SinceSave++
    $view = (@(@($m.Cells.Keys) + @($m.Rechecks.Keys) + @($m.Guesses.Keys) | ForEach-Object { $_.Substring($_.IndexOf('|') + 1) } | Sort-Object -Unique) -join ',')
    $isNew = -not $rec.SeenViews.ContainsKey($view)
    if (-not $isNew -and $rec.SinceSave -lt 4) { return }
    $rec.SeenViews[$view] = $true
    $rec.Saved++; $rec.SinceSave = 0
    $name = 'frame_{0:D2}' -f $rec.Saved
    try {
        $frame.Save((Join-Path $rec.SampleDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        Set-Content -Path (Join-Path $rec.SampleDir "$name.txt") -Value (Format-OcrDump $ocr) -Encoding UTF8
    } catch { Log ('Could not save a sample frame: ' + $_.Exception.Message) }
}

# Writes what the review window showed (with ? on yellow cells) next to the saved frames.
function Save-MatchReport($match, [string]$fileName, [string]$text) {
    if (-not $match.SampleDir) { return }
    try { Set-Content -Path (Join-Path $match.SampleDir $fileName) -Value $text -Encoding UTF8 } catch { }
}

function Format-MatchTable($match) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('Match {0}, {1} player(s). "?" = yellow (hard to read or assumed 0).' -f $match.Stamp, $match.N))
    foreach ($row in $match.Rows) {
        $cells = for ($i = 0; $i -lt $row.Values.Count; $i++) {
            $v = [string]$row.Values[$i]
            if ($row.PSObject.Properties['Guessed'] -and $row.Guessed[$i]) { $v += '?' }
            '{0,-16}' -f $v
        }
        [void]$sb.AppendLine(('{0,-26} {1}' -f $row.Label, ($cells -join '')))
    }
    return $sb.ToString()
}

function Get-TopVote($tally) {
    if ($tally -eq $null -or $tally.Count -eq 0) { return '' }
    return [string](($tally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key)
}

function Parse-ClockTime([string]$s) {
    if ($s -match '^(\d{1,2}):(\d{2})$') { return ([int]$Matches[1] * 60 + [int]$Matches[2]) }
    return $null
}

# Returns @{ Error } or @{ N; Stamp; Rows; Found; Wanted; Thumb }. Rows: @{ Key; Label; Values = string[N] }.
function Build-MatchTable($rec, $statList) {
    if ($rec.Wanted.Count -eq 0) { return @{ Error = 'No stats are ticked on the Stats tab.' } }
    if ($rec.Frames.Count -eq 0) { return @{ Error = 'The stats screen was never recognised. Use Detection > Save sample on the stats screen and send the files.' } }

    # Player count: the most common panel count, weighted by how much each frame read.
    $nVotes = @{}
    foreach ($f in $rec.Frames) { $nVotes[$f.N] = [int]$nVotes[$f.N] + $f.Cells.Count + 1 }
    $n = [int](Get-TopVote $nVotes)

    # Three tiers, each voted on separately: full-frame readings, second-look readings (enlarged crop), and guessed
    # zeros (value line visible but unreadable). A lower tier is only used when no frame produced a higher one.
    $votes = @{}; $recheckVotes = @{}; $guessVotes = @{}
    foreach ($f in $rec.Frames) {
        if ($f.N -ne $n) { continue }
        foreach ($pair in @(@($f.Cells, $votes), @($f.Head, $votes), @($f.Rechecks, $recheckVotes), @($f.Guesses, $guessVotes))) {
            $src = $pair[0]; $tally = $pair[1]
            if ($src -eq $null) { continue }
            foreach ($k in @($src.Keys)) {
                $v = [string]$src[$k]
                if (-not $v) { continue }
                if (-not $tally.ContainsKey($k)) { $tally[$k] = @{} }
                $tally[$k][$v] = [int]$tally[$k][$v] + 1
            }
        }
    }
    $realKeys = $votes
    $get = {
        param($k)
        if ($votes.ContainsKey($k)) { return Get-TopVote $votes[$k] }
        if ($recheckVotes.ContainsKey($k)) { return Get-TopVote $recheckVotes[$k] }
        return Get-TopVote $guessVotes[$k]
    }

    # Survival time: seconds until knocked out. A player never knocked out ("---") gets the longest time anyone was out.
    $secs = @(); $maxOut = $null
    for ($c = 0; $c -lt $n; $c++) {
        $s = Parse-ClockTime (& $get "$c|out"); $secs += $s
        if ($s -ne $null -and ($maxOut -eq $null -or $s -gt $maxOut)) { $maxOut = $s }
    }

    # A player with "---", or no time at all while others have one, was never knocked out.
    $surv = @(); $neverOut = @()
    for ($c = 0; $c -lt $n; $c++) {
        $never = ($secs[$c] -eq $null) -and $maxOut -ne $null
        $neverOut += $never
        if ($secs[$c] -ne $null) { $surv += [string]$secs[$c] } elseif ($never) { $surv += [string]$maxOut } else { $surv += '' }
    }
    # Placement: read from the screen if possible, otherwise ranked by survival (never knocked out = 1st).
    $places = @()
    for ($c = 0; $c -lt $n; $c++) {
        $p = & $get "$c|place"
        if (-not $p -and $maxOut -ne $null) {
            $better = 0
            for ($o = 0; $o -lt $n; $o++) {
                if ($o -eq $c) { continue }
                if ($neverOut[$o] -and -not $neverOut[$c]) { $better++ }
                elseif (-not $neverOut[$o] -and -not $neverOut[$c] -and $secs[$o] -ne $null -and $secs[$c] -ne $null -and $secs[$o] -gt $secs[$c]) { $better++ }
            }
            $p = [string]($better + 1)
        }
        $places += $p
    }

    $rows = @()
    foreach ($fr in $FixedRows) {
        $vals = @()
        for ($c = 0; $c -lt $n; $c++) {
            switch ($fr.Key) {
                'surv'  { $vals += $surv[$c] }
                'place' { $vals += $places[$c] }
                default { $vals += (& $get ("$c|" + $fr.Key)) }
            }
        }
        $rows += [pscustomobject]@{ Key = $fr.Key; Label = $fr.Label; Values = $vals }
    }
    $found = 0
    foreach ($stat in $statList) {
        if ($rec.Wanted -notcontains $stat.Name) { continue }
        $vals = @(); $guessed = @(); $any = $false
        for ($c = 0; $c -lt $n; $c++) {
            $k = "$c|" + $stat.Name
            $v = & $get $k
            if ($v) { $any = $true }
            $vals += $v
            $guessed += ([bool]$v -and -not $realKeys.ContainsKey($k))
        }
        if ($any) { $found++ }
        $rows += [pscustomobject]@{ Key = ('stat:' + $stat.Name); Label = (Get-StatDisplayName $stat); Values = $vals; Guessed = $guessed }
    }
    return @{ N = $n; Stamp = $rec.Stamp; Rows = $rows; Found = $found; Wanted = $rec.Wanted.Count; Thumb = $rec.Thumb; SampleDir = $rec.SampleDir }
}
