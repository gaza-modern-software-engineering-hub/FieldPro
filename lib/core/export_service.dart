import 'dart:io';
import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_colors.dart';
import 'database.dart';

class ExportService {
  static Future<String> saveInApp(String fileName, Uint8List bytes) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/FieldPro_exports');
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('${dir.path}/$fileName');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  static Future<void> shareFile(String path, String mime) async {
    await SharePlus.instance
        .share(ShareParams(files: [XFile(path, mimeType: mime)]));
  }

  static Future<void> share(
      String fileName, Uint8List bytes, String mime) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$fileName');
    await f.writeAsBytes(bytes);
    await shareFile(f.path, mime);
  }

  static Future<void> saveToDevice(
      String baseName, String ext, Uint8List bytes, MimeType type) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$baseName.$ext');
    await f.writeAsBytes(bytes);
    await shareFile(f.path, 'application/octet-stream');
  }

  static Future<void> openFile(String path) async {
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done) {
      throw Exception(r.message);
    }
  }

  /// يفتح واتساب برسالة نصية (المرفقات تُرسل عبر المشاركة)
  static Future<void> whatsappText(String text) async {
    final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw Exception('تعذر فتح واتساب');
    }
  }
}

Future<void> showExportSheet(
    BuildContext context, {
      required String baseName,
      required String ext,
      required Uint8List bytes,
      required String mime,
      required MimeType mimeType,
      int? projectId,
    }) {
  final fileName = '$baseName.$ext';

  Future<void> run(Future<void> Function() job, String okMsg) async {
    Navigator.pop(context);
    try {
      await job();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(okMsg)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر التنفيذ: $e')));
      }
    }
  }

  Widget tile(IconData icon, String title, String sub, VoidCallback onTap) =>
      ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              color: AppColors.navy, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: AppColors.gold),
        ),
        title: Text(title,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        subtitle: Text(sub, style: GoogleFonts.cairo(fontSize: 12)),
        onTap: onTap,
      );

  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('تصدير الملف',
                  style: GoogleFonts.cairo(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              tile(
                  Icons.open_in_new_rounded,
                  'فتح الملف',
                  'يفتحه بتطبيق مناسب على الجوال',
                      () => run(() async {
                    final path =
                    await ExportService.saveInApp(fileName, bytes);
                    if (projectId != null) {
                      await AppDatabase.instance.insertFile(
                          projectId: projectId,
                          name: fileName,
                          type: ext,
                          path: path);
                    }
                    await ExportService.openFile(path);
                  }, 'تم الفتح')),
              tile(Icons.download_rounded, 'حفظ على الجهاز',
                  'اختر المكان الذي تريد الحفظ فيه',
                      () => run(
                          () => ExportService.saveToDevice(
                          baseName, ext, bytes, mimeType),
                      'تم الحفظ')),
              tile(Icons.share_rounded, 'مشاركة (واتساب وغيره)',
                  'أرسل الملف لأي تطبيق',
                      () => run(() => ExportService.share(fileName, bytes, mime),
                      'تمت المشاركة')),
              tile(
                  Icons.folder_special_rounded,
                  'حفظ داخل التطبيق',
                  projectId == null
                      ? 'يبقى محفوظاً في FieldPro'
                      : 'يُحفظ ضمن ملفات المشروع',
                      () => run(() async {
                    final path =
                    await ExportService.saveInApp(fileName, bytes);
                    if (projectId != null) {
                      await AppDatabase.instance.insertFile(
                          projectId: projectId,
                          name: fileName,
                          type: ext,
                          path: path);
                    }
                  }, 'تم الحفظ داخل التطبيق')),
            ],
          ),
        ),
      ),
    ),
  );
}