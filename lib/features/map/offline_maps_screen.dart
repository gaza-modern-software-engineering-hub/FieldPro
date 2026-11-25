import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart'
    show FMTCStore;
import 'package:google_fonts/google_fonts.dart';
import '../../core/app_colors.dart';
import '../../core/database.dart';
import '../../core/offline_downloader.dart';
import '../../core/offline_maps.dart';

class OfflineMapsScreen extends StatefulWidget {
  final LatLngBounds? currentBounds;
  const OfflineMapsScreen({super.key, this.currentBounds});

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  final _dl = OfflineDownloader.instance;
  bool _sat = false;
  bool _wasRunning = false;
  final Set<String> _doneKeys = {};
  Map<String, ({double sizeMb, int tiles})> _stats = {};

  String get _store => _sat ? OfflineMaps.satellite : OfflineMaps.streets;

  OfflinePack? get _currentPack => widget.currentBounds == null
      ? null
      : OfflinePack('current', 'المنطقة الظاهرة على الخريطة الآن',
      'بتفصيل عالٍ (مباني وأزقة، حتى مستوى 17)', widget.currentBounds!, 12, 17);

  @override
  void initState() {
    super.initState();
    if (_dl.running) _sat = _dl.satellite;
    _wasRunning = _dl.running;
    _dl.addListener(_onDl);
    _refresh();
  }

  @override
  void dispose() {
    _dl.removeListener(_onDl);
    super.dispose();
  }

  void _onDl() {
    if (!mounted) return;
    if (_wasRunning && !_dl.running) _refresh();
    _wasRunning = _dl.running;
    setState(() {});
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _refresh() async {
    final keys = <String>{};
    for (final p in OfflineMaps.packs) {
      for (final s in [OfflineMaps.streets, OfflineMaps.satellite]) {
        final v = await AppDatabase.instance
            .getSetting('offline_pack_${p.id}_$s');
        if (v != null && v.isNotEmpty && v != '0') keys.add('${p.id}_$s');
      }
    }
    final m = <String, ({double sizeMb, int tiles})>{};
    if (OfflineMaps.ready) {
      for (final s in [OfflineMaps.streets, OfflineMaps.satellite]) {
        try {
          final st = FMTCStore(s);
          final kb = await st.stats.size;
          final n = await st.stats.length;
          m[s] = (sizeMb: kb / 1024, tiles: n);
        } catch (_) {}
      }
    }
    if (mounted) {
      setState(() {
        _doneKeys
          ..clear()
          ..addAll(keys);
        _stats = m;
      });
    }
  }

  double _mb(int tiles) => tiles * (_sat ? 28 : 18) / 1024;

  Future<void> _deleteStore(String name, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('حذف كل خرائط "$label" المحفوظة؟',
              style: GoogleFonts.cairo()),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('إلغاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('حذف',
                    style: GoogleFonts.cairo(color: Colors.red))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final st = FMTCStore(name);
      await st.manage.delete();
      await st.manage.create();
      for (final p in OfflineMaps.packs) {
        OfflineMaps.clearStore(name);
        await AppDatabase.instance
            .setSetting('offline_pack_${p.id}_$name', '0');
      }
    } catch (e) {
      _snack('تعذر الحذف: $e');
    }
    _refresh();
  }

