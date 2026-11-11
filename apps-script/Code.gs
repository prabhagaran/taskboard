/**
 * TaskBoard backend: a Google Apps Script web app bound to a Google Sheet.
 *
 * Setup (see README.md for screenshots-level detail):
 *   1. In your Google Sheet: Extensions > Apps Script, replace Code.gs with this file.
 *   2. Run setup() once and copy the API token from the execution log.
 *   3. Deploy > New deployment > Web app. Execute as: Me. Who has access: Anyone.
 *   4. Paste the web app URL and the token into TaskBoard's settings.
 *
 * Optional, each run once before deploying so its permission is approved:
 *   setupCalendarSync()  Google Calendar sync
 *   setupReminders()     daily email of due and overdue tasks
 *   setupBackups()       daily copy of this spreadsheet to Drive
 * Per-device tokens: see createDeviceTokens().
 */

const SHEET_NAME = 'Tasks';
const HISTORY_SHEET = 'History';
const DEVICES_SHEET = 'Devices';
const NOTES_SHEET = 'Notes';
const CALENDAR_NAME = 'TaskBoard';
const BACKUP_FOLDER = 'TaskBoard backups';
const BACKUPS_KEPT = 14;
const REMINDER_HOUR = 8;
const BACKUP_HOUR = 2;
// New columns go at the end so existing sheets can be upgraded in place.
const HEADERS = ['id', 'title', 'description', 'status', 'priority', 'project', 'dueDate', 'createdAt', 'updatedAt', 'tags', 'links', 'sortOrder', 'completedAt', 'recurrence', 'checklist'];
const HISTORY_HEADERS = ['at', 'taskId', 'title', 'action', 'details'];
const DEVICE_HEADERS = ['name', 'token'];
// taskIds is a comma-separated list of the tasks a note is linked to.
const NOTE_HEADERS = ['id', 'title', 'body', 'taskIds', 'createdAt', 'updatedAt'];
const NOTE_BODY_MAX = 40000; // A Sheets cell holds at most 50,000 characters.
const EDITABLE = ['title', 'description', 'status', 'priority', 'project', 'dueDate', 'tags', 'links', 'sortOrder', 'recurrence', 'checklist'];
const TRACKED = ['title', 'description', 'status', 'priority', 'project', 'dueDate', 'tags', 'links', 'recurrence', 'checklist'];
const STATUSES = ['todo', 'inprogress', 'done'];
const PRIORITIES = ['low', 'medium', 'high'];
const RECURRENCES = ['daily', 'weekly', 'monthly', 'yearly'];
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

/**
 * Gives each device its own revocable token. Type a name per device in column A
 * of the Devices sheet (this creates it on first run), then run this again to
 * fill in the tokens. Delete a row to revoke that device immediately.
 */
function createDeviceTokens() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sheet = ss.getSheetByName(DEVICES_SHEET) || ss.insertSheet(DEVICES_SHEET);
  ensureColumns_(sheet, DEVICE_HEADERS);
  const last = sheet.getLastRow();
  for (let row = 2; row <= last; row++) {
    const cell = sheet.getRange(row, 2);
    if (sheet.getRange(row, 1).getValue() && !cell.getValue()) cell.setValue(newToken_());
  }
}

function newToken_() {
  return Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
}

function isDeviceToken_(token) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(DEVICES_SHEET);
  if (!sheet || sheet.getLastRow() < 2) return false;
  return sheet
    .getRange(2, 2, sheet.getLastRow() - 1, 1)
    .getValues()
    .some(function (row) { return row[0] !== '' && row[0] === token; });
}

/** Run once from the editor: emails due and overdue tasks every morning. */
function setupReminders() {
  replaceTrigger_('sendReminders', REMINDER_HOUR);
  sendReminders();
}

function sendReminders() {
  const today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  const due = readTasks_(getSheet_()).filter(function (task) {
    return task.status !== 'done' && task.dueDate && task.dueDate <= today;
  });
  if (!due.length) return;
  due.sort(function (a, b) { return a.dueDate < b.dueDate ? -1 : a.dueDate > b.dueDate ? 1 : 0; });
  const lines = due.map(function (task) {
    const when = task.dueDate < today ? 'overdue since ' + task.dueDate : 'due today';
    return '- ' + task.title + ' (' + task.priority + ', ' + when + ')';
  });
  MailApp.sendEmail(
    Session.getEffectiveUser().getEmail(),
    'TaskBoard: ' + due.length + ' task' + (due.length === 1 ? '' : 's') + ' need attention',
    lines.join('\n')
  );
}

/** Run once from the editor: copies this spreadsheet to Drive every night. */
function setupBackups() {
  replaceTrigger_('backupSheet', BACKUP_HOUR);
  backupSheet();
}

function backupSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const folders = DriveApp.getFoldersByName(BACKUP_FOLDER);
  const folder = folders.hasNext() ? folders.next() : DriveApp.createFolder(BACKUP_FOLDER);
  const stamp = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  DriveApp.getFileById(ss.getId()).makeCopy(ss.getName() + ' backup ' + stamp, folder);

  const copies = [];
  const files = folder.getFiles();
  while (files.hasNext()) copies.push(files.next());
  copies
    .sort(function (a, b) { return b.getDateCreated() - a.getDateCreated(); })
    .slice(BACKUPS_KEPT)
    .forEach(function (file) { file.setTrashed(true); });
}

function replaceTrigger_(handler, hour) {
  ScriptApp.getProjectTriggers()
    .filter(function (t) { return t.getHandlerFunction() === handler; })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger(handler).timeBased().everyDays(1).atHour(hour).create();
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
    return json_(failure_(err));
  }
}

function failure_(err) {
  const result = { ok: false, error: err.message };
  if (err.conflict) result.conflict = err.conflict;
  return result;
}

function route_(req) {
  if (req.action === 'list') return { tasks: readTasks_(getSheet_()), notes: readNotes_(getNotesSheet_()) };
  if (req.action === 'history') return { entries: readHistory_(req.id) };

  // Serialize writes so concurrent requests can't clobber row positions.
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const sheet = getSheet_();
    if (req.action === 'batch') {
      // One failed op must not stop the rest, so each reports its own result.
      return {
        results: (req.ops || []).map(function (op) {
          try {
            return Object.assign({ ok: true }, applyWrite_(sheet, op));
          } catch (err) {
            return failure_(err);
          }
        }),
      };
    }
    return applyWrite_(sheet, req);
  } finally {
    lock.releaseLock();
  }
}

function applyWrite_(sheet, op) {
  switch (op.action) {
    case 'create':
      return { task: createTask_(sheet, op.task || {}) };
    case 'update':
      return updateTask_(sheet, op.task || {}, op.force === true);
    case 'delete':
      deleteTask_(sheet, op.id);
      return {};
    case 'createNote':
      return { note: createNote_(getNotesSheet_(), op.note || {}) };
    case 'updateNote':
      return { note: updateNote_(getNotesSheet_(), op.note || {}, op.force === true) };
    case 'deleteNote': {
      const notes = getNotesSheet_();
      const rowIndex = findRow_(notes, op.id);
      if (rowIndex) notes.deleteRow(rowIndex);
      return {};
    }
    default:
      throw new Error('Unknown action: ' + op.action);
  }
}

function checkToken_(token) {
  const expected = PropertiesService.getScriptProperties().getProperty('API_TOKEN');
  if (!expected) throw new Error('Backend not configured: run setup() in Apps Script.');
  if (!token || (token !== expected && !isDeviceToken_(token))) throw new Error('Invalid API token.');
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
  return getOrCreateSheet_(HISTORY_SHEET, HISTORY_HEADERS);
}

function getNotesSheet_() {
  return getOrCreateSheet_(NOTES_SHEET, NOTE_HEADERS);
}

function getOrCreateSheet_(name, headers) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(name);
  if (!sheet) {
    sheet = ss.insertSheet(name);
    sheet.setFrozenRows(1);
  }
  ensureColumns_(sheet, headers);
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
      if (key === 'description' || key === 'links' || key === 'checklist') return key + ' changed';
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
  const task = clean_(input, { description: '', status: 'todo', priority: 'medium', project: '', dueDate: '', tags: '', links: '', sortOrder: '', recurrence: '', checklist: '' });
  const id = String(input.id || '');
  const validId = /^[\w-]{1,64}$/.test(id);
  // A retried create (say, after a lost response) must not add a second copy.
  const existing = validId ? findRow_(sheet, id) : 0;
  if (existing) return rowToTask_(sheet.getRange(existing, 1, 1, HEADERS.length).getValues()[0]);
  task.id = validId ? id : Utilities.getUuid();
  task.createdAt = task.updatedAt = new Date().toISOString();
  task.completedAt = task.status === 'done' ? task.createdAt : '';
  sheet.appendRow(taskToRow_(task));
  logHistory_(task, 'created', '');
  return task;
}

/** The next copy of a recurring task, due on its first date after today. */
function nextOccurrence_(task) {
  const today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  const start = task.dueDate || today;
  let due = start;
  for (let step = 1; due <= today; step++) due = advanceDay_(start, task.recurrence, step);
  const now = new Date().toISOString();
  return Object.assign({}, task, {
    id: Utilities.getUuid(),
    status: 'todo',
    dueDate: due,
    sortOrder: '',
    completedAt: '',
    checklist: task.checklist.replace(/^\[x\]/gim, '[ ]'),
    createdAt: now,
    updatedAt: now,
  });
}

