import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

class KmlPoint {
  final String name;
  final String note;
  final double lat;
  final double lng;
  KmlPoint(this.name, this.note, this.lat, this.lng);
}

bool _isClosedPath(List<LatLng> p) =>
    p.length >= 3 &&
        const Distance().as(LengthUnit.Meter, p.first, p.last) <= 40;

class KmlLine {
  final String name;
  final String note;
  final List<LatLng> pts;
  final bool polygon;
  final int? color; // ARGB
  final bool closed;
  KmlLine(this.name, this.note, this.pts, this.polygon, this.color)
      : closed = polygon || _isClosedPath(pts);
}

class KmlGroup {
  final String name;
  final List<KmlPoint> points = [];
  final List<KmlLine> lines = [];
  KmlGroup(this.name);

  int get closedCount => lines.where((l) => l.closed).length;
  int get openCount => lines.length - closedCount;
  bool get isEmpty => points.isEmpty && lines.isEmpty;
}

class GeoMath {
  static double area(List<LatLng> p) {
    if (p.length < 3) return 0;
    const r = 6371000.0;
    final lat0 = p.map((e) => e.latitude).reduce((a, b) => a + b) /
        p.length *
        math.pi /
        180;
    final pts = p
        .map((e) => [
      e.longitude * math.pi / 180 * r * math.cos(lat0),
      e.latitude * math.pi / 180 * r
    ])
        .toList();
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      s += a[0] * b[1] - b[0] * a[1];
    }
    return s.abs() / 2;
  }

  static double perimeter(List<LatLng> p) {
    if (p.length < 2) return 0;
    const d = Distance();
    var t = 0.0;
    for (var i = 0; i < p.length - 1; i++) {
      t += d.as(LengthUnit.Meter, p[i], p[i + 1]);
    }
    if (p.length > 2) t += d.as(LengthUnit.Meter, p.last, p.first);
    return t;
  }
}

