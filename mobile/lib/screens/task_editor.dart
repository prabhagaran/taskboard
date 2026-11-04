import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

class TaskEditor extends StatefulWidget {
  const TaskEditor({super.key, this.task, this.initialDueDate = ''});

  /// The task being edited, or null when creating one.
  final Task? task;
  final String initialDueDate;

  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _project;
  late TaskStatus _status;
  late TaskPriority _priority;
  late String _dueDate;
  bool _titleMissing = false;

  bool get _isNew => widget.task == null;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title = TextEditingController(text: task?.title);
    _description = TextEditingController(text: task?.description);
    _project = TextEditingController(text: task?.project);
    _status = task?.status ?? TaskStatus.todo;
    _priority = task?.priority ?? TaskPriority.medium;
    _dueDate = task?.dueDate ?? widget.initialDueDate;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _project.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final current = DateTime.tryParse(_dueDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) setState(() => _dueDate = dateKey(picked));
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleMissing = true);
      return;
    }
    final store = StoreScope.of(context);
    final base = widget.task ?? Task(id: TaskStore.newId(), title: title);
    final task = base.copyWith(
      title: title,
      description: _description.text.trim(),
      status: _status,
      priority: _priority,
      project: _project.text.trim(),
      dueDate: _dueDate,
    );
    if (_isNew) {
      store.add(task);
    } else {
      store.edit(task);
    }
    Navigator.of(context).pop();
  }

  void _delete() {
    deleteWithUndo(StoreScope.of(context), widget.task!);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final projects = StoreScope.of(context).projects;
    final label = Theme.of(context).textTheme.labelLarge;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New task' : 'Edit task'),
        actions: [
          if (!_isNew)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          TextButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _title,
              autofocus: _isNew,
              maxLength: 500,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              style: Theme.of(context).textTheme.titleLarge,
              onChanged: (_) {
                if (_titleMissing) setState(() => _titleMissing = false);
              },
              decoration: InputDecoration(
                hintText: 'Task title',
                counterText: '',
                errorText: _titleMissing ? 'Enter a title' : null,
              ),
            ),
            const SizedBox(height: 20),
            Text('Status', style: label),
            const SizedBox(height: 8),
            SegmentedButton<TaskStatus>(
              showSelectedIcon: false,
              segments: [
                for (final s in TaskStatus.values) ButtonSegment(value: s, label: Text(s.label)),
              ],
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
            const SizedBox(height: 20),
            Text('Priority', style: label),
            const SizedBox(height: 8),
            SegmentedButton<TaskPriority>(
              showSelectedIcon: false,
              segments: [
                for (final p in TaskPriority.values) ButtonSegment(value: p, label: Text(p.label)),
              ],
              selected: {_priority},
              onSelectionChanged: (s) => setState(() => _priority = s.first),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _project,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Project',
                prefixIcon: Icon(Icons.folder_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            if (projects.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final p in projects)
                      ActionChip(label: Text(p), onPressed: () => _project.text = p),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Due date',
                prefixIcon: Icon(Icons.event_outlined),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                      onPressed: _pickDate,
                      child: Text(_dueDate.isEmpty ? 'Pick a date' : dueLabel(_dueDate)),
                    ),
                  ),
                  if (_dueDate.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear due date',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _dueDate = ''),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _description,
              minLines: 4,
              maxLines: 12,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
