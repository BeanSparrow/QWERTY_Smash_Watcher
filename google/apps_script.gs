// Smash Watcher receiver. Paste ALL of this into your sheet's Extensions > Apps Script, then deploy as a Web app
// (Execute as: Me, Who has access: Anyone). After pasting a new version: Deploy > Manage deployments > edit >
// Version: New version > Deploy.

function doGet(e) {
  // Lets you test the link in a browser: it should show this message.
  return ContentService.createTextOutput('Smash Watcher script is live.');
}

function doPost(e) {
  var d = JSON.parse(e.postData.contents);
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var name = d.sheet || 'Smash Matches';
  var header = d.header || [];
  var sh = ss.getSheetByName(name);

  // If the tab's columns don't match what the app sends (an older version made it), keep the old tab under a
  // new name and start a fresh one, so rows never land under the wrong headings.
  if (sh && header.length && sh.getLastRow() > 0 && !headerMatches(sh, header)) {
    var n = 1;
    while (ss.getSheetByName(name + ' (old ' + n + ')')) n++;
    sh.setName(name + ' (old ' + n + ')');
    sh = null;
  }
  if (!sh) sh = ss.insertSheet(name);
  if (sh.getLastRow() === 0 && header.length) {
    sh.appendRow(header);
    sh.setFrozenRows(1);
  }

  var rows = d.rows || [];
  if (rows.length) {
    var w = header.length;
    rows.forEach(function (r) { w = Math.max(w, r.length); });
    rows = rows.map(function (r) { while (r.length < w) r.push(''); return r; });
    sh.getRange(sh.getLastRow() + 1, 1, rows.length, w).setValues(rows);
  }
  return ContentService.createTextOutput('ok');
}

function headerMatches(sh, header) {
  var width = Math.max(sh.getLastColumn(), header.length);
  var current = sh.getRange(1, 1, 1, width).getValues()[0];
  for (var i = 0; i < width; i++) {
    var want = i < header.length ? String(header[i]) : '';
    if (String(current[i]) !== want) return false;
  }
  return true;
}
