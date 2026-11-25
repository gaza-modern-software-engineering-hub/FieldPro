import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart' show DateFormat;
import 'session_result.dart';

/// يبني ملف Word (.docx) عربي RTL بدون أي مكتبة إضافية.
class SessionDocx {
  static const _ns =
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';

  static const _navy = '0B2545';
  static const _gold = 'D4AF37';

  static String _x(String s) => s
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _run(String t,
      {bool b = false,
        bool i = false,
        String color = '222222',
        int size = 24}) =>
      '<w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>'
          '${b ? '<w:b/><w:bCs/>' : ''}${i ? '<w:i/><w:iCs/>' : ''}'
          '<w:color w:val="$color"/><w:sz w:val="$size"/><w:szCs w:val="$size"/><w:rtl/></w:rPr>'
          '<w:t xml:space="preserve">${_x(t)}</w:t></w:r>';

  static String _p(String runs,
      {String? jc,
        int before = 0,
        int after = 100,
        bool keepNext = false,
        String? borderColor}) =>
      '<w:p><w:pPr>${keepNext ? '<w:keepNext/>' : ''}'
          '${borderColor != null ? '<w:pBdr><w:bottom w:val="single" w:sz="8" w:space="2" w:color="$borderColor"/></w:pBdr>' : ''}'
          '<w:bidi/><w:spacing w:before="$before" w:after="$after" w:line="320" w:lineRule="auto"/>'
          '${jc != null ? '<w:jc w:val="$jc"/>' : ''}</w:pPr>$runs</w:p>';

  static String _h(String t) => _p(_run(t, b: true, color: _navy, size: 28),
      before: 260, after: 100, keepNext: true, borderColor: _gold);

  static String _bullet(String t) => _p(_run('•  $t', size: 23), after: 60);

  static String _cell(int w, String inner, {String? fill}) =>
      '<w:tc><w:tcPr><w:tcW w:w="$w" w:type="dxa"/>'
          '${fill != null ? '<w:shd w:val="clear" w:color="auto" w:fill="$fill"/>' : ''}'
          '<w:vAlign w:val="center"/></w:tcPr>$inner</w:tc>';

  static String _tr(List<String> cells, {bool header = false, int? minH}) =>
      '<w:tr><w:trPr><w:cantSplit/>'
          '${minH != null ? '<w:trHeight w:val="$minH" w:hRule="atLeast"/>' : ''}'
          '${header ? '<w:tblHeader/>' : ''}</w:trPr>${cells.join()}</w:tr>';

  static String _tbl(List<int> widths, List<String> rows) {
    final total = widths.reduce((a, b) => a + b);
    String bd(String n) =>
        '<w:$n w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>';
    return '<w:tbl><w:tblPr><w:bidiVisual/><w:tblW w:w="$total" w:type="dxa"/>'
        '<w:tblBorders>${bd('top')}${bd('left')}${bd('bottom')}${bd('right')}${bd('insideH')}${bd('insideV')}</w:tblBorders>'
        '<w:tblLayout w:type="fixed"/>'
        '<w:tblCellMar><w:top w:w="60" w:type="dxa"/><w:left w:w="110" w:type="dxa"/><w:bottom w:w="60" w:type="dxa"/><w:right w:w="110" w:type="dxa"/></w:tblCellMar>'
        '</w:tblPr><w:tblGrid>${widths.map((w) => '<w:gridCol w:w="$w"/>').join()}</w:tblGrid>'
        '${rows.join()}</w:tbl>${_p('', after: 60)}';
  }

  static String _dataTable(
      List<String> head, List<List<String>> rows, List<int> widths,
      {String? Function(int r, int c)? fill, int? minH}) {
    final trs = <String>[
      _tr([
        for (var i = 0; i < head.length; i++)
          _cell(widths[i],
              _p(_run(head[i], b: true, color: 'FFFFFF', size: 22), after: 0),
              fill: _navy)
      ], header: true)
    ];
    for (var r = 0; r < rows.length; r++) {
      trs.add(_tr([
        for (var i = 0; i < widths.length; i++)
          _cell(
              widths[i],
              _p(_run(i < rows[r].length ? rows[r][i] : '', size: 22),
                  after: 0),
              fill: fill?.call(r, i) ?? (r.isOdd ? 'F4F6F9' : null))
      ], minH: minH));
    }
    return _tbl(widths, trs);
  }

