import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:excel/excel.dart' as xl;
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../core/app_colors.dart';
import '../../core/database.dart';
import '../../core/export_service.dart';
import 'visit_detail_screen.dart';
import 'visit_form_screen.dart';
import 'visit_models.dart';
import 'visit_sync.dart';

class VisitsScreen extends StatefulWidget {
  const VisitsScreen({super.key});

  @override
  State<VisitsScreen> createState() => _VisitsScreenState();
}

class _VisitsScreenState extends State<VisitsScreen> {
  final _sync = VisitSync.instance;
  final _search = TextEditingController();
  List<Visit> _all = [];
  List<String> _purposes = List.of(kDefaultPurposes);
  String _me = '';
  String? _fPurpose;
  String? _fStatus;
  String? _fVisitor;
  int _tab = 0;
  bool _loading = true;
  bool _wasSyncing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync.addListener(_onSync);
    _init();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _sync.syncNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sync.removeListener(_onSync);
    _search.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _purposes = await VisitSync.loadPurposes();
    _me = await VisitSync.loadVisitor();
    await _load();
    _sync.syncNow();
  }

  void _onSync() {
    if (!mounted) return;
    if (_wasSyncing && !_sync.syncing) _load();
    _wasSyncing = _sync.syncing;
    setState(() {});
  }

  Future<void> _load() async {
    try {
      final l = await AppDatabase.instance.getVisits();
      await _sync.refreshPending();
      if (mounted) {
        setState(() {
          _all = l;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  String _fmt(DateTime d) => DateFormat('yyyy/MM/dd HH:mm').format(d);

  List<Visit> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _all.where((v) {
      if (_fPurpose != null && v.purpose != _fPurpose) return false;
      if (_fStatus != null && v.status != _fStatus) return false;
      if (_fVisitor != null && v.visitor != _fVisitor) return false;
      if (q.isNotEmpty) {
        final hay =
        '${v.siteCode} ${v.siteName} ${v.purpose} ${v.visitor} ${v.notes}'
            .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  Future<void> _newVisit() async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const VisitFormScreen()));
    if (ok == true) _load();
  }

  Future<void> _open(Visit v) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VisitDetailScreen(visit: v, me: _me)));
    _me = await VisitSync.loadVisitor();
    _load();
  }

  Future<void> _openSettings() async {
    final name = TextEditingController(text: _me);
    final purposes = TextEditingController(text: _purposes.join('\n'));
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('إعدادات الزيارات',
                    style: GoogleFonts.cairo(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                      labelText: 'اسمك (اسم الباحث)',
                      labelStyle: GoogleFonts.cairo(),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12))),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: purposes,
                  minLines: 4,
                  maxLines: 10,
                  decoration: InputDecoration(
                      labelText: 'أغراض الزيارة (غرض بكل سطر)',
                      labelStyle: GoogleFonts.cairo(),
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12))),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => purposes.text = kDefaultPurposes.join('\n'),
                      child: Text('الافتراضي', style: GoogleFonts.cairo()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.gold,
                          foregroundColor: AppColors.navyDark),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text('حفظ',
                          style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok == true) {
      final list = purposes.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final db = AppDatabase.instance;
      await db.setSetting('visit_visitor_name', name.text.trim());
      await db.setSetting(
          'visit_purposes', jsonEncode(list.isEmpty ? kDefaultPurposes : list));
      _purposes = await VisitSync.loadPurposes();
      _me = name.text.trim();
      if (mounted) setState(() {});
    }
    name.dispose();
    purposes.dispose();
  }

  Future<void> _export() async {
    final list = _filtered;
    if (list.isEmpty) {
      _snack('لا توجد زيارات للتصدير');
      return;
    }
    try {
      final x = xl.Excel.createExcel();
      final s = x['الزيارات'];
      s.isRTL = true;
      s.appendRow([
        for (final h in [
          'التاريخ',
          'كود الموقع',
          'اسم الموقع',
          'الغرض',
          'الحالة',
          'الباحث',
          'خط العرض',
          'خط الطول',
          'الدقة (م)',
          'ملاحظات',
          'عدد الصور'
        ])
          xl.TextCellValue(h)
      ]);
      for (final v in list.reversed) {
        s.appendRow([
          xl.TextCellValue(_fmt(v.visitedAt)),
          xl.TextCellValue(v.siteCode),
          xl.TextCellValue(v.siteName),
          xl.TextCellValue(v.purpose),
          xl.TextCellValue(statusLabel(v.status)),
          xl.TextCellValue(v.visitor),
          v.lat == null ? xl.TextCellValue('') : xl.DoubleCellValue(v.lat!),
          v.lng == null ? xl.TextCellValue('') : xl.DoubleCellValue(v.lng!),
          v.accuracy == null
              ? xl.TextCellValue('')
              : xl.DoubleCellValue(double.parse(v.accuracy!.toStringAsFixed(1))),
          xl.TextCellValue(v.notes),
          xl.IntCellValue(v.photoIds.length),
        ]);
      }
      x.delete('Sheet1');
      final data = x.save();
      if (data == null) throw Exception('تعذر إنشاء الملف');
      if (!mounted) return;
      await showExportSheet(
        context,
        baseName: 'visits_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}',
        ext: 'xlsx',
        bytes: Uint8List.fromList(data),
        mime:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        mimeType: MimeType.microsoftExcel,
      );
    } catch (e) {
      _snack('تعذر التصدير: $e');
    }
  }

  // ---------------- الواجهة ----------------
  Widget _syncBanner() {
    final s = _sync;
    String? msg;
    var c = Colors.green;
    if (!s.enabled) {
      msg = 'المزامنة غير مفعّلة: الخادم الوسيط غير مضبوط';
      c = Colors.orange;
    } else if (s.error != null) {
      msg = s.error;
      c = Colors.red;
    } else if (s.syncing) {
      msg = 'جاري المزامنة...';
      c = Colors.blue;
    } else if (s.pending > 0) {
      msg = '${s.pending} بانتظار الرفع';
      c = Colors.orange;
    } else if (s.lastOk != null) {
      msg = 'آخر مزامنة: ${DateFormat('HH:mm').format(s.lastOk!)}';
      c = Colors.green;
    }
    if (msg == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: c.withOpacity(0.10), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.cloud_sync_rounded, size: 18, color: c),
        const SizedBox(width: 8),
        Expanded(
            child: Text(msg, style: GoogleFonts.cairo(fontSize: 12, color: c))),
      ]),
    );
  }

  Widget _stat(String label, int n, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        Text('$n',
            style: GoogleFonts.cairo(
                fontSize: 20, fontWeight: FontWeight.w700, color: c)),
        Text(label,
            style:
            GoogleFonts.cairo(fontSize: 11, color: AppColors.textMuted)),
      ]),
    ),
  );

  Widget _dd(String hint, String? value, List<String> items,
      void Function(String?) on,
      {String Function(String)? label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: value,
          hint: Text(hint, style: GoogleFonts.cairo(fontSize: 12)),
          isDense: true,
          items: [
            DropdownMenuItem<String?>(
                value: null,
                child: Text('$hint: الكل', style: GoogleFonts.cairo(fontSize: 12))),
            for (final i in items)
              DropdownMenuItem<String?>(
                  value: i,
                  child: Text(label == null ? i : label(i),
                      style: GoogleFonts.cairo(fontSize: 12))),
          ],
          onChanged: on,
        ),
      ),
    );
  }

  Widget _filters() {
    final purposes = <String>{
      ..._purposes,
      ..._all.map((v) => v.purpose)
    }.where((e) => e.isNotEmpty).toList();
    final visitors =
    _all.map((v) => v.visitor).where((e) => e.isNotEmpty).toSet().toList();
    return Column(children: [
      TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'بحث بالموقع أو الغرض أو الباحث',
          hintStyle: GoogleFonts.cairo(fontSize: 13),
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          _dd('الغرض', _fPurpose, purposes, (v) => setState(() => _fPurpose = v)),
          _dd('الحالة', _fStatus, kVisitStatuses,
                  (v) => setState(() => _fStatus = v),
              label: statusLabel),
          _dd('الباحث', _fVisitor, visitors,
                  (v) => setState(() => _fVisitor = v)),
        ]),
      ),
    ]);
  }

  Widget _card(Visit v) {
    final c = statusColor(v.status);
    return InkWell(
      onTap: () => _open(v),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: AppColors.navy.withOpacity(0.06),
                blurRadius: 12,
                offset: const Offset(0, 5)),
          ],
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              width: 6,
              decoration: BoxDecoration(
                  color: c,
                  borderRadius: const BorderRadiusDirectional.only(
                      topStart: Radius.circular(16),
                      bottomStart: Radius.circular(16))),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(v.siteLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                                fontWeight: FontWeight.w700, fontSize: 15)),
                      ),
                      if (v.dirty > 0)
                        const Icon(Icons.cloud_upload_rounded,
                            size: 18, color: Colors.orange),
                      if (v.photoIds.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.photo_camera_rounded,
                            size: 16, color: AppColors.textMuted),
                        Text('${v.photoIds.length}',
                            style: GoogleFonts.cairo(
                                fontSize: 11, color: AppColors.textMuted)),
                      ],
                    ]),
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      _chip(v.purpose, AppColors.navy),
                      _chip(statusLabel(v.status), c),
                    ]),
                    const SizedBox(height: 4),
                    Text('${v.visitor}  •  ${_fmt(v.visitedAt)}',
                        style: GoogleFonts.cairo(
                            fontSize: 11, color: AppColors.textMuted)),
                    if (v.notes.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(v.notes,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(fontSize: 12)),
                      ),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _chip(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
        color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
    child: Text(t,
        style: GoogleFonts.cairo(
            fontSize: 11, fontWeight: FontWeight.w700, color: c)),
  );

  Widget _sitesView(List<Visit> list) {
    final groups = <String, List<Visit>>{};
    for (final v in list) {
      groups.putIfAbsent(v.siteKey, () => []).add(v);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) =>
          groups[b]!.first.visitedAt.compareTo(groups[a]!.first.visitedAt));
    if (keys.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
            child: Text('لا توجد زيارات',
                style: GoogleFonts.cairo(color: AppColors.textMuted))),
      );
    }
    return Column(children: [
      for (final k in keys)
        Builder(builder: (_) {
          final g = groups[k]!;
          final last = g.first;
          final visitors = g.map((e) => e.visitor).toSet().length;
          final worst = g.any((e) => e.status == 'urgent')
              ? 'urgent'
              : (g.any((e) => e.status == 'followup') ? 'followup' : 'completed');
          return InkWell(
            onTap: () => setState(() {
              _search.text = last.siteCode.trim().isNotEmpty
                  ? last.siteCode.trim()
                  : last.siteName.trim();
              _tab = 0;
            }),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Icon(statusIcon(worst), color: statusColor(worst)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(last.siteLabel,
                          style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(
                          '${g.length} زيارة  •  $visitors باحث  •  آخر زيارة ${_fmt(last.visitedAt)}',
                          style: GoogleFonts.cairo(
                              fontSize: 11, color: AppColors.textMuted)),
                      Text('آخر غرض: ${last.purpose}',
                          style: GoogleFonts.cairo(fontSize: 12)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_left_rounded),
              ]),
            ),
          );
        }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    final urgent = list.where((v) => v.status == 'urgent').length;
    final follow = list.where((v) => v.status == 'followup').length;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('الزيارات الميدانية',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
          actions: [
            IconButton(
              tooltip: 'مزامنة',
              icon: _sync.syncing
                  ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync_rounded),
              onPressed: _sync.syncing ? null : _sync.syncNow,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'export') _export();
                if (v == 'settings') _openSettings();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'export',
                    child: Text('تصدير Excel', style: GoogleFonts.cairo())),
                PopupMenuItem(
                    value: 'settings',
                    child: Text('اسمي وأغراض الزيارة',
                        style: GoogleFonts.cairo())),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.navyDark,
          onPressed: _newVisit,
          icon: const Icon(Icons.add_location_alt_rounded),
          label: Text('زيارة جديدة',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
          onRefresh: () async {
            await _sync.syncNow();
            await _load();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
            children: [
              _syncBanner(),
              Row(children: [
                _stat('زيارات', list.length, AppColors.navy),
                const SizedBox(width: 8),
                _stat('تحتاج متابعة', follow, const Color(0xFFEF6C00)),
                const SizedBox(width: 8),
                _stat('عاجلة', urgent, const Color(0xFFD32F2F)),
              ]),
              const SizedBox(height: 12),
              _filters(),
              const SizedBox(height: 10),
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                      value: 0,
                      icon: const Icon(Icons.list_alt_rounded),
                      label: Text('الزيارات', style: GoogleFonts.cairo())),
                  ButtonSegment(
                      value: 1,
                      icon: const Icon(Icons.holiday_village_rounded),
                      label: Text('حسب الموقع',
                          style: GoogleFonts.cairo())),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              const SizedBox(height: 12),
              if (_tab == 1)
                _sitesView(list)
              else if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text(
                        _all.isEmpty
                            ? 'لا توجد زيارات بعد. اضغط «زيارة جديدة»'
                            : 'لا توجد نتائج للفلتر الحالي',
                        style: GoogleFonts.cairo(
                            color: AppColors.textMuted)),
                  ),
                )
              else
                for (final v in list) _card(v),
            ],
          ),
        ),
      ),
    );
  }
}