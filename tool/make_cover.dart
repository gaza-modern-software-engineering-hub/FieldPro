import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  const w = 1024, h = 500;
  final im = img.Image(width: w, height: h);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final t = (x / w * 0.5 + y / h * 0.5);
      im.setPixelRgb(x, y, (19 + (7 - 19) * t).round(),
          (49 + (21 - 49) * t).round(), (92 + (43 - 92) * t).round());
    }
  }

  final gold = img.ColorRgb8(212, 175, 55);
  final navy = img.ColorRgb8(7, 21, 43);
  final white = img.ColorRgb8(255, 255, 255);

  // مضلع حدود
  final pts = [
    [90, 400], [220, 460], [420, 420], [380, 330], [160, 340]
  ];
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    img.drawLine(im,
        x1: a[0], y1: a[1], x2: b[0], y2: b[1], color: white, thickness: 6);
  }
  for (final p in pts) {
    img.fillCircle(im, x: p[0], y: p[1], radius: 11, color: gold);
  }

  // دبوس
  const cx = 250, cy = 170, r = 95;
  img.fillCircle(im, x: cx, y: cy, radius: r, color: gold);
  img.fillPolygon(im, vertices: [
    img.Point(cx - (r * 0.86).round(), cy + (r * 0.5).round()),
    img.Point(cx, cy + (r * 2.0).round()),
    img.Point(cx + (r * 0.86).round(), cy + (r * 0.5).round()),
  ], color: gold);
  img.fillCircle(im, x: cx, y: cy, radius: (r * 0.42).round(), color: navy);

  // نص
  img.drawString(im, 'FieldPro',
      font: img.arial48, x: 560, y: 190, color: white);
  img.drawString(im, 'Survey - Map - Report',
      font: img.arial24, x: 562, y: 260, color: gold);
  img.fillRect(im,
      x1: 562, y1: 300, x2: 700, y2: 304, color: gold);

  Directory('assets/icon').createSync(recursive: true);
  File('assets/icon/cover.png').writeAsBytesSync(img.encodePng(im));
  stdout.writeln('assets/icon/cover.png');
}