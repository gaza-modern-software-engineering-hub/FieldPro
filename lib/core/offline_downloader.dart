import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart' show TileLayer;
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart'
    show
    FMTCStore,
    FailedRequestTileEvent,
    NegativeResponseTileEvent,
    RectangleRegion;
import 'package:http/http.dart' as http;
import 'database.dart';
import 'offline_maps.dart';

/// مدير تنزيل يعيش خارج الشاشة: الخروج من الصفحة لا يوقف التنزيل ولا يضيّع نتيجته
class OfflineDownloader extends ChangeNotifier {
  OfflineDownloader._();
  static final OfflineDownloader instance = OfflineDownloader._();

  bool running = false;
  bool cancelling = false;
  String? packId;
  String packName = '';
  bool satellite = false;
  int attempted = 0;
  int total = 0;
  int okCount = 0;
  int failed = 0;
  int existing = 0;
  String phase = '';
  String? hint;
  String? message;
  bool messageIsError = false;

  StreamSubscription<dynamic>? _p;
  StreamSubscription<dynamic>? _t;

  String get storeName =>
      satellite ? OfflineMaps.satellite : OfflineMaps.streets;

  double get fraction =>
      total == 0 ? 0 : (attempted / total).clamp(0.0, 1.0).toDouble();

  void clearMessage() {
    message = null;
    notifyListeners();
  }

  void _msg(String m, {bool error = false}) {
    message = m;
    messageIsError = error;
  }

  static String _statusHint(int c) {
    switch (c) {
      case 401:
        return 'رفض الخادم (401): الكلمة السرية بالتطبيق غير مطابقة';
      case 403:
        return 'رفض المزوّد (403): مفتاح الخرائط غير صالح';
      case 429:
        return 'تجاوز حد الاستخدام (429)، حاول لاحقاً';
      case 503:
        return 'الخدمة مشغولة (503)';
      default:
        return 'رد الخادم $c';
    }
  }

  Future<String?> _preflight(bool sat) async {
    try {
      final r = await http
          .get(Uri.parse(OfflineMaps.testTileUrl(sat)))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) return null;
      return _statusHint(r.statusCode);
    } on TimeoutException {
      return 'الاتصال بطيء أو غير متوفر';
    } catch (_) {
      return 'لا يوجد اتصال بالإنترنت';
    }
  }

  Future<void> start({required OfflinePack pack, required bool sat}) async {
    if (running) return;
    if (!OfflineMaps.ready) {
      _msg('نظام تخزين الخرائط لم يعمل على هذا الجهاز', error: true);
      notifyListeners();
      return;
    }
    if (!OfflineMaps.canUse) {
      _msg('خدمة الخرائط غير مفعّلة. راجع مسؤول التطبيق', error: true);
      notifyListeners();
      return;
    }
    final tiles = OfflineMaps.tileCount(pack.bounds, pack.minZ, pack.maxZ);
    if (tiles > OfflineMaps.maxTiles) {
      _msg('المنطقة كبيرة جداً ($tiles مربع). قرّب الخريطة أكثر', error: true);
      notifyListeners();
      return;
    }

    running = true;
    cancelling = false;
    packId = pack.id;
    packName = pack.name;
    satellite = sat;
    attempted = 0;
    total = tiles;
    okCount = 0;
    failed = 0;
    existing = 0;
    hint = null;
    message = null;
    phase = 'جاري التحقق من الاتصال...';
    notifyListeners();

    try {
      final err = await _preflight(sat);
      if (err != null) {
        _msg(err, error: true);
        return;
      }
      phase = 'جاري التنزيل...';
      notifyListeners();

      final store = FMTCStore(storeName);
      final dl = store.download.startForeground(
        region: RectangleRegion(pack.bounds).toDownloadable(
          minZoom: pack.minZ,
          maxZoom: pack.maxZ,
          options: TileLayer(
            urlTemplate: OfflineMaps.urlTemplate(sat),
            userAgentPackageName: OfflineMaps.userAgent,
          ),
        ),
        skipExistingTiles: true,
        skipSeaTiles: false,
        parallelThreads: 4,
        rateLimit: 40,
        urlTransformer: OfflineMaps.cacheKey,
      );

      final done = Completer<void>();
      _p = dl.downloadProgress.listen((e) {
        total = e.maxTilesCount;
        attempted = e.attemptedTilesCount;
        okCount = e.successfulTilesCount;
        failed = e.failedTilesCount;
        existing = e.existingTilesCount;
        notifyListeners();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      }, onError: (_) {
        if (!done.isCompleted) done.complete();
      });
      _t = dl.tileEvents.listen((e) {
        if (hint != null) return;
        if (e is NegativeResponseTileEvent) {
          hint = _statusHint(e.fetchResponse.statusCode);
        } else if (e is FailedRequestTileEvent) {
          hint = 'انقطع الاتصال أثناء التنزيل';
        }
      });

      await done.future;
      await _evaluate(pack);
    } catch (e) {
      final s = e.toString();
      if (s.contains('already exists')) {
        try {
          await FMTCStore(storeName).download.cancel();
        } catch (_) {}
        _msg('كان في تنزيل قديم عالق، تم إيقافه. اضغط تنزيل من جديد',
            error: true);
      } else {
        _msg('تعذر التنزيل: $s', error: true);
      }
    } finally {
      await _p?.cancel();
      await _t?.cancel();
      _p = null;
      _t = null;
      running = false;
      cancelling = false;
      notifyListeners();
    }
  }

  Future<void> _evaluate(OfflinePack pack) async {
    if (cancelling) {
      _msg('تم إيقاف التنزيل. اللي نزل انحفظ وما رح ينزل ثاني');
      return;
    }
    if (total == 0 || attempted == 0) {
      _msg('ما نزل أي مربع. ${hint ?? 'تحقق من الإنترنت وحاول ثاني'}',
          error: true);
      return;
    }
    final good = okCount + existing;
    if (good / total >= 0.97) {
      if (pack.id != 'current') {
        OfflineMaps.markDone(pack.id, storeName);
        await AppDatabase.instance.setSetting(
            'offline_pack_${pack.id}_$storeName',
            DateTime.now().toIso8601String());
      }
      _msg('اكتمل تنزيل ${pack.name}: $okCount مربع جديد، $existing موجود مسبقاً');
    } else {
      _msg(
          'نزل $good من $total مربع (فشل $failed). ${hint ?? ''}\nأعد المحاولة: اللي نزل ما رح ينزل ثاني.',
          error: true);
    }
  }

  /// إيقاف حقيقي للتنزيل (مش بس المتابعة)
  Future<void> cancel() async {
    if (!running) return;
    cancelling = true;
    phase = 'جاري الإيقاف...';
    notifyListeners();
    try {
      await FMTCStore(storeName).download.cancel();
    } catch (_) {}
  }
}