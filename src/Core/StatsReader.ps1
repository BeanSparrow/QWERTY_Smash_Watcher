# Reads one frame of the SSBU post-match stats screen.
#
# Layout (from Ken's real samples, Nov 2026): one panel per player, side by side. Each stat is a label bar on the
# left with the player's value on the line below it, right-aligned. Above the list, each panel shows the character
# name (large), "P1"-style player number, the player's tag, and a big placement digit. The list scrolls inside the
# panel, so each frame shows a different slice of the stats; the recorder combines frames.
# KOs and Falls appear as stock icons on this screen (not readable as text).

# Text that can appear near the panel headers but isn't player info (menus, replay overlay, capture app chrome).
# Stats shown as stock icons on the stats screen, so an empty value line there doesn't mean 0.
$NoGuessLabels = @('KOs', 'Falls')

$HeaderStopWords = @('next', 'replay', 'quit', 'save', 'back', 'ok', 'results', 'continue', 'menu', 'fullscreen', 'display', 'projector')

function Get-NormText([string]$s) { return (($s.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s+', ' ').Trim() }
# Folds the digit/letter pairs the OCR confuses most, so "K0s" still matches "KOs".
function Get-FoldText([string]$s) { return ((Get-NormText $s) -replace '0', 'o') -replace '1', 'l' }

# Turns an OCR token into a plain number string ("34.5%" -> "34.5", "1O2" -> "102"), or $null if it isn't one.
function ConvertTo-StatNumber([string]$token) {
    # The OCR often reads "%" as "0/0" or "o/o" (so "9.9%" comes back as "9.90/0").
    $t = $token.Trim() -replace '[0Oo°]/[0Oo]$', '%'
    # A lone zero in the game font often comes back as the letter O ("O", "O sec."). Only called on the value line.
    $t = $t -replace '^[OoQ](?=[.,]?\s*(%|[a-zA-Z/]+\.?)?$)', '0'
    $m = [regex]::Match($t, '^([0-9OoIl|][0-9OoIl|.,]*)\s*(%|[a-zA-Z/]{0,5}\.?)$')
    if (-not $m.Success) { return $null }
    $raw = $m.Groups[1].Value
    if ($raw -notmatch '\d') { return $null }
    $num = (($raw -replace '[Oo]', '0') -replace '[Il|]', '1') -replace ',', ''
    $num = $num.TrimEnd('.')
    if ($num -notmatch '^\d+(\.\d+)?$') { return $null }
    return $num
}

# Snaps an OCR'd character name to the official fighter list ("soNlC" -> "SONIC"). Unknown names are kept as read.
$script:CharacterKeys = $null
function Resolve-CharacterName([string]$raw) {
    if (-not $raw) { return '' }
    if ($script:CharacterKeys -eq $null) {
        $script:CharacterKeys = @(Get-CharacterList | ForEach-Object { [pscustomobject]@{ Name = $_; Key = ((Get-FoldText $_) -replace ' ', '') } })
    }
    $k = (Get-FoldText $raw) -replace ' ', ''
    if (-not $k) { return $raw }
    $best = $null; $bestD = 99
    foreach ($ch in $script:CharacterKeys) {
        if ([Math]::Abs($ch.Key.Length - $k.Length) -gt 3) { continue }
        $d = [SmashWatcher.Native]::Lev($k, $ch.Key)
        if ($d -lt $bestD) { $bestD = $d; $best = $ch }
    }
    if ($best -ne $null -and $bestD -le [Math]::Max(1, [int]($best.Key.Length / 4))) { return $best.Name }
    return $raw.ToUpper()
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

# Reads one frame. $ocr is the OCR of an image $imageWidth wide; $frame (optional) is the original frame, used for
# a second look at values the OCR missed. Returns $null when no stats panel is visible, else
# @{ N = players; Cells = "col|label" -> value; Rechecks = same, from the second look (less sure);
#    Guesses = "col|label" -> "0"; Head = "col|field" -> text }
# with header fields character, player, place, num, out.
function Read-StatsFrame($ocr, [string[]]$labels, [double]$imageWidth, $frame = $null, $digitStore = $null) {
    $words = @(); foreach ($l in $ocr) { $words += $l.Words }
    if ($words.Count -eq 0) { return $null }
    # The first results page ("Out at", KOs, Falls, SDs) has a different layout; the recorder reads it at the end,
    # once the list pages have shown where each player's panel is.
    if (Test-SummaryPage $ocr) { return [pscustomobject]@{ Summary = $true; N = 0; Cells = @{}; Rechecks = @{}; Guesses = @{}; Head = @{} } }
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
    # A panel ends just before the next one starts (4-player panels touch; 2-player panels have a gap).
    $rights = @()
    $step = 0.0; if ($n -ge 2) { $step = ($lefts[$n - 1] - $lefts[0]) / ($n - 1) }
    for ($c = 0; $c -lt $n; $c++) {
        if ($c + 1 -lt $n) { $rights += ($lefts[$c + 1] - 0.05 * $step) }
        elseif ($step -gt 0) { $rights += [Math]::Min($imageWidth, $lefts[$c] + 0.95 * $step) }
        else { $rights += $imageWidth }
    }

    # Replays draw "Next Replay", a countdown number and "Quit" down the middle of the screen, on top of the panels.
    # Ignore anything in that column so the countdown isn't read as a stat. Real end screens don't have it.
    $valueWords = $words
    $isReplay = @($words | Where-Object { @('replay', 'quit') -contains (Get-NormText $_.T) }).Count -gt 0
    if ($isReplay) {
        $cx = $imageWidth / 2
        $valueWords = @($words | Where-Object { [Math]::Abs(($_.X + $_.W / 2) - $cx) -gt 1.5 * $hMed })
    }
    # Each panel ends in an "(A) OK" button and replays add "(B) Quit"; the button icons read as "0" or "O".
    # Drop anything on the same line as an OK or Quit.
    $okWords = @($words | Where-Object { @('ok', 'quit') -contains (Get-FoldText $_.T) })
    if ($okWords.Count -gt 0) {
        $valueWords = @($valueWords | Where-Object {
            $w = $_; $yc = $w.Y + $w.H / 2
            @($okWords | Where-Object { [Math]::Abs(($_.Y + $_.H / 2) - $yc) -lt 0.6 * $_.H }).Count -eq 0 })
    }

    $panelOf = {
        param($x)
        $p = -1
        for ($c = 0; $c -lt $n; $c++) { if ($x -ge $lefts[$c] - $gap / 2) { $p = $c } }
        return $p
    }

    # Row spacing: the usual distance between one label and the next one down in the same panel.
    $diffs = @()
    foreach ($h in $hits) {
        $c = & $panelOf $h.X
        $below = @($hits | Where-Object { $_.Y -gt $h.Y + $hMed -and (& $panelOf $_.X) -eq $c } | ForEach-Object { $_.Y - $h.Y } | Sort-Object)
        if ($below.Count -gt 0) { $diffs += $below[0] }
    }
    $spacing = 4.5 * $hMed
    if ($diffs.Count -gt 0) { $spacing = Get-Median $diffs }

    # 2. Values: each value sits on the line BELOW its label, right-aligned in the panel. Take the rightmost number
    #    between the label and the next label down, inside this panel.
    $cells = @{}
    $cands = New-Object System.Collections.ArrayList
    foreach ($h in $hits) {
        $c = & $panelOf $h.X
        if ($c -lt 0) { continue }
        $yTop = $h.Y + 0.4 * $h.H
        $yBottom = $h.Y + 0.75 * $spacing
        foreach ($o in $hits) {
            if ($o.Y -gt $h.Y + $hMed -and $o.Y - 0.4 * $o.H -lt $yBottom -and (& $panelOf $o.X) -eq $c) { $yBottom = $o.Y - 0.4 * $o.H }
        }
        $band = @($valueWords | Where-Object {
            $xc = $_.X + $_.W / 2; $yc = $_.Y + $_.H / 2
            $xc -gt $h.X -and $xc -lt $rights[$c] -and $yc -gt $yTop -and $yc -lt $yBottom } | Sort-Object X)
        # The OCR sometimes splits one value into pieces ("1" + "79%", "5" + "sec."). Join pieces that sit close
        # together on the same line, then try the joined groups from right to left.
        $pieces = @(); $piece = $null
        foreach ($w in $band) {
            # Units ("sec.", "m") are smaller than the digits, so measure against the taller of the two.
            if ($piece -ne $null) { $big = [Math]::Max($w.H, $piece.H) }
            if ($piece -ne $null -and [Math]::Abs(($w.Y + $w.H / 2) - $piece.Yc) -lt 0.5 * $big -and ($w.X - $piece.XR) -lt 1.2 * $big) {
                $piece.T += $w.T; $piece.XR = $w.X + $w.W
                $piece.YT = [Math]::Min($piece.YT, $w.Y); $piece.YB = [Math]::Max($piece.YB, $w.Y + $w.H)
            } else {
                if ($piece -ne $null) { $pieces += $piece }
                $piece = [pscustomobject]@{ T = $w.T; XL = $w.X; XR = $w.X + $w.W; Yc = $w.Y + $w.H / 2; H = $w.H; YT = $w.Y; YB = $w.Y + $w.H }
            }
        }
        if ($piece -ne $null) { $pieces += $piece }
        [array]::Reverse($pieces)
        $found = @()
        foreach ($w in $pieces) {
            $v = ConvertTo-StatNumber $w.T
            if ($v -ne $null) { $found += [pscustomobject]@{ V = $v; XL = $w.XL; XR = $w.XR; YT = $w.YT; YB = $w.YB } }
        }
        if ($found.Count -gt 0) { [void]$cands.Add([pscustomobject]@{ C = $c; Key = ([string]$c + '|' + $labels[$h.Index]); Found = $found }) }
    }

    $script:LastValueCandidates = $cands   # for tools\ debugging
    $toFrame = 1.0
    if ($frame -ne $null) { $toFrame = $frame.Width / $imageWidth }
    $glyphMinH = 0.8 * $hMed * $toFrame   # digits are at least about as tall as the label text
    $toFrameRect = {
        param($x0, $y0, $x1, $y1)
        New-Object System.Drawing.Rectangle ([int]($x0 * $toFrame)), ([int]($y0 * $toFrame)), ([int](($x1 - $x0) * $toFrame)), ([int](($y1 - $y0) * $toFrame))
    }

    # Values are right-aligned, so in each panel they all end at about the same x. A "number" that ends somewhere
    # else (the A button icon read as "0", stray marks) is not a value.
    for ($c = 0; $c -lt $n; $c++) {
        $mine = @($cands | Where-Object { $_.C -eq $c })
        $edge = $null
        if ($mine.Count -ge 2) { $edge = Get-Median ($mine | ForEach-Object { $_.Found[0].XR }) }
        foreach ($cand in $mine) {
            foreach ($f in $cand.Found) {
                # Allow some slack to the left: units differ in width and a faint unit may not be read at all.
                if ($edge -ne $null -and ($f.XR -lt $edge - 3 * $hMed -or $f.XR -gt $edge + 1.5 * $hMed)) { continue }
                if (-not $cells.ContainsKey($cand.Key)) {
                    $cells[$cand.Key] = $f.V
                    # Learn what these digits look like, for values the OCR misses later.
                    if ($frame -ne $null -and $digitStore -ne $null) {
                        $pad = 0.3 * $hMed
                        Add-DigitExamples $digitStore $frame (& $toFrameRect ($f.XL - $pad) ($f.YT - $pad) ($f.XR + $pad) ($f.YB + $pad)) $f.V $glyphMinH
                    }
                }
                break
            }
        }
    }

    # 3. Second look. If a label is on screen with the next label below it, its value line is fully visible, so a
    #    value is definitely there; the full-frame OCR skips short ones. Read it by digit shape first, then by
    #    OCR on the enlarged line. Either way the result is less certain, so it goes in Rechecks (yellow).
    #    Nothing is guessed: an unreadable value stays blank.
    $guesses = @{}; $rechecks = @{}
    if ($frame -ne $null) {
        foreach ($h in $hits) {
            $c = & $panelOf $h.X
            if ($c -lt 0) { continue }
            $label = $labels[$h.Index]
            $key = ([string]$c + '|' + $label)
            if ($cells.ContainsKey($key)) { continue }
            $next = @($hits | Where-Object { $_.Y -gt $h.Y + $hMed -and (& $panelOf $_.X) -eq $c } | Sort-Object Y | Select-Object -First 1)
            if ($next.Count -eq 0 -or $next[0].Y - $h.Y -gt 1.4 * $spacing) { continue }
            $x0 = $h.X + 0.45 * ($rights[$c] - $h.X); $x1 = $rights[$c]
            $clipped = $false
            if ($isReplay) {
                # Keep clear of the replay countdown in the middle of the screen. A value there may be hidden by
                # the play button, so never guess one.
                $mid = $imageWidth / 2; $clear = 0.7 * $hMed
                if ($x0 -lt $mid + $clear -and $x1 -gt $mid - $clear) {
                    $clipped = $true
                    if ($h.X -lt $mid) { $x1 = $mid - $clear } else { $x0 = $mid + $clear }
                }
            }
            # Just the value line: it sits about halfway between this label and the next.
            $y0 = $h.Y + 0.15 * $spacing; $y1 = [Math]::Min($h.Y + 0.8 * $spacing, $next[0].Y - 0.5 * $next[0].H)
            if ($x1 - $x0 -lt 2 * $hMed -or $y1 - $y0 -lt $hMed) { continue }
            $rect = & $toFrameRect $x0 $y0 $x1 $y1
            if ($NoGuessLabels -contains $label) { continue }   # stock icons, not numbers
            $shape = Read-DigitsByShape $digitStore $frame $rect $glyphMinH
            # Tested on 168 known values from real matches: 167 right, 0 wrong. Very clear matches count as read;
            # merely likely ones are shown yellow.
            if ($shape -ne $null -and $shape.Sure -and $shape.WorstD -le 0.03 -and $shape.WorstRatio -le 0.35) { $cells[$key] = $shape.Value; continue }
            if ($shape -ne $null -and $shape.Sure) { $rechecks[$key] = $shape.Value; continue }
            $v = ConvertTo-StatNumber (Read-OcrArea $frame $rect)
            if ($v -ne $null) { $rechecks[$key] = $v }
        }
    }

    # 3. Header above the list. The list scrolls but the header doesn't, so measure from the highest label on
    #    screen in any panel (a panel's own top label may be missing from this frame).
    $head = @{}
    $top = ($hits | ForEach-Object { $_.Y - $_.H / 2 } | Measure-Object -Minimum).Minimum
    # In replays the big "Next Replay / Replay" text sits over the middle of the headers; skip that strip.
    $stripHalf = 0.0
    if ($isReplay) { $stripHalf = 0.06 * $imageWidth }
    # When the list is scrolled, the row just above the top visible label (its value, or part of its label) sits
    # right under the header. Words that look like a stat value or a stat label word are not player info.
    $labelWords = @($labels | ForEach-Object { (Get-NormText $_).Split(' ') } | Where-Object { $_.Length -ge 4 } | ForEach-Object { Get-FoldText $_ } | Select-Object -Unique)
    $looksLikeStat = {
        param([string]$t)
        if ($t -match '^(sec\.?|m|km/h|%)$') { return $true }
        if ($t -notmatch '^[1-8]$' -and (ConvertTo-StatNumber $t) -ne $null) { return $true }
        $f = (Get-FoldText $t) -replace ' ', ''
        if ($f.Length -lt 4) { return $false }
        foreach ($lw in $labelWords) {
            if ([Math]::Abs($lw.Length - $f.Length) -le 2 -and [SmashWatcher.Native]::Lev($f, $lw) -le [Math]::Max(1, [int]($lw.Length / 5))) { return $true }
        }
        return $false
    }
    for ($c = 0; $c -lt $n; $c++) {
        $x0 = $lefts[$c] - 0.03 * $imageWidth; $x1 = $rights[$c]
        # The header sits a couple of rows above the list. Further up is the capture app's own title bar, so stop there.
        $hw = @($words | Where-Object {
            $xc = $_.X + $_.W / 2; $yc = $_.Y + $_.H / 2
            $xc -ge $x0 -and $xc -lt $x1 -and $yc -lt $top - 0.2 * $hMed -and $yc -gt $top - 2.6 * $spacing -and
            [Math]::Abs($xc - $imageWidth / 2) -ge $stripHalf -and
            $HeaderStopWords -notcontains (Get-NormText $_.T) -and $_.T -notmatch '\d+x\d+' -and -not (& $looksLikeStat $_.T) })

        $out = ''; $place = ''; $pnum = ''; $nameWords = @()
        foreach ($w in $hw) {
            $t = $w.T.Trim()
            if ($t -match '^\d{1,2}[:.]\d{2}$') { $out = ($t -replace '\.', ':') }
            elseif ($t -match '^[-–—_.]{2,}$') { if (-not $out) { $out = '---' } }
            elseif ($t -match '^([1-8lI])(st|nd|rd|th)$') { $place = ($Matches[1] -replace '[lI]', '1') }
            elseif ($t -match '^([1-8lI][Pp]|[Pp][1-8lI])$') { $pnum = (($t -replace '[Pp]', '') -replace '[lI]', '1') }
            elseif ($t -match '^[Pp]([1-8])([A-Za-z].*)$') {
                # "P3" badge read together with the tag ("P3Kam"): split it, and treat the tag as normal-size text.
                # (A real digit only: "Player" must not become "P1" + "ayer".)
                $pnum = $Matches[1]
                $nameWords += [pscustomobject]@{ T = $Matches[2]; X = $w.X + $w.W / 2; Y = $w.Y; W = $w.W / 2; H = $hMed }
            }
            elseif ($t -match '^CPU$') { $pnum = 'CPU' }
            # The placement digit is huge (several times the label text); the "P3" badge is merely big.
            elseif ($t -match '^[1-8]$' -and $w.H -ge 3 * $hMed) { $place = $t }
            elseif ($t -match '^[1-8]$' -and $w.H -ge 1.3 * $hMed) { }   # a lone badge digit: not a name
            elseif ($t -match '[A-Za-z0-9]' -and $w.H -ge 0.5 * $hMed) { $nameWords += $w }   # digits too: "Player 2"
        }
        $character = ''; $player = ''
        if ($nameWords.Count -gt 0) {
            $maxH = ($nameWords | ForEach-Object { $_.H } | Measure-Object -Maximum).Maximum
            # The character name is much larger than everything else; the player tag ("Player 2") is normal size.
            # Names can wrap onto two lines ("DONKEY / KONG") and are drawn at a slant, so group words into lines
            # loosely (a new line starts more than ~2/3 of a word height lower), then read each line left to right.
            $isBig = { $_.H -ge 0.75 * $maxH -and $_.H -ge 1.5 * $hMed }
            $inReadingOrder = {
                param($list)
                $lines = @(); $line = @(); $lastY = $null
                foreach ($w in @($list | Sort-Object { $_.Y + $_.H / 2 })) {
                    $yc = $w.Y + $w.H / 2
                    if ($lastY -ne $null -and $yc - $lastY -gt 0.66 * $w.H) { $lines += , $line; $line = @() }
                    $line += $w; $lastY = $yc
                }
                if ($line.Count -gt 0) { $lines += , $line }
                return (@($lines | ForEach-Object { @($_ | Sort-Object X | ForEach-Object { $_.T }) -join ' ' }) -join ' ')
            }
            $character = Resolve-CharacterName (& $inReadingOrder @($nameWords | Where-Object $isBig))
            $player = & $inReadingOrder @($nameWords | Where-Object { -not (& $isBig) })
            # Default tags are "Player N"; keep exactly that so stray marks don't tag along. Custom names stay as read.
            if ($player -match '(?i)\b(Player\s*[1-8])\b') { $player = $Matches[1] -replace '\s+', ' ' }
        }
        $head["$c|character"] = $character
        $head["$c|player"] = $player
        $head["$c|place"] = $place
        $head["$c|num"] = $pnum
        $head["$c|out"] = $out
    }
    # Panel positions as fractions of the width, so the first page (whose panels have no labels) can be read later.
    $geo = [pscustomobject]@{ Lefts = @($lefts | ForEach-Object { $_ / $imageWidth }); Rights = @($rights | ForEach-Object { $_ / $imageWidth }); LabelH = $hMed / $imageWidth }
    return [pscustomobject]@{ N = $n; Cells = $cells; Rechecks = $rechecks; Guesses = $guesses; Head = $head; Geometry = $geo }
}

# ---------------------------------------------------------------- first results page
# Layout (from real matches): each panel shows "Out at" (the time that player was knocked out, or "---" for the
# winner) and then KOs, Falls and SDs, as large numbers on the same row as the label. Only the left panel has the
# labels; the other panels show just the numbers on the same rows. Falls and SDs are shown negative ("-1").

$SummaryRows = @(
    @{ Key = 'out'; Words = 'outat'; Field = 'head' },
    @{ Key = 'KOs'; Words = 'kos'; Field = 'stat' },
    @{ Key = 'Falls'; Words = 'falls'; Field = 'stat' },
    @{ Key = 'Self-Destructs'; Words = 'sds'; Field = 'stat' }
)

function Test-SummaryPage($ocr) {
    foreach ($l in $ocr) { if (((Get-FoldText $l.Text) -replace ' ', '') -eq 'outat') { return $true } }
    return $false
}

# Reads the first page with known panel positions ($geo from a list page of the same match).
# Returns @{ Cells = "col|stat" -> value; Rechecks; Head = "col|out" -> "m:ss" or "---" }.
function Read-SummaryPage($ocr, [double]$imageWidth, $frame, $digitStore, $geo) {
    $cells = @{}; $rechecks = @{}; $head = @{}
    $toFrame = $frame.Width / $imageWidth
    $words = @(); foreach ($l in $ocr) { $words += $l.Words }
    # row labels, from the OCR lines
    $rows = @()
    foreach ($r in $SummaryRows) {
        foreach ($l in $ocr) {
            if (((Get-FoldText $l.Text) -replace ' ', '') -eq $r.Words) {
                $ws = @($l.Words)
                $rows += [pscustomobject]@{ Key = $r.Key; Field = $r.Field; Y = ($ws | ForEach-Object { $_.Y + $_.H / 2 } | Measure-Object -Average).Average; H = ($ws | ForEach-Object { $_.H } | Measure-Object -Maximum).Maximum }
                break
            }
        }
    }
    if ($rows.Count -lt 2) { return $null }
    $rows = @($rows | Sort-Object Y)
    $gaps = @(); for ($i = 1; $i -lt $rows.Count; $i++) { $gaps += ($rows[$i].Y - $rows[$i - 1].Y) }
    $gap = Get-Median $gaps
    $labelH = Get-Median ($rows | ForEach-Object { $_.H })
    $n = $geo.Lefts.Count
    foreach ($row in $rows) {
        # The big numbers sit lower in their row than the small label text, so look further below the label than
        # above it. The time row is taller than the count rows.
        if ($row.Key -eq 'out') { $y0 = $row.Y - 0.7 * $gap; $y1 = $row.Y + 0.7 * $gap }
        else { $y0 = $row.Y - 0.3 * $gap; $y1 = $row.Y + 0.7 * $gap }
        for ($c = 0; $c -lt $n; $c++) {
            $pl = $geo.Lefts[$c] * $imageWidth; $pr = $geo.Rights[$c] * $imageWidth
            $x0 = $pl + 0.3 * ($pr - $pl); $x1 = $pr
            $inBox = @($words | Where-Object { $xc = $_.X + $_.W / 2; $yc = $_.Y + $_.H / 2; $xc -gt $x0 -and $xc -lt $x1 -and $yc -gt $y0 -and $yc -lt $y1 } | Sort-Object X)
            $text = (@($inBox | ForEach-Object { $_.T }) -join '')
            $rect = New-Object System.Drawing.Rectangle ([int]($x0 * $toFrame)), ([int]($y0 * $toFrame)), ([int](($x1 - $x0) * $toFrame)), ([int](($y1 - $y0) * $toFrame))
            if ($row.Key -eq 'out') {
                if ($text -match '(\d{1,2})[:.](\d{2})') { $head["$c|out"] = '{0}:{1}' -f [int]$Matches[1], $Matches[2]; continue }
                if ($text -match '^[-–—_]{2,}') { $head["$c|out"] = '---'; continue }
                # By shape: three flat bars = "---"; otherwise 3-4 digits = m:ss / mm:ss.
                $flat = @([SmashWatcher.Native]::FindGlyphs($frame, $rect, 170, 75) | Where-Object { $_.W -ge 2 * $_.H -and $_.W -ge $labelH * $toFrame })
                if ($flat.Count -ge 2) { $head["$c|out"] = '---'; continue }
                $shapeTime = $null
                $s = Read-DigitsByShape $digitStore $frame $rect (0.9 * $labelH * $toFrame)
                if ($s -ne $null -and $s.Glyphs -ge 3) {
                    $digits = $s.Value.PadLeft($s.Glyphs, '0')
                    $shapeTime = '{0}:{1}' -f [int]$digits.Substring(0, $digits.Length - 2), $digits.Substring($digits.Length - 2)
                }
                # The time digits are bolder than the list digits, so shape matches are usually "likely" rather than
                # "sure". A sure read counts as read; a likely one is used but shown yellow (Rechecks), and seconds
                # must be a real clock value.
                if ($shapeTime -and [int]$shapeTime.Split(':')[1] -lt 60) {
                    if ($s.Sure) { $head["$c|out"] = $shapeTime } else { $rechecks["$c|out"] = $shapeTime }
                }
                continue
            }
            $key = "$c|" + $row.Key
            $v = ConvertTo-StatNumber ($text -replace '^[-–—]', '')
            if ($v -ne $null) { $cells[$key] = $v; continue }
            $s = Read-DigitsByShape $digitStore $frame $rect (0.9 * $labelH * $toFrame)
            if ($s -ne $null -and $s.Sure -and $s.WorstD -le 0.03 -and $s.WorstRatio -le 0.35) { $cells[$key] = $s.Value }
            elseif ($s -ne $null -and $s.Sure) { $rechecks[$key] = $s.Value }
        }
    }
    return [pscustomobject]@{ Cells = $cells; Rechecks = $rechecks; Head = $head }
}
