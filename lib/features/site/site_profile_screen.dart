import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_colors.dart';
import '../../core/database.dart';
import 'site_profile.dart';

class SiteProfileScreen extends StatefulWidget {
  final int projectId;
  final String projectName;
  const SiteProfileScreen(
      {super.key, required this.projectId, required this.projectName});

  @override
  State<SiteProfileScreen> createState() => _SiteProfileScreenState();
}

class _SiteProfileScreenState extends State<SiteProfileScreen> {
  final _code = TextEditingController();
  final _district = TextEditingController();
  final _manager = TextEditingController();
  final _phone = TextEditingController();
  final _hh = TextEditingController();
  final _ind = TextEditingController();
  final _areaOv = TextEditingController();
  final _notes = TextEditingController();

  List<TextEditingController> get _all =>
      [_code, _district, _manager, _phone, _hh, _ind, _areaOv, _notes];

  double _areaSum = 0;
  int _areaCount = 0;
  int _pointCount = 0;
  DateTime? _updated;
  bool _loading = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _touch() {
    if (!mounted) return;
    setState(() {
      if (!_loading) _dirty = true;
    });
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _load() async {
    try {
      final db = AppDatabase.instance;
      final p = await db.getSiteProfile(widget.projectId);
      final areas = await db.getAreas(projectId: widget.projectId);
      final pts = await db.countPoints(widget.projectId);
      if (!mounted) return;
      setState(() {
        if (p != null) {
          _code.text = p.code;
          _district.text = p.district;
          _manager.text = p.manager;
          _phone.text = p.phone;
          _hh.text = p.households == 0 ? '' : '${p.households}';
          _ind.text = p.individuals == 0 ? '' : '${p.individuals}';
          _areaOv.text =
          p.areaOverride <= 0 ? '' : p.areaOverride.toStringAsFixed(0);
          _notes.text = p.notes;
          _updated = p.updatedAt;
        }
        _areaSum = areas.fold<double>(0, (s, a) => s + a.areaM2);
        _areaCount = areas.length;
        _pointCount = pts;
        _loading = false;
      });
      for (final c in _all) {
        c.addListener(_touch);
      }
    } catch (e) {
      _snack('تعذر قراءة البطاقة: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  String _latin(String s) {
    const a = '٠١٢٣٤٥٦٧٨٩';
    var o = s;
    for (var i = 0; i < 10; i++) {
      o = o.replaceAll(a[i], '$i');
    }
    return o.replaceAll('٫', '.');
  }

  int _toInt(String s) =>
      int.tryParse(_latin(s).replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  double _toDouble(String s) =>
      double.tryParse(_latin(s).replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;

  int get _households => _toInt(_hh.text);
  int get _individuals => _toInt(_ind.text);

  double get _siteArea {
    final o = _toDouble(_areaOv.text);
    return o > 0 ? o : _areaSum;
  }

  double? get _perPerson =>
      (_individuals > 0 && _siteArea > 0) ? _siteArea / _individuals : null;

  double? get _avgHousehold => (_households > 0 && _individuals > 0)
      ? _individuals / _households
      : null;

  double? get _density => (_individuals > 0 && _siteArea > 0)
      ? _individuals / (_siteArea / 1000)
      : null;

  String _f(double? v, [int d = 1]) => v == null ? '—' : v.toStringAsFixed(d);

  Future<void> _save({bool quiet = false}) async {
    try {
      await AppDatabase.instance.saveSiteProfile(SiteProfile(
        projectId: widget.projectId,
        code: _code.text.trim(),
        district: _district.text.trim(),
        manager: _manager.text.trim(),
        phone: _latin(_phone.text).trim(),
        households: _households,
        individuals: _individuals,
        areaOverride: _toDouble(_areaOv.text),
        notes: _notes.text.trim(),
        updatedAt: DateTime.now(),
      ));
      if (mounted) {
        setState(() {
          _dirty = false;
          _updated = DateTime.now();
        });
      }
      if (!quiet) _snack('تم حفظ بطاقة الموقع');
    } catch (e) {
      _snack('تعذر الحفظ: $e');
    }
  }

  String _summary() {
    final b = StringBuffer();
    final code = _code.text.trim();
    b.writeln(
        'موقع: ${widget.projectName}${code.isEmpty ? '' : ' ($code)'}');
    if (_district.text.trim().isNotEmpty) {
      b.writeln('المنطقة: ${_district.text.trim()}');
    }
    if (_manager.text.trim().isNotEmpty || _phone.text.trim().isNotEmpty) {
      b.writeln(
          'المسؤول: ${_manager.text.trim()} ${_latin(_phone.text).trim()}'
              .trim());
    }
    b.writeln('الأسر: $_households  |  الأفراد: $_individuals');
    if (_avgHousehold != null) {
      b.writeln('متوسط حجم الأسرة: ${_f(_avgHousehold)}');
    }
    if (_siteArea > 0) {
      b.writeln(
          'المساحة: ${_siteArea.toStringAsFixed(0)} م² (${(_siteArea / 1000).toStringAsFixed(2)} دونم)');
    }
    if (_perPerson != null) {
      b.writeln('المساحة لكل فرد: ${_f(_perPerson)} م²');
    }
    if (_density != null) {
      b.writeln('الكثافة: ${_f(_density, 0)} فرد/دونم');
    }
    b.writeln('نقاط محفوظة: $_pointCount  |  حدود: $_areaCount');
    if (_notes.text.trim().isNotEmpty) b.writeln('ملاحظات: ${_notes.text.trim()}');
    final dt = _updated ?? DateTime.now();
    b.writeln('آخر تحديث: ${DateFormat('yyyy/MM/dd').format(dt)}');
    return b.toString().trim();
  }

  Future<void> _call() async {
    final n = _latin(_phone.text).replaceAll(RegExp(r'[^0-9+]'), '');
    if (n.isEmpty) return;
    try {
      await launchUrl(Uri(scheme: 'tel', path: n));
    } catch (_) {
      _snack('تعذر فتح الاتصال');
    }
  }

  Widget _field(String label, TextEditingController c, IconData icon,
      {TextInputType? type, int maxLines = 1, Widget? suffix, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: type,
        minLines: 1,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: GoogleFonts.cairo(),
          hintStyle: GoogleFonts.cairo(fontSize: 12),
          prefixIcon: Icon(icon, color: AppColors.navyLight),
          suffixIcon: suffix,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none),
        ),
      ),
    );
  }

  Widget _metric(String label, String value, {String? unit}) => Container(
    width: (MediaQuery.of(context).size.width - 40 - 24 - 10) / 2,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.cairo(
                fontSize: 11, color: AppColors.goldLight)),
        const SizedBox(height: 2),
        Text(unit == null ? value : '$value $unit',
            style: GoogleFonts.cairo(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ],
    ),
  );

  Future<void> _askLeave() async {
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تعديلات غير محفوظة', style: GoogleFonts.cairo()),
          content: Text('هل تريد حفظ التعديلات قبل الخروج؟',
              style: GoogleFonts.cairo()),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('بقاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'discard'),
                child: Text('تجاهل',
                    style: GoogleFonts.cairo(color: Colors.red))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'save'),
                child: Text('حفظ',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700))),
          ],
        ),
      ),
    );
    if (r == 'save') await _save(quiet: true);
    if ((r == 'save' || r == 'discard') && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final area = _siteArea;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _askLeave();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
            title: Text('بطاقة الموقع',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
            actions: [
              IconButton(
                tooltip: 'نسخ الملخص',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _summary()));
                  _snack('تم نسخ ملخص الموقع');
                },
              ),
            ],
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: AppColors.navy,
                    borderRadius: BorderRadius.circular(20)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.holiday_village_rounded,
                            color: AppColors.gold),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(widget.projectName,
                              style: GoogleFonts.cairo(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                        ),
                        if (_code.text.trim().isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 2),
                            decoration: BoxDecoration(
                                color: AppColors.gold,
                                borderRadius:
                                BorderRadius.circular(12)),
                            child: Text(_code.text.trim(),
                                style: GoogleFonts.cairo(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                    color: AppColors.navyDark)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _metric(
                            'المساحة',
                            area > 0
                                ? (area / 1000).toStringAsFixed(2)
                                : '—',
                            unit: area > 0 ? 'دونم' : null),
                        _metric('الأفراد',
                            _individuals == 0 ? '—' : '$_individuals'),
                        _metric('المساحة لكل فرد', _f(_perPerson),
                            unit: _perPerson == null ? null : 'م²'),
                        _metric('متوسط الأسرة', _f(_avgHousehold),
                            unit: _avgHousehold == null ? null : 'فرد'),
                        _metric('الكثافة', _f(_density, 0),
                            unit: _density == null ? null : 'فرد/دونم'),
                        _metric('النقاط / الحدود',
                            '$_pointCount / $_areaCount'),
                      ],
                    ),
                    if (_updated != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                            'آخر تحديث: ${DateFormat('yyyy/MM/dd HH:mm').format(_updated!)}',
                            style: GoogleFonts.cairo(
                                fontSize: 11,
                                color: AppColors.goldLight)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _field('كود الموقع', _code, Icons.qr_code_rounded,
                  hint: 'مثال: GZA5317'),
              _field('الحي / المنطقة', _district,
                  Icons.location_city_rounded),
              _field('مسؤول الموقع', _manager, Icons.person_rounded),
              _field('هاتف المسؤول', _phone, Icons.phone_rounded,
                  type: TextInputType.phone,
                  suffix: IconButton(
                      icon: const Icon(Icons.call_rounded),
                      onPressed: _call)),
              Row(
                children: [
                  Expanded(
                      child: _field('عدد الأسر', _hh,
                          Icons.family_restroom_rounded,
                          type: TextInputType.number)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _field(
                          'عدد الأفراد', _ind, Icons.groups_rounded,
                          type: TextInputType.number)),
                ],
              ),
              _field('مساحة يدوية (م²) - اختياري', _areaOv,
                  Icons.square_foot_rounded,
                  type: const TextInputType.numberWithOptions(
                      decimal: true),
                  hint: _areaCount == 0
                      ? 'لا توجد حدود مرسومة'
                      : 'فاضي = مجموع $_areaCount حدود (${_areaSum.toStringAsFixed(0)} م²)'),
              _field('ملاحظات', _notes, Icons.notes_rounded,
                  maxLines: 5),
              const SizedBox(height: 6),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.navyDark,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () => _save(),
                  icon: const Icon(Icons.save_rounded),
                  label: Text('حفظ البطاقة',
                      style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}