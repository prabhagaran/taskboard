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
        status: TaskStatus.inprogress,
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

    test('is overdue only while open and past due', () {
      expect(Task(id: 'a', title: 'x', dueDate: dayKey(-1)).isOverdue, isTrue);
      expect(Task(id: 'a', title: 'x', dueDate: dayKey(0)).isOverdue, isFalse);
      expect(Task(id: 'a', title: 'x', dueDate: dayKey(-1), status: TaskStatus.done).isOverdue, isFalse);
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

    test('explains an HTML sign-in page', () async {
      final client = MockClient((_) async => http.Response('<html>Sign in</html>', 200));
      final api = TaskApi(url: 'https://script.google.com/x/exec', token: 't', client: client);
      await expectLater(api.list(), throwsA(isA<ApiException>()));
    });
  });
}
