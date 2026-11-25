import 'dart:io';
import 'dart:typed_data';
import 'package:intl/intl.dart' show DateFormat;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../core/app_settings.dart';
import '../map/map_area.dart';
import '../map/map_point.dart';
import '../survey/gemini_service.dart';

class ReportPdf {
  static Future<Uint8List> build({
    required String company,
    required String title,
    required String? projectName,
    required List<NeedCategory> cats,
    required String body,
    required List<MapPoint> points,
    required List<MapArea> areas,
  }) async {
    final regular = await PdfGoogleFonts.cairoRegular();
    final bold = await PdfGoogleFonts.cairoBold();
    final theme = pw.ThemeData.withFont(base: regular, bold: bold);
    final navy = PdfColor.fromInt(0xFF0B2545);
    final gold = PdfColor.fromInt(0xFFD4AF37);
    final total = cats.fold<int>(0, (s, c) => s + c.count);
    final date = DateFormat('yyyy/MM/dd').format(DateTime.now());

    pw.MemoryImage? logo;
    try {
      if (AppSettings.logoPath.isNotEmpty &&
          File(AppSettings.logoPath).existsSync()) {
        logo = pw.MemoryImage(File(AppSettings.logoPath).readAsBytesSync());
      }
    } catch (_) {}

    // صور النقاط (أول 12 صورة لتخفيف حجم الملف)
    final photos = <(MapPoint, pw.MemoryImage)>[];
    for (final p in points) {
      if (photos.length >= 12) break;
      try {
        if (p.photo.isNotEmpty && File(p.photo).existsSync()) {
          photos.add((p, pw.MemoryImage(File(p.photo).readAsBytesSync())));
        }
      } catch (_) {}
    }

    pw.Widget rtl(pw.Widget w) =>
        pw.Directionality(textDirection: pw.TextDirection.rtl, child: w);

    pw.Widget cell(String t, {bool head = false}) => pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(t,
          style: pw.TextStyle(
              fontSize: 10,
              fontWeight: head ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: head ? PdfColors.white : PdfColors.black)),
    );

    pw.Widget table(List<String> head, List<List<String>> rows) => pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400),
      children: [
        pw.TableRow(
            decoration: pw.BoxDecoration(color: navy),
            children: [for (final h in head) cell(h, head: true)]),
        for (final r in rows)
          pw.TableRow(children: [for (final c in r) cell(c)]),
      ],
    );

    final maxC = cats.isEmpty
        ? 1
        : cats.map((c) => c.count).reduce((a, b) => a > b ? a : b);
    pw.Widget chart() => pw.Column(
      children: [
        for (final c in cats.take(10))
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.Row(children: [
              pw.SizedBox(
                  width: 90,
                  child: pw.Text(c.name,
                      style: const pw.TextStyle(fontSize: 10))),
              pw.Expanded(
                child: pw.Stack(children: [
                  pw.Container(height: 14, color: PdfColors.grey200),
                  pw.Container(
                      height: 14,
                      width: 330 * (c.count / maxC),
                      color: gold),
                ]),
              ),
              pw.SizedBox(width: 6),
              pw.Text('${c.count}',
                  style: const pw.TextStyle(fontSize: 10)),
            ]),
          ),
      ],
    );

    pw.Widget heading(String t) => pw.Text(t,
        style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold));

    final doc = pw.Document(theme: theme);

    // الغلاف
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (_) => rtl(pw.Container(
        color: navy,
        width: double.infinity,
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            if (logo != null) ...[
              pw.Container(
                width: 110,
                height: 110,
                padding: const pw.EdgeInsets.all(8),
                color: PdfColors.white,
                child: pw.Image(logo, fit: pw.BoxFit.contain),
              ),
              pw.SizedBox(height: 24),
            ],
            pw.Text(company,
                style: pw.TextStyle(
                    color: gold, fontSize: 26, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 24),
            pw.Container(width: 80, height: 3, color: gold),
            pw.SizedBox(height: 24),
            pw.Text(title,
                style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold),
                textAlign: pw.TextAlign.center),
            if (projectName != null) ...[
              pw.SizedBox(height: 12),
              pw.Text('المشروع: $projectName',
                  style: const pw.TextStyle(
                      color: PdfColors.white, fontSize: 14)),
            ],
            pw.SizedBox(height: 12),
            pw.Text(date, style: pw.TextStyle(color: gold, fontSize: 12)),
          ],
        ),
      )),
    ));

    // المحتوى
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (_) => [
        rtl(pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (cats.isNotEmpty) ...[
              heading('نتائج الاستبيان (الإجمالي: $total)'),
              pw.SizedBox(height: 8),
              table(['الفئة', 'العدد', 'النسبة'], [
                for (final c in cats)
                  [
                    c.name,
                    '${c.count}',
                    '${(c.count / total * 100).toStringAsFixed(1)}%'
                  ]
              ]),
              pw.SizedBox(height: 14),
              chart(),
              pw.SizedBox(height: 18),
            ],
            if (body.isNotEmpty) ...[
              heading('التحليل والتوصيات'),
              pw.SizedBox(height: 6),
              pw.Text(body.replaceAll('*', '').replaceAll('#', ''),
                  style: const pw.TextStyle(fontSize: 11, lineSpacing: 4)),
              pw.SizedBox(height: 18),
            ],
            if (points.isNotEmpty) ...[
              heading('النقاط المحفوظة'),
              pw.SizedBox(height: 8),
              table(['الاسم', 'العرض', 'الطول', 'ملاحظة'], [
                for (final p in points)
                  [
                    p.name,
                    p.lat.toStringAsFixed(6),
                    p.lng.toStringAsFixed(6),
                    p.note
                  ]
              ]),
              pw.SizedBox(height: 18),
            ],
            if (photos.isNotEmpty) ...[
              heading('صور النقاط'),
              pw.SizedBox(height: 8),
              pw.Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final ph in photos)
                    pw.Container(
                      width: 160,
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Container(
                            height: 110,
                            width: 160,
                            child: pw.Image(ph.$2, fit: pw.BoxFit.cover),
                          ),
                          pw.SizedBox(height: 3),
                          pw.Text(ph.$1.name,
                              style: const pw.TextStyle(fontSize: 9)),
                        ],
                      ),
                    ),
                ],
              ),
              pw.SizedBox(height: 18),
            ],
            if (areas.isNotEmpty) ...[
              heading('الحدود والمساحات'),
              pw.SizedBox(height: 8),
              table(['المنطقة', 'المساحة م²', 'دونم', 'المحيط م'], [
                for (final a in areas)
                  [
                    a.name,
                    a.areaM2.toStringAsFixed(0),
                    (a.areaM2 / 1000).toStringAsFixed(2),
                    a.perimeterM.toStringAsFixed(0)
                  ]
              ]),
            ],
          ],
        )),
      ],
      footer: (ctx) => pw.Center(
          child: pw.Text('$company  •  ${ctx.pageNumber}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey))),
    ));

    return doc.save();
  }
}