import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/task.dart';
import 'api.dart';

const _urlKey = 'url';
const _cacheKey = 'tasks';
const _themeKey = 'theme';
const _tokenKey = 'token';

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
  ThemeMode themeMode = ThemeMode.system;
  String url = '';

  bool get isConnected => _api != null;

  List<String> get projects {
    final names = tasks.map((t) => t.project).where((p) => p.isNotEmpty).toSet().toList();
    return names..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
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

  void _saveCache() =>
      _prefs.setString(_cacheKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));
}

/// Gives the widget tree access to the store and rebuilds on changes.
class StoreScope extends InheritedNotifier<TaskStore> {
  const StoreScope({super.key, required TaskStore store, required super.child})
      : super(notifier: store);

  static TaskStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;
}
