# Converts any image Windows can decode (WebP, JPEG, HEIC...) to PNG, e.g. screenshots pasted from chat.
#   powershell -ExecutionPolicy Bypass -File tools\convert_image.ps1 -In shot.webp -Out local\samples\shot.png
param([Parameter(Mandatory = $true)][string]$In, [Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapEncoder, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$ext = [System.WindowsRuntimeSystemExtensions].GetMethods()
$asOp = ($ext | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$asAct = ($ext | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
function Wait-Op($op, [type]$t) { $task = $asOp.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(); $task.Result }

$ms = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes((Resolve-Path $In).Path))
$ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
$dec = Wait-Op ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
$sb = Wait-Op ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$outStream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
$enc = Wait-Op ([Windows.Graphics.Imaging.BitmapEncoder]::CreateAsync([Windows.Graphics.Imaging.BitmapEncoder]::PngEncoderId, $outStream)) ([Windows.Graphics.Imaging.BitmapEncoder])
$enc.SetSoftwareBitmap($sb)
$asAct.Invoke($null, @($enc.FlushAsync())).Wait()
$outStream.Seek(0)
$outPath = [System.IO.Path]::GetFullPath($Out)
$fs = [System.IO.File]::Create($outPath)
try { [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($outStream).CopyTo($fs) } finally { $fs.Close() }
Write-Host ('{0} -> {1} ({2}x{3})' -f $In, $outPath, $sb.PixelWidth, $sb.PixelHeight)
