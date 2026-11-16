# Video sources: an app window (best: e.g. an OBS / Streamlabs projector), a screen region, or a whole monitor.
# Source ids: 'win:<window title>', 'region', 'screen:<device name>'.

Add-Type -AssemblyName System.Windows.Forms

# Lists everything that can be picked. Projector windows go first since they're the usual choice.
function Find-Sources {
    $list = @()
    $wins = @([SmashWatcher.Native]::ListWindows() | Sort-Object @{ Expression = { $_.Title -notmatch 'projector' } }, Title)
    foreach ($w in $wins) {
        $label = 'Window: ' + $w.Title
        if ($w.Minimized) { $label += '  (minimized)' }
        $list += [pscustomobject]@{ Kind = 'window'; Id = ('win:' + $w.Title); Name = $label }
    }
    $rn = 'Screen region (not set)'
    if ([int]$Cfg.region_w -ge 8) { $rn = ('Screen region ({0}x{1})' -f $Cfg.region_w, $Cfg.region_h) }
    $list += [pscustomobject]@{ Kind = 'region'; Id = 'region'; Name = $rn }
    $i = 1
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $list += [pscustomobject]@{ Kind = 'screen'; Id = ('screen:' + $s.DeviceName); Name = ('Whole screen {0}: {1}x{2}' -f $i, $s.Bounds.Width, $s.Bounds.Height) }
        $i++
    }
    return $list
}

# A saved window id may outlive the window. Find it again by exact title, then by a title that starts the same.
function Find-WindowHandle([string]$title) {
    $wins = @([SmashWatcher.Native]::ListWindows())
    $hit = $wins | Where-Object { $_.Title -eq $title } | Select-Object -First 1
    if ($hit -eq $null) { $hit = $wins | Where-Object { $_.Title.StartsWith($title) -or $title.StartsWith($_.Title) } | Select-Object -First 1 }
    if ($hit -eq $null) { throw ("Can't find the window '" + $title + "'. Is it open? Press Refresh and pick it again.") }
    return $hit.Handle
}

function Copy-ScreenArea([int]$x, [int]$y, [int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h)) } finally { $g.Dispose() }
    return $bmp
}

# Grabs one frame from a source. The caller disposes the bitmap.
function Get-Frame($src) {
    switch ($src.Kind) {
        'window' {
            $title = $src.Id.Substring(4)
            return [SmashWatcher.Native]::CaptureWindow((Find-WindowHandle $title))
        }
        'region' {
            $w = [int]$Cfg.region_w; $h = [int]$Cfg.region_h
            if ($w -lt 8 -or $h -lt 8) { throw "No screen region set yet. Press 'Set region'." }
            $sc = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $Cfg.region_screen } | Select-Object -First 1
            if ($sc -eq $null) { $sc = [System.Windows.Forms.Screen]::PrimaryScreen }
            return Copy-ScreenArea ($sc.Bounds.X + [int]$Cfg.region_x) ($sc.Bounds.Y + [int]$Cfg.region_y) $w $h
        }
        'screen' {
            $sc = [System.Windows.Forms.Screen]::AllScreens | Where-Object { ('screen:' + $_.DeviceName) -eq $src.Id } | Select-Object -First 1
            if ($sc -eq $null) { $sc = [System.Windows.Forms.Screen]::PrimaryScreen }
            $b = $sc.Bounds
            return Copy-ScreenArea $b.X $b.Y $b.Width $b.Height
        }
    }
    throw ('Unknown source: ' + $src.Id)
}

# Loads an image file as a 32-bit bitmap (used by tools and tests).
function Read-ImageFile([string]$path) {
    $tmp = New-Object System.Drawing.Bitmap $path
    try {
        $bmp = New-Object System.Drawing.Bitmap $tmp.Width, $tmp.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.DrawImage($tmp, (New-Object System.Drawing.Rectangle 0, 0, $tmp.Width, $tmp.Height)); $g.Dispose()
        return $bmp
    } finally { $tmp.Dispose() }
}
