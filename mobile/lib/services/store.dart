import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/task.dart';
import 'api.dart';
import 'reminders.dart';

const _urlKey = 'url';
const _cacheKey = 'tasks';
const _themeKey = 'theme';
const _tokenKey = 'token';
const _filtersKey = 'savedFilters';
const _queueKey = 'queue';
const _remindersKey = 'reminders';
const _widgetProvider = 'TaskBoardWidget';
const _widgetLines = 6;

/// A write to send, and what to restore if the server refuses it.
class _Job {
  _Job(this.op, [this.previous]);

  final Map<String, dynamic> op;
  final Task? previous;
}

/// App state. Edits apply immediately. If the server can't be reached they wait
/// in a saved queue; if it refuses them, they roll back.
class TaskStore extends ChangeNotifier {
  final _secure = const FlutterSecureStorage();
  final _reminders = Reminders();
  late SharedPreferences _prefs;
  TaskApi? _api;
  Future<void> _writes = Future.value();

  /// Shows a failure to the user; set by the app shell.
  void Function(String message) onError = (_) {};

  /// Offers to overwrite a task that changed elsewhere; set by the app shell.
  void Function(Task mine, Task theirs) onConflict = (_, _) {};

  /// Shows that waiting changes were sent; set by the app shell.
  void Function(int count) onSynced = (_) {};

  bool ready = false;
  bool syncing = false;
  bool remindersOn = false;
  String? syncError;
  List<Task> tasks = [];
  List<SavedFilter> savedFilters = [];
  List<Map<String, dynamic>> queue = [];
  ThemeMode themeMode = ThemeMode.system;
  String url = '';

  bool get isConnected => _api != null;

  List<String> get projects {
    final names = tasks.map((t) => t.project).where((p) => p.isNotEmpty).toSet().toList();
    return names..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<String> get allTags {
    final names = tasks.expand((t) => t.tagList).toSet().toList();
    return names..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<List<HistoryEntry>> history(String id) => _api!.history(id);

  Future<void> saveFilter(SavedFilter filter) async {
    savedFilters = [...savedFilters.where((f) => f.name != filter.name), filter];
    notifyListeners();
    await _saveFilters();
  }

  Future<void> removeFilter(SavedFilter filter) async {
    savedFilters = savedFilters.where((f) => f.name != filter.name).toList();
    notifyListeners();
    await _saveFilters();
  }

  Future<void> _saveFilters() => _prefs.setString(
        _filtersKey,
        jsonEncode(savedFilters.map((f) => f.toJson()).toList()),
      );

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final filters = _prefs.getString(_filtersKey);
    if (filters != null) {
      savedFilters = (jsonDecode(filters) as List)
          .map((f) => SavedFilter.fromJson(f as Map<String, dynamic>))
          .toList();
    }
    final waiting = _prefs.getString(_queueKey);
    if (waiting != null) {
      queue = (jsonDecode(waiting) as List).cast<Map<String, dynamic>>();
    }
    remindersOn = _prefs.getBool(_remindersKey) ?? false;
    themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == _prefs.getString(_themeKey),
      orElse: () => ThemeMode.system,
    );
    url = _prefs.getString(_urlKey) ?? '';
    final token = await _secure.read(key: _tokenKey);
    if (url.isNotEmpty && token != null) {
      _api = TaskApi(url: url, token: token);
      // Show the last synced tasks at once; Apps Script can take seconds.
      final cached = _prefs.getString(_cacheKey);
      if (cached != null) {
        tasks = (jsonDecode(cached) as List)
            .map((t) => Task.fromJson(t as Map<String, dynamic>))
            .toList();
      }
    }
    ready = true;
    notifyListeners();
    // Send anything waiting as soon as the connection returns.
    Connectivity().onConnectivityChanged.listen((states) {
      if (!states.contains(ConnectivityResult.none)) refresh();
    });
    if (isConnected) await refresh();
  }

  /// Sends waiting changes, then loads the sheet.
  Future<void> refresh() {
    final api = _api;
    if (api == null) return Future.value();
    syncing = true;
    notifyListeners();
    return _inOrder(() async {
      try {
        await _flush(api);
        if (queue.isEmpty) {
          tasks = await api.list();
          _saveCache();
        }
        syncError = null;
      } on ApiException catch (e) {
        syncError = e.message;
      }
      syncing = false;
      notifyListeners();
    });
  }

  /// Returns the number of tasks in the sheet, or throws [ApiException].
  Future<int> testConnection(String url, String token) async =>
      (await TaskApi(url: url, token: token).list()).length;

