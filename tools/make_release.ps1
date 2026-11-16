# Packages the app into dist\SmashWatcher_v<VERSION>.zip, ready to attach to a GitHub Release.
# Only app files go in; local\ (user data), tools\, docs\ and .git never do.
#   powershell -ExecutionPolicy Bypass -File tools\make_release.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$include = @('SmashWatcher.ps1', 'Start Smash Watcher.bat', 'README.md', 'VERSION', 'src', 'config', 'google', 'launcher')

foreach ($item in $include) {
    if (-not (Test-Path (Join-Path $root $item))) { throw "Missing $item" }
}

# Parse-check every script so a broken file never ships.
$bad = @()
foreach ($f in (Get-ChildItem -Path $root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\(local|dist)\\' })) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { $bad += ('{0}: {1}' -f $f.Name, $errors[0].Message) }
}
if ($bad.Count -gt 0) { throw ("Syntax errors:`n" + ($bad -join "`n")) }

$dist = Join-Path $root 'dist'
if (-not (Test-Path $dist)) { [void](New-Item -ItemType Directory -Path $dist) }
$stage = Join-Path $dist "SmashWatcher_v$version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
[void](New-Item -ItemType Directory -Path $stage)
foreach ($item in $include) { Copy-Item -Path (Join-Path $root $item) -Destination $stage -Recurse }

$zip = Join-Path $dist "SmashWatcher_v$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Host "Built $zip"
Write-Host "Next: gh release create v$version `"$zip`" --title `"v$version`" --notes `"What changed...`""