  static String _kv(List<List<String>> pairs) => _tbl([
    2400,
    7238
  ], [
    for (final p in pairs)
      _tr([
        _cell(2400,
            _p(_run(p[0], b: true, color: _navy, size: 22), after: 0),
            fill: 'F4F6F9'),
        _cell(7238, _p(_run(p[1], size: 22), after: 0)),
      ])
  ]);

  static String _fmtDur(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (h > 0) return '$h ساعة و$m دقيقة';
    if (m > 0) return '$m دقيقة';
    return '$sec ثانية';
  }

  static Uint8List build({
    required SessionResult r,
    required String company,
    required DateTime date,
    required int durationSec,
    String logoPath = '',
  }) {
    final org = company.trim().isEmpty ? 'FieldPro' : company.trim();
    final when = r.date ?? date;
    final title = r.title.trim();

    // الشعار
    Uint8List? logoPng;
    var lw = 0, lh = 0;
    try {
      if (logoPath.isNotEmpty && File(logoPath).existsSync()) {
        var d = img.decodeImage(File(logoPath).readAsBytesSync());
        if (d != null) {
          if (d.width > 500) d = img.copyResize(d, width: 500);
          logoPng = Uint8List.fromList(img.encodePng(d));
          lw = d.width;
          lh = d.height;
        }
      }
    } catch (_) {
      logoPng = null;
    }

    final body = StringBuffer();

    // شريط العنوان
    final band = _p(_run(org, b: true, color: _gold, size: 26),
        jc: 'center', before: 160, after: 60) +
        _p(_run('محضر اجتماع', b: true, color: 'FFFFFF', size: 44),
            jc: 'center', after: title.isEmpty ? 200 : 60) +
        (title.isEmpty
            ? ''
            : _p(_run(title, color: 'FFFFFF', size: 28),
            jc: 'center', after: 160));
    body.write('<w:tbl><w:tblPr><w:bidiVisual/><w:tblW w:w="9638" w:type="dxa"/>'
        '<w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid><w:gridCol w:w="9638"/></w:tblGrid>'
        '${_tr([_cell(9638, band, fill: _navy)])}</w:tbl>');
    body.write(_p('', after: 120));

    final meta = <List<String>>[
      ['التاريخ', DateFormat('yyyy/MM/dd').format(when)],
      ['الوقت', DateFormat('HH:mm').format(when)],
      if (r.location.trim().isNotEmpty) ['المكان', r.location.trim()],
      if (r.site.trim().isNotEmpty) ['الموقع', r.site.trim()],
      if (durationSec > 0) ['مدة التسجيل', _fmtDur(durationSec)],
    ];
    body.write(_kv(meta));

    if (r.summary.trim().isNotEmpty) {
      body.write(_h('الملخص التنفيذي'));
      for (final para in r.summary.split('\n')) {
        if (para.trim().isEmpty) continue;
        body.write(_p(_run(para.trim()), after: 110));
      }
    }

    final atts = r.attendees
        .where((a) => a.name.trim().isNotEmpty || a.org.trim().isNotEmpty)
        .toList();
    if (atts.isNotEmpty) {
      body.write(_h('الحضور'));
      body.write(_dataTable(
          ['م', 'الاسم', 'الجهة / الصفة', 'التوقيع'],
          [
            for (var i = 0; i < atts.length; i++)
              ['${i + 1}', atts[i].name, atts[i].org, '']
          ],
          [650, 3300, 3188, 2500],
          minH: 560));
    }

    if (r.keyPoints.isNotEmpty) {
      body.write(_h('أبرز النقاط'));
      for (final k in r.keyPoints) {
        body.write(_bullet(k));
      }
    }

    if (r.decisions.isNotEmpty) {
      body.write(_h('القرارات والاتفاقات'));
      body.write(_dataTable(
          ['م', 'القرار'],
          [
            for (var i = 0; i < r.decisions.length; i++)
              ['${i + 1}', r.decisions[i]]
          ],
          [700, 8938]));
    }

    final tasks =
    r.tasks.where((t) => t.what.trim().isNotEmpty || t.who.trim().isNotEmpty).toList();
    if (tasks.isNotEmpty) {
      body.write(_h('المهام والمتابعة'));
      const colors = {
        'مفتوحة': 'FFF1C7',
        'قيد التنفيذ': 'DCEBFF',
        'مغلقة': 'DDF3E2',
      };
      body.write(_dataTable(
          ['م', 'المهمة', 'المسؤول', 'الموعد', 'الحالة'],
          [
            for (var i = 0; i < tasks.length; i++)
              [
                '${i + 1}',
                tasks[i].what,
                tasks[i].who.isEmpty ? 'غير محدد' : tasks[i].who,
                tasks[i].due.isEmpty ? 'غير محدد' : tasks[i].due,
                tasks[i].status,
              ]
          ],
          [600, 3638, 2000, 1600, 1800],
          fill: (row, col) => col == 4 ? colors[tasks[row].status] : null));
    }

    if (r.nextMeeting.trim().isNotEmpty) {
      body.write(_h('الاجتماع القادم'));
      body.write(_p(_run(r.nextMeeting.trim()), after: 100));
    }

    if (r.notes.trim().isNotEmpty) {
      body.write(_h('ملاحظات'));
      for (final para in r.notes.split('\n')) {
        if (para.trim().isEmpty) continue;
        body.write(_p(_run(para.trim()), after: 100));
      }
    }

    if (r.transcript.trim().isNotEmpty) {
      body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      body.write(_h('نص التفريغ الكامل'));
      for (final line in r.transcript.split('\n')) {
        if (line.trim().isEmpty) continue;
        body.write(
            _p(_run(line.trim(), color: '444444', size: 21), after: 90));
      }
    }

    if (r.aiGenerated) {
      body.write(_p(
          _run(
              'مسودة أُعدّت بمساعدة الذكاء الاصطناعي وتحتاج إلى مراجعة قبل الاعتماد.',
              i: true,
              color: '7A7A7A',
              size: 19),
          jc: 'center',
          before: 200));
    }

    const sect =
        '<w:sectPr><w:headerReference w:type="default" r:id="rIdHeader"/>'
        '<w:footerReference w:type="default" r:id="rIdFooter"/>'
        '<w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1400" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>'
        '<w:bidi/></w:sectPr>';

    final document =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document $_ns><w:body>${body.toString()}$sect</w:body></w:document>';

    var logoRun = '';
    if (logoPng != null) {
      const maxW = 1000000, maxH = 360000;
      final sc = (maxW / lw) < (maxH / lh) ? maxW / lw : maxH / lh;
      final cx = (lw * sc).round(), cy = (lh * sc).round();
      logoRun = '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
          '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="1" name="Logo"/>'
          '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
          '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
          '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="logo.png"/><pic:cNvPicPr/></pic:nvPicPr>'
          '<pic:blipFill><a:blip r:embed="rIdLogo"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
          '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
          '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
          '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';
    }

    final header =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:hdr $_ns><w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="8" w:space="4" w:color="$_gold"/></w:pBdr>'
        '<w:bidi/><w:spacing w:before="0" w:after="0"/></w:pPr>'
        '$logoRun${_run('   $org', b: true, color: _navy, size: 24)}</w:p></w:hdr>';

    final footer =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:ftr $_ns><w:p><w:pPr><w:bidi/><w:jc w:val="center"/></w:pPr>'
        '${_run('$org  •  صفحة ', color: '7A7A7A', size: 18)}'
        '<w:fldSimple w:instr=" PAGE "><w:r><w:rPr><w:color w:val="7A7A7A"/><w:sz w:val="18"/></w:rPr><w:t>1</w:t></w:r></w:fldSimple>'
        '</w:p></w:ftr>';

    const contentTypes =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>'
        '<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>'
        '</Types>';

    const rootRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';

    const docRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>'
        '<Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>'
        '</Relationships>';

    const headerRels =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdLogo" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/logo.png"/>'
        '</Relationships>';

    final arc = Archive();
    void add(String name, List<int> data) =>
        arc.addFile(ArchiveFile(name, data.length, data));
    add('[Content_Types].xml', utf8.encode(contentTypes));
    add('_rels/.rels', utf8.encode(rootRels));
    add('word/document.xml', utf8.encode(document));
    add('word/_rels/document.xml.rels', utf8.encode(docRels));
    add('word/header1.xml', utf8.encode(header));
    add('word/footer1.xml', utf8.encode(footer));
    if (logoPng != null) {
      add('word/_rels/header1.xml.rels', utf8.encode(headerRels));
      add('word/media/logo.png', logoPng);
    }

    final zipped = ZipEncoder().encode(arc);
    return Uint8List.fromList(zipped ?? <int>[]);
  }
}