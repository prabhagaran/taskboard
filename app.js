'use strict';

/* ==========================================================================
   Constants
   ========================================================================== */
const STATUSES = [
  { id: 'todo', label: 'To Do' },
  { id: 'done', label: 'Done' },
];
const STATUS_LABEL = Object.fromEntries(STATUSES.map((s) => [s.id, s.label]));
const STATUS_RANK = { todo: 0, done: 1 };
const PRIORITIES = { high: 'High', medium: 'Medium', low: 'Low' };
const PRIORITY_RANK = { high: 0, medium: 1, low: 2 };

const CONFIG_KEY = 'taskboard.config';
const PREFS_KEY = 'taskboard.prefs';
const LOCAL_TASKS_KEY = 'taskboard.localTasks';
const CACHE_KEY = 'taskboard.cache';
const QUEUE_KEY = 'taskboard.queue';

// Smart lists in the sidebar. `test` selects tasks; `badge` is the sidebar count.
const SCOPES = [
  { id: 'dashboard', label: 'Dashboard', icon: 'dashboard' },
  { id: 'all', label: 'All tasks', icon: 'inbox', test: () => true, badge: isOpen },
  { id: 'today', label: 'Today', icon: 'today', test: (t) => isOpen(t) && t.dueDate && t.dueDate <= todayStr() },
  { id: 'upcoming', label: 'Next 7 days', icon: 'calendar', test: (t) => isOpen(t) && t.dueDate > todayStr() && t.dueDate <= addDays(7) },
  { id: 'overdue', label: 'Overdue', icon: 'alert', test: isOverdue, alert: true },
  { id: 'completed', label: 'Completed', icon: 'done', test: (t) => t.status === 'done' },
];

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/* ==========================================================================
   Storage (localStorage can throw in private mode)
   ========================================================================== */
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
  prefs: { view: 'board', hideDone: false, theme: 'system', sort: { key: 'priority', dir: 'asc' }, savedFilters: [], ...storageGet(PREFS_KEY, {}) },
  route: parseRoute(),
  filters: { search: '', priority: '', tag: '' },
  calendar: { month: null, expanded: '' },
  selection: new Set(),
  queue: storageGet(QUEUE_KEY, []), // Writes waiting for a connection.
  quickAdd: null, // { status, text } while the inline board composer is open
  pending: 0,
  syncError: '',
  loaded: false,
};
if (state.prefs.view === 'list') state.prefs.view = 'table';

const isRemote = () => Boolean(state.config.url && state.config.token);
if (isRemote()) {
  // Show the last synced tasks at once; Apps Script can take seconds.
  state.tasks = storageGet(CACHE_KEY, []).map(normalize);
  state.loaded = state.tasks.length > 0;
}
const savePrefs = () => storageSet(PREFS_KEY, state.prefs);

/* ==========================================================================
   API
   ========================================================================== */
/** The server could not be reached, so the request may succeed if retried. */
class NetworkError extends Error {}

async function remoteCall(action, payload = {}, config = state.config) {
  let res;
  try {
    res = await fetch(config.url, {
      method: 'POST',
      // text/plain keeps this a CORS "simple request", so Apps Script needs no preflight.
      headers: { 'Content-Type': 'text/plain;charset=utf-8' },
      body: JSON.stringify({ action, token: config.token, ...payload }),
    });
  } catch {
    throw new NetworkError('Could not reach the web app. Check the URL ends in /exec and that you are online.');
  }
  if (res.status >= 500) throw new NetworkError(`Server responded ${res.status}`);
  if (!res.ok) throw new Error(`Server responded ${res.status}`);
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error('Unexpected response. Check the web app URL and that access is set to "Anyone".');
  }
  if (!data.ok) {
    if (/^Unknown action/.test(data.error)) throw new Error('Apps Script is out of date. Deploy the latest Code.gs as a new version.');
    throw new Error(data.error || 'Request failed');
  }
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
  async history(id) {
    return (await remoteCall('history', { id })).entries;
  },
};

// Mirrors what Apps Script does on a write, for local mode.
function applyLocally(op) {
  const tasks = localStore.read();
  const now = new Date().toISOString();
  if (op.action === 'delete') {
    localStore.write(tasks.filter((t) => t.id !== op.id));
    return { ok: true };
  }
  if (op.action === 'create') {
    const task = { ...op.task, createdAt: now, updatedAt: now, completedAt: op.task.status === 'done' ? now : '' };
    localStore.write([...tasks.filter((t) => t.id !== task.id), task]);
    return { ok: true, task };
  }
  const before = tasks.find((t) => t.id === op.task.id);
  if (!before) return { ok: false, error: 'Task not found.' };
  const finished = before.status !== 'done' && op.task.status === 'done';
  const task = { ...op.task, updatedAt: now, completedAt: finished ? now : op.task.status === 'done' ? before.completedAt : '' };
  const next = finished && task.recurrence ? nextOccurrence(task) : null;
  localStore.write([...tasks.map((t) => (t.id === task.id ? task : t)), ...(next ? [next] : [])]);
  return { ok: true, task, next };
}

function advanceDay(key, recurrence, steps) {
  const date = parseLocal(key);
  if (recurrence === 'daily') date.setDate(date.getDate() + steps);
  else if (recurrence === 'weekly') date.setDate(date.getDate() + steps * 7);
  else {
    const months = recurrence === 'monthly' ? steps : steps * 12;
    const lastDay = new Date(date.getFullYear(), date.getMonth() + months + 1, 0).getDate();
    return localDate(new Date(date.getFullYear(), date.getMonth() + months, Math.min(date.getDate(), lastDay)));
  }
  return localDate(date);
}

function nextOccurrence(task) {
  const today = todayStr();
  const start = task.dueDate || today;
  let due = start;
  for (let step = 1; due <= today; step++) due = advanceDay(start, task.recurrence, step);
  const now = new Date().toISOString();
  return { ...task, id: newId(), status: 'todo', dueDate: due, sortOrder: '', completedAt: '', createdAt: now, updatedAt: now, checklist: task.checklist.replace(/^\[x\]/gim, '[ ]') };
}

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
    renderBanners();
  }
}

/* ==========================================================================
   Data operations (optimistic, rolled back per task on failure)
   ========================================================================== */
function normalize(task) {
  return {
    id: String(task.id),
    title: task.title || '(untitled)',
    description: task.description || '',
    status: STATUS_LABEL[task.status] ? task.status : 'todo',
    priority: PRIORITIES[task.priority] ? task.priority : 'medium',
    project: task.project || '',
    tags: task.tags || '',
    links: task.links || '',
    sortOrder: task.sortOrder === undefined || task.sortOrder === null ? '' : String(task.sortOrder),
    completedAt: task.completedAt || '',
    recurrence: task.recurrence || '',
    checklist: task.checklist || '',
    dueDate: /^\d{4}-\d{2}-\d{2}$/.test(task.dueDate || '') ? task.dueDate : '',
    createdAt: task.createdAt || '',
    updatedAt: task.updatedAt || '',
  };
}

function putLocal(task) {
  const exists = state.tasks.some((t) => t.id === task.id);
  state.tasks = exists ? state.tasks.map((t) => (t.id === task.id ? task : t)) : [...state.tasks, task];
}
function dropLocal(id) {
  state.tasks = state.tasks.filter((t) => t.id !== id);
}

async function loadTasks() {
  const btn = $('#refreshBtn');
  btn.classList.add('spinning');
  try {
    await flushQueue();
    if (!state.queue.length) {
      const tasks = await withSync(() => api.list());
      state.tasks = tasks.map(normalize);
      state.loaded = true;
      saveCache();
    }
  } catch (err) {
    // The banner reports this while saved tasks stay on screen.
    if (!state.loaded) toast(`Could not load tasks: ${err.message}`, { error: true });
  } finally {
    btn.classList.remove('spinning');
    render();
  }
}

/* Every write takes this path: one ordered, batched request per user action.
   If the server can't be reached, the change stays on screen and waits in a
   saved queue. A job is { op, prev }, where prev restores the task on failure. */
let writeChain = Promise.resolve();

function inOrder(fn) {
  const run = writeChain.then(fn, fn);
  writeChain = run.catch(() => {});
  return run;
}

function saveCache() {
  if (isRemote()) storageSet(CACHE_KEY, state.tasks);
}

function saveQueue() {
  storageSet(QUEUE_KEY, state.queue);
  renderSync();
}

function opId(op) {
  return op.task ? op.task.id : op.id;
}

// The server compares this with its copy, to catch edits made elsewhere.
function stampBase(op) {
  if (op.action !== 'update' || op.force) return;
  const current = state.tasks.find((t) => t.id === op.task.id);
  op.task.baseUpdatedAt = op.task.baseUpdatedAt || (current && current.updatedAt) || '';
}

// Merges with queued writes for the same task, so a later edit isn't mistaken
// for a conflict with an earlier one that hasn't been sent yet.
function enqueue(op) {
  const index = state.queue.findIndex((q) => q.action !== 'delete' && opId(q) === opId(op));
  const queued = state.queue[index];
  if (!queued || op.action === 'create') state.queue.push(op);
  else if (op.action === 'delete' && queued.action === 'create') state.queue.splice(index, 1);
  else if (op.action === 'delete') state.queue[index] = op;
  else if (queued.action === 'create') queued.task = op.task;
  else queued.task = { ...op.task, baseUpdatedAt: queued.task.baseUpdatedAt };
}

