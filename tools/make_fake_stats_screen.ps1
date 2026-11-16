# Draws a stand-in for the SSBU stats screen (3 player panels, darkened like a replay) so the reader can be
# tested without the game. The real layout differs in details; always confirm with a real screenshot.
#   powershell -ExecutionPolicy Bypass -File tools\make_fake_stats_screen.ps1 -Out local\fake_stats.png [-FirstRow 0] [-Dim 0.55]
param(
    [string]$Out = 'local\fake_stats.png',
    [int]$FirstRow = 0,
    [double]$Dim = 0.55,
    [int]$Width = 1920,
    [int]$Height = 1080
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$labels = @(Get-Content (Join-Path $AppRoot 'config\stats.txt') | ForEach-Object { $_.Split('|')[0].Trim() } | Where-Object { $_ })

$players = @(
    @{ Char = 'DR. MARIO'; Place = '3'; Num = 'P1'; Out = '3:27'; Color = [System.Drawing.Color]::FromArgb(180, 40, 40) },
    @{ Char = 'ROY';       Place = '2'; Num = 'P2'; Out = '3:45'; Color = [System.Drawing.Color]::FromArgb(40, 70, 180) },
    @{ Char = 'LUCINA';    Place = '1'; Num = 'P3'; Out = '---';  Color = [System.Drawing.Color]::FromArgb(40, 150, 60) }
)
$rand = New-Object System.Random 7
function Fake-Value($label, $p) {
    if ($label -match 'Damage|Hit Percentage') { return ('{0:N1}%' -f ($rand.Next(50, 999) / 10.0)) }
    if ($label -match 'Distance') { return ('{0:N1} m' -f ($rand.Next(100, 9000) / 10.0)) }
    if ($label -match 'Time|Drought') { return ('{0:N1} s' -f ($rand.Next(10, 2000) / 10.0)) }
    if ($label -match 'Speed') { return ('{0:N1} km/h' -f ($rand.Next(100, 4000) / 10.0)) }
    return [string]$rand.Next(0, 40)
}

$bmp = New-Object System.Drawing.Bitmap $Width, $Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.Clear([System.Drawing.Color]::FromArgb(30, 30, 40))
$fLabel = New-Object System.Drawing.Font('Arial', 20, [System.Drawing.FontStyle]::Bold)
$fName = New-Object System.Drawing.Font('Arial Black', 34)
$fPlace = New-Object System.Drawing.Font('Arial Black', 72)
$fSmall = New-Object System.Drawing.Font('Arial', 20, [System.Drawing.FontStyle]::Bold)
$white = [System.Drawing.Brushes]::White
$panelW = [int]($Width * 0.31); $gapX = [int](($Width - 3 * $panelW) / 4)
$expected = @()
for ($p = 0; $p -lt 3; $p++) {
    $pl = $players[$p]
    $x = $gapX + $p * ($panelW + $gapX)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $pl.Color), $x, 60, $panelW, $Height - 140)
    $g.DrawString($pl.Char, $fName, $white, $x + 16, 70)
    $g.DrawString($pl.Place, $fPlace, $white, $x + $panelW - 110, 50)
    $g.DrawString($pl.Num, $fSmall, $white, $x + 18, 130)
    $g.DrawString($pl.Out, $fSmall, $white, $x + $panelW - 110, 170)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 0, 0, 0))), $x + 10, 220, $panelW - 20, $Height - 320)
    $y = 240
    for ($i = $FirstRow; $i -lt [Math]::Min($labels.Count, $FirstRow + 8); $i++) {
        $v = Fake-Value $labels[$i] $p
        $g.DrawString($labels[$i], $fLabel, $white, $x + 24, $y)
        $sz = $g.MeasureString($v, $fLabel)
        $g.DrawString($v, $fLabel, $white, $x + $panelW - 30 - $sz.Width, $y)
        $expected += ('P{0} {1} = {2}' -f ($p + 1), $labels[$i], $v)
        $y += 82
    }
}
# Replay overlay text in the middle, like the real replay screen.
$g.DrawString('Next Replay', $fSmall, $white, $Width / 2 - 70, 40)
# Darken like a replay.
$g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb([int](255 * $Dim), 0, 0, 0))), 0, 0, $Width, $Height)
$g.Dispose()
$path = Join-Path $AppRoot $Out
$bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
Write-Host "Wrote $path"
Write-Host 'Expected values:'
$expected | ForEach-Object { Write-Host "  $_" }
