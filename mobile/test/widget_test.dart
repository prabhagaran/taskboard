import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taskboard/models/note.dart';
import 'package:taskboard/models/task.dart';
import 'package:taskboard/services/api.dart';
import 'package:taskboard/services/setup_link.dart';

void main() {
  group('Note', () {
    test('survives a JSON round trip', () {
      const note = Note(id: 'n', title: 'Plan', body: 'Line one\nLine two', taskIds: ['a', 'b']);
      expect(Note.fromJson(note.toJson()).toJson(), note.toJson());
      expect(note.toJson()['taskIds'], 'a,b');
    });

    test('untitled notes go by their first line', () {
      const note = Note(id: 'n', body: '\nIdea for the trip\nBook early');
      expect(note.displayTitle, 'Idea for the trip');
      expect(note.preview, 'Book early');
      expect(const Note(id: 'n').displayTitle, 'Untitled note');
    });

    test('titled notes show their whole text as the preview', () {
      const note = Note(id: 'n', title: 'Plan', body: 'Line one\nLine two');
      expect(note.displayTitle, 'Plan');
      expect(note.preview, 'Line one\nLine two');
    });

    test('ignores blank task links', () {
      expect(Note.fromJson({'id': 1, 'taskIds': ' , a ,,'}).taskIds, ['a']);
      expect(Note.fromJson({'id': 1}).taskIds, isEmpty);
    });
  });

  group('Task', () {
    test('survives a JSON round trip', () {
      const task = Task(
        id: 'a',
        title: 'Ship',
        status: TaskStatus.done,
        priority: TaskPriority.high,
        project: 'Alpha',
        dueDate: '2026-11-10',
      );
      final copy = Task.fromJson(task.toJson());
      expect(copy.toJson(), task.toJson());
    });

    test('falls back on values edited by hand in the sheet', () {
      final task = Task.fromJson({'id': 7, 'title': '', 'status': 'blocked', 'priority': 'urgent', 'dueDate': 'soon'});
      expect(task.id, '7');
      expect(task.title, '(untitled)');
      expect(task.status, TaskStatus.todo);
      expect(task.priority, TaskPriority.medium);
      expect(task.dueDate, '');
    });

    test('shows tasks from the old In Progress status as To Do', () {
      expect(Task.fromJson({'id': 'a', 'title': 'x', 'status': 'inprogress'}).status, TaskStatus.todo);
    });

    test('is overdue only while open and past due', () {
      expect(Task(id: 'a', title: 'x', dueDate: dayKey(-1)).isOverdue, isTrue);
      expect(Task(id: 'a', title: 'x', dueDate: dayKey(0)).isOverdue, isFalse);
      expect(Task(id: 'a', title: 'x', dueDate: dayKey(-1), status: TaskStatus.done).isOverdue, isFalse);
    });
  });

  group('Task fields', () {
    test('keeps new fields through JSON and tolerates older sheets', () {
      const task = Task(id: 'a', title: 'x', tags: 'home, urgent', links: 'https://a.example', sortOrder: '1536.5');
      expect(Task.fromJson(task.toJson()).toJson(), task.toJson());
      final old = Task.fromJson({'id': 'b', 'title': 'x'});
      expect(old.tagList, isEmpty);
      expect(old.linkList, isEmpty);
      expect(old.order, isNull);
    });

    test('normalizes tags and drops unsafe links', () {
      expect(cleanTags(' a , b ,, '), 'a, b');
      expect(const Task(id: 'a', title: 'x', tags: 'a, b').tagList, ['a', 'b']);
      expect(cleanLinks('https://a.example\njavascript:alert(1)\n  http://b.example '), 'https://a.example\nhttp://b.example');
      expect(const Task(id: 'a', title: 'x', links: 'file:///etc/hosts\nHTTPS://c.example').linkList, ['HTTPS://c.example']);
    });

    test('places hand-ordered tasks first, then by urgency', () {
      const placed = Task(id: 'p', title: 'x', priority: TaskPriority.low, sortOrder: '2048');
      const earlier = Task(id: 'e', title: 'x', priority: TaskPriority.low, sortOrder: '1024');
      const urgent = Task(id: 'u', title: 'x', priority: TaskPriority.high);
      const relaxed = Task(id: 'r', title: 'x', priority: TaskPriority.low);
      final sorted = [relaxed, placed, urgent, earlier]..sort(compareManual);
      expect(sorted.map((t) => t.id), ['e', 'p', 'u', 'r']);
    });
  });

  group('Repeats and checklists', () {
    test('reads and writes checklist lines', () {
      final items = parseChecklist('[x] One\n[ ] Two\nnot a step\n[X] Three');
      expect(items.map((i) => i.text), ['One', 'Two', 'Three']);
      expect(items.map((i) => i.done), [true, false, true]);
      expect(formatChecklist(items), '[x] One\n[ ] Two\n[x] Three');
    });

    test('ignores repeat rules it does not know', () {
      expect(Task.fromJson({'id': 'a', 'title': 'x', 'recurrence': 'sometimes'}).recurrence, '');
      expect(Task.fromJson({'id': 'a', 'title': 'x', 'recurrence': 'weekly'}).recurrence, 'weekly');
    });

    test('uses the completion time, then falls back to the last update', () {
      const finished = Task(id: 'a', title: 'x', status: TaskStatus.done, completedAt: '2026-03-02T10:00:00', updatedAt: '2026-09-09T10:00:00');
      const older = Task(id: 'b', title: 'x', status: TaskStatus.done, updatedAt: '2026-09-09T10:00:00');
      expect(completedOn(finished), '2026-03-02');
      expect(completedOn(older), '2026-09-09');
    });
  });

  group('My day', () {
    test('counts only the pick made today, so older picks lapse', () {
      expect(Task(id: '1', title: 'a', focusDate: todayKey()).isFocus, isTrue);
      expect(Task(id: '1', title: 'a', focusDate: dayKey(-1)).isFocus, isFalse);
      expect(const Task(id: '1', title: 'a').isFocus, isFalse);
    });

    test('keeps the pick through JSON and drops values typed by hand', () {
      final task = Task.fromJson(Task(id: '1', title: 'a', focusDate: todayKey()).toJson());
      expect(task.isFocus, isTrue);
      expect(Task.fromJson({'id': '1', 'title': 'a', 'focusDate': 'today'}).focusDate, '');
      expect(Task.fromJson({'id': '1', 'title': 'a'}).focusDate, '', reason: 'older sheets have no column');
      expect(task.copyWith(focusDate: '').isFocus, isFalse);
      expect(task.copyWith(title: 'b').isFocus, isTrue);
    });
  });

  group('SetupLink', () {
    const id = 'AKfycbExampleScriptId_123-abcdefgh';
    const token = 'abcdef0123456789abcdef0123456789';

    test('reads a setup link', () {
      final link = SetupLink.parse('https://prabhagaran.github.io/taskboard/#connect=$id.$token')!;
      expect(link.url, 'https://script.google.com/macros/s/$id/exec');
      expect(link.token, token);
    });

    test('always points at Google, whatever the code says', () {
      final link = SetupLink.parse('https://evil.example/#connect=$id.$token')!;
      expect(Uri.parse(link.url).host, 'script.google.com');
    });

    test('rejects anything else', () {
      expect(SetupLink.parse('https://example.com/'), isNull);
      expect(SetupLink.parse('#connect=short.short'), isNull);
      expect(SetupLink.parse('#connect=$id.$token/../x'), isNull);
    });
  });

  group('TaskApi', () {
    test('follows the Apps Script redirect after a POST', () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.method);
        if (request.method == 'POST') {
          return http.Response('', 302, headers: {'location': 'https://script.googleusercontent.com/echo'});
        }
        return http.Response(
          jsonEncode({
            'ok': true,
            'tasks': [
              {'id': '1', 'title': 'Hello', 'status': 'done'},
            ],
          }),
          200,
        );
      });
      final data = await TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client).list();
      expect(calls, ['POST', 'GET']);
      expect(data.tasks.single.status, TaskStatus.done);
      expect(data.notes, isEmpty, reason: 'a script from before notes sends none');
      expect(data.version, 0, reason: 'old scripts send no version, so they read as out of date');
    });

    test('reads notes with their linked tasks', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode({
              'ok': true,
              'version': 3,
              'tasks': [],
              'notes': [
                {'id': 'n1', 'title': 'Plan', 'body': 'Steps', 'taskIds': 't1, t2'},
              ],
            }),
            200,
          ));
      final data = await TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client).list();
      expect(data.notes.single.taskIds, ['t1', 't2']);
      expect(data.version, 3);
    });

    test('reports the server error message', () async {
      final client = MockClient((_) async => http.Response(jsonEncode({'ok': false, 'error': 'Invalid API token.'}), 200));
      final api = TaskApi(url: 'https://script.google.com/x/exec', token: 'bad', client: client);
      await expectLater(
        api.list(),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Invalid API token.')),
      );
    });

    test('treats server outages as retryable', () async {
      final client = MockClient((_) async => http.Response('', 503));
      final api = TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client);
      await expectLater(api.list(), throwsA(isA<NetworkException>()));
    });

    test('treats a dropped connection as retryable', () async {
      final client = MockClient((_) async => throw http.ClientException('no route'));
      final api = TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client);
      await expectLater(api.list(), throwsA(isA<NetworkException>()));
    });

    test('does not retry a refusal', () async {
      final client = MockClient((_) async => http.Response(jsonEncode({'ok': false, 'error': 'Invalid API token.'}), 200));
      final api = TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client);
      await expectLater(api.list(), throwsA(isNot(isA<NetworkException>())));
    });

    test('explains an outdated Apps Script', () async {
      final client = MockClient((_) async => http.Response(jsonEncode({'ok': false, 'error': 'Unknown action: batch'}), 200));
      final api = TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client);
      await expectLater(
        api.list(),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('out of date'))),
      );
    });

    test('explains an HTML sign-in page', () async {
      final client = MockClient((_) async => http.Response('<html>Sign in</html>', 200));
      final api = TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client);
      await expectLater(api.list(), throwsA(isA<ApiException>()));
    });
  });
  group('SupabaseApi', () {
    SupabaseSession session({int expiresIn = 3600}) => SupabaseSession(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn,
          email: 'me@example.com',
        );

    test('signs in with email and password', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({
              'access_token': 'a',
              'refresh_token': 'r',
              'expires_in': 3600,
              'user': {'email': 'me@example.com'},
            }),
            200);
      });
      final s = await SupabaseApi.signIn('me@example.com', 'pw', client: client);
      expect(seen.url.path, '/auth/v1/token');
      expect(seen.url.queryParameters['grant_type'], 'password');
      expect(seen.headers['apikey'], supabaseKey);
      expect(jsonDecode(seen.body), {'email': 'me@example.com', 'password': 'pw'});
      expect(s.accessToken, 'a');
      expect(s.email, 'me@example.com');
      expect(s.expiresSoon, isFalse);
    });

    test('reports a wrong password', () async {
      final client = MockClient((_) async =>
          http.Response(jsonEncode({'error': 'invalid_grant', 'error_description': 'Invalid login credentials'}), 400));
      expect(
        () => SupabaseApi.signIn('me@example.com', 'bad', client: client),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Invalid login credentials')),
      );
    });

    test('calls the database functions with the session', () async {
      final calls = <http.Request>[];
      final client = MockClient((req) async {
        calls.add(req);
        if (req.url.path.endsWith('list_all')) {
          return http.Response(jsonEncode({'ok': true, 'version': 4, 'tasks': [], 'notes': []}), 200);
        }
        if (req.url.path.endsWith('apply_ops')) {
          return http.Response(jsonEncode({'ok': true, 'results': [{'ok': true}]}), 200);
        }
        return http.Response(jsonEncode({'ok': true, 'entries': []}), 200);
      });
      final api = SupabaseApi(session: session(), onSession: (_) async {}, client: client);
      expect((await api.list()).version, 4);
      await api.batch([{'action': 'delete', 'id': 't1'}]);
      await api.history('t1');
      expect(calls.map((c) => c.url.path), ['/rest/v1/rpc/list_all', '/rest/v1/rpc/apply_ops', '/rest/v1/rpc/task_history']);
      expect(calls.first.headers['Authorization'], 'Bearer old-access');
      expect(jsonDecode(calls[1].body)['today'], todayKey());
      expect(jsonDecode(calls[2].body), {'p_task_id': 't1'});
    });

    test('refreshes an expired session once and saves it', () async {
      SupabaseSession? saved;
      final paths = <String>[];
      final client = MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path == '/auth/v1/token') {
          return http.Response(jsonEncode({'access_token': 'new-access', 'refresh_token': 'new-refresh', 'expires_in': 3600}), 200);
        }
        if (req.headers['Authorization'] == 'Bearer old-access') return http.Response('{"message":"JWT expired"}', 401);
        return http.Response(jsonEncode({'ok': true, 'version': 4, 'tasks': [], 'notes': []}), 200);
      });
      final api = SupabaseApi(session: session(), onSession: (s) async => saved = s, client: client);
      await api.list();
      expect(paths, ['/rest/v1/rpc/list_all', '/auth/v1/token', '/rest/v1/rpc/list_all']);
      expect(saved?.refreshToken, 'new-refresh');
      expect(saved?.email, 'me@example.com', reason: 'refresh responses may omit the email');
    });

    test('asks to sign in again when the refresh is refused', () async {
      final client = MockClient((req) async => req.url.path == '/auth/v1/token'
          ? http.Response('{"error_description":"Invalid Refresh Token"}', 400)
          : http.Response('{}', 200));
      final api = SupabaseApi(session: session(expiresIn: 0), onSession: (_) async {}, client: client);
      expect(api.list(), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('Sign in again'))));
    });

    test('queues writes when Supabase is unreachable', () async {
      final client = MockClient((_) async => throw const SocketExceptionStub());
      final api = SupabaseApi(session: session(), onSession: (_) async {}, client: client);
      expect(api.batch([]), throwsA(isA<NetworkException>()));
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
