# Smash Watcher v2 (no-install). Uses only what Windows already includes.
# Source: webcam / OBS Virtual Camera / capture card (or a monitor as fallback).
# Detects the end screen by on-screen TEXT and/or reference IMAGES, then reads for ~20s,
# pulls out the SSBU stats you've toggled on, and sends them to Google Sheets.

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Here

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class GrayImg { public int W; public int H; public byte[] D; }

public static class SW {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    public static void DpiAware() { try { SetProcessDPIAware(); } catch { } }

    public static void Opaque(byte[] d) { for (int i = 3; i < d.Length; i += 4) d[i] = 255; }

    public static GrayImg Gray(Bitmap bmp, int f) {
        int W = bmp.Width, H = bmp.Height;
        GrayImg g = new GrayImg(); g.W = W / f; g.H = H / f; g.D = new byte[g.W * g.H];
        BitmapData data = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        byte[] buf = new byte[Math.Abs(stride) * H];
        Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(data);
        for (int y = 0; y < g.H; y++) {
            for (int x = 0; x < g.W; x++) {
                int sum = 0;
                for (int dy = 0; dy < f; dy++) {
                    for (int dx = 0; dx < f; dx++) {
                        int i = (y * f + dy) * stride + (x * f + dx) * 4;
                        sum += (buf[i] * 29 + buf[i + 1] * 150 + buf[i + 2] * 77) >> 8;
                    }
                }
                g.D[y * g.W + x] = (byte)(sum / (f * f));
            }
        }
        return g;
    }

    static double ScoreAt(GrayImg fr, int x, int y, int[] off, double[] tv, double tMean, double tSd) {
        int m = off.Length; int b = y * fr.W + x;
        double sum = 0, sumsq = 0, cross = 0;
        for (int k = 0; k < m; k++) {
            double v = fr.D[b + off[k]];
            sum += v; sumsq += v * v; cross += v * tv[k];
        }
        double mean = sum / m; double var = sumsq / m - mean * mean;
        if (var < 1e-6) return -1;
        double cov = cross / m - mean * tMean;
        return cov / (Math.Sqrt(var) * tSd);
    }

    public static double Score(GrayImg fr, GrayImg t) {
        if (t.W > fr.W || t.H > fr.H || t.W < 2 || t.H < 2) return 0;
        int n = t.W * t.H; int step = 1;
        while (n / step > 2500) step++;
        int m = 0; int[] offT = new int[n / step + 1]; double[] tvT = new double[n / step + 1];
        for (int i = 0; i < n; i += step) {
            int ty = i / t.W, tx = i % t.W;
            offT[m] = ty * fr.W + tx; tvT[m] = t.D[i]; m++;
        }
        int[] off = new int[m]; double[] tv = new double[m];
        Array.Copy(offT, off, m); Array.Copy(tvT, tv, m);
        double tMean = 0; for (int k = 0; k < m; k++) tMean += tv[k]; tMean /= m;
        double tVar = 0; for (int k = 0; k < m; k++) tVar += (tv[k] - tMean) * (tv[k] - tMean); tVar /= m;
        double tSd = Math.Sqrt(tVar);
        if (tSd < 1e-6) return 0;
        double best = -1; int bx = 0, by = 0;
        for (int y = 0; y <= fr.H - t.H; y += 2) {
            for (int x = 0; x <= fr.W - t.W; x += 2) {
                double s = ScoreAt(fr, x, y, off, tv, tMean, tSd);
                if (s > best) { best = s; bx = x; by = y; }
            }
        }
        for (int y = Math.Max(0, by - 1); y <= Math.Min(fr.H - t.H, by + 1); y++) {
            for (int x = Math.Max(0, bx - 1); x <= Math.Min(fr.W - t.W, bx + 1); x++) {
                double s = ScoreAt(fr, x, y, off, tv, tMean, tSd);
                if (s > best) best = s;
            }
        }
        return best;
    }
}
'@
[SW]::DpiAware()

# ================= settings =================
$Cfg = @{
    webhook_url = ''; source_id = ''; photo_source = 'Auto'; scale = 4
    region_screen = ''; region_x = 0; region_y = 0; region_w = 0; region_h = 0
    trigger_text = $true; trigger_image = $false
    keywords = @('Damage Given', 'Damage Taken', 'Falls', 'KOs')
    words_needed = 2; image_threshold = 0.80; checks_in_row = 1
    read_duration_s = 20; gameplay_warning_after_s = 90; gameplay_warning = $true
    stats_checked = $null
}
$cfgPath = Join-Path $Here 'settings.json'
if (Test-Path $cfgPath) {
    $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
    foreach ($p in $j.PSObject.Properties) { $Cfg[$p.Name] = $p.Value }
}
$EndDir = Join-Path $Here 'end_images'
$GameDir = Join-Path $Here 'gameplay_images'
$SampleDir = Join-Path $Here 'samples'
$StatsFile = Join-Path $Here 'stats.txt'
foreach ($d in @($EndDir, $GameDir, $SampleDir)) { if (-not (Test-Path $d)) { [void](New-Item -ItemType Directory -Path $d) } }
$script:unitOf = @{}

