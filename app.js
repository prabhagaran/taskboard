'use strict';

const STATUSES = [
  { id: 'todo', label: 'To Do' },
  { id: 'inprogress', label: 'In Progress' },
  { id: 'done', label: 'Done' },
];
const PRIORITIES = { high: 'High', medium: 'Medium', low: 'Low' };
const PRIORITY_RANK = { high: 0, medium: 1, low: 2 };

const CONFIG_KEY = 'taskboard.config';
const PREFS_KEY = 'taskboard.prefs';
const LOCAL_TASKS_KEY = 'taskboard.localTasks';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/* ---------- Storage (localStorage can throw in private mode) ---------- */
function storageGet(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}
function storageSet(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* storage unavailable; settings just won't persist */
  }
}

const state = {
  tasks: [],
  config: storageGet(CONFIG_KEY, { url: '', token: '' }),
  prefs: storageGet(PREFS_KEY, { view: 'board', hideDone: false }),
  filters: { search: '', project: '', priority: '' },
  pending: 0,
  syncError: '',
  loaded: false,
};

const isRemote = () => Boolean(state.config.url && state.config.token);

/* ---------- API ---------- */
async function remoteCall(action, payload = {}, config = state.config) {
  const res = await fetch(config.url, {
    method: 'POST',
    // text/plain keeps this a CORS "simple request", so Apps Script needs no preflight.
    headers: { 'Content-Type': 'text/plain;charset=utf-8' },
    body: JSON.stringify({ action, token: config.token, ...payload }),
  });
  if (!res.ok) throw new Error(`Server responded ${res.status}`);
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error('Unexpected response. Check the web app URL and that access is set to "Anyone".');
  }
  if (!data.ok) throw new Error(data.error || 'Request failed');
  return data;
}

const localStore = {
  read: () => storageGet(LOCAL_TASKS_KEY, []),
  write: (tasks) => storageSet(LOCAL_TASKS_KEY, tasks),
};

const api = {
  async list() {
    if (isRemote()) return (await remoteCall('list')).tasks;
    return localStore.read();
  },
  async create(task) {
    if (isRemote()) return (await remoteCall('create', { task })).task;
    const now = new Date().toISOString();
    const saved = { ...task, createdAt: now, updatedAt: now };
    localStore.write([...localStore.read(), saved]);
    return saved;
  },
  async update(task) {
    if (isRemote()) return (await remoteCall('update', { task })).task;
    const saved = { ...task, updatedAt: new Date().toISOString() };
    localStore.write(localStore.read().map((t) => (t.id === task.id ? saved : t)));
    return saved;
  },
  async remove(id) {
    if (isRemote()) return remoteCall('delete', { id });
    localStore.write(localStore.read().filter((t) => t.id !== id));
  },
};

async function withSync(fn) {
  state.pending++;
  renderSync();
  try {
    const result = await fn();
    state.syncError = '';
    return result;
  } catch (err) {
    state.syncError = err.message;
    throw err;
  } finally {
    state.pending--;
    renderSync();
  }
}

/* ---------- Data operations (optimistic, rolled back on failure) ---------- */
function normalize(task) {
  return {
    id: String(task.id),
    title: task.title || '(untitled)',
    description: task.description || '',
    status: STATUSES.some((s) => s.id === task.status) ? task.status : 'todo',
    priority: PRIORITIES[task.priority] ? task.priority : 'medium',
    project: task.project || '',
    dueDate: task.dueDate || '',
    createdAt: task.createdAt || '',
    updatedAt: task.updatedAt || '',
  };
}

async function loadTasks() {
  const btn = $('#refreshBtn');
  btn.classList.add('spinning');
  try {
    const tasks = await withSync(() => api.list());
    state.tasks = tasks.map(normalize);
    state.loaded = true;
  } catch (err) {
    toast(`Could not load tasks: ${err.message}`, true);
  } finally {
    btn.classList.remove('spinning');
    render();
  }
}

