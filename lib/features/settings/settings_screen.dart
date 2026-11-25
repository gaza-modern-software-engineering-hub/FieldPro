import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/app_colors.dart';
import '../../core/app_settings.dart';
import '../../core/database.dart';
import '../survey/gemini_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _company = TextEditingController(text: AppSettings.company);
  final _model = TextEditingController(text: AppSettings.geminiModel);
  bool _testing = false;
  String _logo = AppSettings.logoPath;

  @override
  void dispose() {
    _company.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 800);
      if (x == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final dest = '${dir.path}/company_logo.png';
      await File(x.path).copy(dest);
      await AppDatabase.instance.setSetting('logo_path', dest);
      await AppSettings.load();
      if (mounted) setState(() => _logo = dest);
    } catch (e) {
      _snack('تعذر حفظ الشعار: $e');
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _save({bool quiet = false}) async {
    final d = AppDatabase.instance;
    await d.setSetting('company', _company.text.trim());
    await d.setSetting('gemini_model', _model.text.trim());
    await AppSettings.load();
    if (!quiet) _snack('تم حفظ الإعدادات');
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      await _save(quiet: true);
      final r = await GeminiService.ping();
      _snack('الاتصال ناجح ✓ (الموديل: ${AppSettings.effectiveModel}) — $r');
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  InputDecoration _dec(String l, IconData i) => InputDecoration(
    labelText: l,
    labelStyle: GoogleFonts.cairo(),
    prefixIcon: Icon(i, color: AppColors.navyLight),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none),
  );

  Widget _title(String t) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Text(t,
        style: GoogleFonts.cairo(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textDark)),
  );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('الإعدادات',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _title('الشركة'),
            TextField(
                controller: _company,
                decoration: _dec(
                    'اسم الشركة (يظهر بالتقارير)', Icons.business_rounded)),
            const SizedBox(height: 10),
            Row(
              children: [
                if (_logo.isNotEmpty && File(_logo).existsSync())
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(File(_logo),
                        width: 64, height: 64, fit: BoxFit.contain),
                  ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _pickLogo,
                  icon: const Icon(Icons.image_rounded),
                  label: Text(
                      _logo.isEmpty ? 'اختر شعار الشركة' : 'تغيير الشعار',
                      style: GoogleFonts.cairo()),
                ),
              ],
            ),
            _title('الذكاء الاصطناعي'),
            Text(
                'يعمل عبر الخادم الوسيط، فلا حاجة لأي مفتاح. اترك الموديل فاضياً للافتراضي.',
                style: GoogleFonts.cairo(
                    fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 8),
            TextField(
                controller: _model,
                decoration: _dec(
                    'اسم الموديل (الافتراضي: ${AppSettings.defaultModel})',
                    Icons.memory_rounded)),
            const SizedBox(height: 10),
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering_rounded),
                label: Text('اختبار اتصال الذكاء الاصطناعي',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 10),
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
                label: Text('حفظ',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              ),
            ),
            _title('عن التطبيق'),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: AppColors.navy,
                  borderRadius: BorderRadius.circular(18)),
              child: Column(
                children: [
                  Text('FieldPro',
                      style: GoogleFonts.poppins(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('Survey • Map • Report',
                      style: GoogleFonts.poppins(
                          fontSize: 12, color: AppColors.goldLight)),
                  const SizedBox(height: 10),
                  Text('Developed by Eng. Saeed Al-Sourani',
                      style: GoogleFonts.poppins(
                          fontSize: 13, color: AppColors.gold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}