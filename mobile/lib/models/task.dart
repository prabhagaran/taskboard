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
  final String createdAt;
  final String updatedAt;

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
  }) =>
      Task(
        id: id,
        title: title ?? this.title,
        description: description ?? this.description,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        project: project ?? this.project,
        dueDate: dueDate ?? this.dueDate,
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

/// Local day a done task was finished, approximated by its last update.
String completedOn(Task task) {
  if (task.status != TaskStatus.done) return '';
  final parsed = DateTime.tryParse(task.updatedAt);
  return parsed == null ? '' : dateKey(parsed.toLocal());
}