function applyResults(jobs, results) {
  let allOk = true;
  results.forEach((result, i) => {
    const { op, prev } = jobs[i];
    const id = opId(op);
    if (result.ok) {
      if (result.task && state.tasks.some((t) => t.id === id)) putLocal(normalize(result.task));
      if (result.next) putLocal(normalize(result.next));
      return;
    }
    allOk = false;
    if (result.conflict) {
      const theirs = normalize(result.conflict);
      putLocal(theirs);
      toast(`“${theirs.title}” was changed somewhere else, so your edit wasn't saved.`, {
        error: true,
        action: { label: 'Keep mine', run: () => forceSave(op.task) },
      });
      return;
    }
    if (prev) putLocal(prev);
    else if (op.action === 'create') dropLocal(id);
    toast(`Not saved: ${result.error}`, { error: true });
  });
  return allOk;
}

function forceSave(task) {
  const mine = normalize(task);
  putLocal(mine);
  render();
  return send([{ op: { action: 'update', force: true, task: mine } }]);
}

function send(jobs) {
  return inOrder(async () => {
    try {
      if (!isRemote()) return applyResults(jobs, jobs.map((j) => applyLocally(j.op)));
      jobs.forEach((j) => stampBase(j.op));
      if (state.queue.length) {
        jobs.forEach((j) => enqueue(j.op)); // Stay behind what is already waiting.
        return true;
      }
      const ops = jobs.map((j) => j.op);
      const { results } = await withSync(() => remoteCall('batch', { ops }));
      return applyResults(jobs, results);
    } catch (err) {
      if (err instanceof NetworkError) {
        jobs.forEach((j) => enqueue(j.op));
        state.syncError = '';
        return true;
      }
      jobs.forEach(({ op, prev }) => {
        if (prev) putLocal(prev);
        else if (op.action === 'create') dropLocal(opId(op));
      });
      toast(`Not saved: ${err.message}`, { error: true });
      return false;
    } finally {
      saveQueue();
      saveCache();
      render();
    }
  });
}

/** Sends queued writes. Leaves them queued if the server is still unreachable. */
function flushQueue() {
  return inOrder(async () => {
    if (!state.queue.length || !isRemote()) return;
    const ops = [...state.queue];
    const { results } = await withSync(() => remoteCall('batch', { ops }));
    state.queue = state.queue.slice(ops.length);
    saveQueue();
    applyResults(ops.map((op) => ({ op })), results);
    saveCache();
    toast(`Synced ${plural(ops.length, 'waiting change')}`);
  });
}

function saveTask(task, isNew) {
  const prev = isNew ? null : state.tasks.find((t) => t.id === task.id);
  putLocal(task);
  render();
  return send([{ op: { action: isNew ? 'create' : 'update', task: { ...task } }, prev }]);
}

async function bulkUpdate(ids, patch) {
  const jobs = state.tasks.filter((t) => ids.has(t.id)).map((prev) => ({ prev, op: { action: 'update', task: { ...prev, ...patch } } }));
  jobs.forEach((j) => putLocal(j.op.task));
  render();
  if (await send(jobs)) toast(`Updated ${plural(jobs.length, 'task')}`);
}

async function deleteTasks(ids) {
  const removed = state.tasks.filter((t) => ids.has(t.id));
  if (!removed.length) return;
  removed.forEach((t) => {
    dropLocal(t.id);
    state.selection.delete(t.id);
  });
  render();
  const ok = await send(removed.map((t) => ({ prev: t, op: { action: 'delete', id: t.id } })));
  if (!ok) return;
  const msg = removed.length === 1 ? `Deleted “${removed[0].title}”` : `Deleted ${removed.length} tasks`;
  toast(msg, { action: { label: 'Undo', run: () => restoreTasks(removed) } });
}

async function restoreTasks(tasks) {
  tasks.forEach(putLocal);
  render();
  await send(tasks.map((task) => ({ op: { action: 'create', task: { ...task } } })));
  toast(tasks.length === 1 ? 'Task restored' : `${tasks.length} tasks restored`);
}

function setStatus(id, status) {
  const task = state.tasks.find((t) => t.id === id);
  if (task && task.status !== status) saveTask({ ...task, status }, false);
}

function newTask(fields) {
  return normalize({ id: newId(), title: '', status: 'todo', priority: 'medium', createdAt: new Date().toISOString(), ...fields });
}

/* ==========================================================================
   Helpers
   ========================================================================== */
const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const icon = (name) => `<svg class="i" aria-hidden="true"><use href="#i-${name}"/></svg>`;
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

const pad = (n) => String(n).padStart(2, '0');
const localDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const todayStr = () => localDate(new Date());
function addDays(n, from = new Date()) {
  const d = new Date(from);
  d.setDate(d.getDate() + n);
  return localDate(d);
}
function parseLocal(s) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d);
}

function isOpen(t) {
  return t.status !== 'done';
}
function isOverdue(t) {
  return isOpen(t) && Boolean(t.dueDate) && t.dueDate < todayStr();
}

function fmtDate(s, opts = {}) {
  const d = parseLocal(s);
  return d.toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    year: d.getFullYear() !== new Date().getFullYear() ? 'numeric' : undefined,
    ...opts,
  });
}

function dueInfo(t) {
  if (!t.dueDate) return null;
  const today = todayStr();
  if (t.dueDate === today) return { text: 'Today', tone: isOpen(t) ? 'today' : '' };
  if (t.dueDate === addDays(1)) return { text: 'Tomorrow', tone: '' };
  if (t.dueDate === addDays(-1)) return { text: 'Yesterday', tone: isOpen(t) ? 'overdue' : '' };
  return { text: fmtDate(t.dueDate), tone: isOverdue(t) ? 'overdue' : '' };
}

function dueHtml(t) {
  const due = dueInfo(t);
  if (!due) return '';
  const label = due.tone === 'overdue' ? `Overdue · ${due.text}` : due.text;
  return `<span class="due ${due.tone}">${icon(due.tone === 'overdue' ? 'alert' : 'calendar')}${esc(label)}</span>`;
}

function relTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const mins = Math.round((Date.now() - d.getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days}d ago`;
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function fullTime(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

// Tasks finished before completedAt existed fall back to their last update.
function completedOn(t) {
  if (t.status !== 'done' || !(t.completedAt || t.updatedAt)) return '';
  const d = new Date(t.completedAt || t.updatedAt);
  return Number.isNaN(d.getTime()) ? '' : localDate(d);
}

function newId() {
  return crypto.randomUUID ? crypto.randomUUID() : `t-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

const priorityHtml = (p) => `<span class="prio ${p}">${icon('flag')}${PRIORITIES[p]}</span>`;
const statusHtml = (s) => `<span class="status-pill"><span class="dot ${s}"></span>${STATUS_LABEL[s]}</span>`;
const projectHtml = (p) => (p ? `<span class="tag" title="${esc(p)}">${icon('folder')}${esc(p)}</span>` : '');

const tagList = (t) => t.tags.split(',').map((x) => x.trim()).filter(Boolean);
const linkList = (t) => t.links.split('\n').map((x) => x.trim()).filter((x) => /^https?:\/\//i.test(x));
const parseChecklist = (text) =>
  text.split('\n').map((line) => /^\[( |x)\]\s*(.*)$/i.exec(line.trim())).filter(Boolean).map((m) => ({ done: m[1].toLowerCase() === 'x', text: m[2] }));
const formatChecklist = (items) => items.map((i) => `[${i.done ? 'x' : ' '}] ${i.text}`).join('\n');
const tagsHtml = (t) => tagList(t).map((x) => `<span class="tag label">${esc(x)}</span>`).join('');

function allTags() {
  return [...new Set(state.tasks.flatMap(tagList))].sort((a, b) => a.localeCompare(b));
}

function projects() {
  return [...new Set(state.tasks.map((t) => t.project).filter(Boolean))].sort((a, b) => a.localeCompare(b));
}

/* ==========================================================================
   Routing (#/dashboard, #/today, #/project/<name>, ...)
   ========================================================================== */
function parseRoute() {
  const path = decodeURIComponent(location.hash.replace(/^#\/?/, ''));
  if (path.startsWith('project/')) return { scope: 'project', project: path.slice(8) };
  if (SCOPES.some((s) => s.id === path)) return { scope: path, project: null };
  return { scope: 'all', project: null };
}
function routeHash(route) {
  return route.scope === 'project' ? `#/project/${encodeURIComponent(route.project)}` : `#/${route.scope}`;
}
function go(route) {
  location.hash = routeHash(route);
}
window.addEventListener('hashchange', () => {
  if (handleConnectLink()) return;
  state.route = parseRoute();
  state.selection.clear();
  state.quickAdd = null;
  $('#app').classList.remove('nav-open');
  render();
  window.scrollTo(0, 0);
});

function scopeTasks(route = state.route) {
  if (route.scope === 'project') return state.tasks.filter((t) => t.project === route.project);
  const scope = SCOPES.find((s) => s.id === route.scope);
  return scope && scope.test ? state.tasks.filter(scope.test) : state.tasks;
}

function visibleTasks() {
  const q = state.filters.search.trim().toLowerCase();
  const hideDone = state.prefs.hideDone && state.route.scope !== 'completed';
  return scopeTasks()
    .filter((t) => !hideDone || t.status !== 'done')
    .filter((t) => !state.filters.priority || t.priority === state.filters.priority)
    .filter((t) => !state.filters.tag || tagList(t).includes(state.filters.tag))
    .filter((t) => !q || `${t.title} ${t.description} ${t.project} ${t.tags}`.toLowerCase().includes(q));
}

function routeDefaults() {
  if (state.route.scope === 'project') return { project: state.route.project };
  if (state.route.scope === 'today') return { dueDate: todayStr() };
  return {};
}

/* ==========================================================================
   Sorting
   ========================================================================== */
const SORTERS = {
  title: (a, b) => a.title.localeCompare(b.title),
  status: (a, b) => STATUS_RANK[a.status] - STATUS_RANK[b.status],
  priority: (a, b) => PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority],
  project: (a, b) => (a.project || '￿').localeCompare(b.project || '￿'),
  dueDate: (a, b) => (a.dueDate || '9999').localeCompare(b.dueDate || '9999'),
  updatedAt: (a, b) => b.updatedAt.localeCompare(a.updatedAt),
};

function defaultCompare(a, b) {
  return SORTERS.priority(a, b) || SORTERS.dueDate(a, b) || a.createdAt.localeCompare(b.createdAt);
}

// Board order: hand-placed cards first, in the order they were dropped.
function boardCompare(a, b) {
  if (a.sortOrder && b.sortOrder) return Number(a.sortOrder) - Number(b.sortOrder);
  if (a.sortOrder) return -1;
  if (b.sortOrder) return 1;
  return defaultCompare(a, b);
}

function sortTasks(tasks) {
  const { key, dir } = state.prefs.sort;
  const sorter = SORTERS[key] || SORTERS.priority;
  const sign = dir === 'desc' ? -1 : 1;
  return [...tasks].sort((a, b) => sign * sorter(a, b) || defaultCompare(a, b));
}

/* ==========================================================================
   Rendering
   ========================================================================== */
function render() {
  applyTheme();
  renderSidebar();
  renderHeader();
  renderBanners();
  renderSync();
  renderDatalist();
  renderFilters();

  const isDash = state.route.scope === 'dashboard';
  $('#toolbar').hidden = isDash;
  $('#hideDoneWrap').hidden = state.route.scope === 'completed';
  $('#hideDone').checked = state.prefs.hideDone;
  $$('#viewSwitch button').forEach((b) => {
    const active = b.dataset.view === state.prefs.view;
    b.classList.toggle('active', active);
    b.setAttribute('aria-selected', active);
  });

  const main = $('#main');
  if (isDash) {
    $('#bulkbar').hidden = true;
    main.innerHTML = dashboardHtml();
    return;
  }

  const tasks = visibleTasks();
  const visibleIds = new Set(tasks.map((t) => t.id));
  for (const id of state.selection) if (!visibleIds.has(id)) state.selection.delete(id);
  $('#resultCount').textContent = plural(tasks.length, 'task');

  if (isRemote() && !state.loaded) main.innerHTML = skeletonHtml();
  else if (state.prefs.view === 'table') main.innerHTML = tableHtml(tasks);
  else if (state.prefs.view === 'calendar') main.innerHTML = calendarHtml(tasks);
  else main.innerHTML = boardHtml(tasks);

  renderBulkbar();
  restoreQuickAdd();
}

function renderSidebar() {
  const r = state.route;
  $('#navMain').innerHTML = SCOPES.map((s) => {
    let count = '';
    if (s.test) {
      const n = state.tasks.filter(s.badge || s.test).length;
      if (n) count = `<span class="count ${s.alert ? 'alert' : ''}">${n}</span>`;
    }
    const active = r.scope === s.id ? 'active' : '';
    return `<a class="sb-link ${active}" href="${routeHash({ scope: s.id })}" ${active ? 'aria-current="page"' : ''}>
      ${icon(s.icon)}<span class="label">${s.label}</span>${count}</a>`;
  }).join('');

  const list = projects();
  $('#navProjects').innerHTML = list.length
    ? list
        .map((p) => {
          const open = state.tasks.filter((t) => t.project === p && isOpen(t)).length;
          const active = r.scope === 'project' && r.project === p ? 'active' : '';
          return `<a class="sb-link ${active}" href="${esc(routeHash({ scope: 'project', project: p }))}" title="${esc(p)}">
            ${icon('folder')}<span class="label">${esc(p)}</span>${open ? `<span class="count">${open}</span>` : ''}</a>`;
        })
        .join('')
    : `<div class="sb-empty">Add a project to a task to see it here.</div>`;
}

function renderHeader() {
  const r = state.route;
  let crumbs = 'Tasks';
  let title = 'All tasks';
  if (r.scope === 'dashboard') {
    crumbs = 'Workspace';
    title = 'Dashboard';
  } else if (r.scope === 'project') {
    crumbs = 'Projects';
    title = r.project;
  } else {
    title = SCOPES.find((s) => s.id === r.scope).label;
  }
  $('#crumbs').textContent = crumbs;
  $('#pageTitle').textContent = title;
  document.title = `${title} · TaskBoard`;
}

function renderBanners() {
  $('#setupBanner').hidden = isRemote();
  $('#errorBanner').hidden = !state.syncError;
  $('#errorText').textContent = state.syncError ? `Sync error: ${state.syncError}` : '';
}

function renderSync() {
  const el = $('#sync');
  el.className = 'sync';
  el.title = '';
  if (state.pending) {
    el.classList.add('saving');
    el.textContent = 'Syncing…';
  } else if (state.queue.length) {
    el.classList.add('saving');
    el.textContent = `${plural(state.queue.length, 'change')} waiting to sync`;
  } else if (state.syncError) {
    el.classList.add('error');
    el.textContent = 'Sync error';
    el.title = state.syncError;
  } else {
    el.classList.add('ok');
    el.textContent = isRemote() ? 'Synced with Google Sheets' : 'Local mode';
  }
}

function renderDatalist() {
  $('#projectList').innerHTML = projects()
    .map((p) => `<option value="${esc(p)}">`)
    .join('');
}

function hasActiveFilter() {
  return Boolean(state.filters.search || state.filters.priority || state.filters.tag);
}

function renderFilters() {
  const tags = allTags();
  if (state.filters.tag && !tags.includes(state.filters.tag)) state.filters.tag = '';
  $('#tagFilter').hidden = !tags.length;
  $('#tagFilter').innerHTML = `<option value="">Any tag</option>` +
    tags.map((t) => `<option value="${esc(t)}" ${t === state.filters.tag ? 'selected' : ''}>${esc(t)}</option>`).join('');
  $('#saveFilterBtn').hidden = !hasActiveFilter();
  $('#savedHead').hidden = !state.prefs.savedFilters.length;
  $('#navSaved').innerHTML = state.prefs.savedFilters
    .map((f) => `<div class="sb-saved">
      <button class="sb-link" type="button" data-saved="${esc(f.id)}">${icon('bookmark')}<span class="label">${esc(f.name)}</span></button>
      <button class="remove" type="button" data-saved-remove="${esc(f.id)}" aria-label="Remove ${esc(f.name)}">${icon('x')}</button></div>`)
    .join('');
}

function renderBulkbar() {
  const n = state.selection.size;
  $('#bulkbar').hidden = !n || state.prefs.view !== 'table';
  $('#bulkCount').textContent = `${n} selected`;
}

function skeletonHtml() {
  const card = `<div class="skeleton" style="height:76px"></div>`;
  return `<div class="board">${STATUSES.map(
    (s) => `<section class="column"><div class="column-head"><span class="dot ${s.id}"></span><h2>${s.label}</h2></div>
      <div class="column-body">${card.repeat(s.id === 'done' ? 1 : 3)}</div></section>`,
  ).join('')}</div>`;
}

function emptyStateHtml() {
  const filtered = state.filters.search || state.filters.priority;
  if (filtered) {
    return `<div class="empty-state"><div class="empty-icon">${icon('search')}</div>
      <h3>No matching tasks</h3><p>Try a different search or clear the priority filter.</p>
      <button class="btn" data-action="clear-filters">Clear filters</button></div>`;
  }
  return `<div class="empty-state"><div class="empty-icon">${icon('check')}</div>
    <h3>${state.route.scope === 'overdue' ? 'Nothing overdue' : 'No tasks here yet'}</h3>
    <p>${state.route.scope === 'overdue' ? 'You are on top of your deadlines.' : 'Create a task to start tracking your work.'}</p>
    <button class="btn primary" data-action="new">${icon('plus')}New task</button></div>`;
}

/* ---------- Board ---------- */
function boardHtml(tasks) {
  return `<div class="board">${STATUSES.map((s) => {
    const items = tasks.filter((t) => t.status === s.id).sort(boardCompare);
    const composing = state.quickAdd && state.quickAdd.status === s.id;
    const composer = composing
      ? `<input class="input quick-input" data-quick="${s.id}" placeholder="Task title, then Enter" maxlength="500" aria-label="New task title">`
      : `<button class="quick-add" data-quick-open="${s.id}">${icon('plus')}Add task</button>`;
    return `
      <section class="column" aria-label="${s.label}">
        <div class="column-head">
          <span class="dot ${s.id}"></span>
          <h2>${s.label}</h2>
          <span class="count">${items.length}</span>
          <button class="icon-btn ghost" data-quick-open="${s.id}" title="Add to ${s.label}" aria-label="Add task to ${s.label}">${icon('plus')}</button>
        </div>
        <div class="column-body" data-status="${s.id}">
          ${items.length ? items.map(cardHtml).join('') : `<div class="column-empty">Drop tasks here</div>`}
          ${composer}
        </div>
      </section>`;
  }).join('')}</div>`;
}

function cardHtml(t) {
  const done = t.status === 'done';
  const top = projectHtml(t.project) + tagsHtml(t);
  const links = linkList(t).length;
  const steps = parseChecklist(t.checklist);
  return `
    <article class="card ${done ? 'is-done' : ''}" draggable="true" tabindex="0" data-id="${esc(t.id)}">
      ${top ? `<div class="card-top">${top}</div>` : ''}
      <div class="card-row">
        <input type="checkbox" class="checkbox toggle" ${done ? 'checked' : ''} aria-label="Mark “${esc(t.title)}” done">
        <h3 class="card-title">${esc(t.title)}</h3>
      </div>
      ${t.description ? `<p class="card-desc">${esc(t.description)}</p>` : ''}
      <div class="card-foot">
        ${priorityHtml(t.priority)}
        ${dueHtml(t)}
        ${links ? `<span class="attach" title="${plural(links, 'link')}">${icon('link')}${links}</span>` : ''}
        ${steps.length ? `<span class="attach" title="Checklist">${icon('checklist')}${steps.filter((x) => x.done).length}/${steps.length}</span>` : ''}
        ${t.recurrence ? `<span class="attach" title="Repeats ${esc(t.recurrence)}">${icon('repeat')}</span>` : ''}
        <span class="updated" title="Updated ${esc(fullTime(t.updatedAt))}">${esc(relTime(t.updatedAt))}</span>
      </div>
    </article>`;
}

function restoreQuickAdd() {
  const input = state.quickAdd && $(`[data-quick="${state.quickAdd.status}"]`);
  if (!input) return;
  input.value = state.quickAdd.text;
  input.focus();
}

/* ---------- Table ---------- */
const COLUMNS = [
  { key: 'title', label: 'Task' },
  { key: 'status', label: 'Status' },
  { key: 'priority', label: 'Priority' },
  { key: 'project', label: 'Project' },
  { key: 'dueDate', label: 'Due' },
  { key: 'updatedAt', label: 'Updated' },
];

function tableHtml(tasks) {
  if (!tasks.length) return emptyStateHtml();
  const rows = sortTasks(tasks);
  const allSelected = rows.every((t) => state.selection.has(t.id));
  const someSelected = !allSelected && rows.some((t) => state.selection.has(t.id));
  const { key, dir } = state.prefs.sort;
  const head = COLUMNS.map((c) => {
    const active = c.key === key;
    const aria = active ? `aria-sort="${dir === 'asc' ? 'ascending' : 'descending'}"` : '';
    const ic = active ? (dir === 'asc' ? 'arrow-up' : 'arrow-down') : 'sort';
    return `<th ${aria}><button class="sort-btn ${active ? 'active' : ''}" data-sort="${c.key}">${c.label}${icon(ic)}</button></th>`;
  }).join('');
  const body = rows
    .map((t) => {
      const sel = state.selection.has(t.id);
      return `
        <tr class="${sel ? 'selected' : ''} ${t.status === 'done' ? 'is-done' : ''}" data-id="${esc(t.id)}" tabindex="0">
          <td class="sel"><input type="checkbox" class="checkbox row-select" ${sel ? 'checked' : ''} aria-label="Select “${esc(t.title)}”"></td>
          <td class="title-cell"><strong>${esc(t.title)}</strong>${t.tags ? `<small>${esc(tagList(t).join(' · '))}</small>` : t.description ? `<small>${esc(t.description)}</small>` : ''}</td>
          <td>${statusHtml(t.status)}</td>
          <td>${priorityHtml(t.priority)}</td>
          <td>${projectHtml(t.project) || '<span class="muted-cell">—</span>'}</td>
          <td>${dueHtml(t) || '<span class="muted-cell">—</span>'}</td>
          <td class="num" title="${esc(fullTime(t.updatedAt))}">${esc(relTime(t.updatedAt))}</td>
        </tr>`;
    })
    .join('');
  return `
    <div class="table-card">
      <table class="data-table">
        <thead><tr>
          <th class="sel"><input type="checkbox" class="checkbox" id="selectAll" ${allSelected ? 'checked' : ''} data-indeterminate="${someSelected}" aria-label="Select all"></th>
          ${head}
        </tr></thead>
        <tbody>${body}</tbody>
      </table>
    </div>`;
}

/* ---------- Calendar ---------- */
function calendarHtml(tasks) {
  const now = new Date();
  const month = state.calendar.month || new Date(now.getFullYear(), now.getMonth(), 1);
  const start = new Date(month.getFullYear(), month.getMonth(), 1 - month.getDay());
  const today = todayStr();
  const byDay = new Map();
  [...tasks].filter((t) => t.dueDate).sort(defaultCompare).forEach((t) => {
    if (!byDay.has(t.dueDate)) byDay.set(t.dueDate, []);
    byDay.get(t.dueDate).push(t);
  });
  const undated = tasks.filter((t) => !t.dueDate && isOpen(t)).length;
  const cells = Array.from({ length: 42 }, (_, i) => {
    const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
    const key = localDate(d);
    const items = byDay.get(key) || [];
    const limit = state.calendar.expanded === key ? items.length : 3;
    const chips = items.slice(0, limit).map((t) => `<button class="cal-task ${t.status === 'done' ? 'is-done' : ''} ${isOverdue(t) ? 'overdue' : ''}" data-id="${esc(t.id)}" title="${esc(t.title)}"><span class="dot ${t.status}"></span><span>${esc(t.title)}</span></button>`).join('');
    const more = items.length > limit ? `<button class="cal-more" data-cal-more="${key}">+${items.length - limit} more</button>` : '';
    return `<div class="cal-day ${d.getMonth() === month.getMonth() ? '' : 'other'} ${key === today ? 'today' : ''}" data-new-date="${key}"><span class="cal-num">${d.getDate()}</span>${chips}${more}</div>`;
  }).join('');
  const days = Array.from({ length: 7 }, (_, i) => new Date(2023, 0, 1 + i).toLocaleDateString(undefined, { weekday: 'short' }));
  return `
    <div class="cal-head">
      <button class="icon-btn" data-cal-nav="-1" aria-label="Previous month">${icon('left')}</button>
      <button class="icon-btn" data-cal-nav="1" aria-label="Next month">${icon('right')}</button>
      <button class="btn small" data-cal-nav="0">Today</button>
      <h2>${esc(month.toLocaleDateString(undefined, { month: 'long', year: 'numeric' }))}</h2>
      ${undated ? `<span class="note">${plural(undated, 'open task')} without a due date</span>` : ''}
    </div>
    <div class="cal">${days.map((d) => `<div class="cal-dow">${esc(d)}</div>`).join('')}${cells}</div>`;
}

/* ---------- Dashboard ---------- */
function dashboardHtml() {
  if (isRemote() && !state.loaded) {
    const tile = `<div class="kpi"><div class="skeleton" style="height:70px"></div></div>`;
    return `<div class="dash">${tile.repeat(4)}<div class="panel wide"><div class="panel-body"><div class="skeleton" style="height:220px"></div></div></div>
      <div class="panel narrow"><div class="panel-body"><div class="skeleton" style="height:220px"></div></div></div></div>`;
  }

  const today = todayStr();
  const open = state.tasks.filter(isOpen);
  const overdue = open.filter(isOverdue);
  const dueToday = open.filter((t) => t.dueDate === today);
  const weekStart = addDays(-6);
  const doneWeek = state.tasks.filter((t) => completedOn(t) >= weekStart);
  const dateLabel = new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });

  const kpi = (scope, iconName, label, value, sub) =>
    `<button class="kpi" data-go="${scope}"><span class="kpi-label">${icon(iconName)}${label}</span>
      <span class="kpi-value">${value}</span>${sub}</button>`;

  return `
    <div class="dash">
      <div class="dash-intro"><h2>Overview</h2><span>${esc(dateLabel)}</span></div>
      ${kpi('all', 'inbox', 'Open tasks', open.length, `<span class="kpi-sub">${open.filter((t) => t.dueDate).length} with a due date</span>`)}
      ${kpi('today', 'today', 'Due today', dueToday.length, `<span class="kpi-sub">${open.filter((t) => t.dueDate > today && t.dueDate <= addDays(7)).length} more in the next 7 days</span>`)}
      ${kpi('overdue', 'alert', 'Overdue', overdue.length, overdue.length
        ? `<span class="kpi-sub critical">${icon('alert')}Needs attention</span>`
        : `<span class="kpi-sub good">${icon('done')}All on track</span>`)}
      ${kpi('completed', 'done', 'Completed · 7 days', doneWeek.length, `<span class="kpi-sub">${plural(state.tasks.length - open.length, 'task')} done overall</span>`)}

      <section class="panel wide">
        <div class="panel-head"><h3>Completed per day</h3><span class="sub">Last 14 days</span></div>
        <div class="panel-body">${completionChartHtml()}</div>
      </section>
      <section class="panel narrow">
        <div class="panel-head"><h3>Open by priority</h3></div>
        <div class="panel-body">${priorityChartHtml(open)}</div>
      </section>

      <section class="panel wide">
        <div class="panel-head">
          <h3>Workload by project</h3>
          <span class="spacer"></span>
          <div class="legend">${STATUSES.map((s) => `<span><i class="sw" style="--dot: var(${statusVar(s.id)})"></i>${s.label}</span>`).join('')}</div>
        </div>
        <div class="panel-body">${projectChartHtml()}</div>
      </section>
      <section class="panel narrow">
        <div class="panel-head"><h3>Upcoming deadlines</h3><span class="spacer"></span>
          <a class="btn small ghost" href="#/upcoming">View all${icon('arrow-right')}</a></div>
        <div class="panel-body">${deadlineListHtml(open)}</div>
      </section>

      <section class="panel" style="grid-column: 1 / -1">
        <div class="panel-head"><h3>Recent activity</h3></div>
        <div class="panel-body">${recentListHtml()}</div>
      </section>
    </div>`;
}

const statusVar = (s) => ({ todo: '--s-todo', done: '--s-done' })[s];

function completionChartHtml() {
  const days = Array.from({ length: 14 }, (_, i) => addDays(i - 13));
  const counts = Object.fromEntries(days.map((d) => [d, 0]));
  state.tasks.forEach((t) => {
    const d = completedOn(t);
    if (d in counts) counts[d]++;
  });
  const values = days.map((d) => counts[d]);
  const total = values.reduce((a, b) => a + b, 0);
  const top = Math.max(4, Math.ceil(Math.max(...values) / 2) * 2);
  const ticks = [top, top / 2, 0];
  const cols = days
    .map((d, i) => {
      const v = values[i];
      const label = fmtDate(d, { weekday: 'short' });
      const h = (v / top) * 100;
      return `<div class="vcol" tabindex="0" data-tip="${esc(label)}: ${plural(v, 'task')} completed" aria-label="${esc(label)}: ${v} completed">
        ${v ? `<span class="vval" style="bottom: calc(${h}% + 4px)">${v}</span>` : ''}
        <div class="vbar" style="height:${h}%"></div></div>`;
    })
    .join('');
  const xLabels = days
    .map((d, i) => `<span>${i % 2 === 1 || i === 13 ? esc(i === 13 ? 'Today' : fmtDate(d)) : ''}</span>`)
    .join('');
  return `
    <div class="vchart" role="img" aria-label="${plural(total, 'task')} completed in the last 14 days">
      <div class="vchart-y">${ticks.map((t) => `<span>${t}</span>`).join('')}</div>
      <div class="vchart-plot">
        <div class="gridline" style="top:0"></div><div class="gridline" style="top:50%"></div>
        ${cols}
      </div>
      <div class="vchart-x">${xLabels}</div>
    </div>`;
}

function priorityChartHtml(open) {
  if (!open.length) return `<div class="panel-empty">No open tasks</div>`;
  const counts = Object.keys(PRIORITIES).map((p) => [p, open.filter((t) => t.priority === p).length]);
  const max = Math.max(...counts.map(([, n]) => n), 1);
  return `<div class="hbars">${counts
    .map(
      ([p, n]) => `
      <div class="hrow">
        <span class="hrow-label">${priorityHtml(p)}</span>
        <div class="hrow-track">${n ? `<div class="hseg seq" style="width:${(n / max) * 100}%" data-tip="${PRIORITIES[p]}: ${plural(n, 'open task')}"></div>` : ''}</div>
        <span class="hrow-total">${n}</span>
      </div>`,
    )
    .join('')}</div>`;
}

function projectChartHtml() {
  if (!state.tasks.length) return `<div class="panel-empty">No tasks yet</div>`;
  const groups = new Map();
  state.tasks.forEach((t) => {
    const key = t.project || '';
    if (!groups.has(key)) groups.set(key, { todo: 0, done: 0, total: 0 });
    const g = groups.get(key);
    g[t.status]++;
    g.total++;
  });
  let rows = [...groups.entries()].sort((a, b) => b[1].total - a[1].total);
  // Keep the chart readable: fold the long tail into "Other".
  if (rows.length > 8) {
    const other = { todo: 0, done: 0, total: 0, other: true };
    rows.slice(7).forEach(([, g]) => STATUSES.forEach((s) => (other[s.id] += g[s.id])));
    other.total = other.todo + other.done;
    rows = [...rows.slice(0, 7), ['Other projects', other]];
  }
  const max = Math.max(...rows.map(([, g]) => g.total));
  return `<div class="hbars">${rows
    .map(([name, g]) => {
      const label = name || 'No project';
      const segs = STATUSES.filter((s) => g[s.id])
        .map((s) => `<div class="hseg ${s.id}" style="width:${(g[s.id] / max) * 100}%" data-tip="${esc(label)} · ${s.label}: ${g[s.id]}"></div>`)
        .join('');
      const link = name && !g.other
        ? `<button data-go-project="${esc(name)}" title="${esc(name)}">${esc(name)}</button>`
        : `<span class="muted">${esc(label)}</span>`;
      return `<div class="hrow"><span class="hrow-label">${link}</span><div class="hrow-track">${segs}</div><span class="hrow-total">${g.total}</span></div>`;
    })
    .join('')}</div>`;
}

function deadlineListHtml(open) {
  const items = open
    .filter((t) => t.dueDate && t.dueDate <= addDays(14))
    .sort((a, b) => SORTERS.dueDate(a, b) || SORTERS.priority(a, b))
    .slice(0, 7);
  if (!items.length) return `<div class="panel-empty">No deadlines in the next two weeks</div>`;
  return `<ul class="task-list">${items
    .map((t) => `<li data-id="${esc(t.id)}" tabindex="0"><span class="dot ${t.status}"></span>
      <span class="tl-title">${esc(t.title)}</span>${dueHtml(t)}</li>`)
    .join('')}</ul>`;
}

function recentListHtml() {
  const items = [...state.tasks].sort(SORTERS.updatedAt).slice(0, 6);
  if (!items.length) return `<div class="panel-empty">No activity yet</div>`;
  return `<ul class="task-list">${items
    .map((t) => `<li data-id="${esc(t.id)}" tabindex="0">${statusHtml(t.status)}
      <span class="tl-title">${esc(t.title)}</span>${projectHtml(t.project)}
      <span class="tl-meta" title="${esc(fullTime(t.updatedAt))}">${esc(relTime(t.updatedAt))}</span></li>`)
    .join('')}</ul>`;
}

/* ==========================================================================
   Task drawer
   ========================================================================== */
const drawer = $('#drawer');
const taskForm = $('#taskForm');
let editingId = null;
let draftChecklist = [];

function renderChecklist() {
  const done = draftChecklist.filter((i) => i.done).length;
  $('#checkProgress').textContent = draftChecklist.length ? `${done} of ${draftChecklist.length}` : '';
  $('#checkItems').innerHTML = draftChecklist
    .map((item, i) => `<li class="${item.done ? 'done' : ''}">
      <label><input type="checkbox" class="checkbox" data-check="${i}" ${item.done ? 'checked' : ''}><span>${esc(item.text)}</span></label>
      <button type="button" class="icon-btn ghost" data-check-remove="${i}" aria-label="Remove step">${icon('x')}</button></li>`)
    .join('');
}

function addChecklistItem() {
  const input = $('#checkAdd');
  const text = input.value.trim();
  if (!text) return;
  draftChecklist.push({ done: false, text });
  input.value = '';
  renderChecklist();
  input.focus();
}

function openTaskDrawer(task = null, defaults = {}) {
  editingId = task ? task.id : null;
  const data = task || { title: '', description: '', status: 'todo', priority: 'medium', project: '', dueDate: '', ...routeDefaults(), ...defaults };
  $('#drawerLabel').textContent = task ? 'Task details' : 'New task';
  for (const name of ['title', 'description', 'status', 'priority', 'project', 'dueDate', 'tags', 'links', 'recurrence']) {
    taskForm.elements[name].value = data[name] || '';
  }
  $('#deleteTaskBtn').hidden = !task;
  $('#duplicateBtn').hidden = !task;
  $('#taskMeta').innerHTML = task
    ? `<dt>Created</dt><dd>${esc(fullTime(task.createdAt) || '—')}</dd>
       <dt>Last updated</dt><dd>${esc(fullTime(task.updatedAt) || '—')}</dd>
       <dt>Task ID</dt><dd><code>${esc(task.id)}</code></dd>`
    : '';
  $('#taskLinks').innerHTML = task
    ? linkList(task).map((url) => `<li><a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${icon('link')}${esc(url)}</a></li>`).join('')
    : '';
  draftChecklist = parseChecklist(data.checklist || '');
  renderChecklist();
  loadHistory(task);
  if (!drawer.open) drawer.showModal();
  taskForm.elements.title.focus();
}

$('#checkAddBtn').addEventListener('click', addChecklistItem);
$('#checkAdd').addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' || e.ctrlKey || e.metaKey) return;
  e.preventDefault(); // Enter here adds a step rather than saving the task.
  addChecklistItem();
});
$('#checkItems').addEventListener('click', (e) => {
  const remove = e.target.closest('[data-check-remove]');
  if (remove) {
    draftChecklist.splice(Number(remove.dataset.checkRemove), 1);
    renderChecklist();
  } else if (e.target.dataset.check !== undefined) {
    draftChecklist[Number(e.target.dataset.check)].done = e.target.checked;
    renderChecklist();
  }
});

