import 'dart:io';
import 'dart:typed_data';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../core/app_colors.dart';
import '../../core/export_service.dart';

class DocumentScannerScreen extends StatefulWidget {
  final int? projectId;
  const DocumentScannerScreen({super.key, this.projectId});

  @override
  State<DocumentScannerScreen> createState() => _DocumentScannerScreenState();
}

class _DocumentScannerScreenState extends State<DocumentScannerScreen> {
  final List<String> _pages = [];
  bool _busy = false;

  Future<void> _scan() async {
    try {
      final pics = await CunningDocumentScanner.getPictures(
          isGalleryImportAllowed: true);
      if (pics == null || pics.isEmpty) return;
      setState(() => _pages.addAll(pics));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر المسح: $e')));
    }
  }

  Future<Uint8List> _buildPdf() async {
    final doc = pw.Document();
    for (final path in _pages) {
      final img = pw.MemoryImage(await File(path).readAsBytes());
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain)),
      ));
    }
    return doc.save();
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final bytes = await _buildPdf();
      if (!mounted) return;
      await showExportSheet(
        context,
        baseName: 'scan_${DateTime.now().millisecondsSinceEpoch}',
        ext: 'pdf',
        bytes: bytes,
        mime: 'application/pdf',
        mimeType: MimeType.pdf,
        projectId: widget.projectId,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
          title: Text('المسح الضوئي',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: _pages.isEmpty
            ? Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.document_scanner_rounded,
                  size: 72, color: AppColors.gold.withOpacity(0.8)),
              const SizedBox(height: 12),
              Text('لم تتم إضافة صفحات بعد',
                  style: GoogleFonts.cairo(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              Text('اضغط "مسح صفحة" للبدء',
                  style: GoogleFonts.cairo(color: AppColors.textMuted)),
            ],
          ),
        )
            : GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.72,
          ),
          itemCount: _pages.length,
          itemBuilder: (_, i) => Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(File(_pages[i]), fit: BoxFit.cover),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: CircleAvatar(
                  radius: 13,
                  backgroundColor: AppColors.navy,
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                ),
              ),
              Positioned(
                top: 2,
                left: 2,
                child: IconButton(
                  icon: const Icon(Icons.cancel_rounded,
                      color: Colors.redAccent),
                  onPressed: () => setState(() => _pages.removeAt(i)),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.navy,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _busy ? null : _scan,
                      icon: const Icon(Icons.add_a_photo_rounded,
                          color: AppColors.gold),
                      label: Text(_pages.isEmpty ? 'مسح صفحة' : 'إضافة صفحة',
                          style:
                          GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                if (_pages.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 54,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.gold,
                          foregroundColor: AppColors.navyDark,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: _busy ? null : _export,
                        icon: const Icon(Icons.picture_as_pdf_rounded),
                        label: Text('PDF (${_pages.length})',
                            style:
                            GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}