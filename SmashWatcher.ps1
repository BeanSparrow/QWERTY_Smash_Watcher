# Smash Watcher: reads the Super Smash Bros. Ultimate post-match stats screen and, after you approve them,
# sends the stats to Google Sheets. Uses only what Windows already includes.
#
# Start it with "Start Smash Watcher.bat" or SmashWatcher.exe (built by launcher\make_exe.bat).

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $AppRoot
Add-Type -AssemblyName System.Windows.Forms

try {
    . (Join-Path $AppRoot 'src\Bootstrap.ps1')
    . (Join-Path $AppRoot 'src\UI\MainWindow.ps1')
    . (Join-Path $AppRoot 'src\UI\ReviewWindow.ps1')
    . (Join-Path $AppRoot 'src\UI\RegionPicker.ps1')
    Show-MainWindow
}
catch {
    $details = $_ | Out-String
    $logPath = Join-Path $AppRoot 'local\error.log'
    try {
        if (-not (Test-Path (Split-Path $logPath))) { [void](New-Item -ItemType Directory -Path (Split-Path $logPath)) }
        Add-Content -Path $logPath -Value ("==== {0}`r`n{1}" -f (Get-Date -Format 's'), $details) -Encoding UTF8
    } catch { }
    [void][System.Windows.Forms.MessageBox]::Show("Smash Watcher hit an error. Details were saved to local\error.log.`r`n`r`n" + $_.Exception.Message, 'Smash Watcher')
}
