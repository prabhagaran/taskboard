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

/// This app's Supabase project. The publishable key is meant to be public:
/// row-level security keeps each account's tasks private. For a local stack
/// (`supabase start`), build with `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...`.
const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://pymvievtqpkbnblmkwlz.supabase.co');
const supabaseKey = String.fromEnvironment('SUPABASE_KEY', defaultValue: 'sb_publishable_6YwB2Uok9Oyb2xwZtieevw_mIOM1HqP');

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

  SupabaseSession withEmail(String fallback) => email.isNotEmpty
      ? this
      : SupabaseSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, email: fallback);

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt,
    'email': email,
  };
}

/// Client for the database functions in `supabase/schema.sql`: list_all,
/// apply_ops (batched writes) and task_history.
class TaskApi {
  TaskApi({
    required SupabaseSession session,
    required this.onSession,
    this.url = supabaseUrl,
    this.key = supabaseKey,
    http.Client? client,
  }) : _session = session, // ignore: prefer_initializing_formals
       _client = client ?? http.Client();

  final String url;
  final String key;
  final http.Client _client;
  SupabaseSession _session;

  /// Saves a refreshed session.
  final Future<void> Function(SupabaseSession session) onSession;
  Future<SupabaseSession>? _refreshing;

  static const _timeout = Duration(seconds: 30);

  String get email => _session.email;

  static Future<SupabaseSession> signIn(
    String email,
    String password, {
    String url = supabaseUrl,
    String key = supabaseKey,
    http.Client? client,
  }) async {
    final session = await _auth(client ?? http.Client(), url, key, 'password', {'email': email, 'password': password});
    return session.withEmail(email);
  }

  Future<({List<Task> tasks, List<Note> notes})> list() async {
    final data = await _rpc('list_all', {});
    return (
      tasks: (data['tasks'] as List).map((t) => Task.fromJson(t as Map<String, dynamic>)).toList(),
      notes: ((data['notes'] as List?) ?? const []).map((n) => Note.fromJson(n as Map<String, dynamic>)).toList(),
    );
  }

  /// Applies writes in order; each op reports its own result.
  Future<List<Map<String, dynamic>>> batch(List<Map<String, dynamic>> ops) async {
    final data = await _rpc('apply_ops', {'ops': ops, 'today': todayKey()});
    return (data['results'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<HistoryEntry>> history(String id) async {
    final data = await _rpc('task_history', {'p_task_id': id});
    return (data['entries'] as List).map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
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

  static Future<SupabaseSession> _auth(
    http.Client client,
    String url,
    String key,
    String grant,
    Map<String, String> body,
  ) async {
    final res = await _send(
      () => client.post(
        Uri.parse('$url/auth/v1/token?grant_type=$grant'),
        headers: {'apikey': key, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    final data = _decode(res);
    if (res.statusCode != 200 || data is! Map<String, dynamic>) {
      final map = data is Map ? data : const {};
      throw ApiException('${map['error_description'] ?? map['msg'] ?? map['message'] ?? 'Sign-in failed.'}');
    }
    return SupabaseSession.fromJson(data);
  }

  Future<SupabaseSession> _fresh({bool force = false}) {
    if (!force && !_session.expiresSoon) return Future.value(_session);
    return _refreshing ??= _auth(_client, url, key, 'refresh_token', {'refresh_token': _session.refreshToken})
        .then((next) async {
          _session = next.withEmail(_session.email);
          await onSession(_session);
          return _session;
        })
        .catchError((Object e) {
          if (e is NetworkException) throw e;
          throw ApiException('Your sign-in has expired. Sign in again in Settings.');
        })
        .whenComplete(() => _refreshing = null);
  }

  Future<Map<String, dynamic>> _rpc(String fn, Map<String, dynamic> args) async {
    for (var attempt = 0; ; attempt++) {
      final session = await _fresh(force: attempt > 0);
      final res = await _send(
        () => _client.post(
          Uri.parse('$url/rest/v1/rpc/$fn'),
          headers: {
            'apikey': key,
            'Authorization': 'Bearer ${session.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(args),
        ),
      );
      // The token expired early; refresh once and retry.
      if (res.statusCode == 401 && attempt == 0) continue;
      final data = _decode(res);
      if (res.statusCode != 200 || data is! Map<String, dynamic>) {
        final map = data is Map ? data : const {};
        throw ApiException('${map['message'] ?? map['msg'] ?? 'Supabase responded ${res.statusCode}.'}');
      }
      return data;
    }
  }

  /// Sends a request, turning outages into [NetworkException] so writes wait in the queue.
  static Future<http.Response> _send(Future<http.Response> Function() request) async {
    final http.Response res;
    try {
      res = await request().timeout(_timeout);
    } on TimeoutException {
      throw NetworkException('Supabase took too long to respond.');
    } catch (_) {
      throw NetworkException('Could not reach Supabase. Check your connection.');
    }
    if (res.statusCode >= 500) throw NetworkException('Supabase responded ${res.statusCode}.');
    return res;
  }

  static Object? _decode(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      return null;
    }
  }
}