  Widget _card(Widget child, {Color? color}) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color ?? Colors.white,
      borderRadius: BorderRadius.circular(18),
      boxShadow: [
        BoxShadow(
            color: AppColors.navy.withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 6)),
      ],
    ),
    child: child,
  );

  Widget _banner() {
    final m = _dl.message;
    if (m == null) return const SizedBox.shrink();
    final err = _dl.messageIsError;
    return _card(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(err ? Icons.error_rounded : Icons.check_circle_rounded,
                color: err ? Colors.red : Colors.green),
            const SizedBox(width: 10),
            Expanded(
                child: Text(m,
                    style: GoogleFonts.cairo(fontSize: 13, height: 1.5))),
            IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: _dl.clearMessage),
          ],
        ),
        color: err ? Colors.red.withOpacity(0.08) : Colors.green.withOpacity(0.10));
  }

  Widget _packCard(OfflinePack p) {
    final tiles = OfflineMaps.tileCount(p.bounds, p.minZ, p.maxZ);
    final tooBig = tiles > OfflineMaps.maxTiles;
    final isThis =
        _dl.running && _dl.packId == p.id && _dl.satellite == _sat;
    final done = _doneKeys.contains('${p.id}_$_store');
    final locked = _dl.running && !isThis;

    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(done ? Icons.check_circle_rounded : Icons.map_rounded,
                color: done ? Colors.green : AppColors.navy),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      style: GoogleFonts.cairo(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(p.desc,
                      style: GoogleFonts.cairo(
                          fontSize: 12, color: AppColors.textMuted)),
                ],
              ),
            ),
            if (!isThis)
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: done ? AppColors.navy : AppColors.gold,
                  foregroundColor: done ? Colors.white : AppColors.navyDark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: (locked || tooBig)
                    ? null
                    : () => _dl.start(pack: p, sat: _sat),
                child: Text(done ? 'تحديث' : 'تنزيل',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
            tooBig
                ? 'كبيرة جداً. قرّب الخريطة على منطقة أصغر'
                : '$tiles مربع  •  حوالي ${_mb(tiles).toStringAsFixed(0)} ميغابايت',
            style: GoogleFonts.cairo(
                fontSize: 12,
                color: tooBig ? Colors.red : AppColors.textMuted)),
        if (isThis) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
              value: _dl.attempted == 0 ? null : _dl.fraction),
          const SizedBox(height: 4),
          Text(
              '${_dl.phase}  ${_dl.attempted} / ${_dl.total} مربع'
                  '${_dl.failed > 0 ? '  •  فشل ${_dl.failed}' : ''}',
              style: GoogleFonts.cairo(fontSize: 12)),
          if (_dl.hint != null)
            Text(_dl.hint!,
                style: GoogleFonts.cairo(fontSize: 11, color: Colors.red)),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: _dl.cancelling ? null : _dl.cancel,
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: Text('إيقاف', style: GoogleFonts.cairo()),
            ),
          ),
        ],
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cur = _currentPack;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('الخرائط دون إنترنت',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _banner(),
            _card(
                Text(
                    'حمّل خريطة منطقتك مرة وحدة وانت على واي فاي. التنزيل يكمل لو طلعت من هالصفحة، بس لا تقفل التطبيق ولا تتركه بالخلفية.',
                    style: GoogleFonts.cairo(fontSize: 13, height: 1.6)),
                color: AppColors.gold.withOpacity(0.18)),
            if (!OfflineMaps.ready)
              _card(Text(
                  'نظام تخزين الخرائط لم يعمل على هذا الجهاز، فالتنزيل غير متاح.',
                  style: GoogleFonts.cairo(color: Colors.red))),
            if (!OfflineMaps.canUse)
              _card(Text('خدمة الخرائط غير مفعّلة. راجع مسؤول التطبيق.',
                  style: GoogleFonts.cairo(color: Colors.red))),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.map_rounded),
                    label: Text('شوارع', style: GoogleFonts.cairo())),
                ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.satellite_alt_rounded),
                    label: Text('أقمار صناعية', style: GoogleFonts.cairo())),
              ],
              selected: {_sat},
              onSelectionChanged:
              _dl.running ? null : (s) => setState(() => _sat = s.first),
            ),
            const SizedBox(height: 14),
            for (final p in OfflineMaps.packs) _packCard(p),
            if (cur != null) _packCard(cur),
            const SizedBox(height: 10),
            Text('المحفوظ على هذا الجهاز',
                style: GoogleFonts.cairo(
                    fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final s in [
              (OfflineMaps.streets, 'الشوارع'),
              (OfflineMaps.satellite, 'الأقمار الصناعية'),
            ])
              _card(Row(
                children: [
                  const Icon(Icons.sd_storage_rounded, color: AppColors.navy),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.$2,
                            style: GoogleFonts.cairo(
                                fontWeight: FontWeight.w700)),
                        Text(
                            _stats[s.$1] == null
                                ? '—'
                                : '${_stats[s.$1]!.tiles} مربع  •  ${_stats[s.$1]!.sizeMb.toStringAsFixed(1)} ميغابايت',
                            style: GoogleFonts.cairo(
                                fontSize: 12, color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_rounded, color: Colors.red),
                    onPressed:
                    _dl.running ? null : () => _deleteStore(s.$1, s.$2),
                  ),
                ],
              )),
          ],
        ),
      ),
    );
  }
}