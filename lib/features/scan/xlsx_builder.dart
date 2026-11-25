import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

/// يبني ملف Excel (.xlsx) مرتّباً: ترويسة (شعار + اسم المنظمة + عنوان + تاريخ)
/// ثم جدول بحدود وعرض أعمدة وارتفاع صفوف محسوبين حتى لا يتداخل النص.
class XlsxBuilder {
  static String _col(int i) {
    var s = '';
    var n = i + 1;
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  static String _esc(String s) => s
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static final _numRe = RegExp(r'^-?(0|[1-9]\d{0,7})(\.\d{1,6})?$');

  static String _str(String ref, String text, int st) =>
      '<c r="$ref" s="$st" t="inlineStr"><is><t xml:space="preserve">${_esc(text)}</t></is></c>';

  static String _blank(String ref, int st) => '<c r="$ref" s="$st"/>';

  static String _row(int rn, List<String> cells, num ht) =>
      '<row r="$rn" ht="$ht" customHeight="1">${cells.join()}</row>';

  static Uint8List build({
    required List<List<String>> rows,
    required String org,
    required String title,
    required String dateText,
    Uint8List? logo,
  }) {
    final data =
    rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
    if (data.isEmpty) throw Exception('الجدول فارغ');
    final n = data.map((r) => r.length).reduce(math.max);
    final grid = [
      for (final r in data) [...r, ...List<String>.filled(n - r.length, '')]
    ];

    // الشعار: نحوّله PNG ونصغّره
    Uint8List? png;
    var lw = 0, lh = 0;
    if (logo != null) {
      try {
        var d = img.decodeImage(logo);
        if (d != null) {
          if (d.width > 500) d = img.copyResize(d, width: 500);
          png = Uint8List.fromList(img.encodePng(d));
          lw = d.width;
          lh = d.height;
        }
      } catch (_) {
        png = null;
      }
    }

    // عرض الأعمدة
    final widths = <double>[];
    for (var c = 0; c < n; c++) {
      var m = 0;
      for (final r in grid) {
        for (final line in r[c].split('\n')) {
          if (line.length > m) m = line.length;
        }
      }
      widths.add((m * 1.15 + 3).clamp(10.0, 40.0).toDouble());
    }

    final last = _col(n - 1);
    final out = <String>[];
    final merges = <String>[];

    final bandH = (org.trim().isEmpty && png == null) ? 6 : 64;
    out.add(_row(1, [
      _str('A1', org.trim(), 1),
      for (var i = 1; i < n; i++) _blank('${_col(i)}1', 1),
    ], bandH));
    out.add(_row(2, [
      _str('A2', title.trim(), 2),
      for (var i = 1; i < n; i++) _blank('${_col(i)}2', 2),
    ], 26));
    out.add(_row(3, [
      _str('A3', dateText, 6),
      for (var i = 1; i < n; i++) _blank('${_col(i)}3', 6),
    ], 18));
    out.add('<row r="4" ht="8" customHeight="1"/>');
    if (n > 1) {
      for (var r = 1; r <= 3; r++) {
        merges.add('A$r:$last$r');
      }
    }

    for (var ri = 0; ri < grid.length; ri++) {
      final rn = 5 + ri;
      final head = ri == 0;
      final st = head ? 3 : (ri % 2 == 0 ? 5 : 4);
      var lines = 1;
      final cells = <String>[];
      for (var ci = 0; ci < n; ci++) {
        final v = grid[ri][ci];
        final ref = '${_col(ci)}$rn';
        final cpl = math.max(widths[ci] * 0.9, 1.0);
        var l = 0;
        for (final p in v.split('\n')) {
          l += math.max(1, (p.length / cpl).ceil());
        }
        if (l > lines) lines = l;
        if (!head && _numRe.hasMatch(v.trim())) {
          cells.add('<c r="$ref" s="$st"><v>${v.trim()}</v></c>');
        } else if (v.trim().isEmpty) {
          cells.add(_blank(ref, st));
        } else {
          cells.add(_str(ref, v, st));
        }
      }
      final ht = math.max(head ? 22 : 20, lines * 16 + 6);
      out.add(_row(rn, cells, ht));
    }
    final lastRow = 4 + grid.length;

    final cols = [
      for (var i = 0; i < n; i++)
        '<col min="${i + 1}" max="${i + 1}" width="${widths[i].toStringAsFixed(1)}" customWidth="1"/>'
    ].join();

    final sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>'
        '<dimension ref="A1:$last$lastRow"/>'
        '<sheetViews><sheetView rightToLeft="1" showGridLines="0" workbookViewId="0"/></sheetViews>'
        '<sheetFormatPr defaultRowHeight="18"/>'
        '<cols>$cols</cols><sheetData>${out.join()}</sheetData>'
        '${merges.isEmpty ? '' : '<mergeCells count="${merges.length}">${merges.map((m) => '<mergeCell ref="$m"/>').join()}</mergeCells>'}'
        '<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>'
        '<pageSetup paperSize="9" orientation="landscape" fitToWidth="1" fitToHeight="0"/>'
        '${png != null ? '<drawing r:id="rId1"/>' : ''}'
        '</worksheet>';

    const styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="5">'
        '<font><sz val="11"/><color rgb="FF222222"/><name val="Arial"/></font>'
        '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Arial"/></font>'
        '<font><b/><sz val="20"/><color rgb="FF0B2545"/><name val="Arial"/></font>'
        '<font><sz val="10"/><color rgb="FF7A7A7A"/><name val="Arial"/></font>'
        '<font><b/><sz val="13"/><color rgb="FF0B2545"/><name val="Arial"/></font></fonts>'
        '<fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FF0B2545"/><bgColor indexed="64"/></patternFill></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFF4F6F9"/><bgColor indexed="64"/></patternFill></fill></fills>'
        '<borders count="3"><border><left/><right/><top/><bottom/><diagonal/></border>'
        '<border><left style="thin"><color rgb="FFBFBFBF"/></left><right style="thin"><color rgb="FFBFBFBF"/></right><top style="thin"><color rgb="FFBFBFBF"/></top><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border>'
        '<border><left/><right/><top/><bottom style="medium"><color rgb="FFD4AF37"/></bottom><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="7">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="2" fillId="3" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
        '<xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center" wrapText="1"/></xf>'
        '<xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center" wrapText="1"/></xf>'
        '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
        '</cellXfs></styleSheet>';

    const workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="البيانات" sheetId="1" r:id="rId1"/></sheets>'
        "<definedNames><definedName name=\"_xlnm.Print_Titles\" localSheetId=\"0\">'البيانات'!\$5:\$5</definedName></definedNames>"
        '</workbook>';

    const wbRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>';

    final contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '${png != null ? '<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>' : ''}'
        '</Types>';

    const rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>';

    final arc = Archive();
    void add(String name, List<int> bytes) =>
        arc.addFile(ArchiveFile(name, bytes.length, bytes));

    add('[Content_Types].xml', utf8.encode(contentTypes));
    add('_rels/.rels', utf8.encode(rootRels));
    add('xl/workbook.xml', utf8.encode(workbook));
    add('xl/_rels/workbook.xml.rels', utf8.encode(wbRels));
    add('xl/styles.xml', utf8.encode(styles));
    add('xl/worksheets/sheet1.xml', utf8.encode(sheet));

    if (png != null) {
      const maxH = 56 * 12700;
      const maxW = 1500000;
      final sc = math.min(maxW / lw, maxH / lh);
      final cx = (lw * sc).round();
      final cy = (lh * sc).round();
      add(
          'xl/worksheets/_rels/sheet1.xml.rels',
          utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/>'
              '</Relationships>'));
      add(
          'xl/drawings/drawing1.xml',
          utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<xdr:oneCellAnchor><xdr:from><xdr:col>0</xdr:col><xdr:colOff>76200</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>50800</xdr:rowOff></xdr:from>'
              '<xdr:ext cx="$cx" cy="$cy"/>'
              '<xdr:pic><xdr:nvPicPr><xdr:cNvPr id="2" name="Logo"/><xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr></xdr:nvPicPr>'
              '<xdr:blipFill><a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>'
              '<xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>'
              '<xdr:clientData/></xdr:oneCellAnchor></xdr:wsDr>'));
      add(
          'xl/drawings/_rels/drawing1.xml.rels',
          utf8.encode('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/logo.png"/>'
              '</Relationships>'));
      add('xl/media/logo.png', png);
    }

    final zipped = ZipEncoder().encode(arc);
    return Uint8List.fromList(zipped ?? <int>[]);
  }
}