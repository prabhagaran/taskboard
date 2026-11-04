import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _search = TextEditingController();
  bool _searching = false;
  String _project = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Task> _filtered(TaskStore store) {
    final q = _search.text.trim().toLowerCase();
    return store.tasks.where((t) {
      if (_project.isNotEmpty && t.project != _project) return false;
      if (q.isEmpty) return true;
      return '${t.title} ${t.description} ${t.project}'.toLowerCase().contains(q);
    }).toList()
      ..sort(compareTasks);
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final projects = store.projects;
    // A filtered project can vanish after a delete or a sheet edit.
    if (_project.isNotEmpty && !projects.contains(_project)) _project = '';
    final tasks = _filtered(store);
    final byStatus = {
      for (final s in TaskStatus.values) s: tasks.where((t) => t.status == s).toList(),
    };

    return DefaultTabController(
      length: TaskStatus.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search tasks', border: InputBorder.none),
                  onChanged: (_) => setState(() {}),
                )
              : Text(_project.isEmpty ? 'Tasks' : _project),
          actions: [
            IconButton(
              tooltip: _searching ? 'Close search' : 'Search',
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () => setState(() {
                _searching = !_searching;
                _search.clear();
              }),
            ),
            PopupMenuButton<String>(
              tooltip: 'Filter by project',
              icon: Icon(_project.isEmpty ? Icons.filter_list : Icons.filter_list_alt),
              initialValue: _project,
              onSelected: (value) => setState(() => _project = value),
              itemBuilder: (_) => [
                const PopupMenuItem(value: '', child: Text('All projects')),
                for (final p in projects) PopupMenuItem(value: p, child: Text(p)),
              ],
            ),
          ],
          bottom: TabBar(
            tabs: [
              for (final s in TaskStatus.values) Tab(text: '${s.label} (${byStatus[s]!.length})'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: 'New task',
          onPressed: () => openEditor(context),
          child: const Icon(Icons.add),
        ),
        body: Column(
          children: [
            const SyncErrorBar(),
            Expanded(
              child: TabBarView(
                children: [
                  for (final s in TaskStatus.values)
                    RefreshIndicator(
                      onRefresh: store.refresh,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 96),
                        children: [
                          if (byStatus[s]!.isEmpty)
                            EmptyState(
                              icon: Icons.inbox_outlined,
                              title: 'No tasks',
                              message: store.syncing
                                  ? 'Loading from Google Sheets…'
                                  : 'Nothing in ${s.label} right now.',
                            ),
                          for (final task in byStatus[s]!) TaskTile(task: task),
                        ],
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