async function loadHistory(task) {
  const section = $('#taskHistory');
  const list = $('#historyList');
  section.hidden = !task || !isRemote();
  if (section.hidden) return;
  list.innerHTML = '<li class="muted">Loading…</li>';
  try {
    const entries = await api.history(task.id);
    if (editingId !== task.id) return; // Another task was opened meanwhile.
    list.innerHTML = entries.length
      ? entries.map((e) => `<li>${esc(e.action)}${e.details ? `: ${esc(e.details)}` : ''}<time>${esc(fullTime(e.at))}</time></li>`).join('')
      : '<li class="muted">No changes recorded yet.</li>';
  } catch (err) {
    if (editingId === task.id) list.innerHTML = `<li class="muted">${esc(err.message)}</li>`;
  }
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
    recurrence: f.recurrence.value,
    checklist: formatChecklist(draftChecklist),
    tags: f.tags.value.split(',').map((x) => x.trim()).filter(Boolean).join(', '),
    links: f.links.value.split('\n').map((x) => x.trim()).filter((x) => /^https?:\/\//i.test(x)).join('\n'),
  };
  const existing = state.tasks.find((t) => t.id === editingId);
  if (existing) saveTask({ ...existing, ...fields }, false);
  else saveTask(newTask(fields), true).then((ok) => ok && toast('Task created'));
  drawer.close();
});

