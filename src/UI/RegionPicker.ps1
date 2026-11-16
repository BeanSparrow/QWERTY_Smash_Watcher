# "Set region": take a screenshot of the monitor under the mouse and let the user drag a box on it, like the Snipping Tool.

function Select-ScreenRectangle($shot, $screen) {
    $snip = New-Object System.Windows.Forms.Form
    $snip.FormBorderStyle = 'None'; $snip.StartPosition = 'Manual'; $snip.Bounds = $screen.Bounds
    $snip.TopMost = $true; $snip.Cursor = [System.Windows.Forms.Cursors]::Cross; $snip.KeyPreview = $true
    $snip.AutoScaleMode = 'None'; $snip.BackColor = [System.Drawing.Color]::Black
    $snip.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($snip, $true, $null)
    $script:Snip = @{ Shot = $shot; Drag = $false; P0 = $null; Rect = [System.Drawing.Rectangle]::Empty }
    $snip.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $script:Snip.Rect = [System.Drawing.Rectangle]::Empty; $this.Close() } })
    $snip.Add_MouseDown({ $script:Snip.Drag = $true; $script:Snip.P0 = $_.Location })
    $snip.Add_MouseMove({
        if (-not $script:Snip.Drag) { return }
        $p0 = $script:Snip.P0
        $script:Snip.Rect = New-Object System.Drawing.Rectangle ([Math]::Min($p0.X, $_.X)), ([Math]::Min($p0.Y, $_.Y)), ([Math]::Abs($_.X - $p0.X)), ([Math]::Abs($_.Y - $p0.Y))
        $this.Invalidate()
    })
    $snip.Add_MouseUp({ $script:Snip.Drag = $false; $this.Close() })
    $snip.Add_Paint({
        $g = $_.Graphics
        $g.DrawImage($script:Snip.Shot, 0, 0, $script:Snip.Shot.Width, $script:Snip.Shot.Height)
        if ($script:Snip.Rect.Width -gt 0) {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Red), 2
            $g.DrawRectangle($pen, $script:Snip.Rect); $pen.Dispose()
        }
    })
    [void]$snip.ShowDialog(); $snip.Dispose()
    $r = $script:Snip.Rect
    if ($r.Width -lt 64 -or $r.Height -lt 36) { return $null }
    return $r
}

# Hides the main window, waits for the user to put the mouse on the right monitor, then asks for a box.
function Invoke-RegionPicker($mainForm) {
    Log 'Put the video on screen and keep the mouse on that monitor. Capturing in 4 seconds...'
    $mainForm.WindowState = 'Minimized'
    $end = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $sc = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    $b = $sc.Bounds
    $shot = Copy-ScreenArea $b.X $b.Y $b.Width $b.Height
    [System.Media.SystemSounds]::Asterisk.Play()
    try { $r = Select-ScreenRectangle $shot $sc } finally { $shot.Dispose() }
    $mainForm.WindowState = 'Normal'; $mainForm.Activate()
    if ($r -eq $null) { Log 'Region cancelled (box too small, or Esc).'; return $false }
    $Cfg.region_screen = $sc.DeviceName
    $Cfg.region_x = $r.X; $Cfg.region_y = $r.Y; $Cfg.region_w = $r.Width; $Cfg.region_h = $r.Height
    $Cfg.source_id = 'region'
    Save-Settings
    Log ('Screen region saved ({0}x{1}).' -f $r.Width, $r.Height)
    return $true
}
