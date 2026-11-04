import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final today = todayKey();
    final weekEnd = dayKey(7);
    final open = store.tasks.where((t) => t.isOpen && t.dueDate.isNotEmpty).toList()
      ..sort(compareTasks);
    final overdue = open.where((t) => t.isOverdue).toList();
    final dueToday = open.where((t) => t.dueDate == today).toList();
    final upcoming = open
        .where((t) => t.dueDate.compareTo(today) > 0 && t.dueDate.compareTo(weekEnd) <= 0)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New task',
        onPressed: () => openEditor(context, dueDate: today),
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
                  if (overdue.isEmpty && dueToday.isEmpty && upcoming.isEmpty)
                    const EmptyState(
                      icon: Icons.task_alt,
                      title: 'All clear',
                      message: 'Nothing is due in the next 7 days.',
                    ),
                  ..._section(context, 'Overdue', overdue),
                  ..._section(context, 'Today', dueToday),
                  ..._section(context, 'Next 7 days', upcoming),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _section(BuildContext context, String title, List<Task> tasks) {
    if (tasks.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          '$title (${tasks.length})',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      ),
      for (final task in tasks) TaskTile(task: task),
    ];
  }
}
