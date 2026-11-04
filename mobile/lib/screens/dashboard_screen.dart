import 'dart:math';

import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final tasks = store.tasks;
    final open = tasks.where((t) => t.isOpen).toList();
    final weekStart = dayKey(-6);
    final doneThisWeek = tasks.where((t) {
      final day = completedOn(t);
      return day.isNotEmpty && day.compareTo(weekStart) >= 0;
    }).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: Column(
        children: [
          const SyncErrorBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: store.refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      _Kpi(label: 'Open', value: open.length),
                      const SizedBox(width: 12),
                      _Kpi(
                        label: 'Due today',
                        value: open.where((t) => t.dueDate == todayKey()).length,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _Kpi(
                        label: 'Overdue',
                        value: open.where((t) => t.isOverdue).length,
                        alert: true,
                      ),
                      const SizedBox(width: 12),
                      _Kpi(label: 'Done, last 7 days', value: doneThisWeek),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Panel(title: 'Completed per day, last 14 days', child: _CompletionChart(tasks: tasks)),
                  const SizedBox(height: 16),
                  _Panel(title: 'Open by priority', child: _PriorityBars(open: open)),
                  const SizedBox(height: 16),
                  _Panel(title: 'Workload by project', child: _ProjectBars(tasks: tasks)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.alert = false});

  final String label;
  final int value;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final highlight = alert && value > 0;
    return Expanded(
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: text.bodyMedium),
              const SizedBox(height: 4),
              Text(
                '$value',
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: highlight ? priorityColor(context, TaskPriority.high) : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _CompletionChart extends StatelessWidget {
  const _CompletionChart({required this.tasks});

  final List<Task> tasks;

  @override
  Widget build(BuildContext context) {
    final days = List.generate(14, (i) => dayKey(i - 13));
    final counts = {for (final d in days) d: 0};
    for (final task in tasks) {
      final day = completedOn(task);
      if (counts.containsKey(day)) counts[day] = counts[day]! + 1;
    }
    final peak = max(1, counts.values.reduce(max));
    final color = statusColor(context, TaskStatus.todo);
    final label = Theme.of(context).textTheme.labelSmall;

    return SizedBox(
      height: 130,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final day in days)
            Expanded(
              child: Tooltip(
                message: '${shortDate(day)}: ${counts[day]} completed',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (counts[day]! > 0) Text('${counts[day]}', style: label),
                      const SizedBox(height: 2),
                      Container(
                        height: 88 * counts[day]! / peak,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                      Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                      const SizedBox(height: 4),
                      Text(day.substring(8), style: label),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PriorityBars extends StatelessWidget {
  const _PriorityBars({required this.open});

  final List<Task> open;

  @override
  Widget build(BuildContext context) {
    final counts = {
      for (final p in TaskPriority.values) p: open.where((t) => t.priority == p).length,
    };
    final peak = max(1, counts.values.reduce(max));
    final color = statusColor(context, TaskStatus.todo);
    return Column(
      children: [
        for (final p in TaskPriority.values)
          _BarRow(
            label: p.label,
            total: counts[p]!,
            segments: [(counts[p]! / peak, color)],
          ),
      ],
    );
  }
}

class _ProjectBars extends StatelessWidget {
  const _ProjectBars({required this.tasks});

  final List<Task> tasks;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) return const Text('No tasks yet');
    final groups = <String, List<Task>>{};
    for (final task in tasks) {
      groups.putIfAbsent(task.project.isEmpty ? 'No project' : task.project, () => []).add(task);
    }
    final rows = groups.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final peak = rows.first.value.length;
    final shown = rows.take(8);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          children: [
            for (final s in TaskStatus.values)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: statusColor(context, s),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(s.label, style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        for (final row in shown)
          _BarRow(
            label: row.key,
            total: row.value.length,
            segments: [
              for (final s in TaskStatus.values)
                (
                  row.value.where((t) => t.status == s).length / peak,
                  statusColor(context, s),
                ),
            ],
          ),
      ],
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({required this.label, required this.total, required this.segments});

  final String label;
  final int total;

  /// Share of the track (0 to 1) and color for each stacked segment.
  final List<(double, Color)> segments;

  @override
  Widget build(BuildContext context) {
    final filled = segments.fold<double>(0, (sum, s) => sum + s.$1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 12,
                child: Row(
                  children: [
                    for (final (share, color) in segments)
                      if (share > 0)
                        Expanded(
                          flex: (share * 1000).round(),
                          child: Container(
                            margin: const EdgeInsets.only(right: 2),
                            color: color,
                          ),
                        ),
                    if (filled < 1) Spacer(flex: ((1 - filled) * 1000).round()),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$total',
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
