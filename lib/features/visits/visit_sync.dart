import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../../core/app_config.dart';
import '../../core/database.dart';
import 'visit_models.dart';

class _SyncError implements Exception {
  final String message;
  _SyncError(this.message);
}

/// مزامنة الزيارات مع الخادم: تُحفظ محلياً أولاً ثم تُرفع، وتُنزَّل زيارات الباقين
class VisitSync extends ChangeNotifier {
  VisitSync._();
  static final VisitSync instance = VisitSync._();

  bool syncing = false;
  DateTime? lastOk;
  String? error;
  int pending = 0;

  bool get enabled => AppConfig.proxyUrl.trim().isNotEmpty;
  String get _base =>
      AppConfig.proxyUrl.trim().replaceAll(RegExp(r'/+$'), '');
  Map<String, String> get _h => {'x-app-token': AppConfig.appToken};

  static const _maxB64 = 440000;

  static Future<Directory> photoDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/visit_photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<List<String>> loadPurposes() async {
    final v = await AppDatabase.instance.getSetting('visit_purposes');
    if (v == null || v.isEmpty) return List.of(kDefaultPurposes);
    try {
      final l = (jsonDecode(v) as List).map((e) => e.toString()).toList();
      return l.isEmpty ? List.of(kDefaultPurposes) : l;
    } catch (_) {
      return List.of(kDefaultPurposes);
    }
  }

  static Future<String> loadVisitor() async =>
      (await AppDatabase.instance.getSetting('visit_visitor_name')) ?? '';

  Future<void> refreshPending() async {
    pending = await AppDatabase.instance.pendingSyncCount();
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (syncing) return;
    if (!enabled) {
      error = 'المزامنة تحتاج إعداد الخادم الوسيط';
      notifyListeners();
      return;
    }
    syncing = true;
    error = null;
    notifyListeners();
    try {
      await _push();
      await _pull();
      lastOk = DateTime.now();
    } on _SyncError catch (e) {
      error = e.message;
    } catch (e) {
      error = _friendly(e);
    } finally {
      syncing = false;
      pending = await AppDatabase.instance.pendingSyncCount();
      notifyListeners();
    }
  }

  String _friendly(Object e) {
    if (e is SocketException ||
        e is TimeoutException ||
        e is http.ClientException) {
      return 'لا يوجد اتصال بالإنترنت. التغييرات محفوظة وتُرفع تلقائياً لاحقاً';
    }
    final s = e.toString();
    return 'تعذرت المزامنة: ${s.length > 120 ? s.substring(0, 120) : s}';
  }