async function saveTask(task, isNew) {
  const snapshot = state.tasks;
  state.tasks = isNew ? [...state.tasks, task] : state.tasks.map((t) => (t.id === task.id ? task : t));
  render();
  try {
    const saved = normalize(await withSync(() => (isNew ? api.create(task) : api.update(task))));
    // The server may assign a different id; match on the one we sent.
    state.tasks = state.tasks.map((t) => (t.id === task.id ? saved : t));
    render();
  } catch (err) {
    state.tasks = snapshot;
    render();
    toast(`Could not save task: ${err.message}`, true);
  }
}

async function deleteTask(id) {
  const snapshot = state.tasks;
  state.tasks = state.tasks.filter((t) => t.id !== id);
  render();
  try {
    await withSync(() => api.remove(id));
    toast('Task deleted');
  } catch (err) {
    state.tasks = snapshot;
    render();
    toast(`Could not delete task: ${err.message}`, true);
  }
}

function setStatus(id, status) {
  const task = state.tasks.find((t) => t.id === id);
  if (task && task.status !== status) saveTask({ ...task, status }, false);
}

/* ---------- Helpers ---------- */
const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const pad = (n) => String(n).padStart(2, '0');
function todayStr() {
  const d = new Date();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function dueInfo(task) {
  if (!task.dueDate) return null;
  const [y, m, d] = task.dueDate.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  if (Number.isNaN(date.getTime())) return null;
  const today = todayStr();
  const label = date.toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    year: y !== new Date().getFullYear() ? 'numeric' : undefined,
  });
  return {
    label: task.dueDate === today ? 'Today' : label,
    overdue: task.status !== 'done' && task.dueDate < today,
    today: task.dueDate === today,
  };
}

