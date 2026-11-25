import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../core/app_colors.dart';
import '../../core/database.dart';
import 'visit_models.dart';
import 'visit_sync.dart';

class _Ph {
  final String id;
  final String path;
  final bool isNew;
  _Ph(this.id, this.path, {this.isNew = false});
}

class VisitFormScreen extends StatefulWidget {
  final Visit? visit;
  const VisitFormScreen({super.key, this.visit});

  @override
  State<VisitFormScreen> createState() => _VisitFormScreenState();
}

class _VisitFormScreenState extends State<VisitFormScreen> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _notes = TextEditingController();
  final _visitor = TextEditingController();
  List<String> _purposes = List.of(kDefaultPurposes);
  String _purpose = '';
  String _status = 'completed';
  late DateTime _when;
  double? _lat;
  double? _lng;
  double? _acc;
  bool _gpsBusy = false;
  bool _saving = false;
  bool _dirty = false;
  final List<_Ph> _photos = [];
  final List<_Ph> _removed = [];

  bool get _editing => widget.visit != null;

  @override
  void initState() {
    super.initState();
    _when = DateTime.now();
    _init();
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _notes.dispose();
    _visitor.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _purposes = await VisitSync.loadPurposes();
    final v = widget.visit;
    if (v != null) {
      _code.text = v.siteCode;
      _name.text = v.siteName;
      _notes.text = v.notes;
      _visitor.text = v.visitor;
      _purpose = v.purpose;
      _status = v.status;
      _when = v.visitedAt;
      _lat = v.lat;
      _lng = v.lng;
      _acc = v.accuracy;
      final db = AppDatabase.instance;
      for (final id in v.photoIds) {
        final row = await db.getPhoto(id);
        final p = (row?['path'] ?? '').toString();
        if (p.isNotEmpty && File(p).existsSync()) _photos.add(_Ph(id, p));
      }
    } else {
      _visitor.text = await VisitSync.loadVisitor();
      if (_purposes.isNotEmpty) _purpose = _purposes.first;
      _captureGps();
    }
    if (mounted) setState(() {});
  }

  void _touch() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _captureGps() async {
    setState(() => _gpsBusy = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _snack('فعّل خدمة الموقع (GPS) من الجهاز');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _snack('صلاحية الموقع مرفوضة');
        return;
      }
      Position? p;
      try {
        p = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.best,
                timeLimit: Duration(seconds: 25)));
      } catch (_) {
        p = await Geolocator.getLastKnownPosition();
      }
      if (p != null && mounted) {
        setState(() {
          _lat = p!.latitude;
          _lng = p.longitude;
          _acc = p.accuracy;
          _dirty = true;
        });
      } else {
        _snack('تعذر التقاط الموقع. جرّب في مكان مفتوح');
      }
    } finally {
      if (mounted) setState(() => _gpsBusy = false);
    }
  }

  Future<void> _addPhoto(ImageSource src) async {
    try {
      final x = await ImagePicker()
          .pickImage(source: src, imageQuality: 60, maxWidth: 1280);
      if (x == null) return;
      final dir = await VisitSync.photoDir();
      final id = newId('p');
      final dest = '${dir.path}/$id.jpg';
      await File(x.path).copy(dest);
      setState(() {
        _photos.add(_Ph(id, dest, isNew: true));
        _dirty = true;
      });
    } catch (e) {
      _snack('تعذر إضافة الصورة: $e');
    }
  }

  Future<void> _pickSite() async {
    final db = AppDatabase.instance;
    final entries = <String, ({String code, String name})>{};
    void add(String code, String name) {
      final k = (code.isNotEmpty ? code : name).toLowerCase();
      if (k.isEmpty) return;
      entries.putIfAbsent(k, () => (code: code, name: name));
    }

    for (final p in await db.getProjects()) {
      final sp = p.id == null ? null : await db.getSiteProfile(p.id!);
      add((sp?.code ?? '').trim(), p.name.trim());
    }
    for (final v in await db.getVisits()) {
      add(v.siteCode.trim(), v.siteName.trim());
    }
    if (!mounted) return;
    final all = entries.values.toList();
    final q = TextEditingController();
    final picked = await showModalBottomSheet<({String code, String name})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final f = all.where((e) {
            final t = q.text.trim().toLowerCase();
            return t.isEmpty ||
                e.code.toLowerCase().contains(t) ||
                e.name.toLowerCase().contains(t);
          }).toList();
          return Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(children: [
                  const SizedBox(height: 12),
                  Text('اختر الموقع',
                      style: GoogleFonts.cairo(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: q,
                      onChanged: (_) => setS(() {}),
                      decoration: InputDecoration(
                          hintText: 'بحث',
                          prefixIcon: const Icon(Icons.search_rounded),
                          isDense: true,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12))),
                    ),
                  ),
                  Expanded(
                    child: f.isEmpty
                        ? Center(
                        child: Text('لا توجد مواقع. اكتب الكود والاسم يدوياً',
                            style: GoogleFonts.cairo(
                                color: AppColors.textMuted)))
                        : ListView(children: [
                      for (final e in f)
                        ListTile(
                          leading: const Icon(Icons.holiday_village_rounded,
                              color: AppColors.navy),
                          title: Text(
                              e.code.isNotEmpty && e.name.isNotEmpty
                                  ? '${e.code} - ${e.name}'
                                  : (e.code.isNotEmpty ? e.code : e.name),
                              style: GoogleFonts.cairo()),
                          onTap: () => Navigator.pop(ctx, e),
                        ),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
    q.dispose();
    if (picked != null) {
      setState(() {
        _code.text = picked.code;
        _name.text = picked.name;
        _dirty = true;
      });
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context,
        initialDate: _when,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (d == null) return;
    setState(() {
      _when = DateTime(d.year, d.month, d.day, _when.hour, _when.minute);
      _dirty = true;
    });
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (t == null) return;
    setState(() {
      _when = DateTime(_when.year, _when.month, _when.day, t.hour, t.minute);
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final code = _code.text.trim();
    final name = _name.text.trim();
    final visitor = _visitor.text.trim();
    if (code.isEmpty && name.isEmpty) {
      _snack('حدد الموقع (الكود أو الاسم)');
      return;
    }
    if (_purpose.trim().isEmpty) {
      _snack('اختر الغرض من الزيارة');
      return;
    }
    if (visitor.isEmpty) {
      _snack('اكتب اسم الباحث');
      return;
    }
    setState(() => _saving = true);
    try {
      final db = AppDatabase.instance;
      final old = widget.visit;
      final v = Visit(
        id: old?.id ?? newId('v'),
        siteCode: code,
        siteName: name,
        purpose: _purpose,
        status: _status,
        visitor: visitor,
        visitedAt: _when,
        lat: _lat,
        lng: _lng,
        accuracy: _acc,
        notes: _notes.text.trim(),
        photoIds: _photos.map((p) => p.id).toList(),
        createdAt: old?.createdAt,
        seq: old?.seq ?? 0,
      );
      await db.saveVisitLocal(v);
      for (final p in _photos) {
        if (p.isNew) await db.addPhoto(p.id, v.id, p.path, uploaded: false);
      }
      for (final p in _removed) {
        await db.deletePhotoRow(p.id);
        try {
          File(p.path).deleteSync();
        } catch (_) {}
      }
      await db.setSetting('visit_visitor_name', visitor);
      VisitSync.instance.syncNow();
      _dirty = false;
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _snack('تعذر الحفظ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _askLeave() async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تعديلات غير محفوظة', style: GoogleFonts.cairo()),
          content: Text('هل تريد الخروج بدون حفظ؟', style: GoogleFonts.cairo()),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('بقاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('خروج',
                    style: GoogleFonts.cairo(color: Colors.red))),
          ],
        ),
      ),
    );
    if (r == true && mounted) {
      _dirty = false;
      Navigator.of(context).pop();
    }
  }

  Widget _section(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 14),
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: GoogleFonts.cairo(
                fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );

  Widget _tf(TextEditingController c, String label,
      {int minLines = 1, int? maxLines = 1}) =>
      TextField(
        controller: c,
        minLines: minLines,
        maxLines: maxLines,
        onChanged: (_) => _touch(),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: GoogleFonts.cairo(fontSize: 13),
          isDense: true,
          alignLabelWithHint: true,
          filled: true,
          fillColor: const Color(0xFFF4F6F9),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final purposes = <String>{
      ..._purposes,
      if (_purpose.isNotEmpty) _purpose
    }.toList();
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _askLeave();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
            title: Text(_editing ? 'تعديل الزيارة' : 'زيارة جديدة',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
          ),
          body: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
            children: [
              _section('الموقع', [
                Row(children: [
                  Expanded(flex: 2, child: _tf(_code, 'كود الموقع')),
                  const SizedBox(width: 8),
                  Expanded(flex: 3, child: _tf(_name, 'اسم الموقع')),
                ]),
                TextButton.icon(
                  onPressed: _pickSite,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: Text('اختيار من المواقع المعروفة',
                      style: GoogleFonts.cairo()),
                ),
              ]),
              _section('الغرض والحالة', [
                DropdownButtonFormField<String>(
                  value: purposes.contains(_purpose) ? _purpose : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'الغرض من الزيارة',
                    labelStyle: GoogleFonts.cairo(fontSize: 13),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF4F6F9),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                  items: [
                    for (final p in purposes)
                      DropdownMenuItem(
                          value: p,
                          child: Text(p, style: GoogleFonts.cairo(fontSize: 13))),
                  ],
                  onChanged: (v) => setState(() {
                    _purpose = v ?? _purpose;
                    _dirty = true;
                  }),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, children: [
                  for (final s in kVisitStatuses)
                    ChoiceChip(
                      avatar: Icon(statusIcon(s),
                          size: 18,
                          color: _status == s ? Colors.white : statusColor(s)),
                      label: Text(statusLabel(s),
                          style: GoogleFonts.cairo(
                              color: _status == s ? Colors.white : null)),
                      selected: _status == s,
                      selectedColor: statusColor(s),
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _status = s;
                        _dirty = true;
                      }),
                    ),
                ]),
              ]),
              _section('الباحث والتاريخ', [
                _tf(_visitor, 'اسم الباحث'),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today_rounded, size: 18),
                      label: Text(DateFormat('yyyy/MM/dd').format(_when),
                          style: GoogleFonts.cairo()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule_rounded, size: 18),
                      label: Text(DateFormat('HH:mm').format(_when),
                          style: GoogleFonts.cairo()),
                    ),
                  ),
                ]),
              ]),
              _section('موقع GPS', [
                Row(children: [
                  Expanded(
                    child: Text(
                        _lat == null
                            ? 'لم يُلتقط الموقع بعد'
                            : '${_lat!.toStringAsFixed(6)}, ${_lng!.toStringAsFixed(6)}'
                            '${_acc == null ? '' : '  (±${_acc!.toStringAsFixed(0)} م)'}',
                        style: GoogleFonts.cairo(
                            fontSize: 13,
                            color: _lat == null
                                ? AppColors.textMuted
                                : Colors.black87)),
                  ),
                  _gpsBusy
                      ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton.icon(
                    onPressed: _captureGps,
                    icon: const Icon(Icons.my_location_rounded, size: 18),
                    label: Text(_lat == null ? 'التقاط' : 'تحديث',
                        style: GoogleFonts.cairo()),
                  ),
                ]),
              ]),
              _section('ملاحظات', [
                _tf(_notes, 'ملاحظات الزيارة', minLines: 3, maxLines: null),
              ]),
              _section('الصور', [
                if (_photos.isNotEmpty)
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final p in _photos)
                      Stack(children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(File(p.path),
                              width: 96, height: 96, fit: BoxFit.cover),
                        ),
                        PositionedDirectional(
                          top: 2,
                          end: 2,
                          child: GestureDetector(
                            onTap: () => setState(() {
                              _photos.remove(p);
                              _removed.add(p);
                              _dirty = true;
                            }),
                            child: const CircleAvatar(
                                radius: 12,
                                backgroundColor: Colors.red,
                                child: Icon(Icons.close_rounded,
                                    size: 16, color: Colors.white)),
                          ),
                        ),
                      ]),
                  ]),
                Row(children: [
                  TextButton.icon(
                    onPressed: () => _addPhoto(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded, size: 18),
                    label: Text('كاميرا', style: GoogleFonts.cairo()),
                  ),
                  TextButton.icon(
                    onPressed: () => _addPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded, size: 18),
                    label: Text('المعرض', style: GoogleFonts.cairo()),
                  ),
                ]),
              ]),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.navyDark,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_rounded),
                  label: Text('حفظ الزيارة',
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}