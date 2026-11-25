import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'map_area.dart';
import 'map_point.dart';

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

List<int> _utf8(String s) => const Utf8Encoder().convert(s);

String _two(int n) => n.toString().padLeft(2, '0');

/// صيغة الوقت التي يكتبها Maps.me: 2026-09-28T04:36:33.710Z
String _stamp(DateTime d) {
  final u = d.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-${_two(u.month)}-${_two(u.day)}'
      'T${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)}'
      '.${u.millisecond.toString().padLeft(3, '0')}Z';
}

/// KML يستخدم الترتيب AABBGGRR
String _abgr(int argb) {
  String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  return 'FF${h(argb & 0xFF)}${h((argb >> 8) & 0xFF)}${h((argb >> 16) & 0xFF)}';
}

String _coord(double lng, double lat) =>
    '${lng.toStringAsFixed(6)},${lat.toStringAsFixed(6)}';

class MapExport {
  /// الأنماط التي يعرفها Maps.me (نفس القائمة بملفاته)
  static const _styles = <String>[
    'placemark-red',
    'placemark-blue',
    'placemark-purple',
    'placemark-yellow',
    'placemark-pink',
    'placemark-brown',
    'placemark-green',
    'placemark-orange',
    'placemark-deeppurple',
    'placemark-lightblue',
    'placemark-cyan',
    'placemark-teal',
    'placemark-lime',
    'placemark-deeporange',
    'placemark-gray',
    'placemark-bluegray',
  ];

  static String _ext(String n, String now) =>
      '<ExtendedData xmlns:mwm="https://maps.me">'
          '<mwm:name>$n</mwm:name><mwm:customName>$n</mwm:customName>'
          '<mwm:scale>17</mwm:scale><mwm:visibility>1</mwm:visibility>'
          '<mwm:lastModified>$now</mwm:lastModified><mwm:isDeleted>0</mwm:isDeleted>'
          '<mwm:uniqueId></mwm:uniqueId></ExtendedData>';

  /// بنفس صيغة ملفات Maps.me:
  /// - النقطة = إشارة مرجعية، والحد = مسار (خط مغلق) + نقطة بمركزه بالاسم والمساحة.
  /// - المضلّعات (Polygon) يتجاهلها Maps.me، لذلك لا نكتبها.
  static String _kmlText(
      List<MapPoint> points, List<MapArea> areas, String docName) {
    final now = _stamp(DateTime.now());
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://earth.google.com/kml/2.2">')
      ..writeln('<Document>');

    for (final id in _styles) {
      b.writeln('<Style id="$id"><IconStyle><Icon>'
          '<href>http://maps.me/placemarks/$id.png</href>'
          '</Icon></IconStyle></Style>');
    }
    b
      ..writeln('<name>${_esc(docName)}</name>')
      ..writeln('<description>${_esc(docName)}</description>')
      ..writeln('<visibility>1</visibility>')
      ..writeln('<ExtendedData xmlns:mwm="https://maps.me">'
          '<mwm:lastModified>$now</mwm:lastModified>'
          '<mwm:isDeleted>0</mwm:isDeleted><mwm:uniqueId></mwm:uniqueId>'
          '</ExtendedData>');

    for (final p in points) {
      final n = _esc(p.name);
      final note = p.note.trim().isEmpty
          ? ''
          : '<description>${_esc(p.note)}</description>';
      b.writeln('<Placemark><name>$n</name>$note'
          '<TimeStamp><when>$now</when></TimeStamp>'
          '<styleUrl>#${p.favorite ? 'placemark-red' : 'placemark-blue'}</styleUrl>'
          '<Point><coordinates>${_coord(p.lng, p.lat)}</coordinates></Point>'
          '${_ext(n, now)}</Placemark>');
    }

    for (final a in areas) {
      if (a.points.length < 3) continue;
      final ring = [...a.points, a.points.first]
          .map((e) => _coord(e.longitude, e.latitude))
          .join(' ');
      final cLat = a.points.map((e) => e.latitude).reduce((x, y) => x + y) /
          a.points.length;
      final cLng = a.points.map((e) => e.longitude).reduce((x, y) => x + y) /
          a.points.length;
      final n = _esc(a.name);
      final info = _esc('المساحة: ${a.areaM2.toStringAsFixed(0)} م²، '
          'المحيط: ${a.perimeterM.toStringAsFixed(0)} م');
      final color = a.color == 0 ? kNavyArgb : a.color;

      // الحد كمسار مغلق بلون المنطقة
      b.writeln('<Placemark><name>$n</name><description>$info</description>'
          '<Style><LineStyle><color>${_abgr(color)}</color><width>5</width>'
          '</LineStyle></Style>'
          '<TimeStamp><when>$now</when></TimeStamp>'
          '<LineString><coordinates>$ring</coordinates></LineString>'
          '</Placemark>');
      // نقطة بمركز المنطقة تحمل الاسم والمساحة
      b.writeln('<Placemark><name>$n</name><description>$info</description>'
          '<TimeStamp><when>$now</when></TimeStamp>'
          '<styleUrl>#placemark-green</styleUrl>'
          '<Point><coordinates>${_coord(cLng, cLat)}</coordinates></Point>'
          '${_ext(n, now)}</Placemark>');
    }

    b
      ..writeln('</Document>')
      ..writeln('</kml>');
    return b.toString();
  }

