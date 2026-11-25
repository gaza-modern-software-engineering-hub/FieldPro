import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:fieldpro/features/audio_report/session_result.dart';
import 'package:fieldpro/features/map/kml_parser.dart';
import 'package:fieldpro/features/visits/visit_models.dart';

const _mmKml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://earth.google.com/kml/2.2">
<Document>
  <name>zohor alsalam GZA5317</name>
  <ExtendedData xmlns:mwm="https://maps.me">
    <mwm:name><mwm:lang code="default">zohor alsalam GZA5317</mwm:lang></mwm:name>
  </ExtendedData>
  <Style id="track-1"><LineStyle><color>ffcc3399</color><width>5</width></LineStyle></Style>
  <Placemark>
    <name>مدخل الموقع</name>
    <description><![CDATA[<b>بوابة</b> رئيسية&nbsp;شرقية]]></description>
    <Point><coordinates>34.4668, 31.5017, 0</coordinates></Point>
  </Placemark>
  <Placemark>
    <name></name>
    <Point><coordinates>34.47,31.51</coordinates></Point>
  </Placemark>
  <Placemark>
    <name>حدود الموقع</name><styleUrl>#track-1</styleUrl>
    <LineString><coordinates>34.4660,31.5010 34.4670,31.5010 34.4670,31.5020 34.4660,31.5020 34.4660,31.5010</coordinates></LineString>
  </Placemark>
  <Placemark>
    <name>مسار مفتوح</name>
    <LineString><coordinates>34.40,31.50 34.41,31.51 34.42,31.52</coordinates></LineString>
  </Placemark>
  <Folder><name>مرافق</name>
    <Placemark><name>خزان</name><Point><coordinates>34.468,31.502,0</coordinates></Point></Placemark>
    <Placemark><name>poly</name><Polygon><outerBoundaryIs><LinearRing><coordinates>34.1,31.1,0 34.2,31.1,0 34.2,31.2,0 34.1,31.1,0</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
  </Folder>
</Document></kml>''';

void main() {
  group('KmlParser', () {
    test('يقرأ ملف شبيه بـ Maps.me (مجموعات، نقاط، حدود، ألوان)', () {
      final g = KmlParser.parse(
          'a.kml', Uint8List.fromList(utf8.encode(_mmKml)));
      expect(g.length, 2);

      expect(g[0].name, 'zohor alsalam GZA5317');
      expect(g[0].points.length, 2);
      expect(g[0].points[0].name, 'مدخل الموقع');
      expect(g[0].points[0].note, 'بوابة رئيسية شرقية');
      expect(g[0].points[0].lat, closeTo(31.5017, 1e-9));
      expect(g[0].points[0].lng, closeTo(34.4668, 1e-9));
      expect(g[0].lines.length, 2);
      expect(g[0].closedCount, 1);
      expect(g[0].openCount, 1);
      expect(g[0].lines[0].name, 'حدود الموقع');
      expect(g[0].lines[0].closed, true);
      expect(g[0].lines[0].pts.length, 5);
      expect(g[0].lines[0].color, 0xFF9933CC);

      expect(g[1].name, 'مرافق');
      expect(g[1].points.length, 1);
      expect(g[1].lines.length, 1);
      expect(g[1].lines[0].polygon, true);
      expect(g[1].lines[0].pts.length, 4);
    });

    test('يقرأ KMZ', () {
      final bytes = Uint8List.fromList(utf8.encode(_mmKml));
      final arc = Archive()..addFile(ArchiveFile('doc.kml', bytes.length, bytes));
      final kmz = Uint8List.fromList(ZipEncoder().encode(arc)!);
      final g = KmlParser.parse('x.kmz', kmz);
      expect(g.length, 2);
      expect(g[0].points.length, 2);
    });

    test('يقرأ GPX', () {
      const gpx =
          '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
          '<wpt lat="31.5" lon="34.46"><name>A</name></wpt>'
          '<trk><name>T</name><trkseg>'
          '<trkpt lat="31.5" lon="34.46"/><trkpt lat="31.5" lon="34.47"/>'
          '<trkpt lat="31.51" lon="34.47"/></trkseg></trk></gpx>';
      final g = KmlParser.parse('g.gpx', Uint8List.fromList(utf8.encode(gpx)));
      expect(g.length, 1);
      expect(g[0].name, 'g');
      expect(g[0].points.length, 1);
      expect(g[0].lines.length, 1);
      expect(g[0].lines[0].pts.length, 3);
      expect(g[0].lines[0].closed, false);
    });

    test('يرفض ملفاً تالفاً', () {
      expect(
              () => KmlParser.parse(
              'bad.kml', Uint8List.fromList(utf8.encode('not xml'))),
          throwsException);
    });
  });

  group('GeoMath', () {
    final square = [
      const LatLng(31.5, 34.46),
      const LatLng(31.5, 34.461),
      const LatLng(31.501, 34.461),
      const LatLng(31.501, 34.46),
    ];
    test('المساحة', () {
      expect(GeoMath.area(square), closeTo(10542, 105));
      expect(GeoMath.area([]), 0);
      expect(GeoMath.area([const LatLng(1, 1), const LatLng(2, 2)]), 0);
    });
    test('المحيط', () {
      expect(GeoMath.perimeter(square), closeTo(412, 5));
    });
  });

  group('SessionResult', () {
    test('يحلّل رد الذكاء الاصطناعي', () {
      const raw = '''
