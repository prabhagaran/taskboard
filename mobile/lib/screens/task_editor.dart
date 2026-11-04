import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/task.dart';
import '../services/api.dart';
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
  late final TextEditingController _tags;
  late final TextEditingController _links;
  final _newStep = TextEditingController();
  late List<ChecklistItem> _steps;
  late String _recurrence;
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
    _tags = TextEditingController(text: task?.tags);
    _links = TextEditingController(text: task?.links);
    _steps = task?.steps ?? [];
    _recurrence = task?.recurrence ?? '';
    _status = task?.status ?? TaskStatus.todo;
    _priority = task?.priority ?? TaskPriority.medium;
    _dueDate = task?.dueDate ?? widget.initialDueDate;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _project.dispose();
    _tags.dispose();
    _links.dispose();
    _newStep.dispose();
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

  void _addStep() {
    final text = _newStep.text.trim();
    if (text.isEmpty) return;
    setState(() => _steps.add(ChecklistItem(text: text)));
    _newStep.clear();
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
      tags: cleanTags(_tags.text),
      links: cleanLinks(_links.text),
      recurrence: _recurrence,
      checklist: formatChecklist(_steps),
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

  Future<void> _openLink(String link) async {
    final opened = await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    if (!opened) showMessage('Could not open that link.');
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final projects = store.projects;
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
          padding: EdgeInsets.symmetric(
            horizontal: max(16, (MediaQuery.sizeOf(context).width - 640) / 2),
            vertical: 16,
          ),
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
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _recurrence,
              decoration: const InputDecoration(
                labelText: 'Repeats',
                prefixIcon: Icon(Icons.repeat),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('Never')),
                for (final rule in recurrenceLabels.entries)
                  DropdownMenuItem(value: rule.key, child: Text(rule.value)),
              ],
              onChanged: (value) => setState(() => _recurrence = value ?? ''),
            ),
            const SizedBox(height: 20),
            Text(
              _steps.isEmpty
                  ? 'Checklist'
                  : 'Checklist (${_steps.where((s) => s.done).length} of ${_steps.length})',
              style: label,
            ),
            for (final (i, step) in _steps.indexed)
              CheckboxListTile(
                key: ObjectKey(step),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: step.done,
                title: Text(step.text),
                secondary: IconButton(
                  tooltip: 'Remove step',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => setState(() => _steps.removeAt(i)),
                ),
                onChanged: (value) => setState(() => step.done = value ?? false),
              ),
            TextField(
              controller: _newStep,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addStep(),
              decoration: InputDecoration(
                hintText: 'Add a step',
                suffixIcon: IconButton(
                  tooltip: 'Add step',
                  icon: const Icon(Icons.add),
                  onPressed: _addStep,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Tags',
                hintText: 'home, urgent',
                prefixIcon: Icon(Icons.sell_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _links,
              minLines: 2,
              maxLines: 6,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Links',
                hintText: 'One https:// link per line',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            for (final link in widget.task?.linkList ?? const <String>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.open_in_new, size: 20),
                title: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _openLink(link),
              ),
            if (!_isNew)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 12),
                expandedAlignment: Alignment.centerLeft,
                title: const Text('History'),
                children: [_HistoryList(load: () => store.history(widget.task!.id))],
              ),
          ],
        ),
      ),
    );
  }
}

/// Loads a task's change log when its panel is first opened.
class _HistoryList extends StatefulWidget {
  const _HistoryList({required this.load});

  final Future<List<HistoryEntry>> Function() load;

  @override
  State<_HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<_HistoryList> {
  late final Future<List<HistoryEntry>> _entries = widget.load();

  String _timestamp(String at) {
    final time = DateTime.tryParse(at)?.toLocal();
    if (time == null) return at;
    final clock = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return '${shortDate(dateKey(time))}, $clock';
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return FutureBuilder<List<HistoryEntry>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error;
          return Text(error is ApiException ? error.message : 'Could not load history.', style: muted);
        }
        final entries = snapshot.data;
        if (entries == null) return const LinearProgressIndicator();
        if (entries.isEmpty) return Text('No changes recorded yet.', style: muted);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.details.isEmpty ? entry.action : '${entry.action}: ${entry.details}'),
                    Text(_timestamp(entry.at), style: muted),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
