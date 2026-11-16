# User settings (local\settings.json) and the stat list (config\stats.txt).

$Cfg = @{
    webhook_url           = ''
    source_id             = ''
    region_screen         = ''; region_x = 0; region_y = 0; region_w = 0; region_h = 0
    trigger_on_labels     = $true
    extra_keywords        = @()
    trigger_labels_needed = 1
    checks_in_row         = 1
    read_duration_s       = 20
    enhance               = $true
    stats_checked         = $null
}

function Import-Settings {
    if (-not (Test-Path $SettingsFile)) { return }
    try {
        $json = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $Cfg[$p.Name] = $p.Value }
    } catch {
        Log ('settings.json could not be read, so defaults are used: ' + $_.Exception.Message)
    }
    if ([string]$Cfg.webhook_url -like 'PASTE*') { $Cfg.webhook_url = '' }
}

function Save-Settings {
    try { ($Cfg | ConvertTo-Json -Depth 4) | Set-Content -Path $SettingsFile -Encoding UTF8 }
    catch { Log ('Could not save settings: ' + $_.Exception.Message) }
}

# Returns the stats in on-screen order: @( @{ Name; Unit } ... ). A line is "Label" or "Label|unit".
function Get-StatList {
    $list = @()
    foreach ($line in (Get-Content $StatsFile -Encoding UTF8)) {
        $parts = $line.Split('|')
        $name = $parts[0].Trim()
        if (-not $name -or $name.StartsWith('#')) { continue }
        $unit = ''
        if ($parts.Count -gt 1) { $unit = $parts[1].Trim() }
        $list += [pscustomobject]@{ Name = $name; Unit = $unit }
    }
    return $list
}

function Get-StatDisplayName($stat) {
    if ($stat.Unit) { return ('{0} ({1})' -f $stat.Name, $stat.Unit) }
    return $stat.Name
}
