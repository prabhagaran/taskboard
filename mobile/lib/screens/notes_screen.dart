import 'package:flutter/material.dart';

import '../models/note.dart';
import '../models/task.dart';
import '../services/store.dart';
import '../widgets/common.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final q = _query.trim().toLowerCase();
    final notes =
        store.notes
            .where(
              (n) =>
                  q.isEmpty ||
                  '${n.title} ${n.body} ${store.tasksFor(n).map((t) => t.title).join(' ')}'
                      .toLowerCase()
                      .contains(q),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New note',
        onPressed: () => openNoteEditor(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          const SyncErrorBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search notes',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: store.refresh,
              child: notes.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        q.isEmpty
                            ? const EmptyState(
                                icon: Icons.sticky_note_2_outlined,
                                title: 'No notes yet',
                                message:
                                    'Write down ideas, meeting notes or research, and link them to the tasks they belong to.',
                              )
                            : const EmptyState(
                                icon: Icons.search_off,
                                title: 'No matching notes',
                                message: 'Try a different search.',
                              ),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      itemCount: notes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => NoteCard(note: notes[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class NoteCard extends StatelessWidget {
  const NoteCard({super.key, required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final tasks = store.tasksFor(note);
    final edited = DateTime.tryParse(note.updatedAt)?.toLocal();

    return Dismissible(
      key: ValueKey(note.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: scheme.error,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => deleteNoteWithUndo(store, note),
      // Dismissible stacks its child loosely, so stretch the card to the list's width.
      child: SizedBox(
        width: double.infinity,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openNoteEditor(context, note: note),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.displayTitle,
                    style: text.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (note.preview.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      note.preview,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final task in tasks.take(2)) _TaskChip(task: task),
                      if (tasks.length > 2)
                        Text(
                          '+${tasks.length - 2}',
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (edited != null)
                        Text(
                          'Edited ${dueLabel(dateKey(edited))}',
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskChip extends StatelessWidget {
  const _TaskChip({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final tint = statusColor(context, task.status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          task.status == TaskStatus.done
              ? Icons.check_circle
              : Icons.radio_button_unchecked,
          size: 14,
          color: tint,
        ),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
