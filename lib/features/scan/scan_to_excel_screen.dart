import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:path_provider/path_provider.dart';
import '../../core/app_colors.dart';
import '../../core/app_settings.dart';
import '../../core/database.dart';
import '../../core/export_service.dart';
import '../survey/gemini_service.dart';
import 'xlsx_builder.dart';

class _Hdr {
  final String org;
  final String title;
  final String logo;
  _Hdr(this.org, this.title, this.logo);
}

class ScanToExcelScreen extends StatefulWidget {
  final int? projectId;
  const ScanToExcelScreen({super.key, this.projectId});

  @override
  State<ScanToExcelScreen> createState() => _ScanToExcelScreenState();
}

class _ScanToExcelScreenState extends State<ScanToExcelScreen> {
  final _picker = ImagePicker();
  File? _image;
  List<List<String>> _rows = [];
  bool _loading = false;
  String _status = '';
  String? _error;

  int get _cols =>
      _rows.isEmpty ? 0 : _rows.map((r) => r.length).reduce(math.max);

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  // ---------------- القراءة من الصورة ----------------
  List<List<String>> _pad(List<List<String>> rows, int n) => [
    for (final r in rows)
      [...r, ...List<String>.filled(math.max(0, n - r.length), '')]
  ];

  List<List<String>> _normalize(List<List<String>> rows) {
    if (rows.isEmpty) return [];
    final n = rows.map((r) => r.length).reduce(math.max);
    return _pad(rows, n);
  }

