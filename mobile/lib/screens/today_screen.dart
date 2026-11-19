import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';
import 'plan_day_screen.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final today = todayKey();
    final weekEnd = dayKey(7);
    // Picks done today stay listed, struck through, to show progress.
    final focus = store.tasks.where((t) => t.isFocus).toList()
      ..sort((a, b) => a.isOpen == b.isOpen ? compareTasks(a, b) : (a.isOpen ? -1 : 1));
    final focusDone = focus.where((t) => !t.isOpen).length;
    final open = store.tasks.where((t) => t.isOpen && !t.isFocus && t.dueDate.isNotEmpty).toList()..sort(compareTasks);
    final overdue = open.where((t) => t.isOverdue).toList();
    final dueToday = open.where((t) => t.dueDate == today).toList();
    final upcoming = open.where((t) => t.dueDate.compareTo(today) > 0 && t.dueDate.compareTo(weekEnd) <= 0).toList();
    final others = [
      ..._section(context, 'Overdue', overdue),
      ..._section(context, 'Due today', dueToday),
      ..._section(context, 'Next 7 days', upcoming),
    ];
    final otherCount = overdue.length + dueToday.length + upcoming.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          IconButton(
            tooltip: 'Plan my day',
            icon: const Icon(Icons.wb_sunny_outlined),
            onPressed: () => openPlanDay(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New task',
        onPressed: () => openEditor(context, dueDate: today, focus: true),
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
                  if (focus.isEmpty)
                    _PlanPrompt(onPlan: () => openPlanDay(context))
                  else ...[
                    _header(
                      context,
                      'My day · $focusDone of ${focus.length} done',
                      trailing: TextButton(onPressed: () => openPlanDay(context), child: const Text('Edit')),
                    ),
                    for (final task in focus) TaskTile(task: task),
                  ],
                  if (focus.isEmpty) ...others,
                  // Once the day is planned, everything else folds away.
                  if (focus.isNotEmpty && otherCount > 0)
                    ExpansionTile(
                      title: Text('Other due tasks ($otherCount)'),
                      shape: const Border(),
                      collapsedShape: const Border(),
                      children: others,
                    ),
                  if (focus.isEmpty && otherCount == 0)
                    const EmptyState(
                      icon: Icons.task_alt,
                      title: 'All clear',
                      message: 'Nothing is due in the next 7 days.',
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String title, {Widget? trailing}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, trailing == null ? 16 : 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  List<Widget> _section(BuildContext context, String title, List<Task> tasks) {
    if (tasks.isEmpty) return const [];
    return [_header(context, '$title (${tasks.length})'), for (final task in tasks) TaskTile(task: task)];
  }
}

class _PlanPrompt extends StatelessWidget {
  const _PlanPrompt({required this.onPlan});

  final VoidCallback onPlan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      color: scheme.secondaryContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.wb_sunny_outlined, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Pick the tasks you\'ll work on today.',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
            FilledButton.tonal(onPressed: onPlan, child: const Text('Plan my day')),
          ],
        ),
      ),
    );
  }
}
