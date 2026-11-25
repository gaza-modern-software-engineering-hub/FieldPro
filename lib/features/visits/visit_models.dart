import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';

const kVisitStatuses = ['completed', 'followup', 'urgent'];

const kDefaultPurposes = [
  'Service Mapping (خريطة الخدمات)',
  'Infrastructure (البنية التحتية)',
  'Site Alert (إنذار موقع)',
  'تقييم مخاطر (Risk Assessment)',
  'أخرى',
];

String statusLabel(String s) =>
    s == 'urgent' ? 'عاجلة' : (s == 'followup' ? 'تحتاج متابعة' : 'مكتملة');

Color statusColor(String s) => s == 'urgent'
    ? const Color(0xFFD32F2F)
    : (s == 'followup' ? const Color(0xFFEF6C00) : const Color(0xFF2E7D32));

IconData statusIcon(String s) => s == 'urgent'
    ? Icons.warning_rounded
    : (s == 'followup' ? Icons.flag_rounded : Icons.check_circle_rounded);

String newId(String prefix) {
  final r = math.Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final s = List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  return '${prefix}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_$s';
}

List<String> _ids(dynamic v) {
  try {
    final d = v is String ? jsonDecode(v.isEmpty ? '[]' : v) : v;
    if (d is List) {
      return d.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
  } catch (_) {}
  return [];
}

class Visit {
  final String id;
  String siteCode;
  String siteName;
  String purpose;
  String status;
  String visitor;
  DateTime visitedAt;
  double? lat;
  double? lng;
  double? accuracy;
  String notes;
  List<String> photoIds;
  bool deleted;
  DateTime createdAt;
  int seq;
  int dirty;

  Visit({
    required this.id,
    this.siteCode = '',
    this.siteName = '',
    this.purpose = '',
    this.status = 'completed',
    this.visitor = '',
    DateTime? visitedAt,
    this.lat,
    this.lng,
    this.accuracy,
    this.notes = '',
    List<String>? photoIds,
    this.deleted = false,
    DateTime? createdAt,
    this.seq = 0,
    this.dirty = 0,
  })  : visitedAt = visitedAt ?? DateTime.now(),
        photoIds = photoIds ?? [],
        createdAt = createdAt ?? DateTime.now();

  String get siteLabel {
    final c = siteCode.trim();
    final n = siteName.trim();
    if (c.isNotEmpty && n.isNotEmpty) return '$c - $n';
    return c.isNotEmpty ? c : (n.isNotEmpty ? n : 'موقع غير محدد');
  }

  String get siteKey =>
      (siteCode.trim().isNotEmpty ? siteCode.trim() : siteName.trim())
          .toLowerCase();

  Map<String, Object?> toLocalMap() => {
    'id': id,
    'site_code': siteCode,
    'site_name': siteName,
    'purpose': purpose,
    'status': status,
    'visitor': visitor,
    'visited_at': visitedAt.toUtc().toIso8601String(),
    'lat': lat,
    'lng': lng,
    'accuracy': accuracy,
    'notes': notes,
    'photo_ids': jsonEncode(photoIds),
    'deleted': deleted ? 1 : 0,
    'created_at': createdAt.toUtc().toIso8601String(),
    'seq': seq,
    'dirty': dirty,
  };

  Map<String, dynamic> toRemote() {
    final m = Map<String, dynamic>.from(toLocalMap());
    m.remove('seq');
    m.remove('dirty');
    return m;
  }

  factory Visit.fromMap(Map<String, dynamic> m) {
    DateTime d(dynamic v) =>
        DateTime.tryParse((v ?? '').toString())?.toLocal() ?? DateTime.now();
    final st = (m['status'] ?? 'completed').toString();
    return Visit(
      id: (m['id'] ?? '').toString(),
      siteCode: (m['site_code'] ?? '').toString(),
      siteName: (m['site_name'] ?? '').toString(),
      purpose: (m['purpose'] ?? '').toString(),
      status: kVisitStatuses.contains(st) ? st : 'completed',
      visitor: (m['visitor'] ?? '').toString(),
      visitedAt: d(m['visited_at']),
      lat: (m['lat'] as num?)?.toDouble(),
      lng: (m['lng'] as num?)?.toDouble(),
      accuracy: (m['accuracy'] as num?)?.toDouble(),
      notes: (m['notes'] ?? '').toString(),
      photoIds: _ids(m['photo_ids']),
      deleted: (m['deleted'] ?? 0) == 1,
      createdAt: d(m['created_at']),
      seq: (m['seq'] as num?)?.toInt() ?? 0,
      dirty: (m['dirty'] as num?)?.toInt() ?? 0,
    );
  }
}