[[TITLE]]
اجتماع تنسيقي
[[ATTENDEES]]
- أحمد - إدارة الموقع
- سعاد
[[SUMMARY]]
ملخص قصير.
[[POINTS]]
- نقطة 1
- نقطة 2
[[DECISIONS]]
- قرار 1
[[TASKS]]
أحمد | متابعة المورد | الأسبوع القادم
''';
      final r = SessionResult.fromMarked(raw);
      expect(r.title, 'اجتماع تنسيقي');
      expect(r.attendees.length, 2);
      expect(r.attendees[0].name, 'أحمد');
      expect(r.attendees[0].org, 'إدارة الموقع');
      expect(r.attendees[1].name, 'سعاد');
      expect(r.keyPoints, ['نقطة 1', 'نقطة 2']);
      expect(r.decisions, ['قرار 1']);
      expect(r.tasks.length, 1);
      expect(r.tasks[0].who, 'أحمد');
      expect(r.tasks[0].what, 'متابعة المورد');
      expect(r.tasks[0].due, 'الأسبوع القادم');
      expect(r.tasks[0].status, 'مفتوحة');
      expect(r.aiGenerated, true);
    });

    test('«لا يوجد» لا يصير حضوراً', () {
      final r = SessionResult.fromMarked(
          '[[ATTENDEES]]\nلا يوجد\n[[SUMMARY]]\nنص');
      expect(r.attendees, isEmpty);
      expect(r.summary, 'نص');
    });

    test('رد بدون علامات يصير ملخصاً', () {
      final r = SessionResult.fromMarked('كلام عادي بدون علامات');
      expect(r.summary, 'كلام عادي بدون علامات');
    });

    test('JSON ذهاباً وإياباً، ويقبل الحضور بصيغة قديمة', () {
      final r = SessionResult()
        ..title = 'ت'
        ..attendees = [Attendee('أحمد', 'جهة')]
        ..tasks = [SessionTask('س', 'م', 'غداً', 'مغلقة')];
      final back = SessionResult.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.attendees[0].org, 'جهة');
      expect(back.tasks[0].status, 'مغلقة');

      final legacy = SessionResult.fromJson({
        'attendees': ['خالد']
      });
      expect(legacy.attendees[0].name, 'خالد');
    });

    test('تعبئة الفارغ فقط ولا تمسّ كتابة المستخدم', () {
      final user = SessionResult()
        ..title = 'عنواني'
        ..keyPoints = ['نقطتي'];
      final ai = SessionResult()
        ..title = 'عنوان آلي'
        ..summary = 'ملخص آلي'
        ..keyPoints = ['آلية']
        ..decisions = ['قرار'];
      user.fillEmptyFrom(ai);
      expect(user.title, 'عنواني');
      expect(user.summary, 'ملخص آلي');
      expect(user.keyPoints, ['نقطتي']);
      expect(user.decisions, ['قرار']);
      expect(SessionResult().isEmpty, true);
    });
  });

  group('Visit', () {
    test('رقم الزيارة والصورة يطابقان شرط الخادم', () {
      final re = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
      for (var i = 0; i < 200; i++) {
        expect(re.hasMatch(newId('v')), true);
        expect(re.hasMatch(newId('p')), true);
      }
    });

    test('تحويل للخادم وعودة', () {
      final v = Visit(
        id: 'v_abc12345',
        siteCode: 'GZA5317',
        siteName: 'الزهور',
        purpose: 'Site Alert',
        status: 'urgent',
        visitor: 'سعيد',
        visitedAt: DateTime.utc(2026, 11, 4, 10),
        lat: 31.5,
        lng: 34.46,
        accuracy: 6,
        notes: 'تسريب',
        photoIds: ['p_1', 'p_2'],
      );
      final r = v.toRemote();
      expect(r.containsKey('seq'), false);
      expect(r.containsKey('dirty'), false);
      expect(r['photo_ids'], jsonEncode(['p_1', 'p_2']));
      final back = Visit.fromMap(Map<String, dynamic>.from(r));
      expect(back.id, v.id);
      expect(back.status, 'urgent');
      expect(back.photoIds, ['p_1', 'p_2']);
      expect(back.visitedAt.isAtSameMomentAs(v.visitedAt), true);
      expect(back.lat, 31.5);
      expect(back.siteLabel, 'GZA5317 - الزهور');
    });

    test('حالة غير معروفة تصير مكتملة، ومعرّفات الصور كنص JSON', () {
      final v = Visit.fromMap({
        'id': 'v_abc12345',
        'status': 'weird',
        'visited_at': '2026-11-04T10:00:00Z',
        'photo_ids': '["a","b"]',
      });
      expect(v.status, 'completed');
      expect(v.photoIds, ['a', 'b']);
      expect(v.siteLabel, 'موقع غير محدد');
    });
  });
}