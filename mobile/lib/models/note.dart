/// A note, optionally linked to any number of tasks.
class Note {
  const Note({
    required this.id,
    this.title = '',
    this.body = '',
    this.taskIds = const [],
    this.createdAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String title;
  final String body;
  final List<String> taskIds;
  final String createdAt;
  final String updatedAt;

  /// Untitled notes go by their first line of text.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final first = body.trim().split('\n').first.trim();
    if (first.isEmpty) return 'Untitled note';
    return first.length > 80 ? first.substring(0, 80) : first;
  }

  /// The text shown under the title in a list, without repeating it.
  String get preview => title.isNotEmpty
      ? body.trim()
      : body.trim().split('\n').skip(1).join('\n').trim();

  factory Note.fromJson(Map<String, dynamic> json) => Note(
    id: '${json['id']}',
    title: '${json['title'] ?? ''}',
    body: '${json['body'] ?? ''}',
    taskIds: '${json['taskIds'] ?? ''}'
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(),
    createdAt: '${json['createdAt'] ?? ''}',
    updatedAt: '${json['updatedAt'] ?? ''}',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'taskIds': taskIds.join(','),
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  Note copyWith({String? title, String? body, List<String>? taskIds}) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    taskIds: taskIds ?? this.taskIds,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}