# ================= WinRT: OCR + camera =================
[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
[void][Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType = WindowsRuntime]
[void][Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
[void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
[void][Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
function Wait-Task($t) {
    try { [void]$t.Wait(-1) }
    catch {
        $b = $_.Exception
        if ($t.Exception -ne $null) { $b = $t.Exception.GetBaseException() }
        throw ('{0} (0x{1:X8})' -f $b.Message, $b.HResult)
    }
}
function Await($op, $type) {
    $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    Wait-Task $t
    return $t.Result
}
function AwaitAction($op) {
    $t = $asTaskAction.Invoke($null, @($op))
    Wait-Task $t
}
$Engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()

function Norm($s) { return (($s.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s+', ' ').Trim() }

function Read-Ocr($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $ms.Position = 0
    $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
    $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $res = Await ($Engine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $out = @()
    foreach ($l in $res.Lines) {
        $words = @()
        foreach ($w in $l.Words) {
            $r = $w.BoundingRect
            $words += [pscustomobject]@{ T = $w.Text; X = [double]$r.X; Y = [double]$r.Y; W = [double]$r.Width; H = [double]$r.Height }
        }
        $t = ($l.Text -replace '\s+', ' ').Trim()
        if ($t) { $out += [pscustomobject]@{ Text = $t; Words = $words } }
    }
    $sb.Dispose(); $ras.Dispose(); $ms.Dispose()
    return , $out
}

# ================= sources (camera / capture card / monitor) =================
$script:sources = @()
$script:mc = $null
$script:openId = $null
$script:previewOn = $false

function Find-Sources {
    $list = @()
    $seenIds = @{}
    foreach ($mode in @('selector', 'class')) {
        try {
            if ($mode -eq 'selector') {
                [void][Windows.Media.Devices.MediaDevice, Windows.Media.Devices, ContentType = WindowsRuntime]
                $op = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync([Windows.Media.Devices.MediaDevice]::GetVideoCaptureSelector())
            } else {
                $op = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync([Windows.Devices.Enumeration.DeviceClass]::VideoCapture)
            }
            $col = Await $op ([Windows.Devices.Enumeration.DeviceInformationCollection])
            foreach ($d in $col) {
                if (-not $seenIds.ContainsKey($d.Id)) { $seenIds[$d.Id] = $true; $list += [pscustomobject]@{ Kind = 'cam'; Id = $d.Id; Name = ('Camera: ' + $d.Name) } }
            }
        } catch { }
    }
    $rn = 'Screen region (not set)'; if ([int]$Cfg.region_w -ge 8) { $rn = ('Screen region ({0}x{1})' -f $Cfg.region_w, $Cfg.region_h) }
    $list += [pscustomobject]@{ Kind = 'region'; Id = 'region'; Name = $rn }
    $i = 1
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $list += [pscustomobject]@{ Kind = 'screen'; Id = ('screen:' + $s.DeviceName); Name = ('Screen {0}: {1}x{2}' -f $i, $s.Bounds.Width, $s.Bounds.Height) }
        $i++
    }
    return , $list
}

function Close-Source {
    if ($script:mc -ne $null) {
        if ($script:previewOn) { try { AwaitAction ($script:mc.StopPreviewAsync()) } catch { } }
        try { $script:mc.Dispose() } catch { }
        $script:mc = $null
    }
    $script:previewOn = $false
    $script:openId = $null
}
function Open-Source($src) {
    Close-Source
    if ($src.Kind -eq 'cam') {
        $lastErr = $null
        foreach ($attempt in @('with', 'without')) {
            $mc = New-Object Windows.Media.Capture.MediaCapture
            $st = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
            $st.VideoDeviceId = $src.Id
            $st.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
            if ($attempt -eq 'with') { try { $st.PhotoCaptureSource = [Windows.Media.Capture.PhotoCaptureSource]::$($Cfg.photo_source) } catch { } }
            try { AwaitAction ($mc.InitializeAsync($st)); $script:mc = $mc; $lastErr = $null; break }
            catch { $lastErr = $_.Exception.Message; try { $mc.Dispose() } catch { } }
        }
        if (-not $lastErr) {
            try {
                [void][Windows.Media.VideoFrame, Windows.Foundation, ContentType = WindowsRuntime]
                [void][Windows.Storage.Streams.Buffer, Windows.Storage.Streams, ContentType = WindowsRuntime]
                AwaitAction ($script:mc.StartPreviewAsync())
                $script:previewOn = $true
                Log 'Camera opened (live stream mode).'
            } catch {
                $script:previewOn = $false
                Log ('Camera opened (photo mode; live stream unavailable: ' + $_.Exception.Message + ').')
            }
        }
        if ($lastErr) {
            throw ("Windows couldn't open this camera (" + $lastErr + "). Common causes: another app (such as OBS) is using it; camera access is off in Settings > Privacy > Camera; or it is a DirectShow-only device such as OBS Virtual Camera, which Windows' camera API can't open. Workaround: show your video in an OBS projector window, then use 'Set region' and pick the 'Screen region' source.")
        }
    }
    elseif ($src.Kind -eq 'region' -and [int]$Cfg.region_w -lt 8) { throw "No screen region set yet. Press 'Set region'." }
    $script:openId = $src.Id
}
function Detach-Bitmap($tmp) {
    $b = New-Object System.Drawing.Bitmap $tmp.Width, $tmp.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($b); $g.DrawImage($tmp, 0, 0, $tmp.Width, $tmp.Height); $g.Dispose()
    return $b
}
function Get-PreviewBitmap {
    $w = 0; $h = 0
    try {
        $vp = $script:mc.VideoDeviceController.GetMediaStreamProperties([Windows.Media.Capture.MediaStreamType]::VideoPreview)
        $w = [int]$vp.Width; $h = [int]$vp.Height
    } catch { }
    if ($w -gt 0 -and $h -gt 0) {
        $vf = New-Object Windows.Media.VideoFrame ([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8), $w, $h
        $res = Await ($script:mc.GetPreviewFrameAsync($vf)) ([Windows.Media.VideoFrame])
    } else {
        $res = Await ($script:mc.GetPreviewFrameAsync()) ([Windows.Media.VideoFrame])
    }
    $sb0 = $res.SoftwareBitmap
    if ($sb0 -eq $null) { throw 'The camera returned no frame yet.' }
    $sb = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert($sb0, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, [Windows.Graphics.Imaging.BitmapAlphaMode]::Ignore)
    $bw = $sb.PixelWidth; $bh = $sb.PixelHeight
    $buf = New-Object Windows.Storage.Streams.Buffer ([uint32]($bw * $bh * 4))
    $buf.Length = $buf.Capacity
    $sb.CopyToBuffer($buf)
    $bytes = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::ToArray($buf)
    [SW]::Opaque($bytes)
    $bmp = New-Object System.Drawing.Bitmap $bw, $bh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bd = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $bw, $bh), [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $bd.Scan0, [Math]::Min($bytes.Length, [Math]::Abs($bd.Stride) * $bh))
    $bmp.UnlockBits($bd)
    $sb.Dispose(); $sb0.Dispose(); $res.Dispose()
    return $bmp
}
function Get-Frame($src) {
    if ($src.Kind -eq 'region') {
        $sc = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $Cfg.region_screen } | Select-Object -First 1
        if ($sc -eq $null) { $sc = [System.Windows.Forms.Screen]::PrimaryScreen }
        $w = [int]$Cfg.region_w; $h = [int]$Cfg.region_h
        if ($w -lt 8 -or $h -lt 8) { throw "No screen region set yet. Press 'Set region'." }
        $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($sc.Bounds.X + [int]$Cfg.region_x, $sc.Bounds.Y + [int]$Cfg.region_y, 0, 0, (New-Object System.Drawing.Size $w, $h)); $g.Dispose()
        return $bmp
    }
    if ($src.Kind -eq 'screen') {
        $sc = [System.Windows.Forms.Screen]::AllScreens | Where-Object { ('screen:' + $_.DeviceName) -eq $src.Id } | Select-Object -First 1
        if ($sc -eq $null) { $sc = [System.Windows.Forms.Screen]::PrimaryScreen }
        $b = $sc.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); $g.Dispose()
        return $bmp
    }
    if ($script:mc -eq $null) { throw 'Camera is not open.' }
    if ($script:previewOn) {
        $perr = $null
        for ($try = 1; $try -le 4; $try++) {
            try { return (Get-PreviewBitmap) } catch { $perr = $_.Exception.Message; Start-Sleep -Milliseconds 300 }
        }
        throw ('Could not grab a frame from the camera stream: ' + $perr)
    }
    $ras = $null; $capErr = $null
    for ($try = 1; $try -le 3; $try++) {
        $ras = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
        try {
            $props = [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateBmp()
            AwaitAction ($script:mc.CapturePhotoToStreamAsync($props, $ras))
            $capErr = $null; break
        } catch { $capErr = $_.Exception.Message; $ras.Dispose(); Start-Sleep -Milliseconds 400 }
    }
    if ($capErr) { throw ('Could not grab a frame from the camera: ' + $capErr) }
    $ras.Seek(0)
    $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ras)
    $copy = New-Object System.IO.MemoryStream
    $net.CopyTo($copy); $copy.Position = 0
    $tmp = New-Object System.Drawing.Bitmap $copy
    $bmp = Detach-Bitmap $tmp
    $tmp.Dispose(); $copy.Dispose(); $ras.Dispose()
    return $bmp
}

# ================= templates (images) =================
function Load-Templates($dir) {
    $out = @()
    foreach ($f in (Get-ChildItem -Path $dir -Filter *.png -ErrorAction SilentlyContinue)) {
        $raw = New-Object System.Drawing.Bitmap $f.FullName
        $conv = Detach-Bitmap $raw; $raw.Dispose()
        $out += [SW]::Gray($conv, [int]$Cfg.scale); $conv.Dispose()
    }
    return , $out
}
function Best-Score($gray, $templates) {
    $best = 0.0
    foreach ($t in $templates) { $s = [SW]::Score($gray, $t); if ($s -gt $best) { $best = $s } }
    return $best
}

# ================= text + stats logic =================
function Get-Keys { return @($tbKeys.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Text-Hits($ocr, $keys) {
    $full = Norm (($ocr | ForEach-Object { $_.Text }) -join ' ')
    $hits = @()
    foreach ($k in $keys) { $n = Norm $k; if ($n -and $full.Contains($n)) { $hits += $k } }
    return , $hits
}
function Fold($s) { return ($s -replace '0', 'o') -replace '1', 'l' }
function Lev($a, $b) {
    $n = $a.Length; $m = $b.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = 0..$m
    for ($i = 1; $i -le $n; $i++) {
        $cur = New-Object int[] ($m + 1); $cur[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1; if ($a[$i - 1] -eq $b[$j - 1]) { $cost = 0 }
            $cur[$j] = [Math]::Min([Math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return $prev[$m]
}
function All-Labels { return @($clb.Items | ForEach-Object { [string]$_ }) }

function Top($d) { return ($d.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
function Vote-Add($key, $val) {
    if ($val -eq $null -or [string]$val -eq '') { return }
    if (-not $script:votes.ContainsKey($key)) { $script:votes[$key] = @{} }
    if ($script:votes[$key].ContainsKey($val)) { $script:votes[$key][$val]++ } else { $script:votes[$key][$val] = 1 }
}
function Clean-Num($t) { return ([regex]::Match($t, '^\d[\d.,]*').Value -replace ',', '') }
function Parse-Time($s) {
    if ($s -match '^(\d{1,2}):(\d{2})$') { return ([int]$Matches[1] * 60 + [int]$Matches[2]) }
    return $null
}
function Disp-Label($l) { $u = $script:unitOf[$l]; if ($u) { return ($l + ' (' + $u + ')') } else { return $l } }
function Get-Header {
    $h = @('detected_at', 'player_no', 'name', 'placement', 'survival_time_s')
    foreach ($l in (All-Labels)) { $h += (Disp-Label $l) }
    return , $h
}

# Locates each stat label on screen. Exact matches first, then close matches (OCR slips) that
# are not an exact match for some other label. Returns @{ labelIndex = @{Y;H;XR} }.
function Find-Anchors($ocr, $allLabels) {
    $fl = @(); foreach ($l in $allLabels) { $fl += (Fold (Norm $l)) }
    $exactSet = @{}; foreach ($f in $fl) { $exactSet[$f] = $true }
    $winCache = @{}
    function Get-Wins($n) {
        if ($winCache.ContainsKey($n)) { return , $winCache[$n] }
        $list = @()
        foreach ($l in $ocr) {
            $ws = @($l.Words)
            for ($i = 0; $i + $n -le $ws.Count; $i++) {
                $win = @($ws[$i..($i + $n - 1)])
                $list += [pscustomobject]@{ Txt = (Fold (Norm (($win | ForEach-Object { $_.T }) -join ' '))); Win = $win }
            }
        }
        $winCache[$n] = $list
        return , $list
    }
    function To-Anchor($win) {
        return [pscustomobject]@{
            Y  = ($win | ForEach-Object { $_.Y + $_.H / 2 } | Measure-Object -Average).Average
            H  = ($win | ForEach-Object { $_.H } | Measure-Object -Average).Average
            XR = ($win | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
        }
    }
    $anchors = @{}
    for ($i = 0; $i -lt $fl.Count; $i++) {
        if (-not $fl[$i]) { continue }
        $n = $fl[$i].Split(' ').Count
        foreach ($w in (Get-Wins $n)) { if ($w.Txt -eq $fl[$i]) { $anchors[$i] = (To-Anchor $w.Win); break } }
    }
    for ($i = 0; $i -lt $fl.Count; $i++) {
        if ($anchors.ContainsKey($i) -or -not $fl[$i] -or $fl[$i].Length -lt 6) { continue }
        $n = $fl[$i].Split(' ').Count
        $tol = [int][Math]::Floor($fl[$i].Length / 5)
        $bestD = 99; $bestW = $null
        foreach ($w in (Get-Wins $n)) {
            if ($exactSet.ContainsKey($w.Txt)) { continue }
            if ([Math]::Abs($w.Txt.Length - $fl[$i].Length) -gt $tol -or $w.Txt[0] -ne $fl[$i][0]) { continue }
            $d = Lev $w.Txt $fl[$i]
            if ($d -le $tol -and $d -lt $bestD) { $bestD = $d; $bestW = $w.Win }
        }
        if ($bestW -ne $null) { $anchors[$i] = (To-Anchor $bestW) }
    }
    return $anchors
}

# Reads one frame of the stats table. Columns are the players (left to right).
# Returns $null if the table isn't on screen, else @{ N = player count; Cells = "col|label" -> value; Head = "col|field" -> text }.
function Extract-Match($ocr, $allLabels, $wanted) {
    $allWords = @(); foreach ($l in $ocr) { $allWords += $l.Words }
    if ($allWords.Count -eq 0) { return $null }
    $anchors = Find-Anchors $ocr $allLabels
    if ($anchors.Count -eq 0) { return $null }
    $idx = @($anchors.Keys | Sort-Object)
    $spacing = 0.0
    if ($idx.Count -ge 2) { $spacing = ($anchors[$idx[$idx.Count - 1]].Y - $anchors[$idx[0]].Y) / ($idx[$idx.Count - 1] - $idx[0]) }
    $hAvg = ($anchors.Values | ForEach-Object { $_.H } | Measure-Object -Average).Average
    $xrMin = ($anchors.Values | ForEach-Object { $_.XR } | Measure-Object -Minimum).Minimum
    $numPat = '^\d[\d.,]*(%|[a-zA-Z/]{0,5})?$'

    # numbers on each wanted row (row position is interpolated for labels the OCR missed)
    $rowNums = @{}
    for ($i = 0; $i -lt $allLabels.Count; $i++) {
        if (-not ($wanted -contains $allLabels[$i])) { continue }
        $y = $null; $xmin = $xrMin
        if ($anchors.ContainsKey($i)) { $y = $anchors[$i].Y; $xmin = $anchors[$i].XR }
        else {
            $lo = $null; $hi = $null
            foreach ($k in $idx) { if ($k -lt $i) { $lo = $k } elseif ($k -gt $i -and $hi -eq $null) { $hi = $k } }
            if ($lo -ne $null -and $hi -ne $null) { $y = $anchors[$lo].Y + ($anchors[$hi].Y - $anchors[$lo].Y) * ($i - $lo) / ($hi - $lo) }
        }
        if ($y -eq $null) { continue }
        $tolY = $hAvg * 0.7; if ($spacing -gt 0) { $tolY = [Math]::Min($tolY, $spacing * 0.45) }
        $nums = @($allWords | Where-Object { ($_.X -ge $xmin - 2) -and ([Math]::Abs($_.Y + $_.H / 2 - $y) -le $tolY) -and ($_.T -match $numPat) })
        if ($nums.Count -gt 0) { $rowNums[$i] = $nums }
    }
    if ($rowNums.Count -eq 0) { return $null }

    # player columns = clusters of number positions
    $xs = @(); foreach ($i in $rowNums.Keys) { foreach ($w in $rowNums[$i]) { $xs += ($w.X + $w.W / 2) } }
    $xs = @($xs | Sort-Object)
    $gap = [Math]::Max(40.0, 2.5 * $hAvg)
    $groups = @(); $cur = @($xs[0])
    for ($k = 1; $k -lt $xs.Count; $k++) {
        if ($xs[$k] - $xs[$k - 1] -gt $gap) { $groups += , $cur; $cur = @($xs[$k]) } else { $cur += $xs[$k] }
    }
    $groups += , $cur
    $minSupport = [Math]::Max(1, [int][Math]::Floor(0.3 * $rowNums.Count))
    $centers = @($groups | Where-Object { $_.Count -ge $minSupport } | ForEach-Object { ($_ | Measure-Object -Average).Average })
    if ($centers.Count -eq 0) { return $null }
    $n = [Math]::Min($centers.Count, 8)

    $cells = @{}
    foreach ($i in $rowNums.Keys) {
        foreach ($w in @($rowNums[$i] | Sort-Object X)) {
            $xc = $w.X + $w.W / 2; $bc = -1; $bd = 1e9
            for ($c = 0; $c -lt $n; $c++) { $d = [Math]::Abs($xc - $centers[$c]); if ($d -lt $bd) { $bd = $d; $bc = $c } }
            if ($bc -ge 0 -and $bd -le $gap) {
                $key = ([string]$bc + '|' + $allLabels[$i])
                if (-not $cells.ContainsKey($key)) { $cells[$key] = (Clean-Num $w.T) }
            }
        }
    }

    # header block above the first stat row: name, placement, player number, time out
    $top = ($anchors.Values | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
    $rowH = $spacing; if ($rowH -le 0) { $rowH = 2.5 * $hAvg }
    $csp = 400.0
    if ($n -ge 2) { $csp = 1e9; for ($c = 1; $c -lt $n; $c++) { $csp = [Math]::Min($csp, $centers[$c] - $centers[$c - 1]) } }
    $tolC = [Math]::Max($gap, 0.45 * $csp)
    $hw = @($allWords | Where-Object { $yc = $_.Y + $_.H / 2; ($yc -lt $top - $hAvg * 0.6) -and ($yc -gt $top - 8 * $rowH) })
    $byCol = @{}
    foreach ($w in $hw) {
        $xc = $w.X + $w.W / 2; $bc = -1; $bd = 1e9
        for ($c = 0; $c -lt $n; $c++) { $d = [Math]::Abs($xc - $centers[$c]); if ($d -lt $bd) { $bd = $d; $bc = $c } }
        if ($bc -ge 0 -and $bd -le $tolC) { if (-not $byCol.ContainsKey($bc)) { $byCol[$bc] = @() }; $byCol[$bc] += $w }
    }
    $head = @{}
    for ($c = 0; $c -lt $n; $c++) {
        if (-not $byCol.ContainsKey($c)) { continue }
        $nameToks = @(); $out = ''; $place = ''; $pnum = ''
        foreach ($w in $byCol[$c]) {
            $t = $w.T
            if ($t -match '^\d{1,2}:\d{2}$') { $out = $t }
            elseif ($t -match '^[-–—_.]+$') { if (-not $out) { $out = '---' } }
            elseif ($t -match '^[1-8lI](st|nd|rd|th)$') { $p = $t.Substring(0, 1); if ($p -match '[lI]') { $p = '1' }; $place = $p }
            elseif ($t -match '^([1-8lI][Pp]|[Pp][1-8lI])$') { $p = ($t -replace '[Pp]', ''); if ($p -match '[lI]') { $p = '1' }; $pnum = $p }
            else { $nameToks += $t }
        }
        $head[([string]$c + '|name')] = ($nameToks -join ' ')
        $head[([string]$c + '|place')] = $place
        $head[([string]$c + '|num')] = $pnum
        $head[([string]$c + '|out')] = $out
    }
    return [pscustomobject]@{ N = $n; Cells = $cells; Head = $head }
}

# ================= output =================
function Csv-Line($arr) { return (($arr | ForEach-Object { '"' + ([string]$_ -replace '"', '""') + '"' }) -join ',') }
function Save-Csv($path, $header, $rows) {
    $enc = New-Object System.Text.UTF8Encoding $true
    $sb = New-Object System.Text.StringBuilder
    if (-not (Test-Path $path)) { [void]$sb.AppendLine((Csv-Line $header)) }
    foreach ($r in $rows) { [void]$sb.AppendLine((Csv-Line $r)) }
    [System.IO.File]::AppendAllText($path, $sb.ToString(), $enc)
}
function Jv($v) {
    if ($v -is [int] -or $v -is [double]) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $v) }
    $s = [string]$v
    if ($s -match '^-?\d+(\.\d+)?$') { return $s }
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
    return '"' + $s + '"'
}
function Send-Sheet($sheet, $header, $rows) {
    if (-not $Cfg.webhook_url -or $Cfg.webhook_url -like 'PASTE*') { throw 'webhook_url is empty in settings.json' }
    $rowsJson = ($rows | ForEach-Object { '[' + (($_ | ForEach-Object { Jv $_ }) -join ',') + ']' }) -join ','
    $json = '{"sheet":' + (Jv $sheet) + ',"header":[' + (($header | ForEach-Object { Jv $_ }) -join ',') + '],"rows":[' + $rowsJson + ']}'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $resp = Invoke-RestMethod -Uri $Cfg.webhook_url -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
    $txt = ([string]$resp).Trim()
    if ($txt -ne 'ok') {
        $short = (($txt -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
        if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
        throw ('Google answered: "' + $short + '". Check that the deployment is set to "Anyone" and that the URL ends in /exec.')
    }
}

# ================= UI =================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Smash Watcher'; $form.Size = New-Object System.Drawing.Size(470, 700); $form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(450, 640)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
function New-Ctl($type, $x, $y, $w, $h, $text) {
    $c = New-Object $type; $c.SetBounds($x, $y, $w, $h); if ($text -ne $null) { $c.Text = $text }; return $c
}

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.SetBounds(8, 8, 438, 645); $tabs.Anchor = 'Top,Bottom,Left,Right'
$tabRun = New-Object System.Windows.Forms.TabPage 'Run'
$tabDet = New-Object System.Windows.Forms.TabPage 'Detection'
$tabStat = New-Object System.Windows.Forms.TabPage 'Stats'
foreach ($t in @($tabRun, $tabDet, $tabStat)) { $tabs.TabPages.Add($t) }
$form.Controls.Add($tabs)

# ----- Run tab -----
$status = New-Ctl System.Windows.Forms.Label 8 8 415 40 'Idle'
$status.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold); $status.TextAlign = 'MiddleCenter'
$detail = New-Ctl System.Windows.Forms.Label 8 48 415 34 ''
$detail.ForeColor = [System.Drawing.Color]::Gray; $detail.Font = New-Object System.Drawing.Font('Segoe UI', 8.5); $detail.TextAlign = 'MiddleCenter'
$startBtn = New-Ctl System.Windows.Forms.Button 70 88 140 42 'Start'
$startBtn.BackColor = [System.Drawing.Color]::SeaGreen; $startBtn.ForeColor = [System.Drawing.Color]::White; $startBtn.FlatStyle = 'Flat'
$stopBtn = New-Ctl System.Windows.Forms.Button 220 88 140 42 'Stop'; $stopBtn.Enabled = $false
$stopBtn.BackColor = [System.Drawing.Color]::Firebrick; $stopBtn.ForeColor = [System.Drawing.Color]::White; $stopBtn.FlatStyle = 'Flat'
$lblSrc = New-Ctl System.Windows.Forms.Label 8 142 60 22 'Source'
$cbSrc = New-Ctl System.Windows.Forms.ComboBox 70 138 196 26 $null; $cbSrc.DropDownStyle = 'DropDownList'
$btnRefresh = New-Ctl System.Windows.Forms.Button 272 137 66 28 'Refresh'
$btnRegion = New-Ctl System.Windows.Forms.Button 344 137 80 28 'Set region'
$pic = New-Ctl System.Windows.Forms.PictureBox 8 172 415 234 $null; $pic.SizeMode = 'Zoom'; $pic.BackColor = [System.Drawing.Color]::Black
$logBox = New-Ctl System.Windows.Forms.TextBox 8 414 415 190 $null
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'; $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Anchor = 'Top,Bottom,Left,Right'
foreach ($c in @($status, $detail, $startBtn, $stopBtn, $lblSrc, $cbSrc, $btnRefresh, $btnRegion, $pic, $logBox)) { $tabRun.Controls.Add($c) }

# ----- Detection tab -----
$gTxt = New-Ctl System.Windows.Forms.GroupBox 8 6 415 215 'Detect by text on screen'
$chkText = New-Ctl System.Windows.Forms.CheckBox 12 22 380 22 'Use text detection'
$lblKeys = New-Ctl System.Windows.Forms.Label 12 46 390 18 'Words that appear on the end screen (one per line):'
$tbKeys = New-Ctl System.Windows.Forms.TextBox 12 66 390 80 $null; $tbKeys.Multiline = $true; $tbKeys.ScrollBars = 'Vertical'
$lblNeed = New-Ctl System.Windows.Forms.Label 12 154 190 22 'Words needed to trigger:'
$numNeed = New-Ctl System.Windows.Forms.NumericUpDown 205 150 60 26 $null; $numNeed.Minimum = 1; $numNeed.Maximum = 20
$lblHits = New-Ctl System.Windows.Forms.Label 12 184 390 22 'Live: -'
$lblHits.ForeColor = [System.Drawing.Color]::DimGray
foreach ($c in @($chkText, $lblKeys, $tbKeys, $lblNeed, $numNeed, $lblHits)) { $gTxt.Controls.Add($c) }

$gImg = New-Ctl System.Windows.Forms.GroupBox 8 228 415 150 'Detect by reference images (any one matching triggers)'
$chkImg = New-Ctl System.Windows.Forms.CheckBox 12 22 380 22 'Use image detection'
$btnAddEnd = New-Ctl System.Windows.Forms.Button 12 48 150 28 'Add end-screen image'
$btnClrEnd = New-Ctl System.Windows.Forms.Button 168 48 90 28 'Clear all'
$lblEndCount = New-Ctl System.Windows.Forms.Label 266 53 140 22 ''
$lblThr = New-Ctl System.Windows.Forms.Label 12 86 390 20 'Match strictness:'
$trkThr = New-Ctl System.Windows.Forms.TrackBar 12 104 390 40 $null; $trkThr.Minimum = 50; $trkThr.Maximum = 99; $trkThr.TickFrequency = 5
foreach ($c in @($chkImg, $btnAddEnd, $btnClrEnd, $lblEndCount, $lblThr, $trkThr)) { $gImg.Controls.Add($c) }

$gCommon = New-Ctl System.Windows.Forms.GroupBox 8 384 415 132 'Trigger safety and gameplay warning'
$lblRow = New-Ctl System.Windows.Forms.Label 12 24 250 22 'Checks in a row before triggering:'
$numRow = New-Ctl System.Windows.Forms.NumericUpDown 265 20 60 26 $null; $numRow.Minimum = 1; $numRow.Maximum = 10
$btnAddGame = New-Ctl System.Windows.Forms.Button 12 56 190 28 'Add gameplay image (warning)'
$btnClrGame = New-Ctl System.Windows.Forms.Button 208 56 70 28 'Clear'
$lblGameCount = New-Ctl System.Windows.Forms.Label 284 61 125 22 ''
$chkGame = New-Ctl System.Windows.Forms.CheckBox 12 94 390 24 'Warn me if no gameplay is seen (needs a gameplay image)'
foreach ($c in @($lblRow, $numRow, $btnAddGame, $btnClrGame, $lblGameCount, $chkGame)) { $gCommon.Controls.Add($c) }

$btnTest = New-Ctl System.Windows.Forms.Button 8 526 200 32 'Test now (check this frame)'
$btnSample = New-Ctl System.Windows.Forms.Button 214 526 209 32 'Save sample (image + text dump)'
$tabDet.Controls.AddRange(@($gTxt, $gImg, $gCommon, $btnTest, $btnSample))

# ----- Stats tab -----
$lblStat = New-Ctl System.Windows.Forms.Label 8 8 415 36 'Tick the stats to record. The list is in on-screen order, top to bottom (edit stats.txt: one per line, optional unit after a |). Unticked stats stay blank in the sheet.'
$clb = New-Ctl System.Windows.Forms.CheckedListBox 8 48 415 380 $null; $clb.CheckOnClick = $true; $clb.Anchor = 'Top,Bottom,Left,Right'
$btnAll = New-Ctl System.Windows.Forms.Button 8 436 80 28 'All on'; $btnAll.Anchor = 'Bottom,Left'
$btnNone = New-Ctl System.Windows.Forms.Button 94 436 80 28 'All off'; $btnNone.Anchor = 'Bottom,Left'
$btnEditStats = New-Ctl System.Windows.Forms.Button 180 436 160 28 'Edit stat labels file'; $btnEditStats.Anchor = 'Bottom,Left'
$btnTestSheet = New-Ctl System.Windows.Forms.Button 8 468 260 28 'Test Google Sheets connection'; $btnTestSheet.Anchor = 'Bottom,Left'
$lblDur = New-Ctl System.Windows.Forms.Label 8 504 200 22 'Read for (seconds):'; $lblDur.Anchor = 'Bottom,Left'
$numDur = New-Ctl System.Windows.Forms.NumericUpDown 150 500 70 26 $null; $numDur.Minimum = 3; $numDur.Maximum = 120; $numDur.Anchor = 'Bottom,Left'
$tabStat.Controls.AddRange(@($lblStat, $clb, $btnAll, $btnNone, $btnEditStats, $btnTestSheet, $lblDur, $numDur))

# ================= UI helpers =================
function Log($m) { $logBox.AppendText(('[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $m, "`r`n")) }
function Set-Status($t, $color) { $status.Text = $t; $status.ForeColor = [System.Drawing.Color]::FromName($color) }
function Beep { [System.Media.SystemSounds]::Exclamation.Play() }
function Count-Images($dir) { return @(Get-ChildItem -Path $dir -Filter *.png -ErrorAction SilentlyContinue).Count }
function Refresh-Counts {
    $lblEndCount.Text = ('{0} saved' -f (Count-Images $EndDir))
    $lblGameCount.Text = ('{0} saved' -f (Count-Images $GameDir))
}
function Load-StatLabels {
    $clb.Items.Clear()
    $checked = $Cfg.stats_checked
    $script:unitOf = @{}
    foreach ($line in (Get-Content $StatsFile -Encoding UTF8)) {
        $parts = $line.Split('|'); $s = $parts[0].Trim(); if (-not $s) { continue }
        if ($parts.Count -gt 1) { $script:unitOf[$s] = $parts[1].Trim() }
        $on = ($checked -eq $null) -or ($checked -contains $s)
        [void]$clb.Items.Add($s, $on)
    }
}
function Save-Settings {
    if ($script:loading) { return }
    $Cfg.trigger_text = [bool]$chkText.Checked; $Cfg.trigger_image = [bool]$chkImg.Checked
    $Cfg.keywords = @(Get-Keys); $Cfg.words_needed = [int]$numNeed.Value
    $Cfg.image_threshold = [double]($trkThr.Value / 100.0); $Cfg.checks_in_row = [int]$numRow.Value
    $Cfg.read_duration_s = [int]$numDur.Value; $Cfg.gameplay_warning = [bool]$chkGame.Checked
    $Cfg.stats_checked = @($clb.CheckedItems | ForEach-Object { [string]$_ })
    $sel = $cbSrc.SelectedIndex
    if ($sel -ge 0 -and $sel -lt $script:sources.Count) { $Cfg.source_id = $script:sources[$sel].Id }
    ($Cfg | ConvertTo-Json -Depth 4) | Set-Content -Path $cfgPath -Encoding UTF8
}
function Set-Idle {
    Close-Source
    $script:state = 'idle'
    $startBtn.Enabled = $true; $stopBtn.Enabled = $false; $detail.Text = ''
    foreach ($c in @($btnAddEnd, $btnClrEnd, $btnAddGame, $btnClrGame, $btnTest, $btnSample, $cbSrc, $btnRefresh, $btnRegion)) { $c.Enabled = $true }
}
function Fill-Sources {
    $was = $script:loading; $script:loading = $true
    try {
        $foundSources = Find-Sources
        $script:sources = @($foundSources)
        $cbSrc.Items.Clear()
        foreach ($s in $script:sources) { [void]$cbSrc.Items.Add($s.Name) }
        $idx = 0
        for ($i = 0; $i -lt $script:sources.Count; $i++) { if ($script:sources[$i].Id -eq $Cfg.source_id) { $idx = $i } }
        if ($cbSrc.Items.Count -gt 0) { $cbSrc.SelectedIndex = $idx }
        $cams = @($script:sources | Where-Object { $_.Kind -eq 'cam' })
        if ($cams.Count -eq 0) { Log "Windows listed no cameras. Webcams and capture cards should show up here; check Settings > Privacy > Camera. You can still use 'Set region'." }
        else { Log ('Cameras Windows listed: ' + (($cams | ForEach-Object { $_.Name -replace '^Camera: ', '' }) -join '; ')) }
    } finally { $script:loading = $was }
}
function Current-Source {
    $i = $cbSrc.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:sources.Count) { return $null }
    return $script:sources[$i]
}
function Ensure-Source {
    $src = Current-Source
    if ($src -eq $null) { throw 'No video source selected.' }
    if ($script:openId -ne $src.Id) {
        if ($script:failId -eq $src.Id) { throw $script:failMsg }
        try { Open-Source $src }
        catch { $script:failId = $src.Id; $script:failMsg = $_.Exception.Message; throw }
    }
    return $src
}
function Show-Preview($bmp) {
    $h = [int](320 * $bmp.Height / [Math]::Max(1, $bmp.Width))
    $thumb = New-Object System.Drawing.Bitmap $bmp, 320, $h
    $old = $pic.Image; $pic.Image = $thumb
    if ($old -ne $null) { $old.Dispose() }
}

# ================= snipping from the video frame =================
function Snip-Frame($frame, $folder, $what) {
    $scr = [System.Windows.Forms.Screen]::FromControl($form)
    $snip = New-Object System.Windows.Forms.Form
    $snip.FormBorderStyle = 'None'; $snip.StartPosition = 'Manual'; $snip.Bounds = $scr.Bounds
    $snip.TopMost = $true; $snip.Cursor = [System.Windows.Forms.Cursors]::Cross; $snip.KeyPreview = $true
    $snip.AutoScaleMode = 'None'; $snip.BackColor = [System.Drawing.Color]::Black
    $snip.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($snip, $true, $null)
    $sw = $scr.Bounds.Width; $sh = $scr.Bounds.Height
    $script:sr = [Math]::Min($sw / $frame.Width, $sh / $frame.Height)
    $script:sdx = [int](($sw - $frame.Width * $script:sr) / 2); $script:sdy = [int](($sh - $frame.Height * $script:sr) / 2)
    $script:sframe = $frame
    $script:drag = $false; $script:p0 = $null; $script:rect = [System.Drawing.Rectangle]::Empty
    $snip.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $script:rect = [System.Drawing.Rectangle]::Empty; $this.Close() } })
    $snip.Add_MouseDown({ $script:drag = $true; $script:p0 = $_.Location })
    $snip.Add_MouseMove({
        if ($script:drag) {
            $x = [Math]::Min($script:p0.X, $_.X); $y = [Math]::Min($script:p0.Y, $_.Y)
            $script:rect = New-Object System.Drawing.Rectangle $x, $y, ([Math]::Abs($_.X - $script:p0.X)), ([Math]::Abs($_.Y - $script:p0.Y))
            $this.Invalidate()
        }
    })
    $snip.Add_MouseUp({ $script:drag = $false; $this.Close() })
    $snip.Add_Paint({
        $g = $_.Graphics
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($script:sframe, $script:sdx, $script:sdy, [int]($script:sframe.Width * $script:sr), [int]($script:sframe.Height * $script:sr))
        if ($script:rect.Width -gt 0) {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Red), 2
            $g.DrawRectangle($pen, $script:rect); $pen.Dispose()
        }
    })
    [void]$snip.ShowDialog(); $snip.Dispose()
    $f = [int]$Cfg.scale; $r = $script:rect
    $ix = [int](($r.X - $script:sdx) / $script:sr); $iy = [int](($r.Y - $script:sdy) / $script:sr)
    $iw = [int]($r.Width / $script:sr); $ih = [int]($r.Height / $script:sr)
    $ix = [Math]::Max(0, $ix - ($ix % $f)); $iy = [Math]::Max(0, $iy - ($iy % $f))
    $iw = [int]([Math]::Floor($iw / $f) * $f); $ih = [int]([Math]::Floor($ih / $f) * $f)
    $iw = [Math]::Min($iw, $frame.Width - $ix); $ih = [Math]::Min($ih, $frame.Height - $iy)
    $iw = [int]([Math]::Floor($iw / $f) * $f); $ih = [int]([Math]::Floor($ih / $f) * $f)
    if ($iw -ge 4 * $f -and $ih -ge 4 * $f) {
        $crop = $frame.Clone((New-Object System.Drawing.Rectangle $ix, $iy, $iw, $ih), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $path = Join-Path $folder ('img_{0}.png' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $crop.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $crop.Dispose()
        Log "Added $what image ($iw x $ih)."
    } else { Log "Cancelled $what snip (box too small, or Esc)." }
}
function Add-Image($folder, $what) {
    try {
        $src = Ensure-Source
        $frame = Get-Frame $src
        $form.TopMost = $false
        Snip-Frame $frame $folder $what
        $frame.Dispose()
    } catch { Log ('Could not grab a frame: ' + $_.Exception.Message) }
    if ($script:state -eq 'idle') { Close-Source }
    Refresh-Counts; $form.Activate()
}

# ================= screen region source =================
function Snip-Rect($frame, $scr) {
    $snip = New-Object System.Windows.Forms.Form
    $snip.FormBorderStyle = 'None'; $snip.StartPosition = 'Manual'; $snip.Bounds = $scr.Bounds
    $snip.TopMost = $true; $snip.Cursor = [System.Windows.Forms.Cursors]::Cross; $snip.KeyPreview = $true
    $snip.AutoScaleMode = 'None'; $snip.BackColor = [System.Drawing.Color]::Black
    $snip.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($snip, $true, $null)
    $sw = $scr.Bounds.Width; $sh = $scr.Bounds.Height
    $script:sr = [Math]::Min($sw / $frame.Width, $sh / $frame.Height)
    $script:sdx = [int](($sw - $frame.Width * $script:sr) / 2); $script:sdy = [int](($sh - $frame.Height * $script:sr) / 2)
    $script:sframe = $frame
    $script:drag = $false; $script:p0 = $null; $script:rect = [System.Drawing.Rectangle]::Empty
    $snip.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $script:rect = [System.Drawing.Rectangle]::Empty; $this.Close() } })
    $snip.Add_MouseDown({ $script:drag = $true; $script:p0 = $_.Location })
    $snip.Add_MouseMove({
        if ($script:drag) {
            $x = [Math]::Min($script:p0.X, $_.X); $y = [Math]::Min($script:p0.Y, $_.Y)
            $script:rect = New-Object System.Drawing.Rectangle $x, $y, ([Math]::Abs($_.X - $script:p0.X)), ([Math]::Abs($_.Y - $script:p0.Y))
            $this.Invalidate()
        }
    })
    $snip.Add_MouseUp({ $script:drag = $false; $this.Close() })
    $snip.Add_Paint({
        $g = $_.Graphics
        $g.DrawImage($script:sframe, $script:sdx, $script:sdy, [int]($script:sframe.Width * $script:sr), [int]($script:sframe.Height * $script:sr))
        if ($script:rect.Width -gt 0) {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Red), 2
            $g.DrawRectangle($pen, $script:rect); $pen.Dispose()
        }
    })
    [void]$snip.ShowDialog(); $snip.Dispose()
    $r = $script:rect
    if ($r.Width -lt 8 -or $r.Height -lt 8) { return $null }
    $x = [int](($r.X - $script:sdx) / $script:sr); $y = [int](($r.Y - $script:sdy) / $script:sr)
    $w = [int]($r.Width / $script:sr); $h = [int]($r.Height / $script:sr)
    $x = [Math]::Max(0, $x); $y = [Math]::Max(0, $y)
    $w = [Math]::Min($w, $frame.Width - $x); $h = [Math]::Min($h, $frame.Height - $y)
    return (New-Object System.Drawing.Rectangle $x, $y, $w, $h)
}
function Pick-Region {
    try {
        $startBtn.Enabled = $false
        Log 'Put the video on screen (for example an OBS projector window) and keep the mouse on that monitor. Capturing in 4 seconds...'
        $form.WindowState = 'Minimized'
        $end = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        $sc = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $b = $sc.Bounds
        $shot = New-Object System.Drawing.Bitmap $b.Width, $b.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($shot); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); $g.Dispose()
        [System.Media.SystemSounds]::Asterisk.Play()
        $r = Snip-Rect $shot $sc
        $shot.Dispose()
        $form.WindowState = 'Normal'; $form.Activate()
        if ($r -ne $null -and $r.Width -ge 64 -and $r.Height -ge 36) {
            $Cfg.region_screen = $sc.DeviceName; $Cfg.region_x = $r.X; $Cfg.region_y = $r.Y; $Cfg.region_w = $r.Width; $Cfg.region_h = $r.Height
            $Cfg.source_id = 'region'; $script:failId = $null
            Fill-Sources; Save-Settings
            Log ('Screen region saved ({0}x{1}).' -f $r.Width, $r.Height)
            try { $f = Get-Frame (Current-Source); Show-Preview $f; $f.Dispose() } catch { Log ('Preview failed: ' + $_.Exception.Message) }
        } else { Log 'Region cancelled (box too small, or Esc).' }
    } catch { $form.WindowState = 'Normal'; Log ('Region failed: ' + $_.Exception.Message) }
    finally { if ($script:state -eq 'idle') { $startBtn.Enabled = $true } }
}

# ================= test + sample =================
function Dump-Ocr($ocr) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $ocr) {
        [void]$sb.AppendLine($l.Text)
        foreach ($w in $l.Words) { [void]$sb.AppendLine(('    "{0}"  x={1:N0} y={2:N0} w={3:N0} h={4:N0}' -f $w.T, $w.X, $w.Y, $w.W, $w.H)) }
    }
    return $sb.ToString()
}
function Do-Test {
    try {
        $src = Ensure-Source; $bmp = Get-Frame $src; Show-Preview $bmp
        if ($Engine -eq $null) { Log 'Windows has no OCR language installed.'; $bmp.Dispose(); return }
        $ocr = Read-Ocr $bmp
        Log ('Test: OCR read {0} lines.' -f @($ocr).Count)
        $keys = Get-Keys; $hits = Text-Hits $ocr $keys
        Log ('Words matched: {0} of {1} needed {2}  [{3}]' -f $hits.Count, $keys.Count, $numNeed.Value, ($hits -join ', '))
        $tpl = Load-Templates $EndDir
        if ($chkImg.Checked -and $tpl.Count -gt 0) { $gray = [SW]::Gray($bmp, [int]$Cfg.scale); Log ('Best image match: {0:N2} (needs {1:N2})' -f (Best-Score $gray $tpl), ($trkThr.Value / 100.0)) }
        $labels = @($clb.CheckedItems | ForEach-Object { [string]$_ })
        $m = Extract-Match $ocr (All-Labels) $labels
        if ($m -eq $null) { Log 'Stats table not found on this frame.' }
        else {
            Log ('Stats table found: {0} player column(s), {1} values read.' -f $m.N, $m.Cells.Count)
            for ($c = 0; $c -lt $m.N; $c++) {
                $row = @(); foreach ($f in @('name', 'place', 'num', 'out')) { $row += ('{0}={1}' -f $f, $m.Head["$c|$f"]) }
                Log ('  P{0}: {1}' -f ($c + 1), ($row -join ', '))
            }
            $first = @($m.Cells.Keys | Sort-Object | Select-Object -First 6)
            foreach ($k in $first) { Log ('  {0} = {1}' -f $k, $m.Cells[$k]) }
        }
        $bmp.Dispose()
    } catch { Log ('Test failed: ' + $_.Exception.Message) }
    if ($script:state -eq 'idle') { Close-Source }
}
function Do-Sample {
    try {
        $src = Ensure-Source; $bmp = Get-Frame $src
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $png = Join-Path $SampleDir ("sample_$stamp.png"); $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        if ($Engine -ne $null) { Set-Content -Path (Join-Path $SampleDir ("sample_$stamp.txt")) -Value (Dump-Ocr (Read-Ocr $bmp)) -Encoding UTF8 }
        $bmp.Dispose(); Log "Saved sample_$stamp (.png and .txt) in the samples folder."
    } catch { Log ('Sample failed: ' + $_.Exception.Message) }
    if ($script:state -eq 'idle') { Close-Source }
}

# ================= main loop =================
$script:state = 'idle'; $script:loading = $false
$script:endT = @(); $script:gameT = @(); $script:streak = 0
$script:lastGame = Get-Date; $script:warned = $false; $script:busy = $false
$script:votes = $null; $script:colVotes = @{}; $script:bestCount = -1; $script:bestThumb = $null; $script:allLabels = @(); $script:rv = $null; $script:recStart = $null; $script:recStamp = ''; $script:labels = @()
$script:errCount = 0; $script:lastErr = ''; $script:failId = $null; $script:failMsg = ''

function Process-Ocr($ocr, $bmp) {
    $m = Extract-Match $ocr $script:allLabels $script:labels
    if ($m -eq $null) { return }
    $w = $m.Cells.Count
    if ($script:colVotes.ContainsKey($m.N)) { $script:colVotes[$m.N] += $w } else { $script:colVotes[$m.N] = $w }
    foreach ($k in @($m.Cells.Keys)) { Vote-Add $k $m.Cells[$k] }
    foreach ($k in @($m.Head.Keys)) { Vote-Add ('H:' + $k) $m.Head[$k] }
    if ($w -gt $script:bestCount) {
        $script:bestCount = $w
        if ($script:bestThumb -ne $null) { $script:bestThumb.Dispose() }
        $h = [int](560 * $bmp.Height / [Math]::Max(1, $bmp.Width))
        $script:bestThumb = New-Object System.Drawing.Bitmap $bmp, 560, $h
    }
}

# ---------- review window: nothing is sent until you approve it ----------
function Rv-Cell($r, $c) {
    $v = $script:rvGrid.Rows[$r].Cells[$c].Value
    if ($v -eq $null) { return '' }
    return ([string]$v).Trim()
}
# one sheet row per player: fixed columns, then every stat in list order (unticked stats stay blank)
function Rv-Rows {
    $out = @()
    for ($c = 1; $c -le $script:rv.n; $c++) {
        $pnum = Rv-Cell 2 $c; if ($pnum -eq '') { $pnum = [string]$c }
        $row = @($script:rv.stamp, $pnum, (Rv-Cell 0 $c), (Rv-Cell 1 $c), (Rv-Cell 3 $c))
        foreach ($label in $script:rv.allLabels) {
            if ($script:rv.map.ContainsKey($label)) { $row += (Rv-Cell $script:rv.map[$label] $c) } else { $row += '' }
        }
        $any = @($row[2..($row.Count - 1)] | Where-Object { $_ }).Count
        if ($any -gt 0) { $out += , @($row) }
    }
    return , $out
}
function Show-Review {
    $n = $script:rv.n; $table = $script:rv.table
    $rf = New-Object System.Windows.Forms.Form
    $rf.Text = 'Review match stats'; $rf.ClientSize = New-Object System.Drawing.Size(640, 524)
    $rf.StartPosition = 'CenterScreen'; $rf.TopMost = $true; $rf.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $rf.FormBorderStyle = 'FixedDialog'; $rf.MaximizeBox = $false; $rf.MinimizeBox = $false
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.SetBounds(10, 56, 620, 296)
    $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [System.Drawing.Color]::White
    [void]$grid.Columns.Add('row', ''); $grid.Columns[0].ReadOnly = $true; $grid.Columns[0].FillWeight = 190
    for ($c = 1; $c -le $n; $c++) { [void]$grid.Columns.Add("p$c", "P$c"); $grid.Columns[$c].SortMode = 'NotSortable' }
    $grid.Columns[0].SortMode = 'NotSortable'
    $missing = 0; $statRows = 0
    for ($r = 0; $r -lt $table.Count; $r++) {
        $i = $grid.Rows.Add([object[]]$table[$r])
        $blank = (@($table[$r][1..$n] | Where-Object { $_ }).Count -eq 0)
        if ($blank) { $grid.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
        if ($r -ge 4) { $statRows++; if ($blank) { $missing++ } }
    }
    $msg = ('{0} of {1} stats read for {2} player(s), match at {3}. Columns are left to right on screen. Click any cell to fix it. Survival time: a player who was never knocked out ("---") gets the longest time anyone was out.' -f ($statRows - $missing), $statRows, $n, $script:rv.stamp)
    $lbl = New-Ctl System.Windows.Forms.Label 10 6 620 48 $msg
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $pb = New-Ctl System.Windows.Forms.PictureBox 10 362 270 152 $null
    $pb.SizeMode = 'Zoom'; $pb.BackColor = [System.Drawing.Color]::Black; if ($script:rv.thumb -ne $null) { $pb.Image = $script:rv.thumb }
    $btnSend = New-Ctl System.Windows.Forms.Button 295 362 335 40 'Send to Google Sheets'
    $btnSend.BackColor = [System.Drawing.Color]::SeaGreen; $btnSend.ForeColor = [System.Drawing.Color]::White; $btnSend.FlatStyle = 'Flat'
    $btnCopy = New-Ctl System.Windows.Forms.Button 295 408 335 32 'Copy (paste into the sheet yourself)'
    $btnCsv = New-Ctl System.Windows.Forms.Button 295 446 335 32 'Save to CSV file only'
    $btnDrop = New-Ctl System.Windows.Forms.Button 295 484 335 32 'Discard'
    $rf.Controls.AddRange(@($lbl, $grid, $pb, $btnSend, $btnCopy, $btnCsv, $btnDrop))
    $script:rvForm = $rf; $script:rvGrid = $grid; $script:rvDone = $false

    $btnSend.Add_Click({
        $out = Rv-Rows
        if ($out.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($script:rvForm, 'There is nothing to send.', 'Smash Watcher'); return }
        try {
            Send-Sheet 'Smash Matches' (Get-Header) $out
            Save-Csv (Join-Path $Here 'results_matches.csv') (Get-Header) $out
            $script:rvDone = $true
            Log ('Sent {0} player row(s) to Google Sheets.' -f $out.Count)
            Set-Status ('Sent {0} player row(s). Press Start to watch again.' -f $out.Count) 'SeaGreen'
            $script:rvForm.Close()
        } catch {
            Log ('Send failed: ' + $_.Exception.Message)
            [void][System.Windows.Forms.MessageBox]::Show($script:rvForm, ("Couldn't send to Google Sheets.`r`n`r`n" + $_.Exception.Message + "`r`n`r`nYour stats are still here. Fix the problem and press Send again, or use Copy to paste them into the sheet yourself."), 'Smash Watcher')
        }
    })
    $btnCopy.Add_Click({
        $out = Rv-Rows
        $tsv = (($out | ForEach-Object { ($_ -join "`t").TrimEnd("`t") }) -join "`r`n")
        if ($tsv) { [System.Windows.Forms.Clipboard]::SetText($tsv); Log 'Copied. Click a cell in your sheet and paste (Ctrl+V).' }
    })
    $btnCsv.Add_Click({
        $out = Rv-Rows
        if ($out.Count -gt 0) {
            Save-Csv (Join-Path $Here 'results_matches.csv') (Get-Header) $out
            $script:rvDone = $true; Log 'Saved to results_matches.csv (not sent to Google).'
            Set-Status 'Saved to CSV. Press Start to watch again.' 'SeaGreen'; $script:rvForm.Close()
        }
    })
    $btnDrop.Add_Click({ $script:rvForm.Close() })
    $rf.Add_FormClosed({
        if (-not $script:rvDone) { Log 'Match stats discarded (nothing was sent).'; Set-Status 'Discarded. Press Start to watch again.' 'DimGray' }
        if ($script:rv.thumb -ne $null) { $script:rv.thumb.Dispose() }
    })
    Beep
    [void]$rf.ShowDialog()
    $rf.Dispose()
}

function Vote-Get($key) {
    if ($script:votes.ContainsKey($key)) { return [string](Top $script:votes[$key]) }
    return ''
}
function Finish-Recording {
    Set-Idle
    if ($script:labels.Count -eq 0) { Set-Status 'No stats are ticked.' 'DarkOrange'; Log 'Nothing to read: tick some stats on the Stats tab.'; return }
    $n = 0
    if ($script:colVotes.Count -gt 0) { $n = [int](Top $script:colVotes) }
    if ($n -eq 0) {
        Set-Status 'Done: no stats could be read.' 'DarkOrange'
        Log 'The stats table was never recognised. Use Detection > Save sample on the stats screen and send me the files.'
        return
    }
    # survival time: seconds until knocked out; "---" (never out) gets the longest time anyone was out
    $outSecs = @(); $outRaw = @(); $maxOut = $null
    for ($c = 0; $c -lt $n; $c++) {
        $o = Vote-Get ("H:$c|out"); $outRaw += $o
        $s = Parse-Time $o; $outSecs += $s
        if ($s -ne $null -and ($maxOut -eq $null -or $s -gt $maxOut)) { $maxOut = $s }
    }
    $rName = @('Name'); $rPlace = @('Placement'); $rNum = @('Player number'); $rSurv = @('Survival time (s)')
    for ($c = 0; $c -lt $n; $c++) {
        $rName += (Vote-Get "H:$c|name"); $rPlace += (Vote-Get "H:$c|place"); $rNum += (Vote-Get "H:$c|num")
        if ($outSecs[$c] -ne $null) { $rSurv += [string]$outSecs[$c] }
        elseif ($outRaw[$c] -eq '---' -and $maxOut -ne $null) { $rSurv += [string]$maxOut }
        else { $rSurv += '' }
    }
    $table = @(, $rName) + @(, $rPlace) + @(, $rNum) + @(, $rSurv)
    $map = @{}; $found = 0; $k = 4
    foreach ($label in $script:labels) {
        $row = @(Disp-Label $label); $any = $false
        for ($c = 0; $c -lt $n; $c++) { $v = Vote-Get ("$c|$label"); if ($v) { $any = $true }; $row += $v }
        if ($any) { $found++ }
        $table += , $row; $map[$label] = $k; $k++
    }
    if ($found -eq 0) {
        Set-Status 'Done: no stats could be read.' 'DarkOrange'
        Log 'Players were found but none of the ticked stats were read. Use Detection > Save sample and send me the files.'
        return
    }
    Set-Status ('Review: {0} of {1} stats read.' -f $found, $script:labels.Count) 'RoyalBlue'
    Log ('Recording finished: {0} player(s). Review the stats, then send or discard.' -f $n)
    $script:rv = @{ stamp = $script:recStamp; n = $n; table = $table; map = $map; allLabels = @($script:allLabels); thumb = $script:bestThumb }
    $script:bestThumb = $null
    [void]$form.BeginInvoke([Action] { Show-Review })
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:busy -or $script:state -eq 'idle') { return }
    $script:busy = $true
    $bmp = $null
    try {
        $src = Ensure-Source
        $bmp = Get-Frame $src
        Show-Preview $bmp
        $script:errCount = 0; $script:lastErr = ''
        if ($script:state -eq 'watching') {
            $ocr = $null; $txt = @()
            $needGray = ($chkImg.Checked -and $script:endT.Count -gt 0) -or ($chkGame.Checked -and $script:gameT.Count -gt 0)
            $gray = $null; if ($needGray) { $gray = [SW]::Gray($bmp, [int]$Cfg.scale) }
            $fire = $false
            if ($chkText.Checked) {
                $ocr = Read-Ocr $bmp
                $keys = Get-Keys; $hits = Text-Hits $ocr $keys
                $txt += ('text {0}/{1}' -f $hits.Count, $numNeed.Value)
                $lblHits.Text = ('Live: {0} word(s) seen: {1}' -f $hits.Count, ($hits -join ', '))
                if ($hits.Count -ge $numNeed.Value -and $keys.Count -gt 0) { $fire = $true }
            }
            $thr = $trkThr.Value / 100.0
            if ($chkImg.Checked -and $script:endT.Count -gt 0) {
                $s = Best-Score $gray $script:endT; $txt += ('image {0:N2}/{1:N2}' -f $s, $thr)
                if ($s -ge $thr) { $fire = $true }
            }
            if ($chkGame.Checked -and $script:gameT.Count -gt 0) {
                $gs = Best-Score $gray $script:gameT; $txt += ('gameplay {0:N2}' -f $gs)
                if ($gs -ge $thr) { $script:lastGame = Get-Date; $script:warned = $false }
                elseif (-not $script:warned -and ((Get-Date) - $script:lastGame).TotalSeconds -gt [double]$Cfg.gameplay_warning_after_s) {
                    $script:warned = $true; Beep
                    Set-Status 'Watching (no game seen!)' 'DarkOrange'
                    Log ('WARNING: no Smash gameplay seen for {0}s. Is the game on the selected source?' -f $Cfg.gameplay_warning_after_s)
                    $form.WindowState = 'Normal'; $form.TopMost = $true; $form.TopMost = $false; $form.Activate()
                }
            }
            $detail.Text = ($txt -join '  |  ')
            if ($fire) { $script:streak++ } else { $script:streak = 0 }
            if ($script:streak -ge $numRow.Value) {
                Log 'End screen detected. Recording...'
                $script:state = 'recording'; $script:recStart = Get-Date; $script:recStamp = $script:recStart.ToString('yyyy-MM-dd HH:mm:ss')
                $script:votes = @{}; $script:colVotes = @{}; $script:bestCount = -1
                if ($script:bestThumb -ne $null) { $script:bestThumb.Dispose(); $script:bestThumb = $null }
                $script:allLabels = @(All-Labels)
                $script:labels = @($clb.CheckedItems | ForEach-Object { [string]$_ })
                if ($ocr -eq $null) { $ocr = Read-Ocr $bmp }
                Process-Ocr $ocr $bmp
            }
        }
        elseif ($script:state -eq 'recording') {
            $off = ((Get-Date) - $script:recStart).TotalSeconds
            Set-Status ('Recording... {0}s left' -f ([int]([double]$numDur.Value - $off) + 1)) 'Firebrick'
            Process-Ocr (Read-Ocr $bmp) $bmp
            if ($off -ge [double]$numDur.Value) { Finish-Recording }
        }
    } catch {
        $script:errCount++
        $em = $_.Exception.Message
        if ($em -ne $script:lastErr) { Log ('Error: ' + $em); $script:lastErr = $em }
        if ($script:state -ne 'idle' -and $script:errCount -ge 3) { Set-Status 'Stopped because of repeated errors.' 'DarkOrange'; Set-Idle }
    } finally {
        if ($bmp -ne $null) { $bmp.Dispose() }
        $script:busy = $false
    }
})

# ================= wiring =================
$startBtn.Add_Click({
    try {
        if ($Engine -eq $null) { [void][System.Windows.Forms.MessageBox]::Show('Windows has no OCR language installed. Add one in Settings > Time and language > Language and region.', 'Smash Watcher'); return }
        if (-not $chkText.Checked -and -not $chkImg.Checked) { [void][System.Windows.Forms.MessageBox]::Show('Turn on text or image detection (Detection tab).', 'Smash Watcher'); return }
        $tmpE = Load-Templates $EndDir; $tmpG = Load-Templates $GameDir
        $script:endT = @($tmpE); $script:gameT = @($tmpG)
        if (-not $chkImg.Checked) { $script:endT = @() }
        if (-not $chkGame.Checked) { $script:gameT = @() }
        if ($chkImg.Checked -and -not $chkText.Checked -and $script:endT.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Add at least one end-screen image first.', 'Smash Watcher'); return }
        $script:failId = $null
        [void](Ensure-Source)
    } catch { Log ('Could not open the source: ' + $_.Exception.Message); return }
    Save-Settings
    $script:streak = 0; $script:lastGame = Get-Date; $script:warned = $false; $script:state = 'watching'
    $startBtn.Enabled = $false; $stopBtn.Enabled = $true
    foreach ($c in @($btnAddEnd, $btnClrEnd, $btnAddGame, $btnClrGame, $btnTest, $btnSample, $cbSrc, $btnRefresh, $btnRegion)) { $c.Enabled = $false }
    if ($chkGame.Checked -and $script:gameT.Count -eq 0) { Log "No gameplay image set, so the 'no game' warning is off." }
    Set-Status 'Watching for the end screen...' 'RoyalBlue'; Log 'Started watching.'
})
$stopBtn.Add_Click({
    if ($script:state -eq 'recording') { Log 'Stopped during recording; nothing was sent.' } else { Log 'Stopped.' }
    Set-Idle; Set-Status 'Stopped.' 'DimGray'
})
$btnRefresh.Add_Click({ $script:failId = $null; Fill-Sources })
$btnRegion.Add_Click({ Pick-Region })
$cbSrc.Add_SelectedIndexChanged({
    if ($script:loading) { return }
    $script:failId = $null
    Save-Settings
    try { $src = Ensure-Source; $f = Get-Frame $src; Show-Preview $f; $f.Dispose(); Log ('Source works: ' + $cbSrc.SelectedItem) } catch { Log ('Could not open source: ' + $_.Exception.Message); $script:lastErr = $_.Exception.Message }
    if ($script:state -eq 'idle') { Close-Source }
})
$btnAddEnd.Add_Click({ Add-Image $EndDir 'end-screen' })
$btnAddGame.Add_Click({ Add-Image $GameDir 'gameplay' })
$btnClrEnd.Add_Click({ Get-ChildItem $EndDir -Filter *.png | Remove-Item; Refresh-Counts; Log 'Cleared end-screen images.' })
$btnClrGame.Add_Click({ Get-ChildItem $GameDir -Filter *.png | Remove-Item; Refresh-Counts; Log 'Cleared gameplay images.' })
$btnTest.Add_Click({ Do-Test })
$btnSample.Add_Click({ Do-Sample })
$btnTestSheet.Add_Click({
    try { Send-Sheet 'Smash Matches' (Get-Header) @(); Log 'Google Sheets connection OK. A Smash Matches tab with headers now exists in your sheet.' }
    catch { Log ('Google Sheets test failed: ' + $_.Exception.Message) }
})
$btnAll.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) }; Save-Settings })
$btnNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) }; Save-Settings })
$btnEditStats.Add_Click({ Start-Process notepad.exe $StatsFile; Log 'Edit the labels, save, then press Refresh on the Run tab or restart.' })
$trkThr.Add_ValueChanged({ $lblThr.Text = ('Match strictness: {0:N2}  (higher = must look more alike)' -f ($trkThr.Value / 100.0)); Save-Settings })
foreach ($c in @($chkText, $chkImg, $chkGame)) { $c.Add_CheckedChanged({ Save-Settings }) }
foreach ($c in @($numNeed, $numRow, $numDur)) { $c.Add_ValueChanged({ Save-Settings }) }
$tbKeys.Add_Leave({ Save-Settings })
$clb.Add_ItemCheck({ if (-not $script:loading -and $form.IsHandleCreated) { [void]$form.BeginInvoke([Action]{ Save-Settings }) } })
$form.Add_FormClosing({ $timer.Stop(); Close-Source })

