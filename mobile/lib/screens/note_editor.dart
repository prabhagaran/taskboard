import 'dart:math';

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, this.note, this.taskIds = const []});

  /// The note being edited, or null when creating one.
  final Note? note;

  /// Tasks a new note starts linked to.
  final List<String> taskIds;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late List<String> _taskIds;
  bool _empty = false;

  bool get _isNew => widget.note == null;

  bool get _changed {
    final note = widget.note;
    final ids = note?.taskIds ?? widget.taskIds;
    return _title.text.trim() != (note?.title ?? '') ||
        _body.text.trimRight() != (note?.body ?? '') ||
        _taskIds.join(',') != ids.join(',');
  }

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.note?.title);
    _body = TextEditingController(text: widget.note?.body);
    _taskIds = [...(widget.note?.taskIds ?? widget.taskIds)];
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    final body = _body.text.trimRight();
    if (title.isEmpty && body.trim().isEmpty) {
      setState(() => _empty = true);
      return;
    }
    final store = StoreScope.of(context);
    final base =
        widget.note ??
        Note(
          id: TaskStore.newId(),
          createdAt: DateTime.now().toUtc().toIso8601String(),
        );
    final note = base.copyWith(title: title, body: body, taskIds: _taskIds);
    if (_isNew) {
      store.addNote(note);
    } else {
      store.editNote(note);
    }
    Navigator.of(context).pop();
  }

  void _delete() {
    deleteNoteWithUndo(StoreScope.of(context), widget.note!);
    Navigator.of(context).pop();
  }

  Future<void> _linkTask() async {
    final task = await pickTask(context, exclude: _taskIds);
    if (task != null) setState(() => _taskIds.add(task.id));
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your changes to this note haven\'t been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final linked = [
      for (final id in _taskIds) ...store.tasks.where((t) => t.id == id),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (!_changed || await _confirmDiscard()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New note' : 'Note'),
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
                maxLength: 500,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                style: Theme.of(context).textTheme.titleLarge,
                decoration: const InputDecoration(
                  hintText: 'Title',
                  counterText: '',
                  border: InputBorder.none,
                ),
              ),
              TextField(
                controller: _body,
                autofocus: _isNew,
                minLines: 8,
                maxLines: null,
                maxLength: 40000,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) {
                  if (_empty) setState(() => _empty = false);
                },
                decoration: InputDecoration(
                  hintText: 'Write your note…',
                  counterText: '',
                  border: InputBorder.none,
                  errorText: _empty ? 'Write something first' : null,
                ),
              ),
              const Divider(height: 32),
              Text(
                'Linked tasks',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              if (linked.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Not linked to any task.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              for (final task in linked)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    task.status == TaskStatus.done
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: statusColor(context, task.status),
                  ),
                  title: Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Unlink',
                    icon: const Icon(Icons.link_off),
                    onPressed: () => setState(() => _taskIds.remove(task.id)),
                  ),
                  onTap: () => openEditor(context, task: task),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _linkTask,
                  icon: const Icon(Icons.add_link),
                  label: const Text('Link a task'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets the user choose a task, open ones first; null if dismissed.
Future<Task?> pickTask(
  BuildContext context, {
  List<String> exclude = const [],
}) {
  final store = StoreScope.of(context);
  final tasks = store.tasks.where((t) => !exclude.contains(t.id)).toList()
    ..sort(
      (a, b) => a.status.index.compareTo(b.status.index) != 0
          ? a.status.index.compareTo(b.status.index)
          : a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
  return _pick<Task>(
    context,
    title: 'Link a task',
    empty: 'No other tasks to link.',
    items: tasks,
    text: (t) => t.title,
    icon: (t) => t.status == TaskStatus.done
        ? Icons.check_circle
        : Icons.radio_button_unchecked,
  );
}

/// Lets the user choose a note; null if dismissed.
Future<Note?> pickNote(
  BuildContext context, {
  List<String> exclude = const [],
}) {
  final notes =
      StoreScope.of(
          context,
        ).notes.where((n) => !exclude.contains(n.id)).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return _pick<Note>(
    context,
    title: 'Link a note',
    empty: 'No other notes to link.',
    items: notes,
    text: (n) => n.displayTitle,
    icon: (_) => Icons.sticky_note_2_outlined,
  );
}

Future<T?> _pick<T>(
  BuildContext context, {
  required String title,
  required String empty,
  required List<T> items,
  required String Function(T) text,
  required IconData Function(T) icon,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _Picker<T>(
      title: title,
      empty: empty,
      items: items,
      text: text,
      icon: icon,
    ),
  );
}

class _Picker<T> extends StatefulWidget {
  const _Picker({
    required this.title,
    required this.empty,
    required this.items,
    required this.text,
    required this.icon,
  });

  final String title;
  final String empty;
  final List<T> items;
  final String Function(T) text;
  final IconData Function(T) icon;

  @override
  State<_Picker<T>> createState() => _PickerState<T>();
}

class _PickerState<T> extends State<_Picker<T>> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final matches = widget.items
        .where((i) => widget.text(i).toLowerCase().contains(q))
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Search',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        widget.items.isEmpty ? widget.empty : 'No matches.',
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      itemCount: matches.length,
                      itemBuilder: (context, i) => ListTile(
                        leading: Icon(widget.icon(matches[i])),
                        title: Text(
                          widget.text(matches[i]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, matches[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
