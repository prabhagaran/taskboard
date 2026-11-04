import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/task.dart';
import 'api.dart';

const _urlKey = 'url';
const _cacheKey = 'tasks';
const _themeKey = 'theme';
const _tokenKey = 'token';
const _filtersKey = 'savedFilters';
const _widgetProvider = 'TaskBoardWidget';
const _widgetLines = 6;

/// App state. Edits apply immediately and roll back if the sheet rejects them.
class TaskStore extends ChangeNotifier {
  final _secure = const FlutterSecureStorage();
  late SharedPreferences _prefs;
  TaskApi? _api;

  /// Shows a failure to the user; set by the app shell.
  void Function(String message) onError = (_) {};

  bool ready = false;
  bool syncing = false;
  String? syncError;
  List<Task> tasks = [];
  List<SavedFilter> savedFilters = [];
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
    final numbered = [
      for (var i = 0; i < rest.length; i++) rest[i].copyWith(sortOrder: '${(i + 1) * 1024}'),
    ];
    numbered.forEach(_replace);
    notifyListeners();
    for (final task in numbered) {
      try {
        await _api!.update(task);
      } on ApiException catch (e) {
        onError('Order not saved: ${e.message}');
        return refresh();
      }
    }
    _saveCache();
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final filters = _prefs.getString(_filtersKey);
    if (filters != null) {
      savedFilters = (jsonDecode(filters) as List)
          .map((f) => SavedFilter.fromJson(f as Map<String, dynamic>))
          .toList();
    }
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
    if (isConnected) await refresh();
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    syncing = true;
    notifyListeners();
    try {
      tasks = await api.list();
      syncError = null;
      _saveCache();
    } on ApiException catch (e) {
      syncError = e.message;
    }
    syncing = false;
    notifyListeners();
  }

  /// Returns the number of tasks in the sheet, or throws [ApiException].
  Future<int> testConnection(String url, String token) async =>
      (await TaskApi(url: url, token: token).list()).length;

  Future<void> connect(String newUrl, String token) async {
    url = newUrl;
    await _prefs.setString(_urlKey, newUrl);
    await _secure.write(key: _tokenKey, value: token);
    await _prefs.remove(_cacheKey);
    _api = TaskApi(url: newUrl, token: token);
    tasks = [];
    await refresh();
  }

  Future<void> disconnect() async {
    url = '';
    _api = null;
    tasks = [];
    syncError = null;
    await _prefs.remove(_urlKey);
    await _prefs.remove(_cacheKey);
    await _secure.delete(key: _tokenKey);
    await _updateWidget();
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _prefs.setString(_themeKey, mode.name);
  }

  static String newId() {
    final random = Random.secure();
    final suffix = List.generate(8, (_) => random.nextInt(36).toRadixString(36)).join();
    return 'm-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$suffix';
  }

  Future<void> add(Task task) async {
    tasks = [...tasks, task];
    notifyListeners();
    await _write(() => _api!.create(task), onFail: () => _remove(task.id), id: task.id);
  }

  Future<void> edit(Task task) async {
    final previous = tasks.firstWhere((t) => t.id == task.id);
    _replace(task);
    notifyListeners();
    await _write(() => _api!.update(task), onFail: () => _replace(previous), id: task.id);
  }

  Future<void> setDone(Task task, bool done) =>
      edit(task.copyWith(status: done ? TaskStatus.done : TaskStatus.todo));

  Future<void> remove(Task task) async {
    _remove(task.id);
    notifyListeners();
    try {
      await _api!.delete(task.id);
      _saveCache();
    } on ApiException catch (e) {
      tasks = [...tasks, task];
      notifyListeners();
      onError('Could not delete task: ${e.message}');
    }
  }

  Future<void> _write(
    Future<Task> Function() request, {
    required void Function() onFail,
    required String id,
  }) async {
    try {
      final saved = await request();
      // Skip if the task was deleted while the request was in flight.
      if (tasks.any((t) => t.id == id)) _replace(saved);
      _saveCache();
    } on ApiException catch (e) {
      onFail();
      onError('Not saved: ${e.message}');
    }
    notifyListeners();
  }

  void _replace(Task task) =>
      tasks = [for (final t in tasks) t.id == task.id ? task : t];

  void _remove(String id) => tasks = tasks.where((t) => t.id != id).toList();

  void _saveCache() {
    _prefs.setString(_cacheKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));
    _updateWidget();
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