taskForm.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    taskForm.requestSubmit();
  }
});

$('#deleteTaskBtn').addEventListener('click', () => {
  const id = editingId;
  drawer.close();
  deleteTasks(new Set([id]));
});

$('#duplicateBtn').addEventListener('click', () => {
  const source = state.tasks.find((t) => t.id === editingId);
  if (!source) return;
  const copy = newTask({ ...source, id: newId(), title: `${source.title} (copy)`, status: 'todo', createdAt: new Date().toISOString() });
  drawer.close();
  saveTask(copy, true).then((ok) => ok && toast('Task duplicated', { action: { label: 'Open', run: () => openTaskDrawer(state.tasks.find((t) => t.id === copy.id)) } }));
});

// Close dialogs when clicking the backdrop.
$$('dialog').forEach((d) =>
  d.addEventListener('click', (e) => {
    if (e.target === d) d.close();
  }),
);
$$('[data-close]').forEach((b) => b.addEventListener('click', () => b.closest('dialog').close()));

/* ==========================================================================
   Settings
   ========================================================================== */
const settingsDialog = $('#settingsDialog');
const settingsForm = $('#settingsForm');

function openSettings() {
  settingsForm.elements.url.value = state.config.url;
  settingsForm.elements.token.value = state.config.token;
  setSettingsStatus('');
  $('#qrSection').hidden = !setupLink();
  settingsDialog.showModal();
}

