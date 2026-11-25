class Project {
  final int? id;
  final String name;
  final String client;
  final String location;
  final String notes;
  final DateTime createdAt;

  Project({
    this.id,
    required this.name,
    this.client = '',
    this.location = '',
    this.notes = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'name': name,
    'client': client,
    'location': location,
    'notes': notes,
    'created_at': createdAt.toIso8601String(),
  };

  factory Project.fromMap(Map<String, dynamic> m) => Project(
    id: m['id'] as int,
    name: m['name'] as String,
    client: (m['client'] ?? '') as String,
    location: (m['location'] ?? '') as String,
    notes: (m['notes'] ?? '') as String,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}