# ================= start-up =================
$script:loading = $true
$chkText.Checked = [bool]$Cfg.trigger_text; $chkImg.Checked = [bool]$Cfg.trigger_image
$tbKeys.Text = (@($Cfg.keywords) -join "`r`n"); $numNeed.Value = [int]$Cfg.words_needed
$trkThr.Value = [int][Math]::Round([double]$Cfg.image_threshold * 100); $numRow.Value = [int]$Cfg.checks_in_row
$numDur.Value = [int]$Cfg.read_duration_s; $chkGame.Checked = [bool]$Cfg.gameplay_warning
$lblThr.Text = ('Match strictness: {0:N2}  (higher = must look more alike)' -f ($trkThr.Value / 100.0))
Load-StatLabels; Refresh-Counts; Fill-Sources
$script:loading = $false

Log 'Ready. Pick your video source, set up detection, then press Start.'
if ($Engine -eq $null) { Log 'Windows has no OCR language installed (Settings > Time and language).' }
Log 'Nothing is captured until you press Start (or Test now).'
$timer.Start()
[void]$form.ShowDialog()
}
catch {
    $msg = $_ | Out-String
    Set-Content -Path (Join-Path $Here 'error.log') -Value $msg
    [void][System.Windows.Forms.MessageBox]::Show("Smash Watcher hit an error. Details were saved to error.log.`r`n`r`n" + $_.Exception.Message, 'Smash Watcher')
}