  static Uint8List kml(List<MapPoint> points, List<MapArea> areas,
      {String name = 'FieldPro'}) {
    return Uint8List.fromList(_utf8(_kmlText(points, areas, name)));
  }

  /// KMZ = KML مضغوط ZIP (الملف الرئيسي doc.kml)
  static Uint8List kmz(List<MapPoint> points, List<MapArea> areas,
      {String name = 'FieldPro'}) {
    final data = _utf8(_kmlText(points, areas, name));
    final arc = Archive()..addFile(ArchiveFile('doc.kml', data.length, data));
    final zipped = ZipEncoder().encode(arc);
    return Uint8List.fromList(zipped ?? <int>[]);
  }

  static Uint8List gpx(List<MapPoint> points, List<MapArea> areas) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
          '<gpx version="1.1" creator="FieldPro" xmlns="http://www.topografix.com/GPX/1/1">');
    for (final p in points) {
      b.writeln(
          '<wpt lat="${p.lat}" lon="${p.lng}"><name>${_esc(p.name)}</name>'
              '<desc>${_esc(p.note)}</desc></wpt>');
    }
    for (final a in areas) {
      b.writeln('<trk><name>${_esc(a.name)}</name><trkseg>');
      for (final e in [...a.points, a.points.first]) {
        b.writeln('<trkpt lat="${e.latitude}" lon="${e.longitude}"/>');
      }
      b.writeln('</trkseg></trk>');
    }
    b.writeln('</gpx>');
    return Uint8List.fromList(_utf8(b.toString()));
  }

  static Uint8List? excel(List<MapPoint> points, List<MapArea> areas) {
    final x = Excel.createExcel();
    final s1 = x['النقاط'];
    s1.isRTL = true;
    s1.appendRow([
      TextCellValue('الاسم'),
      TextCellValue('العرض'),
      TextCellValue('الطول'),
      TextCellValue('ملاحظة'),
      TextCellValue('مفضلة'),
    ]);
    for (final p in points) {
      s1.appendRow([
        TextCellValue(p.name),
        DoubleCellValue(p.lat),
        DoubleCellValue(p.lng),
        TextCellValue(p.note),
        TextCellValue(p.favorite ? 'نعم' : 'لا'),
      ]);
    }
    final s2 = x['الحدود'];
    s2.isRTL = true;
    s2.appendRow([
      TextCellValue('الاسم'),
      TextCellValue('المساحة م²'),
      TextCellValue('المساحة دونم'),
      TextCellValue('المحيط م'),
      TextCellValue('عدد النقاط'),
    ]);
    for (final a in areas) {
      s2.appendRow([
        TextCellValue(a.name),
        DoubleCellValue(double.parse(a.areaM2.toStringAsFixed(1))),
        DoubleCellValue(double.parse((a.areaM2 / 1000).toStringAsFixed(3))),
        DoubleCellValue(double.parse(a.perimeterM.toStringAsFixed(1))),
        IntCellValue(a.points.length),
      ]);
    }
    x.delete('Sheet1');
    final data = x.save();
    return data == null ? null : Uint8List.fromList(data);
  }
}