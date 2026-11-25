import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_colors.dart';
import '../../core/database.dart';
import 'visit_form_screen.dart';
import 'visit_models.dart';
import 'visit_sync.dart';

class VisitDetailScreen extends StatefulWidget {
  final Visit visit;
  final String me;
  const VisitDetailScreen({super.key, required this.visit, required this.me});

  @override
  State<VisitDetailScreen> createState() => _VisitDetailScreenState();
}

class _VisitDetailScreenState extends State<VisitDetailScreen> {
  late Visit _v;

  @override
  void initState() {
    super.initState();
    _v = widget.visit;
  }

  bool get _mine =>
      widget.me.trim().isNotEmpty &&
          _v.visitor.trim().toLowerCase() == widget.me.trim().toLowerCase();

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _edit() async {
    final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => VisitFormScreen(visit: _v)));
    if (ok == true) {
      final fresh = await AppDatabase.instance.getVisit(_v.id);
      if (fresh != null && mounted) setState(() => _v = fresh);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('حذف هذه الزيارة للجميع؟', style: GoogleFonts.cairo()),
          content: Text('ستُحذف من أجهزة كل الفريق بعد المزامنة.',
              style: GoogleFonts.cairo()),
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
    if (ok != true) return;
    await AppDatabase.instance.softDeleteVisit(_v.id);
    VisitSync.instance.syncNow();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openMaps() async {
    if (_v.lat == null || _v.lng == null) return;
    try {
      await launchUrl(Uri.parse(
          'geo:${_v.lat},${_v.lng}?q=${_v.lat},${_v.lng}(${Uri.encodeComponent(_v.siteLabel)})'));
    } catch (_) {
      _snack('تعذر فتح تطبيق الخرائط');
    }
  }

  void _viewPhoto(File f) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(8),
        child: Stack(children: [
          InteractiveViewer(child: Image.file(f)),
          PositionedDirectional(
            top: 4,
            end: 4,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
          width: 90,
          child: Text(k,
              style: GoogleFonts.cairo(
                  fontSize: 12, color: AppColors.textMuted))),
      Expanded(
          child: Text(v,
              style: GoogleFonts.cairo(
                  fontSize: 14, fontWeight: FontWeight.w600))),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final c = statusColor(_v.status);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('تفاصيل الزيارة',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
          actions: [
            if (_mine) ...[
              IconButton(
                  tooltip: 'تعديل',
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: _edit),
              IconButton(
                  tooltip: 'حذف',
                  icon: const Icon(Icons.delete_rounded),
                  onPressed: _delete),
            ],
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(statusIcon(_v.status), color: c),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_v.siteLabel,
                          style: GoogleFonts.cairo(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                        color: c.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12)),
                    child: Text(statusLabel(_v.status),
                        style: GoogleFonts.cairo(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: c)),
                  ),
                  const Divider(height: 24),
                  _row('الغرض', _v.purpose),
                  _row('الباحث', _v.visitor),
                  _row('التاريخ',
                      DateFormat('yyyy/MM/dd HH:mm').format(_v.visitedAt)),
                  if (_v.lat != null)
                    _row('الإحداثيات',
                        '${_v.lat!.toStringAsFixed(6)}, ${_v.lng!.toStringAsFixed(6)}'
                            '${_v.accuracy == null ? '' : '  (±${_v.accuracy!.toStringAsFixed(0)} م)'}'),
                  if (_v.lat != null)
                    Row(children: [
                      TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                              text:
                              '${_v.lat!.toStringAsFixed(6)}, ${_v.lng!.toStringAsFixed(6)}'));
                          _snack('تم نسخ الإحداثيات');
                        },
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: Text('نسخ', style: GoogleFonts.cairo()),
                      ),
                      TextButton.icon(
                        onPressed: _openMaps,
                        icon: const Icon(Icons.map_rounded, size: 16),
                        label: Text('فتح بالخرائط', style: GoogleFonts.cairo()),
                      ),
                    ]),
                  if (_v.notes.trim().isNotEmpty) ...[
                    const Divider(height: 24),
                    Text('ملاحظات',
                        style: GoogleFonts.cairo(
                            fontSize: 12, color: AppColors.textMuted)),
                    const SizedBox(height: 4),
                    SelectableText(_v.notes,
                        style: GoogleFonts.cairo(fontSize: 14, height: 1.6)),
                  ],
                  if (_v.photoIds.isNotEmpty) ...[
                    const Divider(height: 24),
                    Text('الصور (${_v.photoIds.length})',
                        style: GoogleFonts.cairo(
                            fontSize: 12, color: AppColors.textMuted)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final id in _v.photoIds)
                        FutureBuilder<File?>(
                          future: VisitSync.instance.photoFile(id, _v.id),
                          builder: (_, snap) {
                            final f = snap.data;
                            return GestureDetector(
                              onTap: f == null ? null : () => _viewPhoto(f),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  width: 100,
                                  height: 100,
                                  color: const Color(0xFFE8ECF2),
                                  child: f != null
                                      ? Image.file(f, fit: BoxFit.cover)
                                      : (snap.connectionState ==
                                      ConnectionState.done
                                      ? const Icon(Icons.broken_image_rounded,
                                      color: Colors.grey)
                                      : const Center(
                                      child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child:
                                          CircularProgressIndicator(
                                              strokeWidth: 2)))),
                                ),
                              ),
                            );
                          },
                        ),
                    ]),
                  ],
                ],
              ),
            ),
            if (!_mine)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                    'هذه زيارة ${_v.visitor}. التعديل والحذف لصاحب الزيارة فقط',
                    style: GoogleFonts.cairo(
                        fontSize: 11, color: AppColors.textMuted)),
              ),
          ],
        ),
      ),
    );
  }
}