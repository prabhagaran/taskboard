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

/// The server could not be reached, so the request may succeed if retried.
class NetworkException extends ApiException {
  NetworkException(super.message);
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

  /// Applies writes in order under one lock; each op reports its own result.
  Future<List<Map<String, dynamic>>> batch(List<Map<String, dynamic>> ops) async {
    final data = await _call('batch', {'ops': ops});
    return (data['results'] as List).cast<Map<String, dynamic>>();
  }

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
      throw NetworkException('The server took too long to respond.');
    } catch (_) {
      throw NetworkException('Could not reach the server. Check your connection.');
    }

    if (res.statusCode >= 500) {
      throw NetworkException('Server responded ${res.statusCode}.');
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
      final error = '${decoded['error'] ?? 'Request failed.'}';
      throw ApiException(
        error.startsWith('Unknown action')
            ? 'Apps Script is out of date. Deploy the latest Code.gs as a new version.'
            : error,
      );
    }
    return decoded;
  }
}
