# The popup shown after each match. Nothing is sent anywhere until the user approves it here.

function Show-ReviewWindow($match, $statList) {
    $n = $match.N
    $script:RV = @{ Match = $match; Stats = $statList; Done = $false; RowOf = @{}; Guesses = 0 }

    $rf = New-Object System.Windows.Forms.Form
    $rf.Text = 'Review match stats'; $rf.ClientSize = New-Object System.Drawing.Size(700, 560)
    $rf.StartPosition = 'CenterScreen'; $rf.TopMost = $true; $rf.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $rf.FormBorderStyle = 'FixedDialog'; $rf.MaximizeBox = $false; $rf.MinimizeBox = $false

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.SetBounds(10, 58, 680, 300)
    $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [System.Drawing.Color]::White
    [void]$grid.Columns.Add('row', ''); $grid.Columns[0].ReadOnly = $true; $grid.Columns[0].FillWeight = 170
    for ($c = 1; $c -le $n; $c++) { [void]$grid.Columns.Add("p$c", "P$c") }
    foreach ($col in $grid.Columns) { $col.SortMode = 'NotSortable' }

    $missing = 0; $statRows = 0
    foreach ($row in $match.Rows) {
        $i = $grid.Rows.Add([object[]](@($row.Label) + @($row.Values)))
        $script:RV.RowOf[$row.Key] = $i
        $blank = (@($row.Values | Where-Object { $_ }).Count -eq 0)
        if ($blank) { $grid.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
        if ($row.PSObject.Properties['Guessed'] -and $row.Guessed) {
            for ($c = 0; $c -lt $n; $c++) {
                if ($row.Guessed[$c]) { $grid.Rows[$i].Cells[$c + 1].Style.BackColor = [System.Drawing.Color]::LightGoldenrodYellow; $script:RV.Guesses++ }
            }
        }
        if ($row.Key -like 'stat:*') { $statRows++; if ($blank) { $missing++ } }
    }
    $msg = ('{0} of {1} ticked stats read for {2} player(s), match at {3}. Columns are the player panels, left to right. Click any cell to fix it. Pink rows were not read.' -f ($statRows - $missing), $statRows, $n, $match.Stamp)
    if ($script:RV.Guesses -gt 0) { $msg += ' Yellow cells were hard to read (or assumed 0), so check them.' }
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.SetBounds(10, 6, 680, 48); $lbl.Text = $msg; $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)

    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.SetBounds(10, 368, 330, 182); $pb.SizeMode = 'Zoom'; $pb.BackColor = [System.Drawing.Color]::Black
    if ($match.Thumb -ne $null) { $pb.Image = $match.Thumb }

    $btnSend = New-Object System.Windows.Forms.Button
    $btnSend.SetBounds(350, 368, 340, 42); $btnSend.Text = 'Send to Google Sheets'
    $btnSend.BackColor = [System.Drawing.Color]::SeaGreen; $btnSend.ForeColor = [System.Drawing.Color]::White; $btnSend.FlatStyle = 'Flat'
    $btnCopy = New-Object System.Windows.Forms.Button; $btnCopy.SetBounds(350, 418, 340, 32); $btnCopy.Text = 'Copy (paste into the sheet yourself)'
    $btnCsv = New-Object System.Windows.Forms.Button; $btnCsv.SetBounds(350, 456, 340, 32); $btnCsv.Text = 'Save to CSV file only'
    $btnDrop = New-Object System.Windows.Forms.Button; $btnDrop.SetBounds(350, 494, 340, 32); $btnDrop.Text = 'Discard'
    $rf.Controls.AddRange(@($lbl, $grid, $pb, $btnSend, $btnCopy, $btnCsv, $btnDrop))
    $script:RV.Form = $rf; $script:RV.Grid = $grid

    $btnSend.Add_Click({
        $rows = @(Get-ReviewRows)
        if ($rows.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($script:RV.Form, 'There is nothing to send.', 'Smash Watcher'); return }
        $script:RV.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Send-Sheet ([string]$Cfg.webhook_url) $SheetTab (Get-SheetHeader $script:RV.Stats) $rows
            Save-Csv $ResultsCsv (Get-SheetHeader $script:RV.Stats) $rows
            $script:RV.Done = $true
            Log ('Sent {0} player row(s) to Google Sheets (also saved to the CSV).' -f $rows.Count)
            Set-Status ('Sent {0} player row(s). Press Start to watch again.' -f $rows.Count) 'SeaGreen'
            $script:RV.Form.Close()
        } catch {
            $script:RV.Form.Cursor = [System.Windows.Forms.Cursors]::Default
            Log ('Send failed: ' + $_.Exception.Message)
            [void][System.Windows.Forms.MessageBox]::Show($script:RV.Form, ("Couldn't send to Google Sheets.`r`n`r`n" + $_.Exception.Message + "`r`n`r`nYour stats are still here. Fix the problem and press Send again, or use Copy or Save to CSV."), 'Smash Watcher')
        }
    })
    $btnCopy.Add_Click({
        $rows = @(Get-ReviewRows)
        $tsv = (($rows | ForEach-Object { ($_ -join "`t") }) -join "`r`n")
        if ($tsv) { [System.Windows.Forms.Clipboard]::SetText($tsv); Log 'Copied. Click the first empty cell in column A of your sheet and paste (Ctrl+V).' }
    })
    $btnCsv.Add_Click({
        $rows = @(Get-ReviewRows)
        if ($rows.Count -eq 0) { return }
        Save-Csv $ResultsCsv (Get-SheetHeader $script:RV.Stats) $rows
        $script:RV.Done = $true
        Log ('Saved to ' + $ResultsCsv + ' (not sent to Google).')
        Set-Status 'Saved to CSV. Press Start to watch again.' 'SeaGreen'
        $script:RV.Form.Close()
    })
    $btnDrop.Add_Click({ $script:RV.Form.Close() })
    $rf.Add_FormClosed({
        if (-not $script:RV.Done) { Log 'Match stats discarded (nothing was sent).'; Set-Status 'Discarded. Press Start to watch again.' 'DimGray' }
        if ($script:RV.Match.Thumb -ne $null) { $script:RV.Match.Thumb.Dispose() }
    })
    [System.Media.SystemSounds]::Exclamation.Play()
    [void]$rf.ShowDialog()
    $rf.Dispose()
}

# Reads the (possibly edited) grid back into sheet rows.
function Get-ReviewRows {
    $cell = {
        param($key, $c)
        if (-not $script:RV.RowOf.ContainsKey($key)) { return '' }
        $v = $script:RV.Grid.Rows[$script:RV.RowOf[$key]].Cells[$c + 1].Value
        if ($v -eq $null) { return '' }
        return ([string]$v).Trim()
    }
    Get-SheetRows $script:RV.Match.Stamp $script:RV.Match.N $script:RV.Stats $cell
}
