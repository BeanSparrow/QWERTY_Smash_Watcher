# Builds the digit-shape starter set (config\digits.txt) from saved frames: every value the OCR reads teaches
# the shapes of its digits. Run it after collecting new real matches.
#   powershell -ExecutionPolicy Bypass -File tools\learn_digits.ps1 [-Frames a.png,b.png | -Folders dir1,dir2] [-Out config\digits.txt]
# With no input it learns from every local\samples\match_* folder plus local\samples\ken\*.png.
param([string[]]$Frames = @(), [string[]]$Folders = @(), [string]$Out = '')
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $AppRoot 'src\Bootstrap.ps1')
if (-not $Out) { $Out = Join-Path $AppRoot 'config\digits.txt' }

$split = { param($list) @($list | ForEach-Object { $_.Split(',') } | Where-Object { $_ }) }
$Frames = & $split $Frames; $Folders = & $split $Folders
if ($Frames.Count -eq 0 -and $Folders.Count -eq 0) {
    $Folders = @(Get-ChildItem (Join-Path $AppRoot 'local\samples') -Directory -Filter 'match_*' | ForEach-Object { $_.FullName })
    $Frames = @(Get-ChildItem (Join-Path $AppRoot 'local\samples\ken') -Filter '*.png' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
foreach ($f in $Folders) { $Frames += @(Get-ChildItem $f -Filter 'frame_*.png' | ForEach-Object { $_.FullName }) }

$labels = @(Get-StatList | ForEach-Object { $_.Name })
$store = New-DigitStore ''          # start empty
$MaxExamplesPerDigit = 60
foreach ($path in $Frames) {
    $fr = Read-ImageFile $path; $img = Get-OcrImage $fr $true
    [void](Read-StatsFrame @(Read-Ocr $img) $labels ([double]$img.Width) $fr $store)
    if (-not [object]::ReferenceEquals($img, $fr)) { $img.Dispose() }; $fr.Dispose()
}
Save-DigitStore $store $Out
Write-Host ('Learned from {0} frame(s): {1}' -f $Frames.Count, ((0..9 | ForEach-Object { '{0}:{1}' -f $_, $store[[string]$_].Count }) -join '  '))
Write-Host "Wrote $Out"
