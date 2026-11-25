import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import '../../core/app_colors.dart';
import '../../core/database.dart';
import '../projects/project.dart';
import 'kml_parser.dart';
import 'map_area.dart';
import 'map_point.dart';

class _Item {
  final String file;
  final KmlGroup group;
  bool selected = true;
  final TextEditingController name;
  _Item(this.file, this.group)
      : name = TextEditingController(text: group.name);
}

class KmlImportScreen extends StatefulWidget {
  const KmlImportScreen({super.key});

  @override
  State<KmlImportScreen> createState() => _KmlImportScreenState();
}

class _KmlImportScreenState extends State<KmlImportScreen> {
  final List<_Item> _items = [];
  final _singleName = TextEditingController(text: 'مجلد مستورد');
  bool _includeOpen = false;
  bool _single = false;
  bool _busy = false;
  String _status = '';
  final List<String> _errors = [];

  @override
  void dispose() {
    for (final i in _items) {
      i.name.dispose();
    }
    _singleName.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  int get _selPoints => _items
      .where((e) => e.selected)
      .fold(0, (s, e) => s + e.group.points.length);

  int get _selAreas => _items.where((e) => e.selected).fold(
      0,
          (s, e) =>
      s + e.group.closedCount + (_includeOpen ? e.group.openCount : 0));

  Future<void> _pick() async {
    try {
      final r = await FilePicker.pickFiles(
          type: FileType.any, allowMultiple: true);
      if (r == null || r.files.isEmpty) return;
      setState(() {
        _busy = true;
        _status = 'جاري قراءة الملفات...';
        _errors.clear();
      });
      for (final f in r.files) {
        final path = f.path;
        if (path == null) continue;
        final lower = f.name.toLowerCase();
        if (!(lower.endsWith('.kml') ||
            lower.endsWith('.kmz') ||
            lower.endsWith('.gpx'))) {
          _errors.add('${f.name}: صيغة غير مدعومة (المدعوم KML وKMZ وGPX)');
          continue;
        }
        try {
          final bytes = await File(path).readAsBytes();
          final groups = KmlParser.parse(f.name, bytes);
          if (groups.isEmpty) {
            _errors.add('${f.name}: لا يحتوي نقاطاً ولا حدوداً');
            continue;
          }
          for (final g in groups) {
            _items.add(_Item(f.name, g));
          }
        } catch (e) {
          _errors.add(
              '${f.name}: ${e.toString().replaceFirst('Exception: ', '')}');
        }
      }
    } catch (e) {
      _errors.add('تعذر فتح الملفات: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _pk(double a, double b) =>
      '${a.toStringAsFixed(6)},${b.toStringAsFixed(6)}';

  String _ak(List<LatLng> p) =>
      '${p.length}|${_pk(p.first.latitude, p.first.longitude)}';

  String _unique(String base, Set<String> used) {
    var n = base;
    var i = 2;
    while (used.contains(n.toLowerCase())) {
      n = '$base ($i)';
      i++;
    }
    used.add(n.toLowerCase());
    return n;
  }

  Future<void> _import() async {
    final chosen = _items.where((e) => e.selected).toList();
    if (chosen.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'جاري الاستيراد...';
    });
    final db = AppDatabase.instance;
    var nPts = 0, nAreas = 0, skipP = 0, skipA = 0, newF = 0, openSkipped = 0;
    try {
      final projects = await db.getProjects();
      final known = <String, int>{
        for (final p in projects)
          if (p.id != null) p.name.trim().toLowerCase(): p.id!
      };
      final byTarget = <String, List<_Item>>{};
      for (final it in chosen) {
        var t = (_single ? _singleName.text : it.name.text).trim();
        if (t.isEmpty) t = it.group.name;
        byTarget.putIfAbsent(t, () => []).add(it);
      }

      for (final e in byTarget.entries) {
        if (mounted) setState(() => _status = 'جاري استيراد "${e.key}"...');
        final key = e.key.toLowerCase();
        final found = known[key];
        final int pid;
        if (found != null) {
          pid = found;
        } else {
          pid = await db.insertProject(Project(name: e.key));
          known[key] = pid;
          newF++;
        }

        final existP = await db.getPoints(projectId: pid);
        final existA = await db.getAreas(projectId: pid);
        final namesP = <String>{for (final p in existP) p.name.toLowerCase()};
        final keysP = <String>{for (final p in existP) _pk(p.lat, p.lng)};
        final namesA = <String>{for (final a in existA) a.name.toLowerCase()};
        final keysA = <String>{
          for (final a in existA)
            if (a.points.length >= 3) _ak(a.points)
        };

        final newPts = <MapPoint>[];
        final newAreas = <MapArea>[];

        for (final it in e.value) {
          var i = 0;
          for (final p in it.group.points) {
            i++;
            if (!keysP.add(_pk(p.lat, p.lng))) {
              skipP++;
              continue;
            }
            final base = p.name.trim().isEmpty ? 'نقطة $i' : p.name.trim();
            newPts.add(MapPoint(
              projectId: pid,
              name: _unique(base, namesP),
              note: p.note,
              lat: p.lat,
              lng: p.lng,
              favorite: false,
            ));
          }
          var j = 0;
          for (final l in it.group.lines) {
            if (!l.closed && !_includeOpen) {
              openSkipped++;
              continue;
            }
            j++;
            final pts = List<LatLng>.of(l.pts);
            if (pts.length > 3 &&
                pts.first.latitude == pts.last.latitude &&
                pts.first.longitude == pts.last.longitude) {
              pts.removeLast();
            }
            if (pts.length < 3) continue;
            if (!keysA.add(_ak(pts))) {
              skipA++;
              continue;
            }
            final base = l.name.trim().isEmpty ? 'حدود $j' : l.name.trim();
            newAreas.add(MapArea(
              projectId: pid,
              name: _unique(base, namesA),
              points: pts,
              areaM2: GeoMath.area(pts),
              perimeterM: GeoMath.perimeter(pts),
              color: l.color ?? kNavyArgb,
            ));
          }
        }
        await db.insertPointsBatch(newPts);
        await db.insertAreasBatch(newAreas);
        nPts += newPts.length;
        nAreas += newAreas.length;
      }

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('تم الاستيراد', style: GoogleFonts.cairo()),
            content: Text(
                'نقاط جديدة: $nPts\nحدود جديدة: $nAreas\nمجلدات جديدة: $newF'
                    '${skipP + skipA > 0 ? '\nمكرّر تم تخطّيه: ${skipP + skipA}' : ''}'
                    '${openSkipped > 0 ? '\nمسارات مفتوحة لم تُستورد: $openSkipped' : ''}',
                style: GoogleFonts.cairo(height: 1.7)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('تمام', style: GoogleFonts.cairo())),
            ],
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _snack('تعذر الاستيراد: $e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _card(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      boxShadow: [
        BoxShadow(
            color: AppColors.navy.withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 6)),
      ],
    ),
    child: child,
  );

  Widget _itemCard(_Item it) {
    final g = it.group;
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Checkbox(
              value: it.selected,
              onChanged: _busy ? null : (v) => setState(() => it.selected = v ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${g.points.length} نقطة  •  ${g.closedCount} حدود مغلقة  •  ${g.openCount} مسار مفتوح',
                      style: GoogleFonts.cairo(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                  Text(it.file,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                          fontSize: 11, color: AppColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
        if (!_single)
          TextField(
            controller: it.name,
            enabled: it.selected && !_busy,
            decoration: InputDecoration(
              labelText: 'اسم المجلد في التطبيق',
              labelStyle: GoogleFonts.cairo(),
              prefixIcon: const Icon(Icons.folder_rounded),
              isDense: true,
            ),
          ),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('استيراد من Maps.me',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _card(Text(
                'صدّر المجلد من Maps.me كملف KML أو KMZ واحفظه على الجوال، ثم اختره هنا. تقدر تختار أكثر من ملف مرة وحدة. ملفات GPX مدعومة كمان.',
                style: GoogleFonts.cairo(fontSize: 13, height: 1.6))),
            SizedBox(
              height: 54,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.navy,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.upload_file_rounded,
                    color: AppColors.gold),
                label: Text('اختيار ملفات KML / KMZ / GPX',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              ),
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_status, style: GoogleFonts.cairo(fontSize: 12)),
                ]),
              ),
            if (_errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_errors.join('\n'),
                    style: GoogleFonts.cairo(fontSize: 12, color: Colors.red)),
              ),
            if (_items.isNotEmpty) ...[
              const SizedBox(height: 12),
              _card(Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('كل مجموعة تصير مجلداً مستقلاً',
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    subtitle: Text('أطفئه لوضع كل شي بمجلد واحد',
                        style: GoogleFonts.cairo(fontSize: 11)),
                    value: !_single,
                    onChanged:
                    _busy ? null : (v) => setState(() => _single = !v),
                  ),
                  if (_single)
                    TextField(
                      controller: _singleName,
                      decoration: InputDecoration(
                        labelText: 'اسم المجلد',
                        labelStyle: GoogleFonts.cairo(),
                        prefixIcon: const Icon(Icons.folder_rounded),
                        isDense: true,
                      ),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('استيراد المسارات المفتوحة كحدود',
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    subtitle: Text(
                        'المسار المغلق (بدايته قرب نهايته) يُستورد كحدود دائماً. المفتوح يُغلق بخط مستقيم لو فعّلت هذا',
                        style: GoogleFonts.cairo(fontSize: 11)),
                    value: _includeOpen,
                    onChanged:
                    _busy ? null : (v) => setState(() => _includeOpen = v),
                  ),
                ],
              )),
              for (final it in _items) _itemCard(it),
              const SizedBox(height: 6),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.navyDark,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed:
                  (_busy || (_selPoints + _selAreas) == 0) ? null : _import,
                  icon: const Icon(Icons.download_done_rounded),
                  label: Text(
                      'استيراد ($_selPoints نقطة، $_selAreas حدود)',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    );
  }
}