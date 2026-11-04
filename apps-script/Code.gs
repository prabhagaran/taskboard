/**
 * TaskBoard backend: a Google Apps Script web app bound to a Google Sheet.
 *
 * Setup (see README.md for screenshots-level detail):
 *   1. In your Google Sheet: Extensions > Apps Script, replace Code.gs with this file.
 *   2. Run setup() once and copy the API token from the execution log.
 *   3. Deploy > New deployment > Web app. Execute as: Me. Who has access: Anyone.
 *   4. Paste the web app URL and the token into TaskBoard's settings.
 *
 * Optional: run setupCalendarSync() once, before deploying, for Google Calendar sync.
 */

const SHEET_NAME = 'Tasks';
const HISTORY_SHEET = 'History';
const CALENDAR_NAME = 'TaskBoard';
// New columns go at the end so existing sheets can be upgraded in place.
const HEADERS = ['id', 'title', 'description', 'status', 'priority', 'project', 'dueDate', 'createdAt', 'updatedAt', 'tags', 'links', 'sortOrder'];
const HISTORY_HEADERS = ['at', 'taskId', 'title', 'action', 'details'];
const EDITABLE = ['title', 'description', 'status', 'priority', 'project', 'dueDate', 'tags', 'links', 'sortOrder'];
const TRACKED = ['title', 'description', 'status', 'priority', 'project', 'dueDate', 'tags', 'links'];
const STATUSES = ['todo', 'inprogress', 'done'];
const PRIORITIES = ['low', 'medium', 'high'];
const HISTORY_READ_LIMIT = 5000;

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

/**
 * Run once from the editor to turn on Google Calendar sync: approves the
 * Calendar permission, syncs now, and schedules an hourly sync.
 */
function setupCalendarSync() {
  ScriptApp.getProjectTriggers()
    .filter(function (t) { return t.getHandlerFunction() === 'syncCalendar'; })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('syncCalendar').timeBased().everyHours(1).create();
  syncCalendar();
}

/**
 * One-way sync of open tasks with due dates into a dedicated calendar.
 * Only events in that calendar are ever changed or removed.
 */
function syncCalendar() {
  const calendar = CalendarApp.getCalendarsByName(CALENDAR_NAME)[0] || CalendarApp.createCalendar(CALENDAR_NAME);
  const timeZone = Session.getScriptTimeZone();
  const from = new Date();
  from.setDate(from.getDate() - 90);
  const to = new Date();
  to.setFullYear(to.getFullYear() + 2);

  const wanted = {};
  readTasks_(getSheet_()).forEach(function (task) {
    if (task.status !== 'done' && task.dueDate) wanted[task.id] = task;
  });

  calendar.getEvents(from, to).forEach(function (event) {
    const id = event.getTag('taskId');
    const task = wanted[id];
    if (!task) {
      event.deleteEvent();
      return;
    }
    delete wanted[id];
    if (event.getTitle() !== task.title) event.setTitle(task.title);
    if (Utilities.formatDate(event.getAllDayStartDate(), timeZone, 'yyyy-MM-dd') !== task.dueDate) {
      event.setAllDayDate(parseDay_(task.dueDate));
    }
  });

  Object.keys(wanted).forEach(function (id) {
    const task = wanted[id];
    const day = parseDay_(task.dueDate);
    if (day < from || day > to) return;
    calendar.createAllDayEvent(task.title, day, { description: task.description }).setTag('taskId', id);
  });
}

function parseDay_(key) {
  const parts = key.split('-').map(Number);
  return new Date(parts[0], parts[1] - 1, parts[2]);
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
  if (req.action === 'history') return { entries: readHistory_(req.id) };

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
    sheet.setFrozenRows(1);
  }
  ensureColumns_(sheet, HEADERS);
  return sheet;
}

