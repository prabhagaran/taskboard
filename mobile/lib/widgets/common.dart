import 'package:flutter/material.dart';

import '../models/task.dart';
import '../screens/task_editor.dart';
import '../services/store.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();

void showMessage(String message) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Chart and status identity colors, stepped separately for each theme.
Color statusColor(BuildContext context, TaskStatus status) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (status) {
    TaskStatus.todo => dark ? const Color(0xFF3987E5) : const Color(0xFF2A78D6),
    TaskStatus.inprogress => dark ? const Color(0xFFD95926) : const Color(0xFFEB6834),
    TaskStatus.done => dark ? const Color(0xFF199E70) : const Color(0xFF1BAF7A),
  };
}

Color priorityColor(BuildContext context, TaskPriority priority) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (priority) {
    TaskPriority.high => dark ? const Color(0xFFF07070) : const Color(0xFFC62828),
    TaskPriority.medium => dark ? const Color(0xFFFDB022) : const Color(0xFFB54708),
    TaskPriority.low => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String shortDate(String key) {
  final parts = key.split('-').map(int.parse).toList();
  final label = '${_months[parts[1] - 1]} ${parts[2]}';
  return parts[0] == DateTime.now().year ? label : '$label, ${parts[0]}';
}

String dueLabel(String key) {
  if (key == todayKey()) return 'Today';
  if (key == dayKey(1)) return 'Tomorrow';
  if (key == dayKey(-1)) return 'Yesterday';
  return shortDate(key);
}

Future<void> openEditor(BuildContext context, {Task? task, String dueDate = ''}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: task == null,
        builder: (_) => TaskEditor(task: task, initialDueDate: dueDate),
      ),
    );

/// Deletes [task] and offers an undo.
void deleteWithUndo(TaskStore store, Task task) {
  store.remove(task);
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Deleted "${task.title}"'),
        duration: const Duration(seconds: 5),
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: () => store.add(task)),
      ),
    );
}

class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final done = task.status == TaskStatus.done;

    return Dismissible(
      key: ValueKey(task.id),
      background: _SwipeBackground(
        color: statusColor(context, TaskStatus.done),
        icon: done ? Icons.undo : Icons.check,
        label: done ? 'Reopen' : 'Done',
        alignment: Alignment.centerLeft,
      ),
      secondaryBackground: _SwipeBackground(
        color: scheme.error,
        icon: Icons.delete_outline,
        label: 'Delete',
        alignment: Alignment.centerRight,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) return true;
        store.setDone(task, !done);
        return false; // The tile moves lists on its own once the status changes.
      },
      onDismissed: (_) => deleteWithUndo(store, task),
      child: ListTile(
        onTap: () => openEditor(context, task: task),
        contentPadding: const EdgeInsets.only(left: 8, right: 16),
        leading: Checkbox(
          value: done,
          onChanged: (value) => store.setDone(task, value ?? false),
        ),
        title: Text(
          task.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.bodyLarge?.copyWith(
            fontWeight: FontWeight.w500,
            decoration: done ? TextDecoration.lineThrough : null,
            color: done ? scheme.onSurfaceVariant : null,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Meta(
                icon: Icons.flag_outlined,
                label: task.priority.label,
                color: priorityColor(context, task.priority),
              ),
              if (task.dueDate.isNotEmpty)
                _Meta(
                  icon: task.isOverdue ? Icons.error_outline : Icons.event_outlined,
                  label: task.isOverdue
                      ? 'Overdue · ${dueLabel(task.dueDate)}'
                      : dueLabel(task.dueDate),
                  color: task.isOverdue ? priorityColor(context, TaskPriority.high) : null,
                ),
              if (task.project.isNotEmpty)
                _Meta(icon: Icons.folder_outlined, label: task.project),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: tint),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tint),
          ),
        ),
      ],
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.color,
    required this.icon,
    required this.label,
    required this.alignment,
  });

  final Color color;
  final IconData icon;
  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      child: Column(
        children: [
          Icon(icon, size: 48, color: scheme.primary),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Thin strip shown under the app bar while the last sync is failing.
class SyncErrorBar extends StatelessWidget {
  const SyncErrorBar({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final error = store.syncError;
    if (error == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: InkWell(
        onTap: store.refresh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Showing saved tasks. $error Tap to retry.',
                  style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