  Future<void> connect(String newUrl, String token) async {
    url = newUrl;
    await _prefs.setString(_urlKey, newUrl);
    await _secure.write(key: _tokenKey, value: token);
    await _clearLocalData();
    _api = TaskApi(url: newUrl, token: token);
    await refresh();
  }

  Future<void> disconnect() async {
    url = '';
    _api = null;
    syncError = null;
    await _prefs.remove(_urlKey);
    await _secure.delete(key: _tokenKey);
    await _clearLocalData();
    await _reminders.cancelAll();
    await _updateWidget();
    notifyListeners();
  }

  Future<void> _clearLocalData() async {
    tasks = [];
    queue = [];
    await _prefs.remove(_cacheKey);
    await _prefs.remove(_queueKey);
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _prefs.setString(_themeKey, mode.name);
  }

  /// Turns due-date notifications on or off. Returns false if permission is denied.
  Future<bool> setReminders(bool on) async {
    if (on && !await _reminders.requestPermission()) return false;
    remindersOn = on;
    await _prefs.setBool(_remindersKey, on);
    notifyListeners();
    await (on ? _reminders.schedule(tasks) : _reminders.cancelAll());
    return true;
  }

  static String newId() {
    final random = Random.secure();
    final suffix = List.generate(8, (_) => random.nextInt(36).toRadixString(36)).join();
    return 'm-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$suffix';
  }

  Future<void> add(Task task) {
    tasks = [...tasks, task];
    notifyListeners();
    return _send([_Job({'action': 'create', 'task': task.toJson()})]);
  }

  Future<void> edit(Task task) {
    final previous = tasks.firstWhere((t) => t.id == task.id);
    _replace(task);
    notifyListeners();
    return _send([_Job({'action': 'update', 'task': task.toJson()}, previous)]);
  }

  /// Saves [task] over a newer copy, after the user chose to keep their edit.
  Future<void> forceEdit(Task task) {
    _replace(task);
    notifyListeners();
    return _send([_Job({'action': 'update', 'force': true, 'task': task.toJson()})]);
  }

  Future<void> setDone(Task task, bool done) =>
      edit(task.copyWith(status: done ? TaskStatus.done : TaskStatus.todo));

  Future<void> remove(Task task) {
    _remove(task.id);
    notifyListeners();
    return _send([_Job({'action': 'delete', 'id': task.id}, task)]);
  }

  /// Moves a task within [column], which must be sorted by [compareManual].
  /// Normally one write; cards with no position yet are numbered the first time.
  Future<void> reorder(List<Task> column, int oldIndex, int index) async {
    if (index == oldIndex) return;
    final rest = [...column];
    final moved = rest.removeAt(oldIndex);
    final prev = index > 0 ? rest[index - 1].order : null;
    final next = index < rest.length ? rest[index].order : null;

    final double? position;
    if (index > 0 && index < rest.length) {
      position = prev != null && next != null ? (prev + next) / 2 : null;
    } else if (index == 0) {
      position = next == null ? null : next - 1024;
    } else {
      position = prev == null ? null : prev + 1024;
    }
    if (position != null) return edit(moved.copyWith(sortOrder: '$position'));

    rest.insert(index, moved);
    final jobs = <_Job>[];
    for (var i = 0; i < rest.length; i++) {
      final task = rest[i].copyWith(sortOrder: '${(i + 1) * 1024}');
      jobs.add(_Job({'action': 'update', 'task': task.toJson()}, rest[i]));
      _replace(task);
    }
    notifyListeners();
    await _send(jobs);
  }

  /// Runs writes one at a time, so each sees the result of the one before.
  Future<void> _inOrder(Future<void> Function() action) {
    final run = _writes.then((_) => action());
    _writes = run.catchError((_) {});
    return run;
  }

  // The server compares this with its copy, to catch edits made elsewhere.
  void _stampBase(Map<String, dynamic> op) {
    if (op['action'] != 'update' || op['force'] == true) return;
    final task = op['task'] as Map<String, dynamic>;
    final current = tasks.where((t) => t.id == task['id']).firstOrNull;
    task['baseUpdatedAt'] ??= current?.updatedAt ?? '';
  }

  static String _opId(Map<String, dynamic> op) =>
      '${op['task'] == null ? op['id'] : (op['task'] as Map)['id']}';

