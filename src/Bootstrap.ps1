# Loads everything that isn't UI. Dot-sourced by SmashWatcher.ps1 and by the scripts in tools\.
# Expects $AppRoot to be set to the app's top folder.

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SrcDir = Join-Path $AppRoot 'src'
if (-not ('SmashWatcher.Native' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -Path (Join-Path $SrcDir 'Native\Native.cs')
}
[SmashWatcher.Native]::MakeDpiAware()

foreach ($module in @('Paths', 'Log', 'Config', 'Ocr', 'Capture', 'StatsReader', 'Recorder', 'Output', 'Updater')) {
    . (Join-Path $SrcDir "Core\$module.ps1")
}