function newId() {
  return crypto.randomUUID ? crypto.randomUUID() : `t-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function compareTasks(a, b) {
  return (
    PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority] ||
    (a.dueDate || '9999').localeCompare(b.dueDate || '9999') ||
    a.createdAt.localeCompare(b.createdAt)
  );
}

function visibleTasks() {
  const q = state.filters.search.trim().toLowerCase();
  return state.tasks
    .filter((t) => !state.prefs.hideDone || t.status !== 'done')
    .filter((t) => !state.filters.project || t.project === state.filters.project)
    .filter((t) => !state.filters.priority || t.priority === state.filters.priority)
    .filter((t) => !q || `${t.title} ${t.description} ${t.project}`.toLowerCase().includes(q))
    .sort(compareTasks);
}

/* ---------- Rendering ---------- */
function render() {
  renderSync();
  renderStats();
  renderProjects();
  $('#setupBanner').hidden = isRemote();
  $$('.segmented button').forEach((b) => {
    const active = b.dataset.view === state.prefs.view;
    b.classList.toggle('active', active);
    b.setAttribute('aria-selected', active);
  });
  $('#hideDone').checked = state.prefs.hideDone;

  const tasks = visibleTasks();
  $('#main').innerHTML = state.prefs.view === 'list' ? listHtml(tasks) : boardHtml(tasks);
}

function renderSync() {
  const el = $('#sync');
  el.className = 'sync';
  if (state.pending) {
    el.classList.add('saving');
    el.textContent = 'Syncing…';
  } else if (state.syncError) {
    el.classList.add('error');
    el.textContent = 'Sync error';
    el.title = state.syncError;
  } else {
    el.classList.add('ok');
    el.textContent = isRemote() ? 'Google Sheets' : 'Local mode';
    el.title = '';
  }
}

function renderStats() {
  const open = state.tasks.filter((t) => t.status !== 'done');
  const overdue = open.filter((t) => dueInfo(t)?.overdue).length;
  const done = state.tasks.length - open.length;
  $('#stats').innerHTML = `
    <span><b>${open.length}</b> open</span>
    <span class="${overdue ? 'overdue' : ''}"><b>${overdue}</b> overdue</span>
    <span><b>${done}</b> done</span>`;
}

function renderProjects() {
  const projects = [...new Set(state.tasks.map((t) => t.project).filter(Boolean))].sort((a, b) => a.localeCompare(b));
  if (state.filters.project && !projects.includes(state.filters.project)) state.filters.project = '';
  $('#projectFilter').innerHTML =
    `<option value="">All projects</option>` +
    projects.map((p) => `<option value="${esc(p)}" ${p === state.filters.project ? 'selected' : ''}>${esc(p)}</option>`).join('');
  $('#projectList').innerHTML = projects.map((p) => `<option value="${esc(p)}">`).join('');
}

function boardHtml(tasks) {
  const emptyText = state.loaded || !isRemote() ? 'No tasks' : 'Loading…';
  return `<div class="board">${STATUSES.map((s) => {
    const items = tasks.filter((t) => t.status === s.id);
    return `
      <section class="column" data-status="${s.id}">
        <div class="column-head">
          <span>${s.label}</span>
          <span class="count">${items.length}</span>
          <button class="add" data-add="${s.id}" title="Add to ${s.label}" aria-label="Add task to ${s.label}">
            <svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>
          </button>
        </div>
        <div class="column-body" data-status="${s.id}">
          ${items.length ? items.map(cardHtml).join('') : `<div class="empty">${emptyText}</div>`}
        </div>
      </section>`;
  }).join('')}</div>`;
}

function cardHtml(t) {
  const due = dueInfo(t);
  const done = t.status === 'done';
  return `
    <article class="card ${done ? 'is-done' : ''}" draggable="true" tabindex="0" data-id="${esc(t.id)}">
      <div class="card-top">
        <input type="checkbox" class="toggle" ${done ? 'checked' : ''} aria-label="Mark “${esc(t.title)}” done">
        <h3 class="card-title">${esc(t.title)}</h3>
      </div>
      ${t.description ? `<p class="card-desc">${esc(t.description)}</p>` : ''}
      <div class="meta">
        <span class="badge prio-${t.priority}">${PRIORITIES[t.priority]}</span>
        ${t.project ? `<span class="chip">${esc(t.project)}</span>` : ''}
        ${due ? `<span class="due ${due.overdue ? 'overdue' : ''} ${due.today ? 'today' : ''}">${due.overdue ? 'Overdue · ' : ''}${esc(due.label)}</span>` : ''}
      </div>
    </article>`;
}

function listHtml(tasks) {
  if (!tasks.length) return `<div class="table-wrap"><div class="empty">No tasks</div></div>`;
  const order = Object.fromEntries(STATUSES.map((s, i) => [s.id, i]));
  const rows = [...tasks]
    .sort((a, b) => order[a.status] - order[b.status] || compareTasks(a, b))
    .map((t) => {
      const due = dueInfo(t);
      const status = STATUSES.find((s) => s.id === t.status).label;
      return `
        <tr class="row ${t.status === 'done' ? 'is-done' : ''}" data-id="${esc(t.id)}" tabindex="0">
          <td><input type="checkbox" class="toggle" ${t.status === 'done' ? 'checked' : ''} aria-label="Mark done"></td>
          <td class="title-cell">${esc(t.title)}</td>
          <td>${status}</td>
          <td><span class="badge prio-${t.priority}">${PRIORITIES[t.priority]}</span></td>
          <td>${t.project ? `<span class="chip">${esc(t.project)}</span>` : ''}</td>
          <td>${due ? `<span class="due ${due.overdue ? 'overdue' : ''} ${due.today ? 'today' : ''}">${esc(due.label)}</span>` : ''}</td>
        </tr>`;
    })
    .join('');
  return `
    <div class="table-wrap">
      <table>
        <thead><tr><th></th><th>Task</th><th>Status</th><th>Priority</th><th>Project</th><th>Due</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
}