  // Merges with queued writes for the same task, so a later edit isn't mistaken
  // for a conflict with an earlier one that hasn't been sent yet.
  void _enqueue(Map<String, dynamic> op) {
    final index = queue.indexWhere((q) => q['action'] != 'delete' && _opId(q) == _opId(op));
    if (index < 0 || op['action'] == 'create') {
      queue.add(op);
      return;
    }
    final queued = queue[index];
    if (op['action'] == 'delete') {
      if (queued['action'] == 'create') {
        queue.removeAt(index);
      } else {
        queue[index] = op;
      }
    } else if (queued['action'] == 'create') {
      queued['task'] = op['task'];
    } else {
      final base = (queued['task'] as Map)['baseUpdatedAt'];
      queued['task'] = {...op['task'] as Map<String, dynamic>, 'baseUpdatedAt': base};
    }
  }

  Future<void> _send(List<_Job> jobs) {
    return _inOrder(() async {
      final api = _api;
      if (api == null) return;
      for (final job in jobs) {
        _stampBase(job.op);
      }
      if (queue.isNotEmpty) {
        // Stay behind what is already waiting.
        jobs.map((j) => j.op).forEach(_enqueue);
      } else {
        try {
          _applyResults(jobs, await api.batch(jobs.map((j) => j.op).toList()));
        } on NetworkException {
          jobs.map((j) => j.op).forEach(_enqueue);
        } on ApiException catch (e) {
          for (final job in jobs) {
            _rollback(job);
          }
          onError('Not saved: ${e.message}');
        }
      }
      await _saveQueue();
      _saveCache();
      notifyListeners();
    });
  }

  Future<void> _flush(TaskApi api) async {
    if (queue.isEmpty) return;
    final ops = [...queue];
    final results = await api.batch(ops);
    queue = queue.sublist(ops.length);
    await _saveQueue();
    _applyResults(ops.map(_Job.new).toList(), results);
    onSynced(ops.length);
  }

  void _applyResults(List<_Job> jobs, List<Map<String, dynamic>> results) {
    for (var i = 0; i < results.length; i++) {
      final job = jobs[i];
      final result = results[i];
      final id = _opId(job.op);
      if (result['ok'] == true) {
        final saved = result['task'];
        if (saved != null && tasks.any((t) => t.id == id)) {
          _replace(Task.fromJson(saved as Map<String, dynamic>));
        }
        final next = result['next'];
        if (next != null) tasks = [...tasks, Task.fromJson(next as Map<String, dynamic>)];
      } else if (result['conflict'] != null) {
        final theirs = Task.fromJson(result['conflict'] as Map<String, dynamic>);
        _replace(theirs);
        onConflict(Task.fromJson(job.op['task'] as Map<String, dynamic>), theirs);
      } else {
        _rollback(job);
        onError('Not saved: ${result['error']}');
      }
    }
  }

  void _rollback(_Job job) {
    final previous = job.previous;
    if (previous != null) {
      if (tasks.any((t) => t.id == previous.id)) {
        _replace(previous);
      } else {
        tasks = [...tasks, previous];
      }
    } else if (job.op['action'] == 'create') {
      _remove(_opId(job.op));
    }
  }

  void _replace(Task task) =>
      tasks = [for (final t in tasks) t.id == task.id ? task : t];

  void _remove(String id) => tasks = tasks.where((t) => t.id != id).toList();

  Future<void> _saveQueue() => _prefs.setString(_queueKey, jsonEncode(queue));

  void _saveCache() {
    _prefs.setString(_cacheKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));
    _updateWidget();
    if (remindersOn) _reminders.schedule(tasks).catchError((_) {});
  }

  /// Sends the open tasks due today or earlier to the home-screen widget.
  Future<void> _updateWidget() async {
    final today = todayKey();
    final due = tasks
        .where((t) => t.isOpen && t.dueDate.isNotEmpty && t.dueDate.compareTo(today) <= 0)
        .toList()
      ..sort(compareTasks);
    final lines = due.take(_widgetLines).map((t) => '• ${t.title}').toList();
    if (due.length > _widgetLines) lines.add('+${due.length - _widgetLines} more');
    try {
      await HomeWidget.saveWidgetData<String>('title', 'Today · ${due.length}');
      await HomeWidget.saveWidgetData<String>(
        'lines',
        lines.isEmpty ? 'Nothing due today' : lines.join('\n'),
      );
      await HomeWidget.updateWidget(androidName: _widgetProvider);
    } catch (_) {
      // The widget is optional; a failure here must never affect saving.
    }
  }
}

/// Gives the widget tree access to the store and rebuilds on changes.
class StoreScope extends InheritedNotifier<TaskStore> {
  const StoreScope({super.key, required TaskStore store, required super.child})
      : super(notifier: store);

  static TaskStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;
}
