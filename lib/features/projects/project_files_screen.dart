import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../core/app_colors.dart';
import '../../core/database.dart';
import '../../core/export_service.dart';

class ProjectFilesScreen extends StatefulWidget {
  final int projectId;
  const ProjectFilesScreen({super.key, required this.projectId});

  @override
  State<ProjectFilesScreen> createState() => _ProjectFilesScreenState();
}

class _ProjectFilesScreenState extends State<ProjectFilesScreen> {
  List<Map<String, dynamic>> _files = [];
  String _query = '';
  String _type = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await AppDatabase.instance.getFiles(widget.projectId);
    if (mounted) setState(() => _files = f);
  }

  String _mime(String t) {
    switch (t) {
      case 'pdf':
        return 'application/pdf';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'kml':
        return 'application/vnd.google-earth.kml+xml';
      default:
        return 'application/octet-stream';
    }
  }

  IconData _icon(String t) {
    switch (t) {
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'xlsx':
        return Icons.table_chart_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  void _msg(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _open(Map<String, dynamic> f) async {
    try {
      await ExportService.openFile(f['path'] as String);
    } catch (e) {
      _msg('تعذر الفتح: $e');
    }
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('حذف "${f['name']}"؟', style: GoogleFonts.cairo()),
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
    try {
      final file = File(f['path'] as String);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    await AppDatabase.instance.deleteFileRecord(f['id'] as int);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _files.where((f) {
      final okType = _type == 'all' || f['type'] == _type;
      final okQ = _query.isEmpty ||
          (f['name'] as String).toLowerCase().contains(_query.toLowerCase());
      return okType && okQ;
    }).toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('ملفات المشروع',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'بحث باسم الملف',
                  hintStyle: GoogleFonts.cairo(),
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final t in const [
                    ('all', 'الكل'),
                    ('pdf', 'PDF'),
                    ('xlsx', 'Excel'),
                    ('kml', 'KML'),
                    ('gpx', 'GPX'),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: ChoiceChip(
                        label: Text(t.$2, style: GoogleFonts.cairo()),
                        selected: _type == t.$1,
                        onSelected: (_) => setState(() => _type = t.$1),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(
                  child: Text('لا توجد ملفات',
                      style:
                      GoogleFonts.cairo(color: AppColors.textMuted)))
                  : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final f = list[i];
                  final date = DateFormat('yyyy/MM/dd HH:mm').format(
                      DateTime.parse(f['created_at'] as String));
                  return ListTile(
                    tileColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    onTap: () => _open(f),
                    leading: Icon(_icon(f['type'] as String),
                        color: AppColors.gold, size: 30),
                    title: Text(f['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700)),
                    subtitle: Text(date,
                        style: GoogleFonts.cairo(fontSize: 12)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.share_rounded),
                          onPressed: () async {
                            try {
                              await ExportService.shareFile(
                                  f['path'] as String,
                                  _mime(f['type'] as String));
                            } catch (e) {
                              _msg('تعذر المشاركة: $e');
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_rounded,
                              color: Colors.red),
                          onPressed: () => _delete(f),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}