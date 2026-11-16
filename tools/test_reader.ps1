# Runs the stats reader on saved images, without the UI. Several images are combined like frames of one recording
# (for example the stats screen at different scroll positions).
#   powershell -ExecutionPolicy Bypass -File tools\test_reader.ps1 -Image a.png[,b.png,...] [-NoEnhance] [-Dump]
param(
    [Parameter(Mandatory = $true)][string[]]$Image,
    [switch]$NoEnhance,
    [switch]$Dump
)
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $AppRoot 'src\Bootstrap.ps1')
Import-Settings

$stats = @(Get-StatList)
$labels = @($stats | ForEach-Object { $_.Name })
$rec = New-Recording $labels $labels

# powershell -File passes "a.png,b.png" as one string, so split it here.
foreach ($path in @($Image | ForEach-Object { $_.Split(',') } | Where-Object { $_ })) {
    $frame = Read-ImageFile (Resolve-Path $path).Path
    $img = Get-OcrImage $frame (-not $NoEnhance)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ocr = @(Read-Ocr $img)
    $ocrSecs = $sw.Elapsed.TotalSeconds
    $sw.Restart()
    $hits = @(Get-TriggerHits $ocr $labels @() $true)
    $got = Add-RecordingFrame $rec $ocr $frame ([double]$img.Width)
    Write-Host ('{0}: {1}x{2}, OCR {3:N2}s ({4} lines), reader {5:N2}s, {6} trigger names, {7} values.' -f
        (Split-Path $path -Leaf), $frame.Width, $frame.Height, $ocrSecs, $ocr.Count, $sw.Elapsed.TotalSeconds, $hits.Count, $got)
    if ($Dump) { Write-Host (Format-OcrDump $ocr) }
    if (-not [object]::ReferenceEquals($img, $frame)) { $img.Dispose() }
    $frame.Dispose()
}

# Show it the way the review window would: one row per field, one column per player.
$table = Build-MatchTable $rec $stats
if ($table.Error) { Write-Host $table.Error; exit 1 }
Write-Host ('{0} player panel(s), {1} of {2} stats read.' -f $table.N, $table.Found, $table.Wanted)
# "?" marks cells the review window shows in yellow (hard to read, or assumed 0).
foreach ($row in $table.Rows) {
    $cellsText = for ($i = 0; $i -lt $row.Values.Count; $i++) {
        $v = [string]$row.Values[$i]
        if ($row.PSObject.Properties['Guessed'] -and $row.Guessed[$i]) { $v += '?' }
        '{0,-14}' -f $v
    }
    Write-Host ('{0,-26} {1}' -f $row.Label, ($cellsText -join ''))
}