function connectTo(config) {
  state.config = config;
  storageSet(CONFIG_KEY, config);
  storageSet(CACHE_KEY, []);
  state.queue = [];
  saveQueue();
  state.loaded = false;
  state.tasks = [];
  loadTasks();
}

function setSettingsStatus(text, kind = '') {
  const el = $('#settingsStatus');
  el.textContent = text;
  el.className = `settings-status ${kind}`;
}

function readSettingsForm() {
  return {
    url: settingsForm.elements.url.value.trim(),
    // Tolerate pasting the whole "API token: ..." line from the Apps Script log.
    token: settingsForm.elements.token.value.replace(/^\s*(info\s+)?api token:\s*/i, '').trim(),
  };
}

$('#testBtn').addEventListener('click', async () => {
  const config = readSettingsForm();
  if (!config.url || !config.token) return setSettingsStatus('Enter both the URL and the token.', 'error');
  setSettingsStatus('Testing…');
  try {
    const { tasks } = await remoteCall('list', {}, config);
    setSettingsStatus(`Connected. ${plural(tasks.length, 'task')} in the sheet.`, 'ok');
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
  settingsDialog.close();
  connectTo(config);
});


/* ---------- QR setup ----------
   Setup links carry the script id and token after the #, which browsers never
   send to a server. */
const SCRIPT_URL = /^https:\/\/script\.google\.com\/macros\/s\/([\w-]+)\/exec$/;
const CONNECT_LINK = /^#connect=([\w-]{20,120})\.([\w-]{16,128})$/;

function setupLink() {
  const match = SCRIPT_URL.exec(state.config.url);
  if (!match || !state.config.token) return '';
  return `${location.origin}${location.pathname}#connect=${match[1]}.${state.config.token}`;
}

function hideQr() {
  $('#qrBox').hidden = true;
  $('#qrCode').innerHTML = ''; // The code holds the token, so don't leave it around.
  $('#qrBtn').textContent = 'Show QR code for another device';
}

$('#qrBtn').addEventListener('click', () => {
  if (!$('#qrBox').hidden) return hideQr();
  const qr = qrcode(0, 'M');
  qr.addData(setupLink());
  qr.make();
  $('#qrCode').innerHTML = qr.createSvgTag(4, 16);
  $('#qrBox').hidden = false;
  $('#qrBtn').textContent = 'Hide QR code';
});

$('#copyLinkBtn').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(setupLink());
    toast('Setup link copied. Keep it private.');
  } catch {
    toast('Could not copy the link.', { error: true });
  }
});

settingsDialog.addEventListener('close', hideQr);

let pendingConnect = null;
const connectDialog = $('#connectDialog');

/** Takes a setup link out of the address bar and asks before using it. */
function handleConnectLink() {
  if (!location.hash.startsWith('#connect=')) return false;
  const match = CONNECT_LINK.exec(location.hash);
  // Replacing the entry keeps the token out of the browser's history.
  history.replaceState(null, '', location.pathname + location.search);
  state.route = parseRoute();
  if (!match) {
    toast('That setup link is not valid.', { error: true });
    return true;
  }
  pendingConnect = { url: `https://script.google.com/macros/s/${match[1]}/exec`, token: match[2] };
  $('#connectScript').textContent = pendingConnect.url;
  connectDialog.showModal();
  return true;
}

$('#connectForm').addEventListener('submit', (e) => {
  e.preventDefault();
  connectDialog.close();
  if (pendingConnect) connectTo(pendingConnect);
});
connectDialog.addEventListener('close', () => {
  pendingConnect = null;
});

$('#disconnectBtn').addEventListener('click', () => {
  state.config = { url: '', token: '' };
  storageSet(CONFIG_KEY, state.config);
  storageSet(CACHE_KEY, []);
  state.queue = [];
  saveQueue();
  state.syncError = '';
  settingsDialog.close();
  loadTasks();
});

/* ==========================================================================
   Command palette
   ========================================================================== */
const palette = $('#palette');
const paletteInput = $('#paletteInput');
let paletteItems = [];
let paletteIndex = 0;

function paletteCommands() {
  const nav = SCOPES.map((s) => ({ group: 'Navigate', icon: s.icon, label: `Go to ${s.label}`, run: () => go({ scope: s.id }) }));
  const proj = projects().map((p) => ({ group: 'Projects', icon: 'folder', label: p, run: () => go({ scope: 'project', project: p }) }));
  const actions = [
    { group: 'Actions', icon: 'plus', label: 'Create new task', hint: 'N', run: () => openTaskDrawer() },
    { group: 'Actions', icon: 'board', label: 'Switch to board view', run: () => setView('board') },
    { group: 'Actions', icon: 'table', label: 'Switch to table view', run: () => setView('table') },
    { group: 'Actions', icon: 'calendar', label: 'Switch to calendar view', run: () => setView('calendar') },
    { group: 'Actions', icon: 'sun', label: 'Light theme', run: () => setTheme('light') },
    { group: 'Actions', icon: 'moon', label: 'Dark theme', run: () => setTheme('dark') },
    { group: 'Actions', icon: 'monitor', label: 'System theme', run: () => setTheme('system') },
    { group: 'Actions', icon: 'refresh', label: 'Refresh from Google Sheets', run: loadTasks },
    { group: 'Actions', icon: 'settings', label: 'Connection settings', run: openSettings },
  ];
  return [...actions, ...nav, ...proj];
}

