# Turning a reviewed match into sheet rows, and sending them: Google Sheets (via google\apps_script.gs) or CSV.

$SheetTab = 'Smash Matches'

function Get-SheetHeader($statList) {
    $h = @('detected_at', 'player_no', 'player', 'character', 'placement', 'survival_time_s')
    foreach ($s in $statList) { $h += (Get-StatDisplayName $s) }
    return $h
}

# One row per player. $cell is a scriptblock (rowKey, column) -> text, so the review grid's edits are used.
# Every stat keeps its own column; stats that weren't ticked stay blank so columns never shift.
function Get-SheetRows([string]$stamp, [int]$players, $statList, [scriptblock]$cell) {
    $out = @()
    for ($c = 0; $c -lt $players; $c++) {
        $num = & $cell 'num' $c
        if (-not $num) { $num = [string]($c + 1) }
        $row = @($stamp, $num, (& $cell 'player' $c), (& $cell 'character' $c), (& $cell 'place' $c), (& $cell 'surv' $c))
        foreach ($s in $statList) { $row += (& $cell ('stat:' + $s.Name) $c) }
        if (@($row[2..($row.Count - 1)] | Where-Object { $_ }).Count -gt 0) { $out += , @($row) }
    }
    return $out
}

function ConvertTo-CsvLine($values) { return (($values | ForEach-Object { '"' + ([string]$_ -replace '"', '""') + '"' }) -join ',') }

function Save-Csv([string]$path, $header, $rows) {
    $sb = New-Object System.Text.StringBuilder
    if (-not (Test-Path $path)) { [void]$sb.AppendLine((ConvertTo-CsvLine $header)) }
    foreach ($r in $rows) { [void]$sb.AppendLine((ConvertTo-CsvLine $r)) }
    [System.IO.File]::AppendAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
}

function ConvertTo-JsonValue($v) {
    $s = [string]$v
    if ($s -match '^-?\d+(\.\d+)?$') { return $s }
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
    return '"' + $s + '"'
}

function Send-Sheet([string]$url, [string]$sheet, $header, $rows) {
    if (-not $url) { throw 'No Google Sheets link yet. Paste your Apps Script web app URL on the Setup tab.' }
    if ($url -notmatch '^https://script\.google\.com/.+/exec$') {
        throw 'That link should start with https://script.google.com/ and end in /exec. Copy it from Deploy > Manage deployments in Apps Script.'
    }
    $rowsJson = ($rows | ForEach-Object { '[' + (($_ | ForEach-Object { ConvertTo-JsonValue $_ }) -join ',') + ']' }) -join ','
    $json = '{"sheet":' + (ConvertTo-JsonValue $sheet) + ',"header":[' + (($header | ForEach-Object { ConvertTo-JsonValue $_ }) -join ',') + '],"rows":[' + $rowsJson + ']}'
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec 60 -UseBasicParsing
        $text = ([string]$resp.Content).Trim()
    } catch {
        $detail = $_.Exception.Message
        $r = $_.Exception.Response
        if ($r -ne $null) { $detail = ('HTTP {0} {1}' -f [int]$r.StatusCode, $r.StatusDescription) }
        throw ('Google Sheets could not be reached: ' + $detail)
    }
    if ($text -eq 'ok') { return }
    $plain = (($text -replace '(?s)<style.*?</style>', ' ' -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
    if ($plain.Length -gt 300) { $plain = $plain.Substring(0, 300) + '...' }
    $hint = 'Check that the deployment is set to "Who has access: Anyone".'
    if ($plain -match 'getSheetByName|null') { $hint = 'The script must be created from inside the sheet (Extensions > Apps Script), not at script.google.com.' }
    elseif ($plain -match 'sign in|Sign in|accounts\.google') { $hint = 'Google asked for a sign-in: set the deployment to "Who has access: Anyone" and deploy again.' }
    elseif ($plain -match 'not found|Script function not found') { $hint = 'Deploy a new version: Deploy > Manage deployments > pencil > Version: New version > Deploy.' }
    throw ('Google answered: "' + $plain + '". ' + $hint)
}
