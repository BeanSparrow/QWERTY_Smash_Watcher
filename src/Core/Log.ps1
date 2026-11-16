# Logging. The main window points $LogSink at its log box; tools fall back to the console.

$script:LogSink = $null

function Log([string]$message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $message
    if ($script:LogSink) { & $script:LogSink $line } else { Write-Host $line }
}

function Write-ErrorLog([string]$text) {
    try { Add-Content -Path $ErrorLog -Value ("==== {0}`r`n{1}" -f (Get-Date -Format 's'), $text) -Encoding UTF8 } catch { }
}
