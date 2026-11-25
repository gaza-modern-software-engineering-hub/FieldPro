import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/app_colors.dart';
import '../../core/app_settings.dart';
import '../../core/app_config.dart';
import '../../core/database.dart';
import '../../core/export_service.dart';
import '../site/site_profile_screen.dart';
import 'kml_import_screen.dart';
import '../../core/offline_maps.dart';
import '../projects/project.dart';
import 'map_area.dart';
import 'map_export.dart';
import 'map_point.dart';
import 'offline_maps_screen.dart';
import 'package:share_plus/share_plus.dart';

const _gaza = LatLng(31.5017, 34.4668);
const _generalId = -1;

const _palette = <int>[
  0xFF7FB7BE, // تركوازي هادئ
  0xFFE8B4B8, // وردي فاتح
  0xFFA8D5BA, // أخضر نعناعي
  0xFFF4D58D, // أصفر دافئ
  0xFFB8B8E8, // بنفسجي فاتح
  0xFFF5B994, // خوخي
  0xFF9CC5E8, // أزرق سماوي
];

// ألوان دبابيس المشاريع
const _pinColors = <int>[
  0xFF1E88E5,
  0xFF43A047,
  0xFF8E24AA,
  0xFFFB8C00,
  0xFF00897B,
  0xFFD81B60,
];

class _Place {
  final String name;
  final LatLng ll;
  _Place(this.name, this.ll);
}

class MapScreen extends StatefulWidget {
  final int? projectId;
  final String? projectName;
  const MapScreen({super.key, this.projectId, this.projectName});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  final _dist = const Distance();

  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  LatLng? _me;
  double _accuracy = 0;
  double _heading = 0;
  bool _follow = true;
  bool _mapReady = false;
  bool _satellite = false;
  bool _centeredOnce = false;
  String? _msg;
  List<MapPoint> _points = [];
  List<MapArea> _areas = [];
  MapPoint? _target;

  // الخرائط المحفوظة (دون إنترنت)
  TileProvider? _provStreets;
  TileProvider? _provSat;

  // الطبقات (المشاريع)
  List<Project> _projects = [];
  late int _activeId;
  final Set<int> _visible = {};

  // البحث
  LatLng? _searchPin;
  String _searchLabel = '';

  bool _drawing = false;
  final List<LatLng> _poly = [];
  int? _dragIndex;
  int _drawColor = _palette.first;
  bool _autoOrder = true;
  final ValueNotifier<int> _fixTick = ValueNotifier(0);
  double _alt = 0;
  double _speed = 0;
  Timer? _gpsRetry;
  bool _offlineOnly = false;
  Timer? _netTimer;
  bool _autoOffline = false;
  bool get _effOffline => _offlineOnly || _autoOffline;

  int? get _activePid => _activeId == _generalId ? null : _activeId;

  TileProvider? get _tileProvider => _satellite ? _provSat : _provStreets;

  String get _activeName {
    if (_activeId == _generalId) return 'الخريطة العامة';
    for (final p in _projects) {
      if (p.id == _activeId) return p.name;
    }
    return widget.projectName ?? 'مشروع';
  }

  Color _layerColor(int? pid) {
    if (pid == null) return const Color(0xFFE53935);
    final i = _projects.indexWhereSafe(pid);
    return Color(_pinColors[(i < 0 ? 0 : i) % _pinColors.length]);
  }

  @override
  void initState() {
    super.initState();
    _activeId = widget.projectId ?? _generalId;
    _visible.add(_activeId);
    if (OfflineMaps.ready) {
      _loadOfflinePref();
      _startNetWatch();
    }
    _loadPoints();
    _startLocation();
    _compassSub = FlutterCompass.events?.listen((e) {
      if (e.heading != null && mounted) {
        setState(() => _heading = e.heading!);
      }
    });
  }

  String get _tileUrl {
    if (OfflineMaps.canUse) return OfflineMaps.urlTemplate(_satellite);
    return _satellite
        ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
        : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  }

