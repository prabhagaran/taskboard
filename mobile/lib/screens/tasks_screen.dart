import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

/// Width at which the three status lists fit side by side.
const _boardWidth = 900.0;

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _search = TextEditingController();
  bool _searching = false;
  String _project = '';
  String _tag = '';

  bool get _filtered => _search.text.trim().isNotEmpty || _project.isNotEmpty || _tag.isNotEmpty;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Task> _visible(TaskStore store) {
    final q = _search.text.trim().toLowerCase();
    return store.tasks.where((t) {
      if (_project.isNotEmpty && t.project != _project) return false;
      if (_tag.isNotEmpty && !t.tagList.contains(_tag)) return false;
      if (q.isEmpty) return true;
      return '${t.title} ${t.description} ${t.project} ${t.tags}'.toLowerCase().contains(q);
    }).toList()
      ..sort(compareManual);
  }

  void _apply(SavedFilter filter) => setState(() {
        _project = filter.project;
        _tag = filter.tag;
        _search.text = filter.query;
        _searching = filter.query.isNotEmpty;
      });

  Future<void> _saveCurrentFilter(TaskStore store) async {
    final name = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save filter'),
        content: TextField(
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final label = name.text.trim();
    name.dispose();
    if (saved != true || label.isEmpty) return;
    store.saveFilter(SavedFilter(
      name: label,
      query: _search.text.trim(),
      project: _project,
      tag: _tag,
    ));
  }

  void _openFilters(TaskStore store) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          void update(VoidCallback change) {
            setState(change);
            setSheet(() {});
          }

          final text = Theme.of(sheetContext).textTheme;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (store.savedFilters.isNotEmpty) ...[
                    Text('Saved filters', style: text.titleSmall),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final filter in store.savedFilters)
                          InputChip(
                            avatar: const Icon(Icons.bookmark_outline, size: 18),
                            label: Text(filter.name),
                            onPressed: () {
                              _apply(filter);
                              Navigator.pop(sheetContext);
                            },
                            onDeleted: () {
                              store.removeFilter(filter);
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text('Project', style: text.titleSmall),
                  const SizedBox(height: 4),
                  _choices(store.projects, _project, (value) => update(() => _project = value)),
                  const SizedBox(height: 16),
                  Text('Tag', style: text.titleSmall),
                  const SizedBox(height: 4),
                  _choices(store.allTags, _tag, (value) => update(() => _tag = value)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _filtered
                            ? () => update(() {
                                  _project = '';
                                  _tag = '';
                                  _search.clear();
                                  _searching = false;
                                })
                            : null,
                        child: const Text('Clear'),
                      ),
                      const Spacer(),
                      OutlinedButton.icon(
                        onPressed: _filtered
                            ? () async {
                                await _saveCurrentFilter(store);
                                setSheet(() {});
                              }
                            : null,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('Save filter'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _choices(List<String> options, String selected, ValueChanged<String> onSelected) {
    if (options.isEmpty) return const Text('None yet');
    return Wrap(
      spacing: 8,
      children: [
        ChoiceChip(
          label: const Text('Any'),
          selected: selected.isEmpty,
          onSelected: (_) => onSelected(''),
        ),
        for (final option in options)
          ChoiceChip(
            label: Text(option),
            selected: selected == option,
            onSelected: (_) => onSelected(option),
          ),
      ],
    );
  }

  Widget _list(TaskStore store, TaskStatus status, List<Task> tasks) {
    const physics = AlwaysScrollableScrollPhysics();
    const padding = EdgeInsets.only(bottom: 96);
    final Widget list;
    if (tasks.isEmpty) {
      list = ListView(
        physics: physics,
        children: [
          EmptyState(
            icon: Icons.inbox_outlined,
            title: 'No tasks',
            message: store.syncing ? 'Loading from Google Sheets…' : 'Nothing in ${status.label} right now.',
          ),
        ],
      );
    } else if (_filtered) {
      // A filtered list hides neighbours, so a position set here would be misleading.
      list = ListView(
        physics: physics,
        padding: padding,
        children: [for (final task in tasks) TaskTile(task: task)],
      );
    } else {
      list = ReorderableListView.builder(
        physics: physics,
        padding: padding,
        itemCount: tasks.length,
        onReorderItem: (from, to) => store.reorder(tasks, from, to),
        itemBuilder: (_, i) => TaskTile(key: ValueKey('row-${tasks[i].id}'), task: tasks[i]),
      );
    }
    return RefreshIndicator(onRefresh: store.refresh, child: list);
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    // A filtered project or tag can vanish after a delete or a sheet edit.
    if (_project.isNotEmpty && !store.projects.contains(_project)) _project = '';
    if (_tag.isNotEmpty && !store.allTags.contains(_tag)) _tag = '';

    final tasks = _visible(store);
    final byStatus = {
      for (final s in TaskStatus.values) s: tasks.where((t) => t.status == s).toList(),
    };
    final wide = MediaQuery.sizeOf(context).width >= _boardWidth;
    final title = [_project, _tag].where((v) => v.isNotEmpty).join(' · ');

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
              : Text(title.isEmpty ? 'Tasks' : title),
          actions: [
            IconButton(
              tooltip: _searching ? 'Close search' : 'Search',
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () => setState(() {
                _searching = !_searching;
                _search.clear();
              }),
            ),
            IconButton(
              tooltip: 'Filters',
              isSelected: _filtered,
              icon: const Icon(Icons.filter_list),
              selectedIcon: const Icon(Icons.filter_list_alt),
              onPressed: () => _openFilters(store),
            ),
          ],
          bottom: wide
              ? null
              : TabBar(
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
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final s in TaskStatus.values)
                          Expanded(child: _boardColumn(context, store, s, byStatus[s]!)),
                      ],
                    )
                  : TabBarView(
                      children: [
                        for (final s in TaskStatus.values) _list(store, s, byStatus[s]!),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _boardColumn(BuildContext context, TaskStore store, TaskStatus status, List<Task> tasks) {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: statusColor(context, status), shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text('${status.label} (${tasks.length})', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
          Expanded(child: _list(store, status, tasks)),
        ],
      ),
    );
  }
}
