import 'dart:convert';
import 'package:latlong2/latlong.dart';

const kNavyArgb = 0xFF7FB7BE;
class MapArea {
  final int? id;
  final int? projectId;
  final String name;
  final List<LatLng> points;
  final double areaM2;
  final double perimeterM;
  final int color; // ARGB
  final DateTime createdAt;

  MapArea({
    this.id,
    this.projectId,
    required this.name,
    required this.points,
    required this.areaM2,
    required this.perimeterM,
    this.color = kNavyArgb,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'project_id': projectId,
    'name': name,
    'coords':
    jsonEncode(points.map((p) => [p.latitude, p.longitude]).toList()),
    'area': areaM2,
    'perimeter': perimeterM,
    'color': color,
    'created_at': createdAt.toIso8601String(),
  };

  factory MapArea.fromMap(Map<String, dynamic> m) {
    final c = (m['color'] ?? 0) as int;
    return MapArea(
      id: m['id'] as int,
      projectId: m['project_id'] as int?,
      name: m['name'] as String,
      points: (jsonDecode(m['coords'] as String) as List)
          .map((e) =>
          LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble()))
          .toList(),
      areaM2: (m['area'] as num).toDouble(),
      perimeterM: (m['perimeter'] as num).toDouble(),
      color: c == 0 ? kNavyArgb : c,
      createdAt: DateTime.parse(m['created_at'] as String),
    );
  }
}