/** Creates the header row, or appends columns missing from an older sheet. */
function ensureColumns_(sheet, headers) {
  if (sheet.getRange(1, headers.length).getValue() === headers[headers.length - 1]) return;
  const missing = headers.length - sheet.getMaxColumns();
  if (missing > 0) sheet.insertColumnsAfter(sheet.getMaxColumns(), missing);
  // Plain text so Sheets doesn't reinterpret dates and IDs.
  sheet.getRange(1, 1, sheet.getMaxRows(), headers.length).setNumberFormat('@');
  sheet.getRange(1, 1, 1, headers.length).setValues([headers]).setFontWeight('bold');
}

function getHistorySheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(HISTORY_SHEET);
  if (!sheet) {
    sheet = ss.insertSheet(HISTORY_SHEET);
    sheet.setFrozenRows(1);
  }
  ensureColumns_(sheet, HISTORY_HEADERS);
  return sheet;
}

function logHistory_(task, action, details) {
  getHistorySheet_().appendRow(
    [new Date().toISOString(), task.id, task.title, action, details].map(safeCell_)
  );
}

/** Newest first, from the most recent rows of the log. */
function readHistory_(id) {
  const sheet = getHistorySheet_();
  const last = sheet.getLastRow();
  if (last < 2 || !id) return [];
  const rows = Math.min(last - 1, HISTORY_READ_LIMIT);
  return sheet
    .getRange(last - rows + 1, 1, rows, HISTORY_HEADERS.length)
    .getValues()
    .filter(function (row) { return String(row[1]) === String(id); })
    .map(function (row) {
      return { at: String(row[0]), action: String(row[3]), details: String(row[4]) };
    })
    .reverse();
}

/** Human-readable list of tracked fields that differ between two versions. */
function describeChanges_(before, after) {
  return TRACKED
    .filter(function (key) { return String(before[key] || '') !== String(after[key] || ''); })
    .map(function (key) {
      if (key === 'description' || key === 'links') return key + ' changed';
      return key + ': ' + (before[key] || 'none') + ' → ' + (after[key] || 'none');
    })
    .join('; ');
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
  const task = clean_(input, { description: '', status: 'todo', priority: 'medium', project: '', dueDate: '', tags: '', links: '', sortOrder: '' });
  const id = String(input.id || '');
  task.id = /^[\w-]{1,64}$/.test(id) && !findRow_(sheet, id) ? id : Utilities.getUuid();
  task.createdAt = task.updatedAt = new Date().toISOString();
  sheet.appendRow(taskToRow_(task));
  logHistory_(task, 'created', '');
  return task;
}

function updateTask_(sheet, input) {
  const rowIndex = findRow_(sheet, input.id);
  if (!rowIndex) throw new Error('Task not found. It may have been deleted.');
  const range = sheet.getRange(rowIndex, 1, 1, HEADERS.length);
  const before = rowToTask_(range.getValues()[0]);
  const task = clean_(input, before);
  task.updatedAt = new Date().toISOString();
  range.setValues([taskToRow_(task)]);
  const changes = describeChanges_(before, task);
  if (changes) logHistory_(task, 'updated', changes);
  return task;
}

function deleteTask_(sheet, id) {
  const rowIndex = findRow_(sheet, id);
  if (!rowIndex) return;
  const task = rowToTask_(sheet.getRange(rowIndex, 1, 1, HEADERS.length).getValues()[0]);
  sheet.deleteRow(rowIndex);
  logHistory_(task, 'deleted', '');
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
  if (task.sortOrder && !/^-?\d+(\.\d+)?$/.test(task.sortOrder)) task.sortOrder = '';
  task.links = (task.links || '')
    .split('\n')
    .map(function (link) { return link.trim(); })
    .filter(function (link) { return /^https?:\/\//i.test(link); })
    .join('\n');
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
  return HEADERS.map(function (header) { return safeCell_(task[header]); });
}

function safeCell_(cell) {
  const value = cell == null ? '' : String(cell);
  // A leading apostrophe stops Sheets from treating user text as a formula.
  return /^[=+\-@]/.test(value) ? "'" + value : value;
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
