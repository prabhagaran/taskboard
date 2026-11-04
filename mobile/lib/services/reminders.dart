import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/task.dart';

const _notifyHour = 9;
const _maxScheduled = 30;

/// Phone notifications for due dates, one per day that has tasks due.
class Reminders {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    final zone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zone.identifier));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _ready = true;
  }

  /// Returns whether the user allowed notifications.
  Future<bool> requestPermission() async {
    await _init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? false;
  }

  Future<void> cancelAll() async {
    await _init();
    await _plugin.cancelAll();
  }

  /// Replaces all scheduled notifications to match [tasks].
  Future<void> schedule(List<Task> tasks) async {
    await _init();
    await _plugin.cancelAll();
    final dueOn = <String, int>{};
    for (final task in tasks.where((t) => t.isOpen && t.dueDate.isNotEmpty)) {
      dueOn[task.dueDate] = (dueOn[task.dueDate] ?? 0) + 1;
    }
    final now = tz.TZDateTime.now(tz.local);
    final days = dueOn.keys.toList()..sort();
    var id = 0;
    for (final day in days) {
      final parts = day.split('-').map(int.parse).toList();
      final when = tz.TZDateTime(tz.local, parts[0], parts[1], parts[2], _notifyHour);
      if (when.isBefore(now)) continue;
      if (id == _maxScheduled) break;
      final count = dueOn[day]!;
      await _plugin.zonedSchedule(
        id: id++,
        scheduledDate: when,
        title: '$count task${count == 1 ? '' : 's'} due today',
        body: 'Open TaskBoard to see what needs doing.',
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'due-tasks',
            'Due tasks',
            channelDescription: 'Reminders on the day tasks are due',
          ),
        ),
      );
    }
  }
}