/* ---------- Task dialog ---------- */
const taskDialog = $('#taskDialog');
const taskForm = $('#taskForm');
let editingId = null;

function openTaskDialog(task = null, defaults = {}) {
  editingId = task ? task.id : null;
  const data = task || { title: '', description: '', status: 'todo', priority: 'medium', project: state.filters.project, dueDate: '', ...defaults };
  $('#taskDialogTitle').textContent = task ? 'Edit task' : 'New task';
  for (const name of ['title', 'description', 'status', 'priority', 'project', 'dueDate']) {
    taskForm.elements[name].value = data[name] || '';
  }
  const delBtn = $('#deleteTaskBtn');
  delBtn.hidden = !task;
  delBtn.classList.remove('confirm');
  delBtn.textContent = 'Delete';
  $('#taskMeta').textContent = task && task.updatedAt ? `Last updated ${new Date(task.updatedAt).toLocaleString()}` : '';
  taskDialog.showModal();
  taskForm.elements.title.focus();
}

taskForm.addEventListener('submit', (e) => {
  e.preventDefault();
  const f = taskForm.elements;
  const title = f.title.value.trim();
  if (!title) return f.title.focus();
  const fields = {
    title,
    description: f.description.value.trim(),
    status: f.status.value,
    priority: f.priority.value,
    project: f.project.value.trim(),
    dueDate: f.dueDate.value,
  };
  const existing = state.tasks.find((t) => t.id === editingId);
  if (existing) saveTask({ ...existing, ...fields }, false);
  else saveTask(normalize({ id: newId(), ...fields, createdAt: new Date().toISOString() }), true);
  taskDialog.close();
});

$('#deleteTaskBtn').addEventListener('click', (e) => {
  const btn = e.currentTarget;
  // Two-step delete instead of a blocking confirm() dialog.
  if (!btn.classList.contains('confirm')) {
    btn.classList.add('confirm');
    btn.textContent = 'Click again to delete';
    return;
  }
  deleteTask(editingId);
  taskDialog.close();
});

/* ---------- Settings dialog ---------- */
const settingsDialog = $('#settingsDialog');
const settingsForm = $('#settingsForm');

function openSettings() {
  settingsForm.elements.url.value = state.config.url;
  settingsForm.elements.token.value = state.config.token;
  setSettingsStatus('');
  settingsDialog.showModal();
}

function setSettingsStatus(text, kind = '') {
  const el = $('#settingsStatus');
  el.textContent = text;
  el.className = `small ${kind}`;
}

function readSettingsForm() {
  return { url: settingsForm.elements.url.value.trim(), token: settingsForm.elements.token.value.trim() };
}

$('#testBtn').addEventListener('click', async () => {
  const config = readSettingsForm();
  if (!config.url || !config.token) return setSettingsStatus('Enter both the URL and the token.', 'error');
  setSettingsStatus('Testing…');
  try {
    const { tasks } = await remoteCall('list', {}, config);
    setSettingsStatus(`Connected. ${tasks.length} task(s) in the sheet.`, 'ok');
  } catch (err) {
    setSettingsStatus(`Failed: ${err.message}`, 'error');
  }
});

settingsForm.addEventListener('submit', (e) => {
  e.preventDefault();
  const config = readSettingsForm();
  if (!config.url || !config.token) return setSettingsStatus('Enter both the URL and the token.', 'error');
  if (!/^https:\/\/script\.google(usercontent)?\.com\//.test(config.url)) {
    return setSettingsStatus('URL should start with https://script.google.com/', 'error');
  }
  state.config = config;
  storageSet(CONFIG_KEY, config);
  settingsDialog.close();
  state.loaded = false;
  state.tasks = [];
  loadTasks();
});

$('#disconnectBtn').addEventListener('click', () => {
  state.config = { url: '', token: '' };
  storageSet(CONFIG_KEY, state.config);
  settingsDialog.close();
  loadTasks();
});

