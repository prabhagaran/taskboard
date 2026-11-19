import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/note.dart';
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
  TaskApi({required this.url, required this.token, http.Client? client}) : _client = client ?? http.Client();

  final String url;
  final String token;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);

  Future<({List<Task> tasks, List<Note> notes, int version})> list() async {
    final data = await _call('list');
    return (
      tasks: (data['tasks'] as List).map((t) => Task.fromJson(t as Map<String, dynamic>)).toList(),
      // A script from before notes existed sends no notes.
      notes: ((data['notes'] as List?) ?? const []).map((n) => Note.fromJson(n as Map<String, dynamic>)).toList(),
      version: int.tryParse('${data['version'] ?? ''}') ?? 0,
    );
  }

  /// Applies writes in order under one lock; each op reports its own result.
  Future<List<Map<String, dynamic>>> batch(List<Map<String, dynamic>> ops) async {
    final data = await _call('batch', {'ops': ops});
    return (data['results'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<HistoryEntry>> history(String id) async {
    final data = await _call('history', {'id': id});
    return (data['entries'] as List).map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Map<String, dynamic>> _call(String action, [Map<String, dynamic> payload = const {}]) async {
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
      throw ApiException('Unexpected response. Check the web app URL and that access is set to "Anyone".');
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

/// This app's Supabase project. The publishable key is meant to be public:
/// row-level security keeps each account's tasks private.
const supabaseUrl = 'https://pymvievtqpkbnblmkwlz.supabase.co';
const supabaseKey = 'sb_publishable_6YwB2Uok9Oyb2xwZtieevw_mIOM1HqP';

/// A signed-in Supabase session. Kept in encrypted storage.
class SupabaseSession {
  const SupabaseSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.email = '',
  });

  factory SupabaseSession.fromJson(Map<String, dynamic> json) => SupabaseSession(
    accessToken: '${json['access_token'] ?? ''}',
    refreshToken: '${json['refresh_token'] ?? ''}',
    expiresAt: json['expires_at'] is int
        ? json['expires_at'] as int
        : DateTime.now().millisecondsSinceEpoch ~/ 1000 + (int.tryParse('${json['expires_in'] ?? ''}') ?? 3600),
    email: '${json['email'] ?? (json['user'] is Map ? json['user']['email'] : '') ?? ''}',
  );

  final String accessToken;
  final String refreshToken;

  /// Seconds since the epoch.
  final int expiresAt;
  final String email;

  bool get expiresSoon => expiresAt - 60 < DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt,
    'email': email,
  };
}

/// Client for the database functions in `supabase/schema.sql`. They answer
/// like the Apps Script web app, so the rest of the app is unchanged.
class SupabaseApi extends TaskApi {
  SupabaseApi({
    super.url = supabaseUrl,
    this.key = supabaseKey,
    required SupabaseSession session,
    required this.onSession,
    super.client,
  }) : _session = session, // ignore: prefer_initializing_formals
       super(token: '');

  final String key;
  SupabaseSession _session;

  /// Saves a refreshed session.
  final Future<void> Function(SupabaseSession session) onSession;
  Future<SupabaseSession>? _refreshing;

  String get email => _session.email;

  static Future<SupabaseSession> signIn(
    String email,
    String password, {
    String url = supabaseUrl,
    String key = supabaseKey,
    http.Client? client,
  }) => _auth(client ?? http.Client(), url, key, 'password', {'email': email, 'password': password});

  static Future<SupabaseSession> _auth(
    http.Client client,
    String url,
    String key,
    String grant,
    Map<String, String> body,
  ) async {
    http.Response res;
    try {
      res = await client
          .post(
            Uri.parse('$url/auth/v1/token?grant_type=$grant'),
            headers: {'apikey': key, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(TaskApi._timeout);
    } on TimeoutException {
      throw NetworkException('Supabase took too long to respond.');
    } catch (_) {
      throw NetworkException('Could not reach Supabase. Check your connection.');
    }
    if (res.statusCode >= 500) throw NetworkException('Supabase responded ${res.statusCode}.');
    final Object? data = _decode(res);
    if (res.statusCode != 200 || data is! Map<String, dynamic>) {
      final map = data is Map ? data : const {};
      throw ApiException('${map['error_description'] ?? map['msg'] ?? map['message'] ?? 'Sign-in failed.'}');
    }
    final session = SupabaseSession.fromJson(data);
    return SupabaseSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresAt: session.expiresAt,
      email: session.email.isEmpty ? (body['email'] ?? '') : session.email,
    );
  }

  static Object? _decode(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  Future<SupabaseSession> _fresh({bool force = false}) async {
    if (!force && !_session.expiresSoon) return _session;
    final pending = _refreshing ??= _auth(_client, url, key, 'refresh_token', {'refresh_token': _session.refreshToken})
        .then((next) async {
          final kept = SupabaseSession(
            accessToken: next.accessToken,
            refreshToken: next.refreshToken,
            expiresAt: next.expiresAt,
            email: next.email.isEmpty ? _session.email : next.email,
          );
          _session = kept;
          await onSession(kept);
          return kept;
        })
        .catchError((Object e) {
          if (e is NetworkException) throw e;
          throw ApiException('Your sign-in has expired. Sign in again in Settings.');
        })
        .whenComplete(() => _refreshing = null);
    return pending;
  }

  /// Best effort: ends the session on the server too.
  Future<void> signOut() async {
    try {
      await _client
          .post(
            Uri.parse('$url/auth/v1/logout'),
            headers: {'apikey': key, 'Authorization': 'Bearer ${_session.accessToken}'},
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> _call(String action, [Map<String, dynamic> payload = const {}]) {
    switch (action) {
      case 'list':
        return _rpc('list_all', {});
      case 'batch':
        return _rpc('apply_ops', {'ops': payload['ops'], 'today': todayKey()});
      case 'history':
        return _rpc('task_history', {'p_task_id': payload['id']});
    }
    throw ApiException('Unknown action: $action');
  }

  Future<Map<String, dynamic>> _rpc(String fn, Map<String, dynamic> args) async {
    for (var attempt = 0; ; attempt++) {
      final session = await _fresh(force: attempt > 0);
      http.Response res;
      try {
        res = await _client
            .post(
              Uri.parse('$url/rest/v1/rpc/$fn'),
              headers: {
                'apikey': key,
                'Authorization': 'Bearer ${session.accessToken}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(args),
            )
            .timeout(TaskApi._timeout);
      } on TimeoutException {
        throw NetworkException('Supabase took too long to respond.');
      } catch (_) {
        throw NetworkException('Could not reach Supabase. Check your connection.');
      }
      if (res.statusCode == 401 && attempt == 0) continue; // Expired early; refresh once.
      if (res.statusCode >= 500) throw NetworkException('Supabase responded ${res.statusCode}.');
      final data = _decode(res);
      if (res.statusCode != 200 || data is! Map<String, dynamic>) {
        final map = data is Map ? data : const {};
        throw ApiException('${map['message'] ?? map['msg'] ?? 'Supabase responded ${res.statusCode}.'}');
      }
      return data;
    }
  }
}
