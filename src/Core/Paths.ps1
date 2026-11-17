# Where everything lives. App files are replaced by updates; everything under local\ belongs to the user and is never touched.

$ConfigDir    = Join-Path $AppRoot 'config'
$GoogleDir    = Join-Path $AppRoot 'google'
$LocalDir     = Join-Path $AppRoot 'local'
$SampleDir    = Join-Path $LocalDir 'samples'
$MatchesDir   = Join-Path $LocalDir 'matches'      # one CSV per kept match
$BackupDir    = Join-Path $LocalDir 'backup'
$StatsFile    = Join-Path $ConfigDir 'stats.txt'
$AppsScript   = Join-Path $GoogleDir 'apps_script.gs'
$SettingsFile = Join-Path $LocalDir 'settings.json'
$ResultsCsv   = Join-Path $LocalDir 'results_matches.csv'
$ErrorLog     = Join-Path $LocalDir 'error.log'
$VersionFile  = Join-Path $AppRoot 'VERSION'
$GitHubRepo   = 'BeanSparrow/QWERTY_Smash_Watcher'

$AppVersion = '0.0.0'
if (Test-Path $VersionFile) { $AppVersion = (Get-Content $VersionFile -Raw).Trim() }

foreach ($dir in @($LocalDir, $SampleDir, $MatchesDir)) {
    if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
}

# Versions before 5 kept these files next to the script. Move them into local\ once.
foreach ($name in @('settings.json', 'results_matches.csv')) {
    $old = Join-Path $AppRoot $name
    $new = Join-Path $LocalDir $name
    if ((Test-Path $old) -and -not (Test-Path $new)) { Move-Item $old $new }
}

# Updates add and replace files but don't delete ones that moved. Remove app files that now live elsewhere.
$MovedFiles = @{
    'Start Smash Watcher.bat' = 'launcher\Start Smash Watcher.bat'   # moved in 5.0.1
}
foreach ($old in $MovedFiles.Keys) {
    $oldPath = Join-Path $AppRoot $old
    if ((Test-Path $oldPath) -and (Test-Path (Join-Path $AppRoot $MovedFiles[$old]))) {
        try { Remove-Item $oldPath -Force } catch { }
    }
}
