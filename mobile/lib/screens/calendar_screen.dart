import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

const _weekdays = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];
const _maxDots = 3;

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month;
  String _selected = todayKey();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  void _shiftMonth(int by) =>
      setState(() => _month = DateTime(_month.year, _month.month + by));

  void _goToToday() {
    final now = DateTime.now();
    setState(() {
      _month = DateTime(now.year, now.month);
      _selected = todayKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final byDay = <String, List<Task>>{};
    for (final task in store.tasks.where((t) => t.dueDate.isNotEmpty)) {
      byDay.putIfAbsent(task.dueDate, () => []).add(task);
    }
    final selectedTasks = [...?byDay[_selected]]..sort(compareTasks);
    final first = DateTime(_month.year, _month.month, 1 - _month.weekday % 7);

    return Scaffold(
      appBar: AppBar(
        title: Text('${_monthNames[_month.month - 1]} ${_month.year}'),
        actions: [
          IconButton(tooltip: 'Today', icon: const Icon(Icons.today), onPressed: _goToToday),
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftMonth(-1),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _shiftMonth(1),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New task',
        onPressed: () => openEditor(context, dueDate: _selected),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          const SyncErrorBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: store.refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: _monthGrid(context, first, byDay),
                      ),
                    ),
                  ),
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      '${dueLabel(_selected)} (${selectedTasks.length})',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ),
                  if (selectedTasks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Nothing due. Tap + to add a task for this day.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  for (final task in selectedTasks) TaskTile(task: task),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _monthGrid(BuildContext context, DateTime first, Map<String, List<Task>> byDay) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final today = todayKey();

    return Column(
      children: [
        Row(
          children: [
            for (final day in _weekdays)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(day, style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                ),
              ),
          ],
        ),
        GridView.count(
          crossAxisCount: DateTime.daysPerWeek,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < 42; i++) _dayCell(context, DateTime(first.year, first.month, first.day + i), byDay, today),
          ],
        ),
      ],
    );
  }

  Widget _dayCell(BuildContext context, DateTime day, Map<String, List<Task>> byDay, String today) {
    final scheme = Theme.of(context).colorScheme;
    final key = dateKey(day);
    final inMonth = day.month == _month.month;
    final selected = key == _selected;
    final items = byDay[key] ?? const <Task>[];
    final count = items.length;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _selected = key),
      child: Semantics(
        label: '${dueLabel(key)}, $count task${count == 1 ? '' : 's'}',
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? scheme.primary : null,
                border: key == today && !selected ? Border.all(color: scheme.primary) : null,
              ),
              child: Text(
                '${day.day}',
                style: TextStyle(
                  fontWeight: key == today ? FontWeight.w700 : null,
                  color: selected
                      ? scheme.onPrimary
                      : inMonth
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant.withValues(alpha: 0.55),
                ),
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: 6,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final task in items.take(_maxDots))
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor(context, task.status),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