class KmlParser {
  /// يقرأ KML أو KMZ أو GPX ويرجع مجموعات (مجلدات)
  static List<KmlGroup> parse(String fileName, Uint8List bytes) {
    String text;
    final isZip = bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    if (isZip) {
      final arc = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? pick;
      for (final f in arc.files) {
        if (!f.isFile) continue;
        final n = f.name.toLowerCase();
        if (n == 'doc.kml') {
          pick = f;
          break;
        }
        if (n.endsWith('.kml') && pick == null) pick = f;
      }
      if (pick == null) throw Exception('لا يوجد ملف KML داخل الأرشيف');
      text = utf8.decode(pick.content as List<int>, allowMalformed: true);
    } else {
      text = utf8.decode(bytes, allowMalformed: true);
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException {
      throw Exception('الملف تالف أو ليس KML/GPX صالحاً');
    }

    final base = _baseName(fileName);
    final root = doc.rootElement;
    if (root.name.qualified == 'gpx') return _gpx(root, base);

    final styles = <String, int>{};
    for (final s in doc.descendants.whereType<XmlElement>()) {
      if (s.name.qualified != 'Style') continue;
      final id = s.getAttribute('id');
      if (id == null) continue;
      String? col;
      for (final ls in s.children.whereType<XmlElement>()) {
        final t = ls.name.qualified;
        if ((t == 'LineStyle' || t == 'PolyStyle') && col == null) {
          col = _childText(ls, 'color');
        }
      }
      final c = _kmlColor(col);
      if (c != null) styles['#$id'] = c;
    }

    final groups = <String, KmlGroup>{};
    KmlGroup grp(String n) => groups.putIfAbsent(n, () => KmlGroup(n));

    void walk(XmlElement el, String groupName) {
      for (final c in el.children.whereType<XmlElement>()) {
        final tag = c.name.qualified;
        if (tag == 'Folder' || tag == 'Document') {
          final n = _childText(c, 'name');
          walk(c, (n == null || n.isEmpty) ? groupName : n);
        } else if (tag == 'Placemark') {
          _placemark(c, grp(groupName), styles);
        }
      }
    }

    walk(root, base);
    return groups.values.where((g) => !g.isEmpty).toList();
  }

  static void _placemark(
      XmlElement pm, KmlGroup g, Map<String, int> styles) {
    final name = _childText(pm, 'name') ?? '';
    final note = _clean(_childText(pm, 'description') ?? '');
    final su = _childText(pm, 'styleUrl');
    final color = su == null ? null : styles[su];
    for (final geo in pm.descendants.whereType<XmlElement>()) {
      final tag = geo.name.qualified;
      if (tag == 'Point') {
        final p = _coords(_firstDesc(geo, 'coordinates'));
        if (p.isNotEmpty) {
          g.points.add(KmlPoint(name, note, p.first.latitude, p.first.longitude));
        }
      } else if (tag == 'LineString') {
        final p = _coords(_firstDesc(geo, 'coordinates'));
        if (p.length >= 2) g.lines.add(KmlLine(name, note, p, false, color));
      } else if (tag == 'Polygon') {
        final p = _coords(_firstDesc(geo, 'coordinates'));
        if (p.length >= 3) g.lines.add(KmlLine(name, note, p, true, color));
      }
    }
  }

  static List<KmlGroup> _gpx(XmlElement root, String base) {
    final g = KmlGroup(base);
    for (final e in root.children.whereType<XmlElement>()) {
      final tag = e.name.qualified;
      if (tag == 'wpt') {
        final lat = double.tryParse(e.getAttribute('lat') ?? '');
        final lon = double.tryParse(e.getAttribute('lon') ?? '');
        if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
          continue;
        }
        g.points.add(KmlPoint(_childText(e, 'name') ?? '',
            _clean(_childText(e, 'desc') ?? ''), lat, lon));
      } else if (tag == 'trk' || tag == 'rte') {
        final pts = <LatLng>[];
        for (final p in e.descendants.whereType<XmlElement>()) {
          final t = p.name.qualified;
          if (t != 'trkpt' && t != 'rtept') continue;
          final lat = double.tryParse(p.getAttribute('lat') ?? '');
          final lon = double.tryParse(p.getAttribute('lon') ?? '');
          if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
            continue;
          }
          if (pts.isNotEmpty &&
              pts.last.latitude == lat &&
              pts.last.longitude == lon) {
            continue;
          }
          pts.add(LatLng(lat, lon));
        }
        if (pts.length >= 2) {
          g.lines.add(KmlLine(_childText(e, 'name') ?? '', '', pts, false, null));
        }
      }
    }
    return g.isEmpty ? [] : [g];
  }

  static String _baseName(String f) {
    final n = f.split(RegExp(r'[\\/]')).last;
    final i = n.lastIndexOf('.');
    return i > 0 ? n.substring(0, i) : n;
  }

  /// نص أول ابن مباشر بهذا الاسم (الاسم الكامل بما فيه البادئة، فلا يختلط مع mwm:name)
  static String? _childText(XmlElement e, String name) {
    for (final c in e.children.whereType<XmlElement>()) {
      if (c.name.qualified == name) return c.innerText.trim();
    }
    return null;
  }

  static String? _firstDesc(XmlElement e, String name) {
    for (final d in e.descendants.whereType<XmlElement>()) {
      if (d.name.qualified == name) return d.innerText;
    }
    return null;
  }

  static List<LatLng> _coords(String? s) {
    final out = <LatLng>[];
    if (s == null) return out;
    final norm = s.trim().replaceAll(RegExp(r'\s*,\s*'), ',');
    for (final t in norm.split(RegExp(r'\s+'))) {
      if (t.isEmpty) continue;
      final p = t.split(',');
      if (p.length < 2) continue;
      final lng = double.tryParse(p[0]);
      final lat = double.tryParse(p[1]);
      if (lat == null || lng == null) continue;
      if (lat.abs() > 90 || lng.abs() > 180) continue;
      if (out.isNotEmpty &&
          out.last.latitude == lat &&
          out.last.longitude == lng) {
        continue;
      }
      out.add(LatLng(lat, lng));
    }
    return out;
  }

  /// KML يستخدم aabbggrr
  static int? _kmlColor(String? c) {
    if (c == null || c.length != 8) return null;
    final v = int.tryParse(c, radix: 16);
    if (v == null) return null;
    final b = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, r = v & 0xFF;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }

  static String _clean(String s) {
    var o = s.replaceAll(RegExp(r'<[^>]*>'), ' ');
    o = o
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return o.length > 500 ? o.substring(0, 500) : o;
  }
}