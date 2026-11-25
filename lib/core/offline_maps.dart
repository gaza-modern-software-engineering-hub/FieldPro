import 'dart:math' as math;
import 'package:flutter_map/flutter_map.dart' show LatLngBounds, TileProvider;
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart'
    show
    BrowseLoadingStrategy,
    BrowseStoreStrategy,
    FMTCObjectBoxBackend,
    FMTCStore,
    FMTCTileProvider;
import 'package:latlong2/latlong.dart';
import 'app_config.dart';
import 'app_settings.dart';
import 'database.dart';

class OfflinePack {
  final String id;
  final String name;
  final String desc;
  final LatLngBounds bounds;
  final int minZ;
  final int maxZ;
  const OfflinePack(
      this.id, this.name, this.desc, this.bounds, this.minZ, this.maxZ);
}

class OfflineMaps {
  static bool ready = false;

  static const streets = 'streets';
  static const satellite = 'satellite';
  static const userAgent = 'saeed_dev.com.fieldpro';
  static const maxTiles = 40000;

  static final packs = <OfflinePack>[
    OfflinePack(
        'gaza',
        'قطاع غزة',
        'الأحياء والشوارع (حتى مستوى 16)',
        LatLngBounds(const LatLng(31.20, 34.20), const LatLng(31.62, 34.58)),
        7,
        16),
    OfflinePack(
        'westbank',
        'الضفة الغربية',
        'المدن والطرق',
        LatLngBounds(const LatLng(31.30, 34.85), const LatLng(32.60, 35.60)),
        7,
        15),
    OfflinePack(
        'palestine',
        'كل فلسطين',
        'عرض عام للتنقل',
        LatLngBounds(const LatLng(29.45, 34.20), const LatLng(33.35, 35.95)),
        7,
        13),
  ];

  /// الباقات المكتملة في الذاكرة (تُحمَّل عند التشغيل وتتحدّث بعد كل تنزيل)
  static final Set<String> _done = {};

  static Future<void> init() async {
    try {
      await FMTCObjectBoxBackend().initialise();
      for (final s in [streets, satellite]) {
        final st = FMTCStore(s);
        if (!await st.manage.ready) await st.manage.create();
      }
      ready = true;
    } catch (_) {
      ready = false;
    }
    try {
      await loadMeta();
    } catch (_) {}
  }

  static Future<void> loadMeta() async {
    _done.clear();
    for (final p in packs) {
      for (final s in [streets, satellite]) {
        final v = await AppDatabase.instance
            .getSetting('offline_pack_${p.id}_$s');
        if (v != null && v.isNotEmpty && v != '0') _done.add('${p.id}_$s');
      }
    }
  }

  static void markDone(String packId, String store) =>
      _done.add('${packId}_$store');

  static void clearStore(String store) =>
      _done.removeWhere((k) => k.endsWith('_$store'));

  /// أعلى مستوى تقريب محفوظ بشكل كامل حول هذا الموقع (للتكبير بدل الفراغ)
  static int nativeZoomAt(LatLng c, bool sat) {
    final s = sat ? satellite : streets;
    var best = 0;
    for (final p in packs) {
      if (_done.contains('${p.id}_$s') && p.bounds.contains(c) && p.maxZ > best) {
        best = p.maxZ;
      }
    }
    return best == 0 ? 16 : best;
  }

  /// مزوّد المربعات المحفوظة للخريطة (يخزّن ما تتصفحه ويعرضه بدون نت)
  static TileProvider? provider(String store, {bool cacheOnly = false}) {
    if (!ready) return null;
    try {
      return FMTCTileProvider(
        stores: {store: BrowseStoreStrategy.readUpdateCreate},
        loadingStrategy: cacheOnly
            ? BrowseLoadingStrategy.cacheOnly
            : BrowseLoadingStrategy.cacheFirst,
        urlTransformer: cacheKey,
      );
    } catch (_) {
      return null;
    }
  }

  /// مفتاح التخزين = مسار المربع فقط، بدون الكلمة السرية ولا المفتاح
  static String cacheKey(String url) {
    final u = Uri.tryParse(url);
    return u == null ? url : u.path;
  }

  static bool get viaProxy => AppConfig.proxyUrl.trim().isNotEmpty;

  static bool get canUse =>
      viaProxy || AppSettings.effectiveMaptiler.isNotEmpty;

  static String get proxyBase =>
      AppConfig.proxyUrl.trim().replaceAll(RegExp(r'/+$'), '');

  static String urlTemplate(bool sat) {
    if (viaProxy) {
      final t = Uri.encodeQueryComponent(AppConfig.appToken);
      return '$proxyBase/tiles/${sat ? 'satellite' : 'streets'}/{z}/{x}/{y}?t=$t';
    }
    final k = AppSettings.effectiveMaptiler;
    return sat
        ? 'https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=$k'
        : 'https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key=$k';
  }

  static String testTileUrl(bool sat) => urlTemplate(sat)
      .replaceAll('{z}', '10')
      .replaceAll('{x}', '610')
      .replaceAll('{y}', '417');

  static int _x(double lng, int z) => ((lng + 180) / 360 * (1 << z)).floor();

  static int _y(double lat, int z) {
    final r = lat * math.pi / 180;
    return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) /
        2 *
        (1 << z))
        .floor();
  }

  static int tileCount(LatLngBounds b, int minZ, int maxZ) {
    var t = 0;
    for (var z = minZ; z <= maxZ; z++) {
      final x1 = _x(b.west, z), x2 = _x(b.east, z);
      final y1 = _y(b.north, z), y2 = _y(b.south, z);
      t += (x2 - x1 + 1) * (y2 - y1 + 1);
    }
    return t;
  }
}