  bool _sameRow(List<String> a, List<String> b) {
    final n = math.max(a.length, b.length);
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i].trim().toLowerCase() : '';
      final y = i < b.length ? b[i].trim().toLowerCase() : '';
      if (x != y) return false;
    }
    return true;
  }

  Future<List<List<String>>> _readTable(Uint8List bytes, String mime) async {
    for (var i = 0; i < 4; i++) {
      try {
        return await GeminiService.imageToTable(bytes, mime);
      } catch (e) {
        final s = e.toString();
        final retry = s.contains('503') ||
            s.contains('429') ||
            s.contains('500') ||
            s.contains('504');
        if (!retry || i == 3) rethrow;
        final wait = 4 * (i + 1);
        if (mounted) {
          setState(() => _status =
          'الخادم مشغول، إعادة المحاولة بعد $wait ثانية (${i + 1}/3)...');
        }
        await Future.delayed(Duration(seconds: wait));
      }
    }
    throw Exception('فشلت قراءة الصورة');
  }

  Future<void> _capture(ImageSource source, {bool append = false}) async {
    try {
      final x = await _picker.pickImage(
          source: source, imageQuality: 85, maxWidth: 2200);
      if (x == null) return;
      final file = File(x.path);
      setState(() {
        _image = file;
        _error = null;
        _loading = true;
        _status = 'جاري قراءة الجدول من الصورة...';
      });
      final bytes = await file.readAsBytes();
      final mime =
      x.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      var got = _normalize(await _readTable(bytes, mime));
      if (got.isEmpty) throw Exception('لم يتم العثور على جدول بالصورة');
      setState(() {
        if (append && _rows.isNotEmpty) {
          if (_sameRow(_rows.first, got.first)) got = got.sublist(1);
          final n = math.max(_cols, got.isEmpty ? 0 : got.first.length);
          _rows = _pad([..._rows, ...got], n);
        } else {
          _rows = got;
        }
      });
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------- التعديل ----------------
  Future<void> _editCell(int r, int c) async {
    final ctrl = TextEditingController(text: _rows[r][c]);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(r == 0 ? 'تعديل العنوان' : 'تعديل الخلية',
              style: GoogleFonts.cairo()),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 1,
            maxLines: 8,
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('إلغاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: Text('حفظ', style: GoogleFonts.cairo())),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (v != null) setState(() => _rows[r][c] = v);
  }

  void _insertRow(int at) => setState(() =>
      _rows.insert(at, List<String>.filled(_cols, '', growable: true)));

  void _deleteRow(int i) => setState(() {
    _rows.removeAt(i);
  });

  void _addRowEnd() {
    if (_rows.isEmpty) return;
    _insertRow(_rows.length);
  }

  void _addColAfter(int c) => setState(() {
    for (var i = 0; i < _rows.length; i++) {
      _rows[i].insert(c + 1, i == 0 ? 'عمود جديد' : '');
    }
  });

  void _deleteCol(int c) {
    if (_cols <= 1) {
      _snack('لا يمكن حذف العمود الأخير');
      return;
    }
    setState(() {
      for (final r in _rows) {
        r.removeAt(c);
      }
    });
  }

  // ---------------- التصدير ----------------
  Future<_Hdr?> _askHeader() async {
    final db = AppDatabase.instance;
    final savedOrg = await db.getSetting('excel_org') ?? '';
    var logo = await db.getSetting('excel_logo') ?? '';
    if (logo.isEmpty || !File(logo).existsSync()) logo = AppSettings.logoPath;
    if (logo.isNotEmpty && !File(logo).existsSync()) logo = '';
    final org = TextEditingController(
        text: savedOrg.isNotEmpty ? savedOrg : AppSettings.company);
    final title = TextEditingController(text: 'جدول البيانات');
    var useLogo = logo.isNotEmpty;
    if (!mounted) return null;

    final res = await showDialog<_Hdr>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          Future<void> pickLogo() async {
            try {
              final x = await _picker.pickImage(
                  source: ImageSource.gallery, maxWidth: 900);
              if (x == null) return;
              final dir = await getApplicationDocumentsDirectory();
              final dest =
                  '${dir.path}/excel_logo_${DateTime.now().millisecondsSinceEpoch}.png';
              await File(x.path).copy(dest);
              setD(() {
                logo = dest;
                useLogo = true;
              });
            } catch (e) {
              _snack('تعذر اختيار الشعار: $e');
            }
          }

          final companyLogoOk = AppSettings.logoPath.isNotEmpty &&
              File(AppSettings.logoPath).existsSync();

          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: Text('ترويسة الملف', style: GoogleFonts.cairo()),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: org,
                      decoration: const InputDecoration(
                          labelText: 'اسم المنظمة (يظهر أعلى الملف)'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: title,
                      decoration:
                      const InputDecoration(labelText: 'عنوان الجدول'),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('إضافة شعار المنظمة',
                          style:
                          GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                      value: useLogo,
                      onChanged: (v) {
                        if (v && logo.isEmpty) {
                          pickLogo();
                        } else {
                          setD(() => useLogo = v);
                        }
                      },
                    ),
                    if (useLogo && logo.isNotEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Image.file(File(logo),
                              height: 60, fit: BoxFit.contain),
                        ),
                      ),
                    Wrap(
                      spacing: 6,
                      children: [
                        TextButton.icon(
                          onPressed: pickLogo,
                          icon: const Icon(Icons.image_rounded, size: 18),
                          label: Text('اختيار شعار من المعرض',
                              style: GoogleFonts.cairo(fontSize: 12)),
                        ),
                        if (companyLogoOk)
                          TextButton.icon(
                            onPressed: () => setD(() {
                              logo = AppSettings.logoPath;
                              useLogo = true;
                            }),
                            icon: const Icon(Icons.business_rounded, size: 18),
                            label: Text('شعار الشركة المحفوظ',
                                style: GoogleFonts.cairo(fontSize: 12)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text('إلغاء', style: GoogleFonts.cairo())),
                TextButton(
                    onPressed: () => Navigator.pop(
                        ctx,
                        _Hdr(org.text.trim(), title.text.trim(),
                            useLogo ? logo : '')),
                    child: Text('تصدير',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w700))),
              ],
            ),
          );
        },
      ),
    );
    org.dispose();
    title.dispose();
    return res;
  }

  Future<void> _export() async {
    if (_rows.isEmpty) return;
    final h = await _askHeader();
    if (h == null || !mounted) return;
    setState(() {
      _loading = true;
      _status = 'جاري إنشاء الملف...';
    });
    try {
      final db = AppDatabase.instance;
      await db.setSetting('excel_org', h.org);
      await db.setSetting('excel_logo', h.logo);
      Uint8List? logoBytes;
      if (h.logo.isNotEmpty && File(h.logo).existsSync()) {
        logoBytes = await File(h.logo).readAsBytes();
      }
      final now = DateTime.now();
      final bytes = XlsxBuilder.build(
        rows: _rows,
        org: h.org,
        title: h.title,
        dateText: 'التاريخ: ${DateFormat('yyyy/MM/dd').format(now)}',
        logo: logoBytes,
      );
      if (bytes.isEmpty) throw Exception('تعذر إنشاء الملف');
      final base =
          '${(h.title.isEmpty ? 'جدول' : h.title).replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')}_${DateFormat('yyyyMMdd_HHmm').format(now)}';
      if (!mounted) return;
      await showExportSheet(
        context,
        baseName: base,
        ext: 'xlsx',
        bytes: bytes,
        mime:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        mimeType: MimeType.microsoftExcel,
        projectId: widget.projectId,
      );
    } catch (e) {
      _snack('تعذر التصدير: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------- الواجهة ----------------
  double _colW(int c) {
    var m = 0;
    for (final r in _rows) {
      for (final line in r[c].split('\n')) {
        if (line.length > m) m = line.length;
      }
    }
    return (m * 8.5 + 28).clamp(96.0, 230.0).toDouble();
  }

  Widget _cell(int r, int c, double w) {
    final head = r == 0;
    return InkWell(
      onTap: () => _editCell(r, c),
      child: Container(
        width: w,
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        alignment: head ? Alignment.center : AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: head
              ? AppColors.navy
              : (r.isEven ? const Color(0xFFF4F6F9) : Colors.white),
          border: Border.all(color: Colors.black12),
        ),
        child: Text(
          _rows[r][c],
          textAlign: head ? TextAlign.center : TextAlign.start,
          style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: head ? FontWeight.w700 : FontWeight.w400,
              color: head ? Colors.white : AppColors.textDark),
        ),
      ),
    );
  }

  Widget _rowNum(int r) => PopupMenuButton<String>(
    padding: EdgeInsets.zero,
    onSelected: (v) {
      if (v == 'above') _insertRow(r);
      if (v == 'below') _insertRow(r + 1);
      if (v == 'delete') _deleteRow(r);
    },
    itemBuilder: (_) => [
      PopupMenuItem(
          value: 'above',
          child: Text('إدراج صف أعلاه', style: GoogleFonts.cairo())),
      PopupMenuItem(
          value: 'below',
          child: Text('إدراج صف أسفله', style: GoogleFonts.cairo())),
      PopupMenuItem(
          value: 'delete',
          child: Text('حذف الصف',
              style: GoogleFonts.cairo(color: Colors.red))),
    ],
    child: Container(
      width: 44,
      constraints: const BoxConstraints(minHeight: 46),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFE8ECF2),
        border: Border.all(color: Colors.black12),
      ),
      child: Text(r == 0 ? '#' : '$r',
          style: GoogleFonts.cairo(
              fontSize: 12, fontWeight: FontWeight.w700)),
    ),
  );

  Widget _table() {
    final widths = [for (var c = 0; c < _cols; c++) _colW(c)];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const SizedBox(width: 44),
            for (var c = 0; c < _cols; c++)
              SizedBox(
                width: widths[c],
                height: 34,
                child: PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                  onSelected: (v) {
                    if (v == 'add') _addColAfter(c);
                    if (v == 'delete') _deleteCol(c);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'add',
                        child: Text('إضافة عمود بعده',
                            style: GoogleFonts.cairo())),
                    PopupMenuItem(
                        value: 'delete',
                        child: Text('حذف العمود',
                            style: GoogleFonts.cairo(color: Colors.red))),
                  ],
                ),
              ),
          ]),
          for (var r = 0; r < _rows.length; r++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _rowNum(r),
                  for (var c = 0; c < _cols; c++) _cell(r, c, widths[c]),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _btn(String t, IconData i, VoidCallback f) => SizedBox(
    height: 60,
    child: ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: _loading ? null : f,
      icon: Icon(i, color: AppColors.gold),
      label: Text(t, style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('من صورة إلى Excel',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(children: [
              Expanded(
                  child: _btn('الكاميرا', Icons.photo_camera_rounded,
                          () => _capture(ImageSource.camera))),
              const SizedBox(width: 12),
              Expanded(
                  child: _btn('المعرض', Icons.photo_library_rounded,
                          () => _capture(ImageSource.gallery))),
            ]),
            if (_image != null && _rows.isEmpty) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(_image!, height: 180, fit: BoxFit.cover),
              ),
            ],
            if (_loading)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 10),
                  Text(_status, style: GoogleFonts.cairo(fontSize: 12)),
                ]),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child:
                Text(_error!, style: GoogleFonts.cairo(color: Colors.red)),
              ),
            if (_rows.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: AppColors.gold.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(14)),
                child: Text(
                    'راجع الجدول: اضغط أي خلية لتعديلها، وقائمة الصف (الرقم على اليمين) وقائمة العمود (النقاط بالأعلى) للإضافة والحذف. القراءة الآلية قد تخطئ بالأرقام والكتابة اليدوية.',
                    style: GoogleFonts.cairo(fontSize: 12, height: 1.5)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _addRowEnd,
                    icon: const Icon(Icons.table_rows_rounded, size: 18),
                    label: Text('إضافة صف', style: GoogleFonts.cairo()),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : () => _addColAfter(_cols - 1),
                    icon: const Icon(Icons.view_column_rounded, size: 18),
                    label: Text('إضافة عمود', style: GoogleFonts.cairo()),
                  ),
                  PopupMenuButton<ImageSource>(
                    enabled: !_loading,
                    onSelected: (s) => _capture(s, append: true),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                          value: ImageSource.camera,
                          child: Text('صفحة أخرى من الكاميرا',
                              style: GoogleFonts.cairo())),
                      PopupMenuItem(
                          value: ImageSource.gallery,
                          child: Text('صفحة أخرى من المعرض',
                              style: GoogleFonts.cairo())),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black26),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.add_a_photo_rounded, size: 18),
                        const SizedBox(width: 6),
                        Text('إضافة صفحة أخرى', style: GoogleFonts.cairo()),
                      ]),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _table(),
              const SizedBox(height: 18),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.navyDark,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _loading ? null : _export,
                  icon: const Icon(Icons.table_view_rounded),
                  label: Text('تصدير Excel (مع الترويسة)',
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