import 'dart:io';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/app_colors.dart';
import '../../core/app_settings.dart';
import '../../core/database.dart';
import '../../core/export_service.dart';
import '../projects/project.dart';
import '../survey/gemini_service.dart';
import 'report_pdf.dart';

class ReportsScreen extends StatefulWidget {
  final Project? initialProject;
  const ReportsScreen({super.key, this.initialProject});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _company = TextEditingController(
      text: AppSettings.company.isEmpty ? 'اسم الشركة' : AppSettings.company);
  final _title = TextEditingController(text: 'تقرير استبيان الاحتياجات');

  List<Project> _projects = [];
  Project? _project;

  String? _fileName;
  List<List<String>> _rows = [];
  int? _col;

  String _status = '';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppDatabase.instance.getProjects().then((p) {
      if (!mounted) return;
      setState(() {
        _projects = p;
        if (widget.initialProject != null) {
          for (final x in p) {
            if (x.id == widget.initialProject!.id) _project = x;
          }
        }
      });
    });
  }

  Future<void> _pickExcel() async {
    try {
      final r = await FilePicker.pickFiles(
          type: FileType.custom, allowedExtensions: ['xlsx']);
      if (r == null || r.files.single.path == null) return;
      final bytes = await File(r.files.single.path!).readAsBytes();
      final ex = Excel.decodeBytes(bytes);
      final sheet = ex.tables[ex.tables.keys.first]!;
      setState(() {
        _fileName = r.files.single.name;
        _rows = sheet.rows
            .map((row) => row.map((c) => c?.value?.toString() ?? '').toList())
            .toList();
        _col = null;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'تعذر قراءة الملف: $e');
    }
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var cats = <NeedCategory>[];
      var body = '';
      if (_col != null) {
        setState(() => _status = 'جاري تصنيف الاحتياجات...');
        final texts = _rows
            .skip(1)
            .map((r) => _col! < r.length ? r[_col!] : '')
            .toList();
        cats = await GeminiService.categorize(texts);
        setState(() => _status = 'جاري كتابة التقرير...');
        body = await GeminiService.writeReport(cats, _title.text.trim());
      }
      setState(() => _status = 'جاري إنشاء PDF...');
      final pid = _project?.id;
      final points = await AppDatabase.instance.getPoints(projectId: pid);
      final areas = await AppDatabase.instance.getAreas(projectId: pid);
      final bytes = await ReportPdf.build(
        company: _company.text.trim(),
        title: _title.text.trim(),
        projectName: _project?.name,
        cats: cats,
        body: body,
        points: points,
        areas: areas,
      );
      if (!mounted) return;
      await showExportSheet(
        context,
        baseName: 'report_${DateTime.now().millisecondsSinceEpoch}',
        ext: 'pdf',
        bytes: bytes,
        mime: 'application/pdf',
        mimeType: MimeType.pdf,
        projectId: _project?.id,
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  InputDecoration _dec(String l, IconData i) => InputDecoration(
    labelText: l,
    labelStyle: GoogleFonts.cairo(),
    prefixIcon: Icon(i, color: AppColors.navyLight),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none),
  );

  @override
  Widget build(BuildContext context) {
    final headers = _rows.isEmpty ? <String>[] : _rows.first;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('التقارير',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
                controller: _company,
                decoration: _dec('اسم الشركة', Icons.business_rounded)),
            const SizedBox(height: 12),
            TextField(
                controller: _title,
                decoration: _dec('عنوان التقرير', Icons.title_rounded)),
            const SizedBox(height: 12),
            DropdownButtonFormField<Project?>(
              value: _project,
              decoration:
              _dec('المشروع (لنقاطه وحدوده)', Icons.folder_rounded),
              items: [
                DropdownMenuItem(
                    value: null,
                    child:
                    Text('عام (بدون مشروع)', style: GoogleFonts.cairo())),
                for (final p in _projects)
                  DropdownMenuItem(
                      value: p,
                      child: Text(p.name, style: GoogleFonts.cairo())),
              ],
              onChanged: (v) => setState(() => _project = v),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickExcel,
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(_fileName ?? 'اختر ملف Excel الاستبيان (اختياري)',
                  style: GoogleFonts.cairo()),
            ),
            if (headers.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: _col,
                decoration:
                _dec('عمود الاحتياجات', Icons.view_column_rounded),
                items: [
                  for (var i = 0; i < headers.length; i++)
                    DropdownMenuItem(
                        value: i,
                        child: Text(
                            headers[i].isEmpty ? 'عمود ${i + 1}' : headers[i],
                            style: GoogleFonts.cairo())),
                ],
                onChanged: (v) => setState(() => _col = v),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              height: 56,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.navyDark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _busy ? null : _generate,
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: Text('إنشاء التقرير PDF',
                    style: GoogleFonts.cairo(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 10),
                  Text(_status, style: GoogleFonts.cairo()),
                ]),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: GoogleFonts.cairo(color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }
}