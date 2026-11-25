class SiteProfile {
  final int projectId;
  String code;
  String district;
  String manager;
  String phone;
  int households;
  int individuals;
  double areaOverride;
  String notes;
  DateTime? updatedAt;

  SiteProfile({
    required this.projectId,
    this.code = '',
    this.district = '',
    this.manager = '',
    this.phone = '',
    this.households = 0,
    this.individuals = 0,
    this.areaOverride = 0,
    this.notes = '',
    this.updatedAt,
  });

  Map<String, Object?> toMap() => {
    'project_id': projectId,
    'code': code,
    'district': district,
    'manager': manager,
    'phone': phone,
    'households': households,
    'individuals': individuals,
    'area_override': areaOverride,
    'notes': notes,
    'updated_at': (updatedAt ?? DateTime.now()).toIso8601String(),
  };

  factory SiteProfile.fromMap(Map<String, dynamic> m) => SiteProfile(
    projectId: m['project_id'] as int,
    code: (m['code'] ?? '') as String,
    district: (m['district'] ?? '') as String,
    manager: (m['manager'] ?? '') as String,
    phone: (m['phone'] ?? '') as String,
    households: (m['households'] ?? 0) as int,
    individuals: (m['individuals'] ?? 0) as int,
    areaOverride: ((m['area_override'] ?? 0) as num).toDouble(),
    notes: (m['notes'] ?? '') as String,
    updatedAt: DateTime.tryParse((m['updated_at'] ?? '') as String),
  );
}