/// Wire values match the Google Sheet columns, so `.name` is sent as-is.
enum TaskStatus {
  todo('To Do'),
  inprogress('In Progress'),
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
  final String createdAt;
  final String updatedAt;

  List<String> get tagList =>
      tags.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

  List<String> get linkList => cleanLinks(links).split('\n').where((l) => l.isNotEmpty).toList();

  double? get order => double.tryParse(sortOrder);

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

/// Local day a done task was finished, approximated by its last update.
String completedOn(Task task) {
  if (task.status != TaskStatus.done) return '';
  final parsed = DateTime.tryParse(task.updatedAt);
  return parsed == null ? '' : dateKey(parsed.toLocal());
}
