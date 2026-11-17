# Reads short numbers by the shape of their digits, for the values Windows OCR skips (lone "8", "11", "0").
#
# How it learns: whenever the OCR does read a value ("803 km/h"), the white glyphs in that spot are cut out and
# remembered as examples of 8, 0 and 3. Unread values are then recognised by comparing their glyphs with those
# examples. A starter set (config\digits.txt, built by tools\learn_digits.ps1 from real matches) covers digits
# not seen yet in the current match. Each recording starts from the starter set and keeps learning.

$DigitsFile = Join-Path $ConfigDir 'digits.txt'
$MaxExamplesPerDigit = 40

function New-DigitStore([string]$starterFile = $DigitsFile) {
    $store = @{}
    foreach ($d in 0..9) { $store[[string]$d] = New-Object System.Collections.ArrayList }
    if ($starterFile -and (Test-Path $starterFile)) {
        foreach ($line in (Get-Content $starterFile)) {
            $parts = $line.Split(' ')
            if ($parts.Count -lt 3 -or $parts[0] -notmatch '^\d$') { continue }
            $f = @($parts[2].Split(',') | ForEach-Object { [double]$_ / 100.0 })
            [void]$store[$parts[0]].Add([pscustomobject]@{ F = [double[]]$f; A = [double]$parts[1] })
        }
    }
    return $store
}

function Save-DigitStore($store, [string]$path) {
    $lines = foreach ($d in 0..9) {
        foreach ($ex in $store[[string]$d]) {
            '{0} {1:F3} {2}' -f $d, $ex.A, (($ex.F | ForEach-Object { [int][Math]::Round($_ * 100) }) -join ',')
        }
    }
    Set-Content -Path $path -Value $lines -Encoding ASCII
}

# The glyphs of the number in an area: white shapes, keeping the tallest run on the right (digits are taller
# than units like "sec." or "km/h"). $minH filters out specks.
function Get-NumberGlyphs($frame, [System.Drawing.Rectangle]$rect, [double]$minH) {
    # Not digits: panel edge lines and bars (very thin, or running into the top or bottom of the area).
    $all = @([SmashWatcher.Native]::FindGlyphs($frame, $rect, 170, 75) | Where-Object {
        $_.H -ge $minH -and $_.W -le 1.3 * $_.H -and $_.W -ge 0.2 * $_.H -and
        $_.Y -gt $rect.Y -and ($_.Y + $_.H) -lt ($rect.Y + $rect.Height) })
    if ($all.Count -eq 0) { return @() }
    $maxH = ($all | ForEach-Object { $_.H } | Measure-Object -Maximum).Maximum
    $tall = @($all | Where-Object { $_.H -ge 0.8 * $maxH } | Sort-Object X)
    # rightmost run of glyphs that sit side by side on one baseline
    $run = @($tall[$tall.Count - 1])
    for ($i = $tall.Count - 2; $i -ge 0; $i--) {
        $g = $tall[$i]; $first = $run[0]
        $gap = $first.X - ($g.X + $g.W)
        $sameLine = [Math]::Abs(($g.Y + $g.H) - ($first.Y + $first.H)) -le 0.25 * $maxH
        if ($gap -le 0.9 * $maxH -and $sameLine) { $run = @($g) + $run } else { break }
    }
    return $run
}

# Learns from a value the OCR read. Only when the number of glyphs matches the number of digits.
function Add-DigitExamples($store, $frame, [System.Drawing.Rectangle]$rect, [string]$value, [double]$minH) {
    if ($store -eq $null) { return }
    $digits = ($value -replace '\D', '')
    if (-not $digits -or $value -match '\.') { return }
    $glyphs = @(Get-NumberGlyphs $frame $rect $minH)
    if ($glyphs.Count -ne $digits.Length) { return }
    for ($i = 0; $i -lt $digits.Length; $i++) {
        $list = $store[[string]$digits[$i]]
        [void]$list.Insert(0, [pscustomobject]@{ F = $glyphs[$i].F; A = $glyphs[$i].Aspect })
        while ($list.Count -gt $MaxExamplesPerDigit) { $list.RemoveAt($list.Count - 1) }
    }
}

# Reads a number by shape. Returns @{ Value; Sure } or $null. "Sure" = every digit clearly closer to one digit's
# examples than to any other digit's.
function Read-DigitsByShape($store, $frame, [System.Drawing.Rectangle]$rect, [double]$minH) {
    if ($store -eq $null) { return $null }
    $glyphs = @(Get-NumberGlyphs $frame $rect $minH)
    if ($glyphs.Count -eq 0 -or $glyphs.Count -gt 4) { return $null }
    $text = ''; $sure = $true; $worstD = 0.0; $worstRatio = 0.0
    foreach ($g in $glyphs) {
        $best = $null; $bestD = 1e9; $second = 1e9
        foreach ($d in 0..9) {
            $dd = 1e9
            foreach ($ex in $store[[string]$d]) { $x = [SmashWatcher.Native]::GlyphDistance($g, $ex.F, $ex.A); if ($x -lt $dd) { $dd = $x } }
            if ($dd -lt $bestD) { $second = $bestD; $bestD = $dd; $best = $d } elseif ($dd -lt $second) { $second = $dd }
        }
        if ($best -eq $null -or $bestD -gt 0.08) { return $null }
        $ratio = $bestD / [Math]::Max(1e-9, $second)
        if ($ratio -gt 0.6) { $sure = $false }
        $worstD = [Math]::Max($worstD, $bestD); $worstRatio = [Math]::Max($worstRatio, $ratio)
        $text += [string]$best
    }
    return [pscustomobject]@{ Value = ([string][int]$text); Sure = $sure; Glyphs = $glyphs.Count; WorstD = $worstD; WorstRatio = $worstRatio }
}