  void _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    if (r.statusCode == 401) {
      throw _SyncError('الكلمة السرية بالتطبيق غير مطابقة للخادم');
    }
    if (r.statusCode == 503) {
      throw _SyncError('قاعدة بيانات الزيارات غير مربوطة بالخادم');
    }
    if (r.statusCode == 429) {
      throw _SyncError('تجاوز حد الاستخدام، حاول لاحقاً');
    }
    throw _SyncError('خطأ من الخادم (${r.statusCode})');
  }

  // ---------- الرفع ----------
  Future<void> _push() async {
    final db = AppDatabase.instance;
    final dirty = await db.dirtyVisits();
    if (dirty.isEmpty) return;

    for (final v in dirty) {
      if (v.deleted) continue;
      for (final p in await db.getPhotos(v.id)) {
        final path = (p['path'] ?? '').toString();
        if ((p['uploaded'] as int? ?? 0) == 0 && path.isNotEmpty) {
          await _uploadPhoto(p['id'].toString(), v.id, path);
        }
      }
    }

    for (var i = 0; i < dirty.length; i += 20) {
      final chunk = dirty.sublist(i, math.min(i + 20, dirty.length));
      final res = await http
          .post(Uri.parse('$_base/api/visits/sync'),
          headers: {..._h, 'Content-Type': 'application/json'},
          body: jsonEncode({'visits': chunk.map((v) => v.toRemote()).toList()}))
          .timeout(const Duration(seconds: 40));
      _check(res);
      for (final v in chunk) {
        await db.markVisitPushed(v.id, v.dirty);
        if (v.deleted) {
          for (final path in await db.removeVisitLocal(v.id)) {
            try {
              File(path).deleteSync();
            } catch (_) {}
          }
        }
      }
    }
  }

  Future<String> _encode(File f) async {
    var bytes = await f.readAsBytes();
    var b64 = base64Encode(bytes);
    if (b64.length <= _maxB64) return b64;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw _SyncError('تعذر قراءة الصورة');
    var width = 1024;
    var q = 60;
    for (var i = 0; i < 5; i++) {
      final r = decoded.width > width
          ? img.copyResize(decoded, width: width)
          : decoded;
      bytes = Uint8List.fromList(img.encodeJpg(r, quality: q));
      b64 = base64Encode(bytes);
      if (b64.length <= _maxB64) return b64;
      width = (width * 0.8).round();
      q = math.max(35, q - 8);
    }
    throw _SyncError('الصورة كبيرة جداً حتى بعد الضغط');
  }

  Future<void> _uploadPhoto(String id, String visitId, String path) async {
    final db = AppDatabase.instance;
    final f = File(path);
    if (!f.existsSync()) {
      await db.setPhotoUploaded(id);
      return;
    }
    String b64;
    try {
      b64 = await _encode(f);
    } on _SyncError {
      await db.setPhotoUploaded(id);
      return;
    }
    final res = await http
        .put(Uri.parse('$_base/api/photos/$id?visit=$visitId'),
        headers: {..._h, 'Content-Type': 'text/plain; charset=utf-8'},
        body: b64)
        .timeout(const Duration(seconds: 90));
    if (res.statusCode == 413 || res.statusCode == 400) {
      await db.setPhotoUploaded(id);
      return;
    }
    _check(res);
    await db.setPhotoUploaded(id);
  }

  // ---------- التنزيل ----------
  Future<void> _pull() async {
    final db = AppDatabase.instance;
    var since = int.tryParse(await db.getSetting('visits_seq') ?? '0') ?? 0;
    for (var page = 0; page < 200; page++) {
      final res = await http
          .get(Uri.parse('$_base/api/visits?since=$since&limit=100'),
          headers: _h)
          .timeout(const Duration(seconds: 40));
      _check(res);
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final rows =
      (j['visits'] as List? ?? []).cast<Map<String, dynamic>>();
      if (rows.isNotEmpty) {
        final paths = await db.applyRemoteVisits(rows);
        for (final p in paths) {
          try {
            File(p).deleteSync();
          } catch (_) {}
        }
      }
      final max = (j['max'] as num?)?.toInt() ?? since;
      if (max > since) {
        since = max;
        await db.setSetting('visits_seq', '$since');
      }
      if (j['more'] != true) break;
    }
  }

  /// صورة زيارة: من الجهاز إن وُجدت، وإلا تُنزَّل من الخادم وتُخزَّن
  Future<File?> photoFile(String photoId, String visitId) async {
    final db = AppDatabase.instance;
    final row = await db.getPhoto(photoId);
    if (row != null) {
      final p = (row['path'] ?? '').toString();
      if (p.isNotEmpty && File(p).existsSync()) return File(p);
    }
    if (!enabled) return null;
    try {
      final res = await http
          .get(Uri.parse('$_base/api/photos/$photoId'), headers: _h)
          .timeout(const Duration(seconds: 40));
      if (res.statusCode != 200) return null;
      final bytes = base64Decode(res.body.trim());
      final dir = await photoDir();
      final f = File('${dir.path}/$photoId.jpg');
      await f.writeAsBytes(bytes);
      await db.addPhoto(photoId, visitId, f.path, uploaded: true);
      return f;
    } catch (_) {
      return null;
    }
  }
}