function buildPalette() {
  const q = paletteInput.value.trim().toLowerCase();
  const commands = paletteCommands().filter((c) => !q || c.label.toLowerCase().includes(q));
  const tasks = (q
    ? state.tasks.filter((t) => `${t.title} ${t.project} ${t.description}`.toLowerCase().includes(q))
    : [...state.tasks].sort(SORTERS.updatedAt)
  )
    .slice(0, q ? 8 : 5)
    .map((t) => ({
      group: q ? 'Tasks' : 'Recent tasks',
      icon: t.status === 'done' ? 'done' : 'status',
      label: t.title,
      hint: t.project || STATUS_LABEL[t.status],
      run: () => openTaskDrawer(state.tasks.find((x) => x.id === t.id)),
    }));
  paletteItems = q ? [...tasks, ...commands] : [...commands.slice(0, 1), ...tasks, ...commands.slice(1)];
  paletteIndex = Math.min(paletteIndex, Math.max(paletteItems.length - 1, 0));

  if (!paletteItems.length) {
    $('#paletteList').innerHTML = `<li class="palette-empty">No results for “${esc(paletteInput.value)}”</li>`;
    return;
  }
  let lastGroup = '';
  $('#paletteList').innerHTML = paletteItems
    .map((item, i) => {
      const header = item.group !== lastGroup ? `<li class="palette-group" role="presentation">${esc(item.group)}</li>` : '';
      lastGroup = item.group;
      return `${header}<li class="palette-item ${i === paletteIndex ? 'active' : ''}" role="option" data-index="${i}" aria-selected="${i === paletteIndex}">
        ${icon(item.icon)}<span class="pi-label">${esc(item.label)}</span>${item.hint ? `<span class="pi-hint">${esc(item.hint)}</span>` : ''}</li>`;
    })
    .join('');
  $('#paletteList .palette-item.active')?.scrollIntoView({ block: 'nearest' });
}

function openPalette() {
  if (palette.open) return;
  paletteInput.value = '';
  paletteIndex = 0;
  buildPalette();
  palette.showModal();
  paletteInput.focus();
}

function runPaletteItem(i) {
  const item = paletteItems[i];
  if (!item) return;
  palette.close();
  item.run();
}

paletteInput.addEventListener('input', () => {
  paletteIndex = 0;
  buildPalette();
});
paletteInput.addEventListener('keydown', (e) => {
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    const n = paletteItems.length;
    if (!n) return;
    paletteIndex = (paletteIndex + (e.key === 'ArrowDown' ? 1 : -1) + n) % n;
    buildPalette();
  } else if (e.key === 'Enter') {
    e.preventDefault();
    runPaletteItem(paletteIndex);
  }
});
$('#paletteList').addEventListener('click', (e) => {
  const item = e.target.closest('.palette-item');
  if (item) runPaletteItem(Number(item.dataset.index));
});
$('#paletteList').addEventListener('mousemove', (e) => {
  const item = e.target.closest('.palette-item');
  if (item && Number(item.dataset.index) !== paletteIndex) {
    paletteIndex = Number(item.dataset.index);
    $$('#paletteList .palette-item').forEach((el) => el.classList.toggle('active', Number(el.dataset.index) === paletteIndex));
  }
});

/* ==========================================================================
   Theme & view
   ========================================================================== */
const THEME_ICON = { system: 'monitor', light: 'sun', dark: 'moon' };
const THEME_NEXT = { system: 'light', light: 'dark', dark: 'system' };

function applyTheme() {
  const theme = state.prefs.theme;
  if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
  else delete document.documentElement.dataset.theme;
  const btn = $('#themeBtn');
  btn.innerHTML = icon(THEME_ICON[theme] || 'monitor');
  btn.title = `Theme: ${theme} (click to change)`;
}

function setTheme(theme) {
  state.prefs.theme = theme;
  savePrefs();
  applyTheme();
}

function setView(view) {
  state.prefs.view = view;
  if (state.route.scope === 'dashboard') go({ scope: 'all' });
  savePrefs();
  render();
}

/* ==========================================================================
   Main area interactions
   ========================================================================== */
const main = $('#main');

main.addEventListener('click', (e) => {
  const t = e.target;

  const goScope = t.closest('[data-go]');
  if (goScope) return go({ scope: goScope.dataset.go });
  const goProject = t.closest('[data-go-project]');
  if (goProject) return go({ scope: 'project', project: goProject.dataset.goProject });

  const action = t.closest('[data-action]');
  if (action) {
    if (action.dataset.action === 'new') openTaskDrawer();
    if (action.dataset.action === 'clear-filters') clearFilters();
    return;
  }

  const calNav = t.closest('[data-cal-nav]');
  if (calNav) {
    const step = Number(calNav.dataset.calNav);
    const now = new Date();
    const cur = state.calendar.month || new Date(now.getFullYear(), now.getMonth(), 1);
    state.calendar.month = step ? new Date(cur.getFullYear(), cur.getMonth() + step, 1) : null;
    state.calendar.expanded = '';
    return render();
  }
  const calMore = t.closest('[data-cal-more]');
  if (calMore) {
    state.calendar.expanded = calMore.dataset.calMore;
    return render();
  }

  const quickOpen = t.closest('[data-quick-open]');
  if (quickOpen) {
    state.quickAdd = { status: quickOpen.dataset.quickOpen, text: '' };
    return render();
  }

  const sort = t.closest('[data-sort]');
  if (sort) {
    const key = sort.dataset.sort;
    const cur = state.prefs.sort;
    state.prefs.sort = { key, dir: cur.key === key && cur.dir === 'asc' ? 'desc' : 'asc' };
    savePrefs();
    return render();
  }

  if (t.id === 'selectAll') {
    const ids = visibleTasks().map((x) => x.id);
    if (t.checked) ids.forEach((id) => state.selection.add(id));
    else state.selection.clear();
    return render();
  }

  const item = t.closest('[data-id]');
  if (!item) {
    const day = t.closest('[data-new-date]');
    if (day) openTaskDrawer(null, { dueDate: day.dataset.newDate });
    return;
  }
  if (t.closest('.quick-input')) return;
  const task = state.tasks.find((x) => x.id === item.dataset.id);
  if (!task) return;

  if (t.classList.contains('row-select')) {
    if (t.checked) state.selection.add(task.id);
    else state.selection.delete(task.id);
    return render();
  }
  if (t.classList.contains('toggle')) return setStatus(task.id, t.checked ? 'done' : 'todo');
  if (t.closest('td.sel')) return; // padding around the row checkbox
  openTaskDrawer(task);
});

main.addEventListener('keydown', (e) => {
  const quick = e.target.closest('.quick-input');
  if (quick) {
    if (e.key === 'Escape') {
      e.preventDefault();
      state.quickAdd = null;
      render();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const title = quick.value.trim();
      if (!title) return;
      state.quickAdd.text = '';
      saveTask(newTask({ title, status: quick.dataset.quick, ...routeDefaults() }), true);
    }
    return;
  }
  if (e.key !== 'Enter' || e.target.matches('input, button, a')) return;
  const item = e.target.closest('[data-id]');
  const task = item && state.tasks.find((t) => t.id === item.dataset.id);
  if (task) openTaskDrawer(task);
});

main.addEventListener('input', (e) => {
  if (e.target.classList.contains('quick-input') && state.quickAdd) state.quickAdd.text = e.target.value;
});
main.addEventListener('focusout', (e) => {
  const quick = e.target.closest('.quick-input');
  // Close an empty composer when focus leaves it (but not during re-render).
  if (quick && !quick.value.trim() && e.relatedTarget && !main.contains(e.relatedTarget)) {
    state.quickAdd = null;
    render();
  }
});

/* ---------- Drag and drop ---------- */
main.addEventListener('dragstart', (e) => {
  const card = e.target.closest('.card');
  if (!card) return;
  e.dataTransfer.setData('text/plain', card.dataset.id);
  e.dataTransfer.effectAllowed = 'move';
  card.classList.add('dragging');
});
main.addEventListener('dragend', (e) => {
  e.target.closest('.card')?.classList.remove('dragging');
  $$('.column-body.drop-target').forEach((z) => z.classList.remove('drop-target'));
});
main.addEventListener('dragover', (e) => {
  const zone = e.target.closest('.column-body');
  if (!zone) return;
  e.preventDefault();
  $$('.column-body.drop-target').forEach((z) => z !== zone && clearDropMarks(z));
  clearDropMarks(zone);
  zone.classList.add('drop-target');
  const before = cardAfterPointer(zone, e.clientY);
  if (before) before.classList.add('drop-before');
  else zone.classList.add('drop-end');
});
main.addEventListener('dragleave', (e) => {
  const zone = e.target.closest('.column-body');
  if (zone && !zone.contains(e.relatedTarget)) clearDropMarks(zone);
});
main.addEventListener('drop', (e) => {
  const zone = e.target.closest('.column-body');
  if (!zone) return;
  e.preventDefault();
  const before = cardAfterPointer(zone, e.clientY);
  clearDropMarks(zone);
  moveCard(e.dataTransfer.getData('text/plain'), zone.dataset.status, before ? before.dataset.id : null);
});

