/// Wire values match the Google Sheet columns, so `.name` is sent as-is.
enum TaskStatus {
  todo('To Do'),
  done('Done');

  const TaskStatus(this.label);
  final String label;

  static TaskStatus parse(Object? value) => values.firstWhere(
        (s) => s.name == value,
        orElse: () => TaskStatus.todo,
      );
}

enum TaskPriority {
  high('High'),
  medium('Medium'),
  low('Low');

  const TaskPriority(this.label);
  final String label;

  static TaskPriority parse(Object? value) => values.firstWhere(
        (p) => p.name == value,
        orElse: () => TaskPriority.medium,
      );
}

class Task {
  const Task({
    required this.id,
    required this.title,
    this.description = '',
    this.status = TaskStatus.todo,
    this.priority = TaskPriority.medium,
    this.project = '',
    this.dueDate = '',
    this.tags = '',
    this.links = '',
    this.sortOrder = '',
    this.completedAt = '',
    this.recurrence = '',
    this.checklist = '',
    this.createdAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String title;
  final String description;
  final TaskStatus status;
  final TaskPriority priority;
  final String project;

  /// `YYYY-MM-DD`, or empty when there is no due date.
  final String dueDate;

  /// Comma-separated labels.
  final String tags;

  /// http(s) links, one per line.
  final String links;

  /// Hand-placed position in a list; empty until the task is first moved.
  final String sortOrder;

  /// When the task was last finished; empty while open.
  final String completedAt;

  /// One of [recurrenceLabels]' keys, or empty when it doesn't repeat.
  final String recurrence;

  /// Steps as lines of `[ ] text` or `[x] text`.
  final String checklist;
  final String createdAt;
  final String updatedAt;

  List<String> get tagList =>
      tags.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

  List<String> get linkList => cleanLinks(links).split('\n').where((l) => l.isNotEmpty).toList();

  double? get order => double.tryParse(sortOrder);

  List<ChecklistItem> get steps => parseChecklist(checklist);

  bool get isOpen => status != TaskStatus.done;
  bool get isOverdue => isOpen && dueDate.isNotEmpty && dueDate.compareTo(todayKey()) < 0;

  factory Task.fromJson(Map<String, dynamic> json) {
    final due = '${json['dueDate'] ?? ''}';
    final title = '${json['title'] ?? ''}';
    return Task(
      id: '${json['id']}',
      title: title.isEmpty ? '(untitled)' : title,
      description: '${json['description'] ?? ''}',
      status: TaskStatus.parse(json['status']),
      priority: TaskPriority.parse(json['priority']),
      project: '${json['project'] ?? ''}',
      dueDate: RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due) ? due : '',
      tags: '${json['tags'] ?? ''}',
      links: '${json['links'] ?? ''}',
      sortOrder: '${json['sortOrder'] ?? ''}',
      completedAt: '${json['completedAt'] ?? ''}',
      recurrence: recurrenceLabels.containsKey(json['recurrence']) ? '${json['recurrence']}' : '',
      checklist: '${json['checklist'] ?? ''}',
      createdAt: '${json['createdAt'] ?? ''}',
      updatedAt: '${json['updatedAt'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'status': status.name,
        'priority': priority.name,
        'project': project,
        'dueDate': dueDate,
        'tags': tags,
        'links': links,
        'sortOrder': sortOrder,
        'completedAt': completedAt,
        'recurrence': recurrence,
        'checklist': checklist,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  Task copyWith({
    String? title,
    String? description,
    TaskStatus? status,
    TaskPriority? priority,
    String? project,
    String? dueDate,
    String? tags,
    String? links,
    String? sortOrder,
    String? recurrence,
    String? checklist,
  }) =>
      Task(
        id: id,
        title: title ?? this.title,
        description: description ?? this.description,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        project: project ?? this.project,
        dueDate: dueDate ?? this.dueDate,
        tags: tags ?? this.tags,
        links: links ?? this.links,
        sortOrder: sortOrder ?? this.sortOrder,
        completedAt: completedAt,
        recurrence: recurrence ?? this.recurrence,
        checklist: checklist ?? this.checklist,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String todayKey() => dateKey(DateTime.now());

/// Date key [days] from today; negative values count back.
String dayKey(int days) {
  final now = DateTime.now();
  return dateKey(DateTime(now.year, now.month, now.day + days));
}

/// Most urgent first: priority, then earliest due date.
int compareTasks(Task a, Task b) {
  final byPriority = a.priority.index.compareTo(b.priority.index);
  if (byPriority != 0) return byPriority;
  final aDue = a.dueDate.isEmpty ? '9999' : a.dueDate;
  final bDue = b.dueDate.isEmpty ? '9999' : b.dueDate;
  return aDue.compareTo(bDue);
}

/// Hand-placed tasks first, in the order they were put; then by urgency.
int compareManual(Task a, Task b) {
  final aOrder = a.order;
  final bOrder = b.order;
  if (aOrder != null && bOrder != null) return aOrder.compareTo(bOrder);
  if (aOrder != null) return -1;
  if (bOrder != null) return 1;
  return compareTasks(a, b);
}

/// Keeps only http(s) links, one per line.
String cleanLinks(String text) => text
    .split('\n')
    .map((l) => l.trim())
    .where((l) => RegExp(r'^https?://', caseSensitive: false).hasMatch(l))
    .join('\n');

/// Normalizes user-typed tags to `a, b`.
String cleanTags(String text) =>
    text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).join(', ');

/// One entry of a task's change log.
class HistoryEntry {
  const HistoryEntry({required this.at, required this.action, required this.details});

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        at: '${json['at'] ?? ''}',
        action: '${json['action'] ?? ''}',
        details: '${json['details'] ?? ''}',
      );

  final String at;
  final String action;
  final String details;
}

/// A named combination of task filters, kept on this device.
class SavedFilter {
  const SavedFilter({required this.name, this.query = '', this.project = '', this.tag = ''});

  factory SavedFilter.fromJson(Map<String, dynamic> json) => SavedFilter(
        name: '${json['name']}',
        query: '${json['query'] ?? ''}',
        project: '${json['project'] ?? ''}',
        tag: '${json['tag'] ?? ''}',
      );

  final String name;
  final String query;
  final String project;
  final String tag;

  Map<String, dynamic> toJson() => {'name': name, 'query': query, 'project': project, 'tag': tag};
}

/// Repeat rules understood by the backend, with their labels.
const recurrenceLabels = {
  'daily': 'Every day',
  'weekly': 'Every week',
  'monthly': 'Every month',
  'yearly': 'Every year',
};

class ChecklistItem {
  ChecklistItem({required this.text, this.done = false});

  final String text;
  bool done;
}

List<ChecklistItem> parseChecklist(String text) {
  final line = RegExp(r'^\[( |x)\]\s*(.*)$', caseSensitive: false);
  return text.split('\n').map((l) => line.firstMatch(l.trim())).nonNulls.map((m) {
    return ChecklistItem(text: m[2]!, done: m[1]!.toLowerCase() == 'x');
  }).toList();
}

String formatChecklist(List<ChecklistItem> items) =>
    items.map((i) => '[${i.done ? 'x' : ' '}] ${i.text}').join('\n');

/// Local day a done task was finished. Tasks finished before completedAt
/// existed fall back to their last update.
String completedOn(Task task) {
  if (task.status != TaskStatus.done) return '';
  final parsed = DateTime.tryParse(task.completedAt.isEmpty ? task.updatedAt : task.completedAt);
  return parsed == null ? '' : dateKey(parsed.toLocal());
}
