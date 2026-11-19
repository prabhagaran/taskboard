import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

Future<void> openPlanDay(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const PlanDayScreen()));

/// Picks the open tasks to work on today, without changing their due dates.
class PlanDayScreen extends StatefulWidget {
  const PlanDayScreen({super.key});

  @override
  State<PlanDayScreen> createState() => _PlanDayScreenState();
}

class _PlanDayScreenState extends State<PlanDayScreen> {
  final _search = TextEditingController();
  Set<String>? _picks;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _picks ??= StoreScope.of(context).tasks.where((t) => t.isOpen && t.isFocus).map((t) => t.id).toSet();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _save() {
    final store = StoreScope.of(context);
    final picks = _picks!;
    store.planDay(picks);
    Navigator.of(context).pop();
    showMessage('My day: ${picks.length} task${picks.length == 1 ? '' : 's'}');
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final picks = _picks!;
    final today = todayKey();
    final q = _search.text.trim().toLowerCase();
    final open =
        store.tasks
            .where((t) => t.isOpen)
            .where((t) => q.isEmpty || '${t.title} ${t.project} ${t.tags}'.toLowerCase().contains(q))
            .toList()
          ..sort(compareTasks);
    bool due(Task t) => t.dueDate.isNotEmpty && t.dueDate.compareTo(today) <= 0;
    final suggested = open.where(due).toList();
    final rest = open.where((t) => !due(t)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Plan my day · ${picks.length}'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search tasks',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: open.isEmpty
                ? EmptyState(
                    icon: Icons.search_off,
                    title: q.isEmpty ? 'No open tasks' : 'No matching tasks',
                    message: q.isEmpty ? 'Add a task first.' : 'Try a different search.',
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      ..._group(context, 'Due today or overdue', suggested, picks),
                      ..._group(context, 'Other open tasks', rest, picks),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _group(BuildContext context, String title, List<Task> tasks, Set<String> picks) {
    if (tasks.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          '$title (${tasks.length})',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      ),
      for (final task in tasks)
        CheckboxListTile(
          controlAffinity: ListTileControlAffinity.leading,
          value: picks.contains(task.id),
          onChanged: (on) => setState(() => on == true ? picks.add(task.id) : picks.remove(task.id)),
          title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              task.priority.label,
              if (task.dueDate.isNotEmpty)
                task.isOverdue ? 'Overdue · ${dueLabel(task.dueDate)}' : dueLabel(task.dueDate),
              if (task.project.isNotEmpty) task.project,
            ].join(' · '),
          ),
        ),
    ];
  }
}