$$('[data-close]').forEach((b) => b.addEventListener('click', () => b.closest('dialog').close()));

/* ---------- Board / list interactions ---------- */
const main = $('#main');

main.addEventListener('click', (e) => {
  const add = e.target.closest('[data-add]');
  if (add) return openTaskDialog(null, { status: add.dataset.add });

  const item = e.target.closest('[data-id]');
  if (!item) return;
  const task = state.tasks.find((t) => t.id === item.dataset.id);
  if (!task) return;
  if (e.target.classList.contains('toggle')) {
    setStatus(task.id, e.target.checked ? 'done' : 'todo');
  } else {
    openTaskDialog(task);
  }
});

main.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' || e.target.classList.contains('toggle')) return;
  const item = e.target.closest('[data-id]');
  const task = item && state.tasks.find((t) => t.id === item.dataset.id);
  if (task) openTaskDialog(task);
});

main.addEventListener('dragstart', (e) => {
  const card = e.target.closest('.card');
  if (!card) return;
  e.dataTransfer.setData('text/plain', card.dataset.id);
  e.dataTransfer.effectAllowed = 'move';
  card.classList.add('dragging');
});
main.addEventListener('dragend', (e) => e.target.closest('.card')?.classList.remove('dragging'));
main.addEventListener('dragover', (e) => {
  const zone = e.target.closest('.column-body');
  if (!zone) return;
  e.preventDefault();
  $$('.column-body.drop-target').forEach((z) => z !== zone && z.classList.remove('drop-target'));
  zone.classList.add('drop-target');
});
main.addEventListener('dragleave', (e) => {
  const zone = e.target.closest('.column-body');
  if (zone && !zone.contains(e.relatedTarget)) zone.classList.remove('drop-target');
});
main.addEventListener('drop', (e) => {
  const zone = e.target.closest('.column-body');
  if (!zone) return;
  e.preventDefault();
  zone.classList.remove('drop-target');
  setStatus(e.dataTransfer.getData('text/plain'), zone.dataset.status);
});

/* ---------- Toolbar ---------- */
$('#search').addEventListener('input', (e) => {
  state.filters.search = e.target.value;
  render();
});
$('#projectFilter').addEventListener('change', (e) => {
  state.filters.project = e.target.value;
  render();
});
$('#priorityFilter').addEventListener('change', (e) => {
  state.filters.priority = e.target.value;
  render();
});
$('#hideDone').addEventListener('change', (e) => {
  state.prefs.hideDone = e.target.checked;
  storageSet(PREFS_KEY, state.prefs);
  render();
});
$$('.segmented button').forEach((b) =>
  b.addEventListener('click', () => {
    state.prefs.view = b.dataset.view;
    storageSet(PREFS_KEY, state.prefs);
    render();
  }),
);

$('#newTaskBtn').addEventListener('click', () => openTaskDialog());
$('#refreshBtn').addEventListener('click', loadTasks);
$('#settingsBtn').addEventListener('click', openSettings);
$('#bannerConnectBtn').addEventListener('click', openSettings);

document.addEventListener('keydown', (e) => {
  const typing = e.target.closest('input, textarea, select, [contenteditable]');
  if (typing || e.ctrlKey || e.metaKey || e.altKey || document.querySelector('dialog[open]')) return;
  if (e.key === 'n') {
    e.preventDefault();
    openTaskDialog();
  } else if (e.key === '/') {
    e.preventDefault();
    $('#search').focus();
  }
});

// Pick up edits made directly in the sheet (or on another device) when returning to the tab.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && isRemote() && !state.pending) loadTasks();
});

/* ---------- Toast ---------- */
let toastTimer;
function toast(message, isError = false) {
  const el = $('#toast');
  el.textContent = message;
  el.classList.toggle('error', isError);
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), isError ? 5000 : 2500);
}

render();
loadTasks();