function clearDropMarks(zone) {
  zone.classList.remove('drop-target', 'drop-end');
  $$('.drop-before', zone).forEach((c) => c.classList.remove('drop-before'));
}

// The card the dragged one would land above, or null for the end of the column.
function cardAfterPointer(zone, y) {
  return $$('.card:not(.dragging)', zone).find((c) => {
    const r = c.getBoundingClientRect();
    return y < r.top + r.height / 2;
  }) || null;
}

// Places a task between its new neighbours. Usually one write: only the moved
// card changes. Cards without an order yet are numbered once, the first time.
function moveCard(id, status, beforeId) {
  const task = state.tasks.find((t) => t.id === id);
  if (!task) return;
  const column = visibleTasks().filter((t) => t.status === status && t.id !== id).sort(boardCompare);
  const index = beforeId ? column.findIndex((t) => t.id === beforeId) : column.length;
  const prev = column[index - 1];
  const next = column[index];
  const order = (t) => (t && t.sortOrder ? Number(t.sortOrder) : null);
  const p = order(prev);
  const n = order(next);
  let sortOrder = null;
  if (!prev && !next) sortOrder = task.sortOrder;
  else if (p !== null && n !== null) sortOrder = String((p + n) / 2);
  else if (!prev && n !== null) sortOrder = String(n - 1024);
  else if (!next && p !== null) sortOrder = String(p + 1024);
  if (sortOrder !== null) {
    if (task.status !== status || task.sortOrder !== sortOrder) saveTask({ ...task, status, sortOrder }, false);
    return;
  }
  const ordered = [...column.slice(0, index), { ...task, status }, ...column.slice(index)];
  const jobs = ordered.map((t, i) => ({
    prev: state.tasks.find((x) => x.id === t.id),
    next: { ...t, sortOrder: String((i + 1) * 1024) },
  }));
  jobs.forEach((j) => putLocal(j.next));
  render();
  send(jobs.map((j) => ({ prev: j.prev, op: { action: 'update', task: j.next } })));
}

/* ---------- Chart tooltips ---------- */
const tooltip = $('#tooltip');
function showTip(el, x, y) {
  tooltip.textContent = el.dataset.tip;
  tooltip.classList.add('show');
  const { width, height } = tooltip.getBoundingClientRect();
  const left = Math.min(Math.max(8, x - width / 2), window.innerWidth - width - 8);
  const top = y - height - 12 < 8 ? y + 16 : y - height - 12;
  tooltip.style.left = `${left}px`;
  tooltip.style.top = `${top}px`;
}
main.addEventListener('mousemove', (e) => {
  const el = e.target.closest('[data-tip]');
  if (el) showTip(el, e.clientX, e.clientY);
  else tooltip.classList.remove('show');
});
main.addEventListener('mouseleave', () => tooltip.classList.remove('show'));
main.addEventListener('focusin', (e) => {
  const el = e.target.closest('[data-tip]');
  if (!el) return;
  const r = el.getBoundingClientRect();
  showTip(el, r.left + r.width / 2, r.top);
});
main.addEventListener('focusout', () => tooltip.classList.remove('show'));

/* ==========================================================================
   Toolbar, header, sidebar
   ========================================================================== */
function clearFilters() {
  setFilters({ search: '', priority: '', tag: '' });
  render();
}

function setFilters(filters) {
  state.filters = { ...filters };
  $('#search').value = filters.search;
  $('#priorityFilter').value = filters.priority;
}

$('#search').addEventListener('input', (e) => {
  state.filters.search = e.target.value;
  render();
});
$('#priorityFilter').addEventListener('change', (e) => {
  state.filters.priority = e.target.value;
  render();
});
$('#tagFilter').addEventListener('change', (e) => {
  state.filters.tag = e.target.value;
  render();
});

const saveFilterDialog = $('#saveFilterDialog');
const saveFilterForm = $('#saveFilterForm');
$('#saveFilterBtn').addEventListener('click', () => {
  saveFilterForm.reset();
  saveFilterDialog.showModal();
});
saveFilterForm.addEventListener('submit', (e) => {
  e.preventDefault();
  const name = saveFilterForm.elements.name.value.trim();
  if (!name) return;
  state.prefs.savedFilters = [...state.prefs.savedFilters, { id: newId(), name, hash: routeHash(state.route), ...state.filters }];
  savePrefs();
  saveFilterDialog.close();
  render();
});
$('#navSaved').addEventListener('click', (e) => {
  const remove = e.target.closest('[data-saved-remove]');
  if (remove) {
    state.prefs.savedFilters = state.prefs.savedFilters.filter((f) => f.id !== remove.dataset.savedRemove);
    savePrefs();
    return render();
  }
  const open = e.target.closest('[data-saved]');
  const saved = open && state.prefs.savedFilters.find((f) => f.id === open.dataset.saved);
  if (!saved) return;
  setFilters({ search: saved.search, priority: saved.priority, tag: saved.tag });
  $('#app').classList.remove('nav-open');
  if (location.hash === saved.hash) render();
  else location.hash = saved.hash;
});

$('#hideDone').addEventListener('change', (e) => {
  state.prefs.hideDone = e.target.checked;
  savePrefs();
  render();
});
$$('#viewSwitch button').forEach((b) => b.addEventListener('click', () => setView(b.dataset.view)));

$('#bulkbar').addEventListener('click', (e) => {
  const btn = e.target.closest('[data-bulk]');
  if (!btn) return;
  const ids = new Set(state.selection);
  if (btn.dataset.bulk === 'done') bulkUpdate(ids, { status: 'done' });
  if (btn.dataset.bulk === 'delete') deleteTasks(ids);
  if (btn.dataset.bulk === 'clear') {
    state.selection.clear();
    render();
  }
});
$('#bulkStatus').addEventListener('change', (e) => {
  if (e.target.value) bulkUpdate(new Set(state.selection), { status: e.target.value });
  e.target.value = '';
});
$('#bulkPriority').addEventListener('change', (e) => {
  if (e.target.value) bulkUpdate(new Set(state.selection), { priority: e.target.value });
  e.target.value = '';
});

$('#newTaskBtn').addEventListener('click', () => openTaskDrawer());
$('#refreshBtn').addEventListener('click', loadTasks);
$('#themeBtn').addEventListener('click', () => setTheme(THEME_NEXT[state.prefs.theme] || 'system'));
$('#settingsBtn').addEventListener('click', openSettings);
$('#bannerConnectBtn').addEventListener('click', openSettings);
$('#errorSettingsBtn').addEventListener('click', openSettings);
$('#errorRetryBtn').addEventListener('click', loadTasks);
$('#paletteBtn').addEventListener('click', openPalette);
$('#menuBtn').addEventListener('click', () => $('#app').classList.add('nav-open'));
$('#scrim').addEventListener('click', () => $('#app').classList.remove('nav-open'));

document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    return openPalette();
  }
  const typing = e.target.closest('input, textarea, select, [contenteditable]');
  if (typing || e.ctrlKey || e.metaKey || e.altKey || document.querySelector('dialog[open]')) return;
  if (e.key === 'n') {
    e.preventDefault();
    openTaskDrawer();
  } else if (e.key === '/') {
    if (state.route.scope === 'dashboard') return;
    e.preventDefault();
    $('#search').focus();
  } else if (e.key === 'Escape' && state.selection.size) {
    state.selection.clear();
    render();
  }
});

// Send anything that was waiting as soon as the connection returns.
window.addEventListener('online', loadTasks);

// Pick up edits made directly in the sheet (or on another device) when returning to the tab.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && isRemote() && !state.pending && !drawer.open) loadTasks();
});

/* ==========================================================================
   Toasts
   ========================================================================== */
function toast(message, { error = false, action = null } = {}) {
  const el = document.createElement('div');
  el.className = `toast ${error ? 'error' : ''}`;
  el.setAttribute('role', error ? 'alert' : 'status');
  el.innerHTML = `<span>${esc(message)}</span>`;
  const dismiss = () => el.remove();
  if (action) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = action.label;
    btn.addEventListener('click', () => {
      dismiss();
      action.run();
    });
    el.appendChild(btn);
  }
  const close = document.createElement('button');
  close.type = 'button';
  close.setAttribute('aria-label', 'Dismiss');
  close.innerHTML = icon('x');
  close.addEventListener('click', dismiss);
  el.appendChild(close);
  $('#toasts').appendChild(el);
  setTimeout(dismiss, error ? 7000 : action ? 6000 : 3000);
}

/* ==========================================================================
   Boot
   ========================================================================== */
// The indeterminate state can't be set from markup; apply it after each render.
new MutationObserver(() => {
  const all = $('#selectAll');
  if (all) all.indeterminate = all.dataset.indeterminate === 'true';
}).observe(main, { childList: true });

handleConnectLink();
render();
loadTasks();
