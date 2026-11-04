/**
 * TaskBoard backend: a Google Apps Script web app bound to a Google Sheet.
 *
 * Setup (see README.md for screenshots-level detail):
 *   1. In your Google Sheet: Extensions > Apps Script, replace Code.gs with this file.
 *   2. Run setup() once and copy the API token from the execution log.
 *   3. Deploy > New deployment > Web app. Execute as: Me. Who has access: Anyone.
 *   4. Paste the web app URL and the token into TaskBoard's settings.
 */

const SHEET_NAME = 'Tasks';
const HEADERS = ['id', 'title', 'description', 'status', 'priority', 'project', 'dueDate', 'createdAt', 'updatedAt'];
const EDITABLE = ['title', 'description', 'status', 'priority', 'project', 'dueDate'];
const STATUSES = ['todo', 'inprogress', 'done'];
const PRIORITIES = ['low', 'medium', 'high'];

/** Run once from the Apps Script editor: creates the sheet and the API token. */
function setup() {
  getSheet_();
  const props = PropertiesService.getScriptProperties();
  let token = props.getProperty('API_TOKEN');
  if (!token) {
    token = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
    props.setProperty('API_TOKEN', token);
  }
  Logger.log('API token: ' + token);
}

/** Run this if the token ever leaks; the old one stops working immediately. */
function rotateToken() {
  PropertiesService.getScriptProperties().deleteProperty('API_TOKEN');
  setup();
}

function doGet() {
  return json_({ ok: true, service: 'TaskBoard', message: 'Send POST requests.' });
}

function doPost(e) {
  let req;
  try {
    req = JSON.parse((e && e.postData && e.postData.contents) || '{}');
  } catch (err) {
    return json_({ ok: false, error: 'Invalid JSON body.' });
  }
  try {
    checkToken_(req.token);
    return json_(Object.assign({ ok: true }, route_(req)));
  } catch (err) {
    return json_({ ok: false, error: err.message });
  }
}

function route_(req) {
  if (req.action === 'list') return { tasks: readTasks_(getSheet_()) };

  // Serialize writes so concurrent requests can't clobber row positions.
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const sheet = getSheet_();
    switch (req.action) {
      case 'create':
        return { task: createTask_(sheet, req.task || {}) };
      case 'update':
        return { task: updateTask_(sheet, req.task || {}) };
      case 'delete':
        deleteTask_(sheet, req.id);
        return {};
      default:
        throw new Error('Unknown action: ' + req.action);
    }
  } finally {
    lock.releaseLock();
  }
}

function checkToken_(token) {
  const expected = PropertiesService.getScriptProperties().getProperty('API_TOKEN');
  if (!expected) throw new Error('Backend not configured: run setup() in Apps Script.');
  if (token !== expected) throw new Error('Invalid API token.');
}

function getSheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
    // Plain text so Sheets doesn't reinterpret dates and IDs.
    sheet.getRange('A:I').setNumberFormat('@');
    sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]).setFontWeight('bold');
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function readTasks_(sheet) {
  const last = sheet.getLastRow();
  if (last < 2) return [];
  return sheet
    .getRange(2, 1, last - 1, HEADERS.length)
    .getValues()
    .filter(function (row) { return row[0] !== ''; })
    .map(rowToTask_);
}

function createTask_(sheet, input) {
  const task = clean_(input, { description: '', status: 'todo', priority: 'medium', project: '', dueDate: '' });
  const id = String(input.id || '');
  task.id = /^[\w-]{1,64}$/.test(id) && !findRow_(sheet, id) ? id : Utilities.getUuid();
  task.createdAt = task.updatedAt = new Date().toISOString();
  sheet.appendRow(taskToRow_(task));
  return task;
}

function updateTask_(sheet, input) {
  const rowIndex = findRow_(sheet, input.id);
  if (!rowIndex) throw new Error('Task not found. It may have been deleted.');
  const range = sheet.getRange(rowIndex, 1, 1, HEADERS.length);
  const task = clean_(input, rowToTask_(range.getValues()[0]));
  task.updatedAt = new Date().toISOString();
  range.setValues([taskToRow_(task)]);
  return task;
}

function deleteTask_(sheet, id) {
  const rowIndex = findRow_(sheet, id);
  if (rowIndex) sheet.deleteRow(rowIndex);
}

function findRow_(sheet, id) {
  if (!id) return 0;
  const last = sheet.getLastRow();
  if (last < 2) return 0;
  const ids = sheet.getRange(2, 1, last - 1, 1).getValues();
  for (let i = 0; i < ids.length; i++) {
    if (String(ids[i][0]) === String(id)) return i + 2;
  }
  return 0;
}

function clean_(input, base) {
  const task = Object.assign({}, base);
  EDITABLE.forEach(function (key) {
    if (input[key] !== undefined && input[key] !== null) task[key] = String(input[key]).trim();
  });
  if (!task.title) throw new Error('Title is required.');
  if (task.title.length > 500) throw new Error('Title is too long.');
  if (STATUSES.indexOf(task.status) < 0) task.status = 'todo';
  if (PRIORITIES.indexOf(task.priority) < 0) task.priority = 'medium';
  if (task.dueDate && !/^\d{4}-\d{2}-\d{2}$/.test(task.dueDate)) throw new Error('Due date must be YYYY-MM-DD.');
  return task;
}

function rowToTask_(row) {
  const task = {};
  HEADERS.forEach(function (header, i) {
    const value = row[i];
    task[header] = value instanceof Date
      ? Utilities.formatDate(value, Session.getScriptTimeZone(), 'yyyy-MM-dd')
      : value == null ? '' : String(value);
  });
  return task;
}

function taskToRow_(task) {
  return HEADERS.map(function (header) {
    const value = task[header] == null ? '' : String(task[header]);
    // A leading apostrophe stops Sheets from treating user text as a formula.
    return /^[=+\-@]/.test(value) ? "'" + value : value;
  });
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
