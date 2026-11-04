import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/task.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Client for the Apps Script web app in `apps-script/Code.gs`.
class TaskApi {
  TaskApi({required this.url, required this.token, http.Client? client})
      : _client = client ?? http.Client();

  final String url;
  final String token;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  Future<List<Task>> list() async {
    final data = await _call('list');
    return (data['tasks'] as List)
        .map((t) => Task.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  Future<Task> create(Task task) async {
    final data = await _call('create', {'task': task.toJson()});
    return Task.fromJson(data['task'] as Map<String, dynamic>);
  }

  Future<Task> update(Task task) async {
    final data = await _call('update', {'task': task.toJson()});
    return Task.fromJson(data['task'] as Map<String, dynamic>);
  }

  Future<void> delete(String id) => _call('delete', {'id': id});

  Future<List<HistoryEntry>> history(String id) async {
    final data = await _call('history', {'id': id});
    return (data['entries'] as List)
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const {},
  ]) async {
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'text/plain;charset=utf-8'},
            body: jsonEncode({'action': action, 'token': token, ...payload}),
          )
          .timeout(_timeout);
      // Apps Script runs the POST, then redirects to its result. package:http
      // only follows redirects for GET, so fetch the result here.
      final location = res.headers['location'];
      if (res.statusCode >= 300 && res.statusCode < 400 && location != null) {
        res = await _client.get(Uri.parse(location)).timeout(_timeout);
      }
    } on TimeoutException {
      throw ApiException('The server took too long to respond.');
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('Could not reach the server. Check your connection.');
    }

    if (res.statusCode != 200) {
      throw ApiException('Server responded ${res.statusCode}.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ApiException(
        'Unexpected response. Check the web app URL and that access is set to "Anyone".',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('Unexpected response from the server.');
    }
    if (decoded['ok'] != true) {
      throw ApiException('${decoded['error'] ?? 'Request failed.'}');
    }
    return decoded;
  }
}
