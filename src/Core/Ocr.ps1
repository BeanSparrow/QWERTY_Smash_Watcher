# Text recognition with the OCR engine built into Windows.

[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]

$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Wait-WinRt($operation, [type]$resultType) {
    $task = $script:AsTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($operation))
    try { [void]$task.Wait(-1) }
    catch {
        $base = $_.Exception
        if ($task.Exception -ne $null) { $base = $task.Exception.GetBaseException() }
        throw ('{0} (0x{1:X8})' -f $base.Message, $base.HResult)
    }
    return $task.Result
}

$OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
$OcrMaxDim = [int][Windows.Media.Ocr.OcrEngine]::MaxImageDimension

# How much to enlarge a frame before OCR. Small text reads much better enlarged.
function Get-OcrScale([int]$width, [int]$height) {
    $scale = 1.0
    if ($width -le 2000) { $scale = 2.0 } elseif ($width -le 2700) { $scale = 1.5 }
    $fit = [double]($OcrMaxDim - 8) / [Math]::Max($width, $height)
    return [Math]::Max(1.0, [Math]::Min($scale, $fit))
}

# Returns the image to OCR. Dispose it afterwards if it isn't the frame you passed in.
function Get-OcrImage($frame, [bool]$enhance) {
    if (-not $enhance) { return $frame }
    $scale = Get-OcrScale $frame.Width $frame.Height
    return [SmashWatcher.Native]::Enhance($frame, $scale, $true)
}

# Reads all text. Returns lines: @{ Text; Words = @( @{ T; X; Y; W; H } ) }, in the image's pixel coordinates.
function Read-Ocr($bmp) {
    if ($OcrEngine -eq $null) { throw 'Windows has no OCR language installed. Add English in Settings > Time and language > Language and region.' }
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $ms.Position = 0
    $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
    try {
        $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $sbmp = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Wait-WinRt ($OcrEngine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])
        $sbmp.Dispose()
    } finally { $ras.Dispose(); $ms.Dispose() }

    $lines = @()
    foreach ($l in $result.Lines) {
        $words = @()
        foreach ($w in $l.Words) {
            $r = $w.BoundingRect
            $words += [pscustomobject]@{ T = $w.Text; X = [double]$r.X; Y = [double]$r.Y; W = [double]$r.Width; H = [double]$r.Height }
        }
        $text = ($l.Text -replace '\s+', ' ').Trim()
        if ($text) { $lines += [pscustomobject]@{ Text = $text; Words = $words } }
    }
    return $lines
}

# Second look at one small area (a value line the full-frame pass missed). The OCR reads short isolated text
# much better when it's enlarged and given a margin. Returns the text left to right, or ''.
function Read-OcrArea($frame, [System.Drawing.Rectangle]$rect) {
    $rect = [System.Drawing.Rectangle]::Intersect($rect, (New-Object System.Drawing.Rectangle 0, 0, $frame.Width, $frame.Height))
    if ($rect.Width -lt 8 -or $rect.Height -lt 8) { return '' }
    $crop = $frame.Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $scale = [Math]::Max(1.0, [Math]::Min(4.0, 150.0 / $rect.Height))
    $w = [int]($rect.Width * $scale); $h = [int]($rect.Height * $scale); $pad = [int](0.4 * $h)
    $canvas = New-Object System.Drawing.Bitmap ($w + 2 * $pad), ($h + 2 * $pad)
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    try {
        $g.Clear([System.Drawing.Color]::Black)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($crop, (New-Object System.Drawing.Rectangle $pad, $pad, $w, $h))
    } finally { $g.Dispose(); $crop.Dispose() }
    $enh = [SmashWatcher.Native]::Enhance($canvas, 1.0, $true)
    $canvas.Dispose()
    try { $lines = @(Read-Ocr $enh) } finally { $enh.Dispose() }
    $ws = @(); foreach ($l in $lines) { $ws += $l.Words }
    return ((@($ws | Sort-Object X | ForEach-Object { $_.T })) -join '')
}

function Format-OcrDump($lines) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $lines) {
        [void]$sb.AppendLine($l.Text)
        foreach ($w in $l.Words) { [void]$sb.AppendLine(('    "{0}"  x={1:N0} y={2:N0} w={3:N0} h={4:N0}' -f $w.T, $w.X, $w.Y, $w.W, $w.H)) }
    }
    return $sb.ToString()
}
