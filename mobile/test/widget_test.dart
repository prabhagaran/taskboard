import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taskboard/models/task.dart';
import 'package:taskboard/services/api.dart';

void main() {
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
      final tasks = await TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client).list();
      expect(calls, ['POST', 'GET']);
      expect(tasks.single.status, TaskStatus.done);
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
}
