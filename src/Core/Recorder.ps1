# Combines many frames of the stats screen into one table. Each value is the reading seen most often, which
# cancels out one-off OCR slips and fills in rows that only appear once the panel scrolls.

$FixedRows = @(
    @{ Key = 'player';    Label = 'Player' },
    @{ Key = 'character'; Label = 'Character' },
    @{ Key = 'place';     Label = 'Placement' },
    @{ Key = 'num';       Label = 'Player number' },
    @{ Key = 'surv';      Label = 'Survival time (s)' }
)

function New-Recording([string[]]$allLabels, [string[]]$wanted) {
    $now = Get-Date
    return [pscustomobject]@{
        Started    = $now
        Stamp      = $now.ToString('yyyy-MM-dd HH:mm:ss')
        AllLabels  = $allLabels
        Wanted     = $wanted
        Frames     = (New-Object System.Collections.ArrayList)
        Thumb      = $null
        ThumbScore = -1
    }
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
    return $m.Cells.Count
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
    return @{ N = $n; Stamp = $rec.Stamp; Rows = $rows; Found = $found; Wanted = $rec.Wanted.Count; Thumb = $rec.Thumb }
}