function advanceDay_(key, recurrence, steps) {
  const parts = key.split('-').map(Number);
  const year = parts[0];
  const month = parts[1] - 1;
  const day = parts[2];
  let result;
  if (recurrence === 'daily') result = new Date(year, month, day + steps);
  else if (recurrence === 'weekly') result = new Date(year, month, day + steps * 7);
  else {
    const months = recurrence === 'monthly' ? steps : steps * 12;
    // Day 0 of the following month is the last day of the target month, so the
    // 31st clamps to shorter months without drifting on later repeats.
    const lastDay = new Date(year, month + months + 1, 0).getDate();
    result = new Date(year, month + months, Math.min(day, lastDay));
  }
  return Utilities.formatDate(result, Session.getScriptTimeZone(), 'yyyy-MM-dd');
}

function updateTask_(sheet, input, force) {
  const rowIndex = findRow_(sheet, input.id);
  if (!rowIndex) throw new Error('Task not found. It may have been deleted.');
  const range = sheet.getRange(rowIndex, 1, 1, HEADERS.length);
  const before = rowToTask_(range.getValues()[0]);
  if (!force && input.baseUpdatedAt && input.baseUpdatedAt !== before.updatedAt) {
    const conflict = new Error('This task was changed somewhere else.');
    conflict.conflict = before;
    throw conflict;
  }
  const task = clean_(input, before);
  task.updatedAt = new Date().toISOString();
  const finished = before.status !== 'done' && task.status === 'done';
  if (finished) task.completedAt = task.updatedAt;
  else if (task.status !== 'done') task.completedAt = '';
  range.setValues([taskToRow_(task)]);
  const changes = describeChanges_(before, task);
  if (changes) logHistory_(task, 'updated', changes);
  if (!finished || !task.recurrence) return { task: task };

  const next = nextOccurrence_(task);
  sheet.appendRow(taskToRow_(next));
  logHistory_(next, 'created', 'repeats ' + task.recurrence);
  return { task: task, next: next };
}

function deleteTask_(sheet, id) {
  const rowIndex = findRow_(sheet, id);
  if (!rowIndex) return;
  const task = rowToTask_(sheet.getRange(rowIndex, 1, 1, HEADERS.length).getValues()[0]);
  sheet.deleteRow(rowIndex);
  logHistory_(task, 'deleted', '');
}

function readNotes_(sheet) {
  const last = sheet.getLastRow();
  if (last < 2) return [];
  return sheet
    .getRange(2, 1, last - 1, NOTE_HEADERS.length)
    .getValues()
    .filter(function (row) { return row[0] !== ''; })
    .map(rowToNote_);
}

function createNote_(sheet, input) {
  const note = cleanNote_(input, { title: '', body: '', taskIds: '' });
  const id = String(input.id || '');
  const validId = /^[\w-]{1,64}$/.test(id);
  // A retried create (say, after a lost response) must not add a second copy.
  const existing = validId ? findRow_(sheet, id) : 0;
  if (existing) return rowToNote_(sheet.getRange(existing, 1, 1, NOTE_HEADERS.length).getValues()[0]);
  note.id = validId ? id : Utilities.getUuid();
  note.createdAt = note.updatedAt = new Date().toISOString();
  sheet.appendRow(noteToRow_(note));
  return note;
}

function updateNote_(sheet, input, force) {
  const rowIndex = findRow_(sheet, input.id);
  if (!rowIndex) throw new Error('Note not found. It may have been deleted.');
  const range = sheet.getRange(rowIndex, 1, 1, NOTE_HEADERS.length);
  const before = rowToNote_(range.getValues()[0]);
  if (!force && input.baseUpdatedAt && input.baseUpdatedAt !== before.updatedAt) {
    const conflict = new Error('This note was changed somewhere else.');
    conflict.conflict = before;
    throw conflict;
  }
  const note = cleanNote_(input, before);
  note.updatedAt = new Date().toISOString();
  range.setValues([noteToRow_(note)]);
  return note;
}

function cleanNote_(input, base) {
  const note = Object.assign({}, base);
  ['title', 'body', 'taskIds'].forEach(function (key) {
    if (input[key] !== undefined && input[key] !== null) note[key] = String(input[key]);
  });
  note.title = note.title.trim();
  note.body = note.body.replace(/\s+$/, '');
  if (!note.title && !note.body.trim()) throw new Error('A note needs a title or some text.');
  if (note.title.length > 500) throw new Error('Title is too long.');
  if (note.body.length > NOTE_BODY_MAX) throw new Error('Note is too long.');
  const ids = note.taskIds
    .split(',')
    .map(function (id) { return id.trim(); })
    .filter(function (id) { return /^[\w-]{1,64}$/.test(id); });
  note.taskIds = ids.filter(function (id, i) { return ids.indexOf(id) === i; }).join(',');
  return note;
}

function rowToNote_(row) {
  const note = {};
  NOTE_HEADERS.forEach(function (header, i) {
    note[header] = row[i] == null ? '' : String(row[i]);
  });
  return note;
}

function noteToRow_(note) {
  return NOTE_HEADERS.map(function (header) { return safeCell_(note[header]); });
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
  if (RECURRENCES.indexOf(task.recurrence) < 0) task.recurrence = '';
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
