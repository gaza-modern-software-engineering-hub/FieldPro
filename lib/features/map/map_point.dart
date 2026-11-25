class MapPoint {
  final int? id;
  final int? projectId;
  final String name;
  final String note;
  final double lat;
  final double lng;
  final bool favorite;
  final String photo;
  final DateTime createdAt;

  MapPoint({
    this.id,
    this.projectId,
    required this.name,
    this.note = '',
    required this.lat,
    required this.lng,
    this.favorite = false,
    this.photo = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'project_id': projectId,
    'name': name,
    'note': note,
    'lat': lat,
    'lng': lng,
    'favorite': favorite ? 1 : 0,
    'photo': photo,
    'created_at': createdAt.toIso8601String(),
  };

  factory MapPoint.fromMap(Map<String, dynamic> m) => MapPoint(
    id: m['id'] as int,
    projectId: m['project_id'] as int?,
    name: m['name'] as String,
    note: (m['note'] ?? '') as String,
    lat: (m['lat'] as num).toDouble(),
    lng: (m['lng'] as num).toDouble(),
    favorite: ((m['favorite'] ?? 0) as int) == 1,
    photo: (m['photo'] ?? '') as String,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}