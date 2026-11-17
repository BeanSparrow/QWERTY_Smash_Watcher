# Replays a saved match (local\samples\match_*\frame_*.png) through the reader and grades every cell against the
# match's truth.json (true values typed in by hand from the frames).
#   powershell -ExecutionPolicy Bypass -File tools\score_match.ps1 [-Match local\samples\match_X] [-Detail]
# With no -Match, every match folder that has a truth.json is scored. Grades per cell:
#   right    = correct and not flagged          flagged-right = correct but yellow
#   WRONG    = wrong and NOT flagged (worst)     flagged-wrong = wrong but yellow
#   missed   = blank
# -Starter uses a different digit starter set (for testing a set built without the match being scored).
param([string[]]$Match = @(), [switch]$Detail, [string]$Starter = '')
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $AppRoot 'src\Bootstrap.ps1')

$stats = @(Get-StatList)
$labels = @($stats | ForEach-Object { $_.Name })
if ($Match.Count -eq 0) {
    $Match = @(Get-ChildItem (Join-Path $AppRoot 'local\samples') -Directory -Filter 'match_*' | Where-Object { Test-Path (Join-Path $_.FullName 'truth.json') } | ForEach-Object { $_.FullName })
}
$total = @{ right = 0; 'flagged-right' = 0; WRONG = 0; 'flagged-wrong' = 0; missed = 0 }
foreach ($dir in $Match) {
    $dir = (Resolve-Path $dir).Path
    $truth = Get-Content (Join-Path $dir 'truth.json') -Raw | ConvertFrom-Json
    $rec = New-Recording $labels $labels
    if ($Starter) { $rec.Digits = New-DigitStore $Starter }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $frames = @(Get-ChildItem $dir -Filter 'frame_*.png' | Sort-Object Name)
    foreach ($f in $frames) {
        $fr = Read-ImageFile $f.FullName; $img = Get-OcrImage $fr $true
        [void](Add-RecordingFrame $rec @(Read-Ocr $img) $fr ([double]$img.Width))
        if (-not [object]::ReferenceEquals($img, $fr)) { $img.Dispose() }; $fr.Dispose()
    }
    $secs = $sw.Elapsed.TotalSeconds / [Math]::Max(1, $frames.Count)
    $table = Build-MatchTable $rec $stats
    $grades = @{ right = 0; 'flagged-right' = 0; WRONG = 0; 'flagged-wrong' = 0; missed = 0 }
    $lines = @()
    if ($table.Error) { Write-Host ("{0}: {1}" -f (Split-Path $dir -Leaf), $table.Error); continue }
    $rowOf = @{}; foreach ($r in $table.Rows) { $rowOf[$r.Key] = $r }
    $fieldKey = @{ player = 'player'; character = 'character'; placement = 'place'; survival_time_s = 'surv' }
    for ($c = 0; $c -lt $truth.players.Count; $c++) {
        foreach ($p in $truth.players[$c].PSObject.Properties) {
            $want = [string]$p.Value
            if (-not $want) { continue }
            $key = $fieldKey[$p.Name]; if (-not $key) { $key = 'stat:' + $p.Name }
            $row = $rowOf[$key]
            $got = ''; $flag = $false
            if ($row -ne $null -and $c -lt $row.Values.Count) {
                $got = [string]$row.Values[$c]
                if ($row.PSObject.Properties['Guessed'] -and $row.Guessed) { $flag = [bool]$row.Guessed[$c] }
            }
            if (-not $got) { $g = 'missed' }
            elseif ($got -eq $want) { if ($flag) { $g = 'flagged-right' } else { $g = 'right' } }
            elseif ($flag) { $g = 'flagged-wrong' } else { $g = 'WRONG' }
            $grades[$g]++; $total[$g]++
            if ($g -ne 'right') { $lines += ('    P{0} {1,-22} want {2,-10} got {3,-10} {4}' -f ($c + 1), $p.Name, $want, $got, $g) }
        }
    }
    $n = ($grades.Values | Measure-Object -Sum).Sum
    Write-Host ('{0}: {1} cells, right {2}, flagged-right {3}, WRONG {4}, flagged-wrong {5}, missed {6}  ({7} players found, {8:N2}s/frame)' -f
        (Split-Path $dir -Leaf), $n, $grades.right, $grades['flagged-right'], $grades.WRONG, $grades['flagged-wrong'], $grades.missed, $table.N, $secs)
    if ($Detail) { $lines | ForEach-Object { Write-Host $_ } }
}
$n = ($total.Values | Measure-Object -Sum).Sum
Write-Host ('TOTAL: {0} cells, right {1}, flagged-right {2}, WRONG {3}, flagged-wrong {4}, missed {5}' -f $n, $total.right, $total['flagged-right'], $total.WRONG, $total['flagged-wrong'], $total.missed)
