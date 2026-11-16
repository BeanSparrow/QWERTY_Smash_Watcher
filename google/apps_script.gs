// Smash Watcher receiver. Paste ALL of this into Extensions > Apps Script, then deploy as a Web app.

function doGet(e) {
  // Lets you test the link in a browser: it should show this message.
  return ContentService.createTextOutput('Smash Watcher script is live.');
}

function doPost(e) {
  var d = JSON.parse(e.postData.contents);
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(d.sheet) || ss.insertSheet(d.sheet);
  if (sh.getLastRow() === 0 && d.header) {
    sh.appendRow(d.header);
  }
  var rows = d.rows || [];
  if (rows.length) {
    var w = 0;
    rows.forEach(function (r) { w = Math.max(w, r.length); });
    rows = rows.map(function (r) { while (r.length < w) r.push(''); return r; });
    sh.getRange(sh.getLastRow() + 1, 1, rows.length, w).setValues(rows);
  }
  return ContentService.createTextOutput('ok');
}