  /// يحمّل المشاريع ثم نقاط وحدود كل الطبقات الظاهرة
  Future<void> _loadPoints() async {
    try {
      final projects = await AppDatabase.instance.getProjects();
      final ids = projects.map((p) => p.id).toSet();
      _visible.removeWhere((id) => id != _generalId && !ids.contains(id));
      if (_activeId != _generalId && !ids.contains(_activeId)) {
        _activeId = _generalId;
      }
      _visible.add(_activeId);

      final pts = <MapPoint>[];
      final ars = <MapArea>[];
      for (final id in _visible) {
        final pid = id == _generalId ? null : id;
        pts.addAll(await AppDatabase.instance.getPoints(projectId: pid));
        ars.addAll(await AppDatabase.instance.getAreas(projectId: pid));
      }
      if (mounted) {
        setState(() {
          _projects = projects;
          _points = pts;
          _areas = ars;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _msg = 'تعذر قراءة المحفوظات: $e');
    }
  }

  void _centerOn(LatLng ll) {
    if (!_centeredOnce && _mapReady) {
      _centeredOnce = true;
      _map.move(ll, 18);
    }
  }



  double _area(List<LatLng> p) {
    if (p.length < 3) return 0;
    const r = 6371000.0;
    final lat0 = p.map((e) => e.latitude).reduce((a, b) => a + b) /
        p.length *
        math.pi /
        180;
    final pts = p
        .map((e) => Offset(e.longitude * math.pi / 180 * r * math.cos(lat0),
        e.latitude * math.pi / 180 * r))
        .toList();
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      s += a.dx * b.dy - b.dx * a.dy;
    }
    return s.abs() / 2;
  }

  double _perimeter(List<LatLng> p) {
    if (p.length < 2) return 0;
    var t = 0.0;
    for (var i = 0; i < p.length - 1; i++) {
      t += _dist.as(LengthUnit.Meter, p[i], p[i + 1]);
    }
    if (p.length > 2) t += _dist.as(LengthUnit.Meter, p.last, p.first);
    return t;
  }

  String _fmtDist(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(2)} كم'
      : '${m.toStringAsFixed(0)} م';

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  // ---------------- البحث ----------------
  String _latinDigits(String s) {
    const a = '٠١٢٣٤٥٦٧٨٩';
    var o = s;
    for (var i = 0; i < 10; i++) {
      o = o.replaceAll(a[i], '$i');
    }
    return o;
  }

  LatLng? _parseCoords(String input) {
    final s = _latinDigits(input);
    final m = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*[,;\s]\s*(-?\d+(?:\.\d+)?)\s*$')
        .firstMatch(s);
    if (m == null) return null;
    var lat = double.parse(m.group(1)!);
    var lng = double.parse(m.group(2)!);
    if (lat.abs() > 90 && lng.abs() <= 90) {
      final t = lat;
      lat = lng;
      lng = t;
    }
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return LatLng(lat, lng);
  }

  Future<List<_Place>> _geocode(String q) async {
    if (!OfflineMaps.canUse) {
      throw Exception('خدمة البحث غير مفعّلة. راجع مسؤول التطبيق');
    }
    final prox = _me ?? _map.camera.center;
    final params = <String, String>{
      'limit': '8',
      'language': 'ar,en',
      'proximity': '${prox.longitude},${prox.latitude}',
    };
    final Uri uri;
    if (OfflineMaps.viaProxy) {
      uri = Uri.parse(
          '${OfflineMaps.proxyBase}/geocode/${Uri.encodeComponent(q)}')
          .replace(queryParameters: {...params, 't': AppConfig.appToken});
    } else {
      uri = Uri.parse(
          'https://api.maptiler.com/geocoding/${Uri.encodeComponent(q)}.json')
          .replace(queryParameters: {
        ...params,
        'key': AppSettings.effectiveMaptiler
      });
    }
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('خطأ بالبحث (${res.statusCode})');
    }
    final data = jsonDecode(res.body);
    final out = <_Place>[];
    for (final f in (data['features'] as List? ?? [])) {
      final c = f['center'] as List?;
      if (c == null || c.length < 2) continue;
      final name = (f['place_name'] ?? f['text'] ?? '').toString();
      out.add(_Place(
          name, LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())));
    }
    return out;
  }

  void _goTo(LatLng ll, String label) {
    setState(() {
      _follow = false;
      _searchPin = ll;
      _searchLabel = label;
    });
    _map.move(ll, 17);
  }

  void _showSearch() {
    final c = TextEditingController();
    var loading = false;
    String? err;
    var results = <_Place>[];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> run() async {
            final q = c.text.trim();
            if (q.isEmpty) return;
            final ll = _parseCoords(q);
            if (ll != null) {
              Navigator.pop(ctx);
              _goTo(ll,
                  '${ll.latitude.toStringAsFixed(6)}, ${ll.longitude.toStringAsFixed(6)}');
              return;
            }
            setS(() {
              loading = true;
              err = null;
              results = [];
            });
            try {
              final r = await _geocode(q);
              if (!ctx.mounted) return;
              setS(() {
                results = r;
                if (r.isEmpty) err = 'لا توجد نتائج';
              });
            } catch (e) {
              if (ctx.mounted) {
                setS(() => err = e.toString().replaceFirst('Exception: ', ''));
              }
            } finally {
              if (ctx.mounted) setS(() => loading = false);
            }
          }

          return Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('بحث عن مكان',
                      style: GoogleFonts.cairo(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: c,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => run(),
                    decoration: InputDecoration(
                      hintText: 'اسم مكان أو إحداثيات (31.5017, 34.4668)',
                      hintStyle: GoogleFonts.cairo(fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: IconButton(
                          icon: const Icon(Icons.arrow_back_rounded),
                          onPressed: run),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                  if (loading)
                    const Padding(
                        padding: EdgeInsets.all(14),
                        child: Center(child: CircularProgressIndicator())),
                  if (err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(err!,
                          style: GoogleFonts.cairo(color: Colors.red)),
                    ),
                  if (results.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final r in results)
                            ListTile(
                              leading: const Icon(Icons.place_rounded,
                                  color: AppColors.navy),
                              title: Text(r.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.cairo(fontSize: 14)),
                              onTap: () {
                                Navigator.pop(ctx);
                                _goTo(r.ll, r.name);
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------- الطبقات ----------------
  Future<String?> _askText(String title, String initial, String label) async {
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title, style: GoogleFonts.cairo()),
          content: TextField(
              controller: c,
              autofocus: true,
              decoration: InputDecoration(labelText: label)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('إلغاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, c.text.trim()),
                child: Text('موافق', style: GoogleFonts.cairo())),
          ],
        ),
      ),
    );
    if (r == null || r.isEmpty) return null;
    return r;
  }

  Future<Map<int, ({int pts, int areas})>> _layerCounts() async {
    final m = <int, ({int pts, int areas})>{};
    final db = AppDatabase.instance;
    final gp = await db.getPoints(projectId: null);
    final ga = await db.getAreas(projectId: null);
    m[_generalId] = (pts: gp.length, areas: ga.length);
    for (final p in _projects) {
      if (p.id == null) continue;
      m[p.id!] = (
      pts: await db.countPoints(p.id!),
      areas: await db.countAreas(p.id!)
      );
    }
    return m;
  }

  Future<void> _zoomToLayer(int id) async {
    final pid = id == _generalId ? null : id;
    final pts = await AppDatabase.instance.getPoints(projectId: pid);
    final ars = await AppDatabase.instance.getAreas(projectId: pid);
    final all = <LatLng>[
      for (final p in pts) LatLng(p.lat, p.lng),
      for (final a in ars) ...a.points,
    ];
    if (all.isEmpty) {
      _snack('هذا المجلد فاضي');
      return;
    }
    setState(() => _follow = false);
    if (all.length == 1) {
      _map.move(all.first, 18);
    } else {
      _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(all),
          padding: const EdgeInsets.all(60)));
    }
  }

  void _showLayers() {
    var counts = <int, ({int pts, int areas})>{};
    var started = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> reload() async {
            await _loadPoints();
            final c = await _layerCounts();
            if (ctx.mounted) setSheet(() => counts = c);
          }

          if (!started) {
            started = true;
            reload();
          }

          final allIds = <int>[_generalId, for (final p in _projects) p.id!];
          final allOn = allIds.every(_visible.contains);

          Widget row(int id, String name) {
            final color = _layerColor(id == _generalId ? null : id);
            final active = _activeId == id;
            final visible = _visible.contains(id);
            final c = counts[id];
            final sub =
            c == null ? '...' : '${c.pts} نقطة  •  ${c.areas} منطقة';

            return InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () async {
                setState(() {
                  _activeId = id;
                  _visible.add(id);
                });
                await reload();
              },
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                decoration: BoxDecoration(
                  color: active
                      ? AppColors.gold.withOpacity(0.15)
                      : const Color(0xFFF4F6F9),
                  borderRadius: BorderRadius.circular(16),
                  border: active
                      ? Border.all(color: AppColors.gold, width: 1.5)
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(Icons.folder_rounded, color: color, size: 34),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.cairo(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15)),
                              ),
                              if (active)
                                Container(
                                  margin: const EdgeInsetsDirectional.only(
                                      start: 8),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 1),
                                  decoration: BoxDecoration(
                                      color: AppColors.gold,
                                      borderRadius: BorderRadius.circular(10)),
                                  child: Text('نشط',
                                      style: GoogleFonts.cairo(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.navyDark)),
                                ),
                            ],
                          ),
                          Text(sub,
                              style: GoogleFonts.cairo(
                                  fontSize: 12, color: AppColors.textMuted)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                          visible
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                          color: visible ? AppColors.navy : Colors.grey),
                      onPressed: active
                          ? () => _snack(
                          'المجلد النشط ظاهر دائماً. اجعل مجلداً آخر نشطاً لتخفيه')
                          : () async {
                        setState(() {
                          if (visible) {
                            _visible.remove(id);
                          } else {
                            _visible.add(id);
                          }
                        });
                        await reload();
                      },
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'go') {
                          Navigator.pop(ctx);
                          await _zoomToLayer(id);
                          return;
                        }
                        if (id == _generalId) return;
                        final p = _projects.firstWhere((x) => x.id == id);
                        if (v == 'profile') {
                          await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => SiteProfileScreen(
                                  projectId: id, projectName: p.name)));
                        } else if (v == 'rename') {
                          final n =
                          await _askText('اسم المجلد', p.name, 'الاسم');
                          if (n == null) return;
                          await AppDatabase.instance.updateProject(Project(
                              id: p.id,
                              name: n,
                              client: p.client,
                              location: p.location,
                              notes: p.notes,
                              createdAt: p.createdAt));
                        } else if (v == 'delete') {
                          if (!await _confirm(
                              'حذف "${p.name}" بكل نقاطه وحدوده؟')) {
                            return;
                          }
                          await AppDatabase.instance.deleteProject(id);
                        }
                        await reload();
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'go',
                            child: Text('اذهب إليه على الخريطة',
                                style: GoogleFonts.cairo())),
                        if (id != _generalId) ...[
                          PopupMenuItem(
                              value: 'profile',
                              child: Text('بطاقة الموقع',
                                  style: GoogleFonts.cairo())),
                          PopupMenuItem(
                              value: 'rename',
                              child: Text('تغيير الاسم',
                                  style: GoogleFonts.cairo())),
                          PopupMenuItem(
                              value: 'delete',
                              child: Text('حذف',
                                  style:
                                  GoogleFonts.cairo(color: Colors.red))),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          }

          return Directionality(
            textDirection: TextDirection.rtl,
            child: SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.85),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    Text('المجلدات',
                        style: GoogleFonts.cairo(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                          'اضغط المجلد ليصير نشطاً (الحفظ يروح له)، والعين للإظهار والإخفاء',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.cairo(
                              fontSize: 11, color: AppColors.textMuted)),
                    ),
                    SwitchListTile(
                      contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20),
                      title: Text('إظهار كل المجلدات على الخريطة',
                          style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      value: allOn,
                      onChanged: (v) async {
                        setState(() {
                          _visible.clear();
                          if (v) {
                            _visible.addAll(allIds);
                          } else {
                            _visible.add(_activeId);
                          }
                        });
                        await reload();
                      },
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          row(_generalId, 'الخريطة العامة'),
                          for (final p in _projects) row(p.id!, p.name),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.gold,
                                    foregroundColor: AppColors.navyDark,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                        BorderRadius.circular(16))),
                                icon: const Icon(
                                    Icons.create_new_folder_rounded),
                                label: Text('مجلد جديد',
                                    style: GoogleFonts.cairo(
                                        fontWeight: FontWeight.w700)),
                                onPressed: () async {
                                  final n = await _askText('مجلد جديد', '',
                                      'اسم المجلد (مثال: GZA5317)');
                                  if (n == null) return;
                                  final id = await AppDatabase.instance
                                      .insertProject(Project(name: n));
                                  setState(() {
                                    _activeId = id;
                                    _visible.add(id);
                                  });
                                  await reload();
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.navy,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                        BorderRadius.circular(16))),
                                icon: const Icon(Icons.upload_file_rounded,
                                    color: AppColors.gold),
                                label: Text('استيراد',
                                    style: GoogleFonts.cairo(
                                        fontWeight: FontWeight.w700)),
                                onPressed: () async {
                                  Navigator.pop(ctx);
                                  final ok = await Navigator.of(context)
                                      .push<bool>(MaterialPageRoute(
                                      builder: (_) =>
                                      const KmlImportScreen()));
                                  if (ok == true) {
                                    await _loadPoints();
                                    _snack(
                                        'تم الاستيراد. افتح المجلدات لرؤية النتيجة');
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
  // ---------------- الرسم ----------------
  void _autoSort() {
    if (!_autoOrder || _poly.length < 4 || _dragIndex != null) return;
    final cLat =
        _poly.map((e) => e.latitude).reduce((a, b) => a + b) / _poly.length;
    final cLng =
        _poly.map((e) => e.longitude).reduce((a, b) => a + b) / _poly.length;
    _poly.sort((a, b) => math
        .atan2(a.latitude - cLat, a.longitude - cLng)
        .compareTo(math.atan2(b.latitude - cLat, b.longitude - cLng)));
  }

  void _insertMidpoints() {
    if (_poly.length < 2) return;
    final out = <LatLng>[];
    for (var i = 0; i < _poly.length; i++) {
      final a = _poly[i];
      final b = _poly[(i + 1) % _poly.length];
      out.add(a);
      if (_poly.length > 2 || i == 0) {
        out.add(LatLng(
            (a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2));
      }
    }
    setState(() {
      _poly
        ..clear()
        ..addAll(out);
    });
  }

  int? _nearestVertex(Offset screen, {double maxPx = 60}) {
    int? best;
    var bestD = maxPx;
    for (var i = 0; i < _poly.length; i++) {
      final o = _map.camera.latLngToScreenOffset(_poly[i]);
      final d = (o - screen).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _onPanStart(DragStartDetails d) {
    if (!_drawing) return;
    final i = _nearestVertex(d.localPosition);
    if (i != null) setState(() => _dragIndex = i);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_dragIndex == null) return;
    final ll = _map.camera.screenOffsetToLatLng(d.localPosition);
    setState(() => _poly[_dragIndex!] = ll);
  }

  void _onPanEnd([Object? _]) {
    if (_dragIndex != null) {
      setState(() {
        _dragIndex = null;
        _autoSort();
      });
    }
  }

  Future<bool> _confirm(String title) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title, style: GoogleFonts.cairo()),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('إلغاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('حذف',
                    style: GoogleFonts.cairo(color: Colors.red))),
          ],
        ),
      ),
    );
    return r == true;
  }

  Widget _colorRow(int selected, void Function(int) onPick) => Wrap(
    spacing: 10,
    runSpacing: 8,
    children: [
      for (final c in _palette)
        GestureDetector(
          onTap: () => onPick(c),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border: Border.all(
                  color: selected == c ? Colors.white : Colors.white54,
                  width: selected == c ? 3 : 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 3)
              ],
            ),
          ),
        ),
    ],
  );

  Future<void> _saveArea() async {
    if (_poly.length < 3) {
      _snack('أضف 3 نقاط على الأقل');
      return;
    }
    final inActive = _areas.where((a) => a.projectId == _activePid).toList();
    final name = TextEditingController(text: 'منطقة ${inActive.length + 1}');
    final area = _area(_poly);
    final per = _perimeter(_poly);
    var color = _drawColor;
    String? err;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('حفظ الحدود', style: GoogleFonts.cairo()),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('المشروع: $_activeName',
                      style: GoogleFonts.cairo(
                          fontSize: 12, color: AppColors.textMuted)),
                  Text(
                      'المساحة: ${area.toStringAsFixed(0)} م²  (${(area / 1000).toStringAsFixed(2)} دونم)\nالمحيط: ${per.toStringAsFixed(0)} م',
                      style: GoogleFonts.cairo(fontSize: 13)),
                  TextField(
                      controller: name,
                      decoration: InputDecoration(
                          labelText: 'اسم المنطقة (فريد)', errorText: err)),
                  const SizedBox(height: 12),
                  Text('لون المنطقة', style: GoogleFonts.cairo(fontSize: 13)),
                  const SizedBox(height: 6),
                  _colorRow(color, (c) => setD(() => color = c)),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('إلغاء', style: GoogleFonts.cairo())),
              TextButton(
                onPressed: () {
                  final n = name.text.trim();
                  if (n.isEmpty) {
                    setD(() => err = 'اكتب اسماً للمنطقة');
                    return;
                  }
                  if (inActive
                      .any((a) => a.name.toLowerCase() == n.toLowerCase())) {
                    setD(() => err = 'هذا الاسم مستخدم، اختر اسماً آخر');
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text('حفظ', style: GoogleFonts.cairo()),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await AppDatabase.instance.insertArea(MapArea(
        projectId: _activePid,
        name: name.text.trim(),
        points: List.of(_poly),
        areaM2: area,
        perimeterM: per,
        color: color,
      ));
      setState(() {
        _poly.clear();
        _drawing = false;
      });
      await _loadPoints();
      if (mounted) _showSaved(tab: 1);
    } catch (e) {
      _snack('فشل الحفظ: $e');
    }
  }

  Future<void> _savePoint(LatLng at, {String? suggestedName}) async {
    final name = TextEditingController(
        text: suggestedName ?? 'نقطة ${_points.length + 1}');
    final note = TextEditingController();
    var fav = false;
    String? err;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('حفظ نقطة', style: GoogleFonts.cairo()),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('المشروع: $_activeName',
                      style: GoogleFonts.cairo(
                          fontSize: 12, color: AppColors.textMuted)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('إضافة للمفضلة',
                        style:
                        GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                    secondary: Icon(
                        fav ? Icons.star_rounded : Icons.star_border_rounded,
                        color: fav ? AppColors.gold : AppColors.textMuted),
                    value: fav,
                    onChanged: (v) => setD(() => fav = v),
                  ),
                  Text(
                      'العرض: ${at.latitude.toStringAsFixed(6)}\nالطول: ${at.longitude.toStringAsFixed(6)}',
                      style: GoogleFonts.cairo(
                          fontSize: 13, color: AppColors.textMuted)),
                  TextField(
                      controller: name,
                      decoration: InputDecoration(
                          labelText: 'اسم النقطة (فريد)', errorText: err)),
                  TextField(
                      controller: note,
                      decoration: const InputDecoration(labelText: 'ملاحظة')),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('إلغاء', style: GoogleFonts.cairo())),
              TextButton(
                onPressed: () async {
                  try {
                    final n = name.text.trim();
                    if (n.isEmpty) {
                      setD(() => err = 'اكتب اسماً للنقطة');
                      return;
                    }
                    if (await AppDatabase.instance
                        .pointNameExists(n, projectId: _activePid)) {
                      setD(() => err = 'هذا الاسم مستخدم، اختر اسماً آخر');
                      return;
                    }
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } catch (e) {
                    setD(() => err = 'خطأ بقاعدة البيانات: $e');
                  }
                },
                child: Text('حفظ', style: GoogleFonts.cairo()),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await AppDatabase.instance.insertPoint(MapPoint(
        projectId: _activePid,
        name: name.text.trim(),
        note: note.text.trim(),
        lat: at.latitude,
        lng: at.longitude,
        favorite: fav,
      ));
      if (_searchPin != null) setState(() => _searchPin = null);
      await _loadPoints();
      _snack('تم حفظ النقطة');
    } catch (e) {
      _snack('فشل الحفظ: $e');
    }
  }

  void _showSaved({int tab = 0}) {
    var onlyFav = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Directionality(
          textDirection: TextDirection.rtl,
          child: DefaultTabController(
            length: 2,
            initialIndex: tab,
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.65,
              maxChildSize: 0.92,
              builder: (_, scroll) {
                final pts = onlyFav
                    ? _points.where((p) => p.favorite).toList()
                    : _points;
                return Column(
                  children: [
                    const SizedBox(height: 8),
                    TabBar(
                      labelStyle:
                      GoogleFonts.cairo(fontWeight: FontWeight.w700),
                      labelColor: AppColors.navy,
                      indicatorColor: AppColors.gold,
                      tabs: [
                        Tab(text: 'النقاط (${_points.length})'),
                        Tab(text: 'الحدود (${_areas.length})'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                child: Row(
                                  children: [
                                    FilterChip(
                                      avatar: const Icon(Icons.star_rounded,
                                          color: AppColors.gold, size: 18),
                                      label: Text('المفضلة فقط',
                                          style: GoogleFonts.cairo()),
                                      selected: onlyFav,
                                      onSelected: (v) =>
                                          setSheet(() => onlyFav = v),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: pts.isEmpty
                                    ? Center(
                                    child: Text('لا توجد نقاط',
                                        style: GoogleFonts.cairo(
                                            color: AppColors.textMuted)))
                                    : ListView.builder(
                                  controller: scroll,
                                  itemCount: pts.length,
                                  itemBuilder: (_, i) {
                                    final p = pts[i];
                                    final d = _me == null
                                        ? ''
                                        : _fmtDist(_dist.as(
                                        LengthUnit.Meter,
                                        _me!,
                                        LatLng(p.lat, p.lng)));
                                    return ListTile(
                                      leading: IconButton(
                                        icon: Icon(
                                            p.favorite
                                                ? Icons.star_rounded
                                                : Icons
                                                .star_border_rounded,
                                            color: p.favorite
                                                ? AppColors.gold
                                                : AppColors.textMuted,
                                            size: 30),
                                        onPressed: () async {
                                          await AppDatabase.instance
                                              .setFavorite(
                                              p.id!, !p.favorite);
                                          await _loadPoints();
                                          setSheet(() {});
                                        },
                                      ),
                                      title: Text(p.name,
                                          style: GoogleFonts.cairo(
                                              fontWeight:
                                              FontWeight.w700)),
                                      subtitle: Text(
                                          'العرض: ${p.lat.toStringAsFixed(6)}\nالطول: ${p.lng.toStringAsFixed(6)}'
                                              '${p.note.isNotEmpty ? '\n${p.note}' : ''}',
                                          style: GoogleFonts.cairo(
                                              fontSize: 12)),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(d,
                                              style: GoogleFonts.cairo(
                                                  color: AppColors
                                                      .textMuted)),
                                          IconButton(
                                            icon: const Icon(
                                                Icons.delete_rounded,
                                                color: Colors.red),
                                            onPressed: () async {
                                              if (!await _confirm(
                                                  'حذف "${p.name}"؟')) {
                                                return;
                                              }
                                              await AppDatabase.instance
                                                  .deletePoint(p.id!);
                                              if (_target?.id == p.id) {
                                                _target = null;
                                              }
                                              await _loadPoints();
                                              setSheet(() {});
                                            },
                                          ),
                                        ],
                                      ),
                                      onTap: () {
                                        Navigator.pop(context);
                                        setState(() => _follow = false);
                                        _map.move(
                                            LatLng(p.lat, p.lng), 18);
                                        _pointSheet(p);
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                          _areas.isEmpty
                              ? Center(
                              child: Text('لا توجد حدود محفوظة',
                                  style: GoogleFonts.cairo(
                                      color: AppColors.textMuted)))
                              : ListView.builder(
                            itemCount: _areas.length,
                            itemBuilder: (_, i) {
                              final a = _areas[i];
                              return ListTile(
                                leading: Icon(Icons.polyline_rounded,
                                    color: Color(a.color), size: 30),
                                title: Text(a.name,
                                    style: GoogleFonts.cairo(
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text(
                                    '${a.areaM2.toStringAsFixed(0)} م²  (${(a.areaM2 / 1000).toStringAsFixed(2)} دونم)\nالمحيط: ${a.perimeterM.toStringAsFixed(0)} م  •  ${a.points.length} نقطة',
                                    style:
                                    GoogleFonts.cairo(fontSize: 12)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                          Icons.palette_rounded),
                                      onPressed: () async {
                                        final c =
                                        await _pickAreaColor(a.color);
                                        if (c == null) return;
                                        await AppDatabase.instance
                                            .setAreaColor(a.id!, c);
                                        await _loadPoints();
                                        setSheet(() {});
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                          Icons.delete_rounded,
                                          color: Colors.red),
                                      onPressed: () async {
                                        if (!await _confirm(
                                            'حذف "${a.name}"؟')) {
                                          return;
                                        }
                                        await AppDatabase.instance
                                            .deleteArea(a.id!);
                                        await _loadPoints();
                                        setSheet(() {});
                                      },
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  setState(() => _follow = false);
                                  final b =
                                  LatLngBounds.fromPoints(a.points);
                                  _map.fitCamera(CameraFit.bounds(
                                      bounds: b,
                                      padding:
                                      const EdgeInsets.all(60)));
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<int?> _pickAreaColor(int current) {
    return showDialog<int>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('اختر لون المنطقة', style: GoogleFonts.cairo()),
          content: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: current == c ? Colors.black54 : Colors.white,
                          width: current == c ? 3 : 2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 3)
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _takePhoto() async {
    final x = await ImagePicker().pickImage(
        source: ImageSource.camera, imageQuality: 80, maxWidth: 1600);
    if (x == null) return '';
    final dir = await getApplicationDocumentsDirectory();
    final dest =
        '${dir.path}/pt_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(x.path).copy(dest);
    return dest;
  }

  void _pointSheet(MapPoint p) {
    final name = TextEditingController(text: p.name);
    final note = TextEditingController(text: p.note);
    var photo = p.photo;
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'الاسم')),
                  TextField(
                      controller: note,
                      decoration: const InputDecoration(labelText: 'ملاحظة')),
                  const SizedBox(height: 8),
                  Text(
                      'العرض: ${p.lat.toStringAsFixed(6)}   الطول: ${p.lng.toStringAsFixed(6)}',
                      style: GoogleFonts.cairo(color: AppColors.textMuted)),
                  const SizedBox(height: 10),
                  if (photo.isNotEmpty && File(photo).existsSync())
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(File(photo),
                          height: 160,
                          width: double.infinity,
                          fit: BoxFit.cover),
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        final path = await _takePhoto();
                        if (path.isNotEmpty) setS(() => photo = path);
                      } catch (e) {
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('تعذر التصوير: $e')));
                        }
                      }
                    },
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: Text(photo.isEmpty ? 'إضافة صورة' : 'تغيير الصورة',
                        style: GoogleFonts.cairo()),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.navy,
                              foregroundColor: Colors.white),
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() => _target = p);
                          },
                          icon: const Icon(Icons.navigation_rounded,
                              color: AppColors.gold),
                          label:
                          Text('اذهب إليها', style: GoogleFonts.cairo()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.gold,
                              foregroundColor: AppColors.navyDark),
                          onPressed: () async {
                            await AppDatabase.instance.updatePoint(p.id!,
                                name: name.text.trim().isEmpty
                                    ? p.name
                                    : name.text.trim(),
                                note: note.text.trim(),
                                photo: photo);
                            if (ctx.mounted) Navigator.pop(ctx);
                            _loadPoints();
                          },
                          icon: const Icon(Icons.save_rounded),
                          label: Text('حفظ', style: GoogleFonts.cairo()),
                        ),
                      ),
                      IconButton(
                        color: Colors.red,
                        icon: const Icon(Icons.delete_rounded),
                        onPressed: () async {
                          if (!await _confirm('حذف "${p.name}"؟')) return;
                          if (ctx.mounted) Navigator.pop(ctx);
                          await AppDatabase.instance.deletePoint(p.id!);
                          if (_target?.id == p.id) _target = null;
                          _loadPoints();
                        },
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
  Future<String?> _reverseGeocode(LatLng ll) async {
    if (!OfflineMaps.canUse) return null;
    final q =
        '${ll.longitude.toStringAsFixed(6)},${ll.latitude.toStringAsFixed(6)}';
    final Uri uri;
    if (OfflineMaps.viaProxy) {
      uri = Uri.parse('${OfflineMaps.proxyBase}/geocode/$q').replace(
          queryParameters: {'language': 'ar,en', 't': AppConfig.appToken});
    } else {
      uri = Uri.parse('https://api.maptiler.com/geocoding/$q.json').replace(
          queryParameters: {
            'language': 'ar,en',
            'key': AppSettings.effectiveMaptiler
          });
    }
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final f = (jsonDecode(res.body)['features'] as List?) ?? [];
    if (f.isEmpty) return null;
    return (f.first['place_name'] ?? f.first['text'])?.toString();
  }


  Widget _meMarker() => Transform.rotate(
    angle: _heading * math.pi / 180,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blue.withValues(alpha: 0.2)),
        ),
        const Icon(Icons.navigation_rounded, color: Colors.blue, size: 32),
      ],
    ),
  );


  Widget _searchCard() => Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 68, 0),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
        color: const Color(0xFF7E57C2),
        borderRadius: BorderRadius.circular(14)),
    child: Row(
      children: [
        const Icon(Icons.place_rounded, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_searchLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.cairo(color: Colors.white, fontSize: 12)),
        ),
        TextButton(
          onPressed: () => _savePoint(_searchPin!,
              suggestedName: _searchLabel.contains(',') &&
                  RegExp(r'^[\d\.\s,\-]+$').hasMatch(_searchLabel)
                  ? null
                  : _searchLabel.split(',').first.trim()),
          child: Text('حفظ',
              style: GoogleFonts.cairo(
                  color: Colors.white, fontWeight: FontWeight.w700)),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded,
              color: Colors.white, size: 20),
          onPressed: () => setState(() => _searchPin = null),
        ),
      ],
    ),
  );

  Widget _targetCard() {
    final t = _target!;
    final tp = LatLng(t.lat, t.lng);
    final meters = _me == null ? 0.0 : _dist.as(LengthUnit.Meter, _me!, tp);
    final bearing = _me == null ? 0.0 : _dist.bearing(_me!, tp);
    final arrow = (bearing - _heading) * math.pi / 180;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 68, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppColors.navy, borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          Transform.rotate(
            angle: arrow,
            child: const Icon(Icons.navigation_rounded,
                color: AppColors.gold, size: 44),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.name,
                    style: GoogleFonts.cairo(
                        color: Colors.white, fontWeight: FontWeight.w700)),
                Text(_fmtDist(meters),
                    style: GoogleFonts.cairo(
                        color: AppColors.goldLight, fontSize: 20)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () => setState(() => _target = null),
          ),
        ],
      ),
    );
  }

  Widget _drawPanel() {
    final area = _area(_poly);
    final per = _perimeter(_poly);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            14, 12, 14, 12 + MediaQuery.of(context).padding.bottom),
        decoration: const BoxDecoration(
          color: AppColors.navy,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _poly.length < 3
                  ? 'اضغط على الخريطة لإضافة نقاط الحدود (${_poly.length})'
                  : 'المساحة: ${area.toStringAsFixed(0)} م²  (${(area / 1000).toStringAsFixed(2)} دونم)',
              style: GoogleFonts.cairo(
                  color: AppColors.goldLight,
                  fontWeight: FontWeight.w700,
                  fontSize: 15),
            ),
            if (_poly.length >= 2)
              Text(
                  'المحيط: ${per.toStringAsFixed(0)} م   •   ${_poly.length} نقطة',
                  style: GoogleFonts.cairo(color: Colors.white70)),
            if (_poly.length >= 2)
              Text('اسحب أي نقطة بإصبعك لتعديل مكانها',
                  style: GoogleFonts.cairo(
                      color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 8),
            _colorRow(_drawColor, (c) => setState(() => _drawColor = c)),
            const SizedBox(height: 6),
            Row(
              children: [
                _pBtn(Icons.my_location_rounded, 'نقطتي', () {
                  if (_me != null) {
                    setState(() {
                      _poly.add(_me!);
                      _autoSort();
                    });
                  }
                }),
                _pBtn(Icons.undo_rounded, 'تراجع', () {
                  if (_poly.isNotEmpty) setState(() => _poly.removeLast());
                }),
                _pBtn(
                    _autoOrder
                        ? Icons.auto_fix_high_rounded
                        : Icons.auto_fix_off_rounded,
                    _autoOrder ? 'تلقائي' : 'يدوي', () {
                  setState(() {
                    _autoOrder = !_autoOrder;
                    _autoSort();
                  });
                }),
                _pBtn(Icons.add_circle_outline_rounded, 'إدراج',
                    _insertMidpoints),
                _pBtn(Icons.delete_sweep_rounded, 'مسح',
                        () => setState(() => _poly.clear())),
                _pBtn(Icons.save_rounded, 'حفظ', _saveArea),
                _pBtn(Icons.close_rounded, 'إغلاق',
                        () => setState(() => _drawing = false)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _savedBar() => SafeArea(
    child: Container(
      color: AppColors.navy,
      child: ListTile(
        onTap: () => _showSaved(),
        leading:
        const Icon(Icons.bookmarks_rounded, color: AppColors.gold),
        title: Text(
            'المحفوظات: ${_points.length} نقطة  •  ${_areas.length} منطقة',
            style: GoogleFonts.cairo(
                color: Colors.white, fontWeight: FontWeight.w700)),
        trailing: const Icon(Icons.keyboard_arrow_up_rounded,
            color: Colors.white),
      ),
    ),
  );

  Widget _pBtn(IconData i, String t, VoidCallback f) => Expanded(
    child: TextButton(
      onPressed: f,
      style: TextButton.styleFrom(padding: const EdgeInsets.all(2)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(i, color: AppColors.gold, size: 22),
          Text(t,
              style: GoogleFonts.cairo(color: Colors.white, fontSize: 10)),
        ],
      ),
    ),
  );

  Widget _roundBtn(IconData i, VoidCallback f, {bool active = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 8, right: 12),
        child: CircleAvatar(
          backgroundColor: active ? AppColors.gold : AppColors.navy,
          child: IconButton(
            icon: Icon(i, color: active ? AppColors.navyDark : Colors.white),
            onPressed: f,
          ),
        ),
      );

  Future<void> _openOffline() async {
    LatLngBounds? b;
    try {
      b = _map.camera.visibleBounds;
    } catch (_) {}
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => OfflineMapsScreen(currentBounds: b)));
  }

  Future<String?> _askName() async {
    final r = await _askText(
        'اسم الملف',
        _activeId == _generalId ? 'خريطة عامة' : 'خريطة $_activeName',
        'سمّ الخريطة (مثال: حي الزيتون)');
    if (r == null) return null;
    return r.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  Future<void> _exportMenu() async {
    if (_points.isEmpty && _areas.isEmpty) {
      _snack('لا يوجد شيء لتصديره بعد');
      return;
    }
    final base = await _askName();
    if (base == null || !mounted) return;

    Widget tile(IconData icon, String title, String sub, VoidCallback f) =>
        ListTile(
          leading: Icon(icon, color: AppColors.navy),
          title: Text(title, style: GoogleFonts.cairo()),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: GoogleFonts.cairo(fontSize: 11)),
          onTap: () {
            Navigator.pop(context);
            f();
          },
        );

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Text('تصدير: $base',
                    style: GoogleFonts.cairo(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                Text('الطبقات الظاهرة فقط',
                    style: GoogleFonts.cairo(
                        fontSize: 11, color: AppColors.textMuted)),
                tile(
                    Icons.map_rounded,
                    'KMZ لـ Maps.me (موصى به)',
                    'ملف واحد مضغوط، يفتح بـ Maps.me',
                        () => showExportSheet(context,
                        baseName: base,
                        ext: 'kmz',
                        bytes: MapExport.kmz(_points, _areas, name: base),
                        mime: 'application/vnd.google-earth.kmz',
                        mimeType: MimeType.other,
                        projectId: _activePid)),
                tile(
                    Icons.public_rounded,
                    'KML',
                    'Maps.me وGoogle Earth',
                        () => showExportSheet(context,
                        baseName: base,
                        ext: 'kml',
                        bytes: MapExport.kml(_points, _areas, name: base),
                        mime: 'application/vnd.google-earth.kml+xml',
                        mimeType: MimeType.other,
                        projectId: _activePid)),
                tile(
                    Icons.route_rounded,
                    'GPX',
                    '',
                        () => showExportSheet(context,
                        baseName: base,
                        ext: 'gpx',
                        bytes: MapExport.gpx(_points, _areas),
                        mime: 'application/gpx+xml',
                        mimeType: MimeType.other,
                        projectId: _activePid)),
                tile(Icons.table_chart_rounded, 'Excel', '', () {
                  final bytes = MapExport.excel(_points, _areas);
                  if (bytes == null) return;
                  showExportSheet(context,
                      baseName: base,
                      ext: 'xlsx',
                      bytes: bytes,
                      mime:
                      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                      mimeType: MimeType.microsoftExcel,
                      projectId: _activePid);
                }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mapView() {
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _me ?? _gaza,
        initialZoom: _me != null ? 18 : 14,
        maxZoom: 19,
        interactionOptions: InteractionOptions(
          flags: _dragIndex != null
              ? InteractiveFlag.none
              : InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () {
          _mapReady = true;
          if (_me != null && !_centeredOnce) {
            _centeredOnce = true;
            _map.move(_me!, 18);
          }
        },
        onTap: (_, ll) {
          if (_drawing) {
            setState(() {
              _poly.add(ll);
              _autoSort();
            });
          }
        },
        onLongPress: (_, ll) {
          if (!_drawing) _savePoint(ll);
        },
        onPositionChanged: (_, byGesture) {
          if (byGesture && _follow) setState(() => _follow = false);
        },
      ),
      children: [
        TileLayer(
          key: ValueKey('$_satellite$_effOffline'),
          urlTemplate: _tileUrl,
          userAgentPackageName: 'saeed_dev.com.fieldpro',
          maxNativeZoom: _effOffline
              ? OfflineMaps.nativeZoomAt(_me ?? _gaza, _satellite)
              : 19,
          minNativeZoom: _effOffline ? 7 : 0,
          tileProvider: _tileProvider,
        ),
        PolygonLayer(polygons: [
          for (final a in _areas)
            Polygon(
              points: a.points,
              color: Color(a.color).withValues(alpha: 0.30),
              borderColor: Color(a.color),
              borderStrokeWidth: 3,
            ),
        ]),
        if (_poly.length >= 3)
          PolygonLayer(polygons: [
            Polygon(
              points: _poly,
              color: Color(_drawColor).withValues(alpha: 0.35),
              borderColor: Color(_drawColor),
              borderStrokeWidth: 3,
            ),
          ])
        else if (_poly.length == 2)
          PolylineLayer(polylines: [
            Polyline(
                points: _poly, strokeWidth: 3, color: Color(_drawColor)),
          ]),
        if (_me != null && _target != null)
          PolylineLayer(polylines: [
            Polyline(
              points: [_me!, LatLng(_target!.lat, _target!.lng)],
              strokeWidth: 4,
              color: Colors.orangeAccent,
            ),
          ]),
        if (_me != null)
          CircleLayer(circles: [
            CircleMarker(
              point: _me!,
              radius: _accuracy,
              useRadiusInMeter: true,
              color: Colors.blue.withValues(alpha: 0.12),
            ),
          ]),
        MarkerLayer(markers: [
          for (final p in _points)
            Marker(
              point: LatLng(p.lat, p.lng),
              width: 46,
              height: 46,
              alignment: Alignment.topCenter,
              child: GestureDetector(
                onTap: () => _pointSheet(p),
                child: Icon(Icons.location_on_rounded,
                    color:
                    p.favorite ? AppColors.gold : _layerColor(p.projectId),
                    size: 42),
              ),
            ),
          if (_searchPin != null)
            Marker(
              point: _searchPin!,
              width: 50,
              height: 50,
              alignment: Alignment.topCenter,
              child: GestureDetector(
                onTap: () => _savePoint(_searchPin!),
                child: const Icon(Icons.place_rounded,
                    color: Color(0xFF7E57C2), size: 48),
              ),
            ),
          for (var i = 0; i < _poly.length; i++)
            Marker(
              point: _poly[i],
              width: 44,
              height: 44,
              child: IgnorePointer(
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: _dragIndex == i ? 38 : 24,
                    height: _dragIndex == i ? 38 : 24,
                    decoration: BoxDecoration(
                      color: _dragIndex == i
                          ? Color(_drawColor).withValues(alpha: 0.85)
                          : Colors.white,
                      shape: BoxShape.circle,
                      border:
                      Border.all(color: Color(_drawColor), width: 3),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 6)
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_me != null)
            Marker(
              point: _me!,
              width: 64,
              height: 64,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showMyLocation,
                child: Center(child: _meMarker()),
              ),
            ),
        ]),
      ],
    );
  }

  @override
  void dispose() {
    _gpsRetry?.cancel();
    _posSub?.cancel();
    _netTimer?.cancel();
    _compassSub?.cancel();
    _fixTick.dispose();
    super.dispose();
  }

  Future<void> _loadOfflinePref() async {
    final v = await AppDatabase.instance.getSetting('map_cache_only');
    _offlineOnly = v == '1';
    _buildProviders();
    if (mounted) setState(() {});
  }
  Future<bool> _reachable() async {
    try {
      final host = OfflineMaps.viaProxy
          ? Uri.parse(OfflineMaps.proxyBase).host
          : 'api.maptiler.com';
      final s = await Socket.connect(host, 443,
          timeout: const Duration(seconds: 3));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _probeNet() async {
    final on = await _reachable();
    if (!mounted) return;
    final auto = !on;
    if (auto != _autoOffline) {
      _autoOffline = auto;
      _buildProviders();
      setState(() {});
    }
  }

  void _startNetWatch() {
    _netTimer?.cancel();
    _probeNet();
    _netTimer = Timer.periodic(const Duration(seconds: 15), (_) => _probeNet());
  }

  void _buildProviders() {
    _provStreets =
        OfflineMaps.provider(OfflineMaps.streets, cacheOnly: _effOffline);
    _provSat =
        OfflineMaps.provider(OfflineMaps.satellite, cacheOnly: _effOffline);
  }

  Future<void> _toggleOfflineOnly() async {
    _offlineOnly = !_offlineOnly;
    await AppDatabase.instance
        .setSetting('map_cache_only', _offlineOnly ? '1' : '0');
    _buildProviders();
    if (mounted) setState(() {});
    _snack(_offlineOnly
        ? 'وضع بدون إنترنت: الخريطة من المخزّن فقط'
        : 'الوضع العادي: يحمّل من النت ما ينقص');
  }

  void _scheduleGpsRetry() {
    _gpsRetry?.cancel();
    _gpsRetry = Timer(const Duration(seconds: 6), () {
      if (mounted) _startLocation();
    });
  }

  Future<void> _startLocation() async {
    _gpsRetry?.cancel();
    await _posSub?.cancel();
    _posSub = null;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          setState(
                  () => _msg = 'فعّل خدمة الموقع (GPS) من إعدادات الجهاز');
        }
        _scheduleGpsRetry();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() =>
          _msg = 'صلاحية الموقع مرفوضة. فعّلها من إعدادات التطبيق');
        }
        return;
      }

      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null && mounted && _me == null) {
          final ll = LatLng(last.latitude, last.longitude);
          setState(() {
            _me = ll;
            _accuracy = last.accuracy;
            _alt = last.altitude;
          });
          _fixTick.value++;
          _centerOn(ll);
        }
      } catch (_) {}

      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best, distanceFilter: 2),
      ).listen((p) {
        if (!mounted) return;
        final ll = LatLng(p.latitude, p.longitude);
        setState(() {
          _me = ll;
          _accuracy = p.accuracy;
          _alt = p.altitude;
          _speed = p.speed;
          _msg = null;
          if (FlutterCompass.events == null &&
              p.speed > 0.5 &&
              p.heading >= 0) {
            _heading = p.heading;
          }
        });
        _fixTick.value++;
        if (_dragIndex != null) return;
        if (!_centeredOnce) {
          _centerOn(ll);
        } else if (_follow && _mapReady && !_drawing) {
          _map.move(ll, _map.camera.zoom);
        }
      }, onError: (_) {
        if (mounted) {
          setState(
                  () => _msg = 'انقطعت إشارة الموقع، جاري إعادة المحاولة...');
        }
        _scheduleGpsRetry();
      }, cancelOnError: true);
    } catch (_) {
      if (mounted) {
        setState(
                () => _msg = 'تعذر تشغيل تحديد الموقع، جاري إعادة المحاولة...');
      }
      _scheduleGpsRetry();
    }
  }

  Widget _coordsBar() => GestureDetector(
    onTap: () {
      if (_me == null) return;
      Clipboard.setData(ClipboardData(
          text:
          '${_me!.latitude.toStringAsFixed(6)}, ${_me!.longitude.toStringAsFixed(6)}'));
      _snack('تم نسخ الإحداثيات');
    },
    child: Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 68, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
          color: AppColors.navy.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          const Icon(Icons.gps_fixed_rounded,
              color: AppColors.gold, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _me == null
                  ? 'بانتظار إشارة GPS...'
                  : 'العرض: ${_me!.latitude.toStringAsFixed(6)}   الطول: ${_me!.longitude.toStringAsFixed(6)}'
                  '\nالدقة: ±${_accuracy.toStringAsFixed(0)} م${_offlineOnly ? '   •   بدون إنترنت' : ''}',
              style: GoogleFonts.cairo(color: Colors.white, fontSize: 12),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'وضع بدون إنترنت',
            icon: Icon(
                _offlineOnly
                    ? Icons.cloud_off_rounded
                    : Icons.cloud_queue_rounded,
                color: _offlineOnly ? AppColors.gold : Colors.white70,
                size: 22),
            onPressed: _toggleOfflineOnly,
          ),
        ],
      ),
    ),
  );

  String _dms(double v, bool isLat) {
    final dir = isLat ? (v >= 0 ? 'N' : 'S') : (v >= 0 ? 'E' : 'W');
    final a = v.abs();
    final d = a.floor();
    final mf = (a - d) * 60;
    final m = mf.floor();
    final s = (mf - m) * 60;
    return '$d°${m.toString().padLeft(2, '0')}′${s.toStringAsFixed(1).padLeft(4, '0')}″ $dir';
  }

  Future<bool> _online() async {
    try {
      final host = OfflineMaps.viaProxy
          ? Uri.parse(OfflineMaps.proxyBase).host
          : 'api.maptiler.com';
      final r =
      await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
      return r.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _showMyLocation() {
    if (_me == null) {
      _snack('لسا ما التقط الجهاز إشارة GPS. اخرج لمكان مفتوح وانتظر قليلاً');
      _startLocation();
      return;
    }
    String? address;
    var addrState = 0; // 0 جاري، 1 جاهز، 2 لا إنترنت، 3 غير متوفر
    var started = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> loadAddress() async {
            final at = _me;
            if (at == null) return;
            setS(() => addrState = 0);
            if (!await _online()) {
              if (ctx.mounted) setS(() => addrState = 2);
              return;
            }
            String? a;
            try {
              a = await _reverseGeocode(at);
            } catch (_) {}
            if (ctx.mounted) {
              setS(() {
                address = a;
                addrState = a == null ? 3 : 1;
              });
            }
          }

          if (!started) {
            started = true;
            loadAddress();
          }

          Widget tile(String label, String value) => Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFFF4F6F9),
                  borderRadius: BorderRadius.circular(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: GoogleFonts.cairo(
                          fontSize: 11, color: AppColors.textMuted)),
                  SelectableText(value,
                      style: GoogleFonts.cairo(
                          fontSize: 19, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          );

          return Directionality(
            textDirection: TextDirection.rtl,
            child: SafeArea(
              child: SingleChildScrollView(
                child: ValueListenableBuilder<int>(
                  valueListenable: _fixTick,
                  builder: (_, __, ___) {
                    final me = _me;
                    if (me == null) return const SizedBox.shrink();
                    final lat = me.latitude.toStringAsFixed(6);
                    final lng = me.longitude.toStringAsFixed(6);
                    final weak = _accuracy > 20;

                    String bounds = '';
                    try {
                      final b = _map.camera.visibleBounds;
                      bounds =
                      'شمال ${b.north.toStringAsFixed(5)}   جنوب ${b.south.toStringAsFixed(5)}\nشرق ${b.east.toStringAsFixed(5)}   غرب ${b.west.toStringAsFixed(5)}';
                    } catch (_) {}

                    final shareText =
                        'موقعي: $lat, $lng\n${address ?? ''}\nhttps://maps.google.com/?q=$lat,$lng';

                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.my_location_rounded,
                                color: Colors.blue),
                            const SizedBox(width: 8),
                            Text('موقعي الآن',
                                style: GoogleFonts.cairo(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 1),
                              decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(10)),
                              child: Text('يتحدّث مباشرة',
                                  style: GoogleFonts.cairo(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.green.shade800)),
                            ),
                          ]),
                          const SizedBox(height: 10),
                          Row(children: [
                            tile('العرض (Latitude)', lat),
                            const SizedBox(width: 10),
                            tile('الطول (Longitude)', lng),
                          ]),
                          const SizedBox(height: 8),
                          Text(
                              '${_dms(me.latitude, true)}    ${_dms(me.longitude, false)}',
                              style: GoogleFonts.cairo(
                                  fontSize: 12, color: AppColors.textMuted)),
                          const SizedBox(height: 6),
                          Text(
                              'الدقة: ±${_accuracy.toStringAsFixed(0)} م'
                                  '${weak ? '  (ضعيفة، اخرج لمكان مفتوح)' : ''}'
                                  '   •   الارتفاع: ${_alt.toStringAsFixed(0)} م (تقريبي)'
                                  '${_speed > 0.5 ? '   •   السرعة: ${(_speed * 3.6).toStringAsFixed(0)} كم/س' : ''}',
                              style: GoogleFonts.cairo(
                                  fontSize: 12,
                                  color: weak
                                      ? Colors.orange.shade800
                                      : AppColors.textMuted)),
                          if (bounds.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text('حدود الخريطة الظاهرة',
                                style: GoogleFonts.cairo(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                            Text(bounds,
                                style: GoogleFonts.cairo(
                                    fontSize: 12, color: AppColors.textMuted)),
                          ],
                          const Divider(height: 22),
                          Row(children: [
                            Expanded(
                              child: addrState == 0
                                  ? const LinearProgressIndicator()
                                  : Text(
                                  addrState == 1
                                      ? address!
                                      : addrState == 2
                                      ? 'بدون إنترنت: العنوان غير متاح (الإحداثيات تشتغل عادي)'
                                      : 'العنوان غير متوفر لهذا المكان',
                                  style: GoogleFonts.cairo(
                                      fontSize: 13,
                                      color: addrState == 1
                                          ? Colors.black87
                                          : AppColors.textMuted)),
                            ),
                            IconButton(
                              tooltip: 'تحديث العنوان',
                              icon: const Icon(Icons.refresh_rounded),
                              onPressed: loadAddress,
                            ),
                          ]),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  Clipboard.setData(
                                      ClipboardData(text: '$lat, $lng'));
                                  _snack('تم نسخ الإحداثيات');
                                },
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                label: Text('نسخ', style: GoogleFonts.cairo()),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => SharePlus.instance
                                    .share(ShareParams(text: shareText)),
                                icon:
                                const Icon(Icons.share_rounded, size: 18),
                                label:
                                Text('مشاركة', style: GoogleFonts.cairo()),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.gold,
                                    foregroundColor: AppColors.navyDark),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _savePoint(me);
                                },
                                icon: const Icon(
                                    Icons.add_location_alt_rounded,
                                    size: 18),
                                label: Text('حفظ', style: GoogleFonts.cairo()),
                              ),
                            ),
                          ]),
                          TextButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(
                                  text:
                                  '${_dms(me.latitude, true)} ${_dms(me.longitude, false)}'));
                              _snack('تم نسخ الإحداثيات بصيغة الدرجات');
                            },
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: Text('نسخ بصيغة الدرجات (DMS)',
                                style: GoogleFonts.cairo(fontSize: 12)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: _drawing ? _onPanStart : null,
                onPanUpdate: _drawing ? _onPanUpdate : null,
                onPanEnd: _drawing ? _onPanEnd : null,
                onPanCancel: _drawing ? _onPanEnd : null,
                child: _mapView(),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Column(
                  children: [
                    _roundBtn(Icons.arrow_forward_rounded,
                            () => Navigator.pop(context)),
                    _roundBtn(Icons.search_rounded, _showSearch),
                    _roundBtn(Icons.layers_rounded, _showLayers),
                    _roundBtn(
                        _satellite
                            ? Icons.map_rounded
                            : Icons.satellite_alt_rounded,
                            () => setState(() => _satellite = !_satellite)),
                    _roundBtn(Icons.bookmarks_rounded, () => _showSaved()),
                    _roundBtn(Icons.polyline_rounded,
                            () => setState(() => _drawing = !_drawing),
                        active: _drawing),
                    _roundBtn(Icons.ios_share_rounded, _exportMenu),
                    _roundBtn(
                        Icons.download_for_offline_rounded, _openOffline),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _showLayers,
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(12, 8, 68, 0),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                            color: AppColors.gold,
                            borderRadius: BorderRadius.circular(12)),
                        child: Row(
                          children: [
                            const Icon(Icons.layers_rounded,
                                size: 18, color: AppColors.navyDark),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                  'النشط: $_activeName  •  ${_visible.length} طبقة',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.cairo(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.navyDark)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    _coordsBar(),
                    if (_searchPin != null) _searchCard(),
                    if (_target != null) _targetCard(),
                    if (_msg != null)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 8, 68, 0),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: Colors.orange.shade100,
                            borderRadius: BorderRadius.circular(14)),
                        child: Text(_msg!, style: GoogleFonts.cairo()),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _drawing ? _drawPanel() : _savedBar(),
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FloatingActionButton.small(
              heroTag: 'follow',
              backgroundColor: Colors.white,
              onPressed: () {
                if (_me == null) {
                  _startLocation();
                  _snack('جاري البحث عن إشارة GPS...');
                  return;
                }
                if (_follow) {
                  _showMyLocation();
                  return;
                }
                setState(() => _follow = true);
                _map.move(_me!, 18);
              },
              child: Icon(Icons.my_location_rounded,
                  color: _follow ? Colors.blue : AppColors.textMuted),
            ),
            if (!_drawing) ...[
              const SizedBox(height: 10),
              FloatingActionButton.extended(
                heroTag: 'save',
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.navyDark,
                onPressed: () => _savePoint(_me ?? _map.camera.center),
                icon: const Icon(Icons.add_location_alt_rounded),
                label: Text('حفظ موقعي',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

extension _ProjectIndex on List<Project> {
  int indexWhereSafe(int? id) => indexWhere((p) => p.id == id);
}
