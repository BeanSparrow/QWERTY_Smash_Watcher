# Self-update from GitHub Releases. Replaces the app files; never touches local\ (settings, results, samples).

function ConvertTo-AppVersion([string]$s) {
    $parts = @((([string]$s).Trim() -replace '^[vV]', '').Split('.') | ForEach-Object {
        $n = 0; [void][int]::TryParse(($_ -replace '\D.*$', ''), [ref]$n); $n })
    while ($parts.Count -lt 3) { $parts += 0 }
    return New-Object System.Version $parts[0], $parts[1], $parts[2]
}

function Test-DeveloperCopy { return (Test-Path (Join-Path $AppRoot '.git')) }

# Returns @{ Version; Tag; Notes; Url; Newer } for the latest published release.
function Get-LatestRelease {
    $api = "https://api.github.com/repos/$GitHubRepo/releases/latest"
    try {
        $rel = Invoke-RestMethod -Uri $api -TimeoutSec 15 -UseBasicParsing -Headers @{ 'User-Agent' = 'SmashWatcher-Updater'; 'Accept' = 'application/vnd.github+json' }
    } catch {
        $r = $_.Exception.Response
        if ($r -ne $null -and [int]$r.StatusCode -eq 404) { throw 'No releases have been published yet.' }
        throw ('Could not reach GitHub: ' + $_.Exception.Message)
    }
    $asset = @($rel.assets | Where-Object { $_.name -like '*.zip' }) | Select-Object -First 1
    $url = $rel.zipball_url
    if ($asset -ne $null) { $url = $asset.browser_download_url }
    $ver = ConvertTo-AppVersion $rel.tag_name
    return [pscustomobject]@{
        Version = $ver; Tag = $rel.tag_name; Notes = [string]$rel.body; Url = $url
        Newer   = ($ver -gt (ConvertTo-AppVersion $AppVersion))
    }
}

# Downloads and installs a release. Returns a list of notes for the user (e.g. "re-paste the Google script").
function Install-Update($release) {
    if (Test-DeveloperCopy) { throw 'This folder is a git checkout (developer copy). Use git pull instead of the updater.' }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $work = Join-Path $env:TEMP ('SmashWatcherUpdate_' + $stamp)
    [void](New-Item -ItemType Directory -Path $work)
    $zip = Join-Path $work 'update.zip'
    Log ('Downloading ' + $release.Tag + '...')
    Invoke-WebRequest -Uri $release.Url -OutFile $zip -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'SmashWatcher-Updater' }
    $extract = Join-Path $work 'files'
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    # The app's top folder is wherever VERSION sits next to SmashWatcher.ps1 (GitHub source zips add a wrapper folder).
    $newRoot = Get-ChildItem -Path $extract -Recurse -Filter 'VERSION' | Where-Object { Test-Path (Join-Path $_.DirectoryName 'SmashWatcher.ps1') } | Select-Object -First 1
    if ($newRoot -eq $null) { throw 'The download does not look like a Smash Watcher release.' }
    $newRoot = $newRoot.DirectoryName

    $oldScriptHash = $null
    if (Test-Path $AppsScript) { $oldScriptHash = (Get-FileHash $AppsScript).Hash }

    # Back up the current app files first, so a bad update can be undone by copying them back.
    $backup = Join-Path $BackupDir ('v' + $AppVersion + '_' + $stamp)
    [void](New-Item -ItemType Directory -Path $backup -Force)
    $skip = @('local', '.git', 'dist')
    foreach ($item in (Get-ChildItem -Path $AppRoot -Force | Where-Object { $skip -notcontains $_.Name })) {
        Copy-Item -Path $item.FullName -Destination $backup -Recurse -Force
    }

    foreach ($item in (Get-ChildItem -Path $newRoot -Force | Where-Object { $skip -notcontains $_.Name })) {
        $dest = Join-Path $AppRoot $item.Name
        if ($item.PSIsContainer) {
            if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
            Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
        } else {
            Copy-Item -Path $item.FullName -Destination $dest -Force
        }
    }
    try { Remove-Item -Path $work -Recurse -Force } catch { }

    $notes = @()
    if ($oldScriptHash -ne $null -and (Test-Path $AppsScript) -and (Get-FileHash $AppsScript).Hash -ne $oldScriptHash) {
        $notes += 'The Google Sheets script changed. Paste the new google\apps_script.gs into your sheet (Extensions > Apps Script), then Deploy > Manage deployments > edit > Version: New version > Deploy.'
    }
    Log ('Installed ' + $release.Tag + '. Your previous version was backed up to ' + $backup)
    return $notes
}

# Starts a fresh copy of the app (after an update).
function Restart-App {
    $entry = Join-Path $AppRoot 'SmashWatcher.ps1'
    Start-Process -FilePath 'powershell.exe' -WorkingDirectory $AppRoot -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + $entry + '"'))
}
