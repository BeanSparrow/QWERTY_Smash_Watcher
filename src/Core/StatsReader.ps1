# Reads one frame of the SSBU post-match stats screen.
#
# Layout (from real screenshots): one panel per player, side by side. Each panel repeats the stat labels down its
# left side with that player's value to the right. Above the labels, each panel shows the character name, the
# placement (a big digit) and the player number. The panel shows only part of the list at a time and scrolls,
# so every frame may contain a different slice of the stats; the recorder combines frames.

# Text that can appear near the panel headers but isn't player info (menus, replay overlay).
$HeaderStopWords = @('next', 'replay', 'quit', 'save', 'back', 'ok', 'results', 'continue', 'menu')

function Get-NormText([string]$s) { return (($s.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s+', ' ').Trim() }
# Folds the digit/letter pairs the OCR confuses most, so "K0s" still matches "KOs".
function Get-FoldText([string]$s) { return ((Get-NormText $s) -replace '0', 'o') -replace '1', 'l' }

# Turns an OCR token into a plain number string ("34.5%" -> "34.5", "1O2" -> "102"), or $null if it isn't one.
function ConvertTo-StatNumber([string]$token) {
    # The OCR often reads "%" as "0/0" or "o/o" (so "9.9%" comes back as "9.90/0").
    $t = $token.Trim() -replace '[0Oo°]/[0Oo]$', '%'
    $m = [regex]::Match($t, '^([0-9OoIl|][0-9OoIl|.,]*)\s*(%|[a-zA-Z/]{0,5})$')
    if (-not $m.Success) { return $null }
    $raw = $m.Groups[1].Value
    if ($raw -notmatch '\d') { return $null }
    $num = (($raw -replace '[Oo]', '0') -replace '[Il|]', '1') -replace ',', ''
    $num = $num.TrimEnd('.')
    if ($num -notmatch '^\d+(\.\d+)?$') { return $null }
    return $num
}

function Get-Median($values) {
    $v = @($values | Sort-Object)
    if ($v.Count -eq 0) { return 0.0 }
    return [double]$v[[int][Math]::Floor($v.Count / 2)]
}

# Finds every place a stat label appears (once per panel). Returns hits: @{ Index; X; XR; Y; H }.
# Exact matches win; otherwise a close match is accepted only if it's clearly closer to one label than to any other.
function Find-LabelHits($ocr, [string[]]$labels) {
    $keys = @($labels | ForEach-Object { (Get-FoldText $_) -replace ' ', '' })
    $tols = @($keys | ForEach-Object { if ($_.Length -lt 5) { 0 } else { [Math]::Max(1, [int][Math]::Floor($_.Length / 6)) } })
    $maxWords = (@($labels | ForEach-Object { (Get-NormText $_).Split(' ').Count }) | Measure-Object -Maximum).Maximum + 1
    $hits = New-Object System.Collections.ArrayList

    foreach ($line in $ocr) {
        $ws = @($line.Words); $cnt = $ws.Count
        if ($cnt -eq 0) { continue }
        $wf = @($ws | ForEach-Object { (Get-FoldText $_.T) -replace ' ', '' })
        $cands = New-Object System.Collections.ArrayList
        for ($s = 0; $s -lt $cnt; $s++) {
            $txt = ''
            for ($n = 1; $n -le $maxWords -and $s + $n -le $cnt; $n++) {
                $txt += $wf[$s + $n - 1]
                if (-not $txt) { continue }
                $best = 99; $bestI = -1; $tie = $false
                for ($i = 0; $i -lt $keys.Count; $i++) {
                    $k = $keys[$i]
                    if (-not $k) { continue }
                    if ($txt -eq $k) { $d = 0 }
                    elseif ($tols[$i] -gt 0 -and [Math]::Abs($txt.Length - $k.Length) -le $tols[$i] -and $txt[0] -eq $k[0]) {
                        $d = [SmashWatcher.Native]::Lev($txt, $k)
                        if ($d -gt $tols[$i]) { continue }
                    } else { continue }
                    if ($d -lt $best) { $best = $d; $bestI = $i; $tie = $false } elseif ($d -eq $best) { $tie = $true }
                }
                if ($bestI -ge 0 -and -not $tie) { [void]$cands.Add([pscustomobject]@{ S = $s; N = $n; I = $bestI; D = $best }) }
            }
        }
        $used = New-Object bool[] $cnt
        foreach ($c in @($cands | Sort-Object D, @{ Expression = 'N'; Descending = $true })) {
            $free = $true
            for ($k = $c.S; $k -lt $c.S + $c.N; $k++) { if ($used[$k]) { $free = $false } }
            if (-not $free) { continue }
            for ($k = $c.S; $k -lt $c.S + $c.N; $k++) { $used[$k] = $true }
            $win = @($ws[$c.S..($c.S + $c.N - 1)])
            [void]$hits.Add([pscustomobject]@{
                Index = $c.I
                X     = $win[0].X
                XR    = ($win | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
                Y     = ($win | ForEach-Object { $_.Y + $_.H / 2 } | Measure-Object -Average).Average
                H     = ($win | ForEach-Object { $_.H } | Measure-Object -Average).Average
            })
        }
    }
    return $hits
}

# Which trigger words are on screen: stat labels (if enabled) plus any extra keywords.
function Get-TriggerHits($ocr, [string[]]$labels, [string[]]$extra, [bool]$useLabels) {
    $found = @()
    if ($useLabels -and $labels.Count -gt 0) {
        $found += @(Find-LabelHits $ocr $labels | ForEach-Object { $labels[$_.Index] } | Select-Object -Unique)
    }
    if ($extra.Count -gt 0) {
        $full = ' ' + (Get-FoldText (($ocr | ForEach-Object { $_.Text }) -join ' ')) + ' '
        foreach ($k in $extra) {
            $f = Get-FoldText $k
            if ($f -and $full.Contains(' ' + $f + ' ') -and $found -notcontains $k) { $found += $k }
        }
    }
    return $found
}

# Reads one frame. Returns $null when no stats panel is visible, else
# @{ N = players; Cells = "col|label" -> value; Head = "col|field" -> text } with fields character, player, place, num, out.
function Read-StatsFrame($ocr, [string[]]$labels, [double]$imageWidth) {
    $words = @(); foreach ($l in $ocr) { $words += $l.Words }
    if ($words.Count -eq 0) { return $null }
    $hits = @(Find-LabelHits $ocr $labels)
    if ($hits.Count -eq 0) { return $null }
    $hMed = Get-Median ($hits | ForEach-Object { $_.H })

    # 1. Panels: labels are left-aligned inside each panel, so their left edges cluster by panel.
    $gap = [Math]::Max(6 * $hMed, 0.06 * $imageWidth)
    $xs = @($hits | ForEach-Object { $_.X } | Sort-Object)
    $groups = @(); $cur = @($xs[0])
    for ($k = 1; $k -lt $xs.Count; $k++) {
        if ($xs[$k] - $xs[$k - 1] -gt $gap) { $groups += , $cur; $cur = @($xs[$k]) } else { $cur += $xs[$k] }
    }
    $groups += , $cur
    $biggest = ($groups | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    $minSupport = [Math]::Min(2, $biggest)
    $lefts = @($groups | Where-Object { $_.Count -ge $minSupport } | ForEach-Object { ($_ | Measure-Object -Minimum).Minimum })
    $n = [Math]::Min($lefts.Count, 8)
    if ($n -eq 0) { return $null }
    $rights = @(); for ($c = 0; $c -lt $n; $c++) { if ($c + 1 -lt $n) { $rights += ($lefts[$c + 1] - 0.01 * $imageWidth) } else { $rights += $imageWidth } }

    $panelOf = {
        param($x)
        $p = -1
        for ($c = 0; $c -lt $n; $c++) { if ($x -ge $lefts[$c] - $gap / 2) { $p = $c } }
        return $p
    }

    # 2. Values: the first number to the right of each label, before the panel edge or the next label on that row.
    $cells = @{}
    foreach ($h in $hits) {
        $c = & $panelOf $h.X
        if ($c -lt 0) { continue }
        $limit = $rights[$c]
        foreach ($o in $hits) {
            if ($o.X -gt $h.XR -and $o.X -lt $limit -and [Math]::Abs($o.Y - $h.Y) -le 0.6 * $h.H) { $limit = $o.X }
        }
        $row = @($words | Where-Object {
            $_.X -ge $h.XR - 2 -and ($_.X + $_.W / 2) -lt $limit -and
            [Math]::Abs(($_.Y + $_.H / 2) - $h.Y) -le 0.6 * [Math]::Max($h.H, $_.H) } | Sort-Object X)
        foreach ($w in $row) {
            $v = ConvertTo-StatNumber $w.T
            if ($v -ne $null) {
                $key = ([string]$c + '|' + $labels[$h.Index])
                if (-not $cells.ContainsKey($key)) { $cells[$key] = $v }
                break
            }
        }
    }

    # 3. Header above each panel's first visible label.
    $head = @{}
    for ($c = 0; $c -lt $n; $c++) {
        $ph = @($hits | Where-Object { (& $panelOf $_.X) -eq $c })
        if ($ph.Count -eq 0) { continue }
        $top = ($ph | ForEach-Object { $_.Y - $_.H / 2 } | Measure-Object -Minimum).Minimum
        $ys = @($ph | ForEach-Object { $_.Y } | Sort-Object)
        $diffs = @(); for ($k = 1; $k -lt $ys.Count; $k++) { if ($ys[$k] - $ys[$k - 1] -gt $hMed) { $diffs += ($ys[$k] - $ys[$k - 1]) } }
        $spacing = 2.5 * $hMed; if ($diffs.Count -gt 0) { $spacing = Get-Median $diffs }
        $x0 = $lefts[$c] - 0.03 * $imageWidth; $x1 = $rights[$c]
        $hw = @($words | Where-Object {
            $xc = $_.X + $_.W / 2; $yc = $_.Y + $_.H / 2
            $xc -ge $x0 -and $xc -lt $x1 -and $yc -lt $top - 0.2 * $hMed -and $yc -gt $top - 7 * $spacing -and
            $HeaderStopWords -notcontains (Get-NormText $_.T) })

        $out = ''; $place = ''; $pnum = ''; $nameWords = @()
        foreach ($w in $hw) {
            $t = $w.T.Trim()
            if ($t -match '^\d{1,2}[:.]\d{2}$') { $out = ($t -replace '\.', ':') }
            elseif ($t -match '^[-–—_.]{2,}$') { if (-not $out) { $out = '---' } }
            elseif ($t -match '^([1-8lI])(st|nd|rd|th)$') { $place = ($Matches[1] -replace '[lI]', '1') }
            elseif ($t -match '^([1-8lI][Pp]|[Pp][1-8lI])$') { $pnum = (($t -replace '[Pp]', '') -replace '[lI]', '1') }
            elseif ($t -match '^CPU$') { $pnum = 'CPU' }
            elseif ($t -match '^[1-8]$' -and $w.H -ge 1.6 * $hMed) { $place = $t }
            elseif ($t -match '[A-Za-z]') { $nameWords += $w }
        }
        $character = ''; $player = ''
        if ($nameWords.Count -gt 0) {
            $maxH = ($nameWords | ForEach-Object { $_.H } | Measure-Object -Maximum).Maximum
            # Reading order: words whose centers are within half a line of each other count as the same line.
            $lineOf = { [Math]::Round(($_.Y + $_.H / 2) / [Math]::Max(1.0, 0.5 * $_.H)) }
            $big = @($nameWords | Where-Object { $_.H -ge 0.75 * $maxH })
            $small = @($nameWords | Where-Object { $_.H -lt 0.75 * $maxH })
            $character = (@($big | Sort-Object @{ Expression = { [Math]::Round(($_.Y + $_.H / 2) / (0.5 * $maxH)) } }, X | ForEach-Object { $_.T }) -join ' ')
            $player = (@($small | Sort-Object @{ Expression = $lineOf }, X | ForEach-Object { $_.T }) -join ' ')
        }
        $head["$c|character"] = $character
        $head["$c|player"] = $player
        $head["$c|place"] = $place
        $head["$c|num"] = $pnum
        $head["$c|out"] = $out
    }
    return [pscustomobject]@{ N = $n; Cells = $cells; Head = $head }
}
