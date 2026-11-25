import 'app_config.dart';
import 'database.dart';

class AppSettings {
  static const defaultModel = 'gemini-3.8-flash';
  static const fallbackModel = 'gemini-3.8-flash-lite';

  static String company = '';
  static String geminiModel = '';
  static String logoPath = '';

  static Future<void> load() async {
    final d = AppDatabase.instance;
    company = await d.getSetting('company') ?? '';
    geminiModel = await d.getSetting('gemini_model') ?? '';
    logoPath = await d.getSetting('logo_path') ?? '';

    // تنظيف لمرة واحدة: مفاتيح شخصية قديمة كانت تتجاوز الخادم الوسيط
    for (final k in ['gemini_key', 'maptiler_key']) {
      final v = await d.getSetting(k);
      if (v != null && v.isNotEmpty) await d.setSetting(k, '');
    }
  }

  // لا مفاتيح شخصية بعد الآن: كل شي يمر عبر الخادم الوسيط
  // (الدوال بقيت لتبقى باقي الملفات تعمل دون تعديل)
  static String get geminiKey => '';
  static String get maptilerKey => '';
  static String get effectiveGemini => '';
  static String get effectiveMaptiler => '';

  static String get effectiveModel =>
      geminiModel.isNotEmpty ? geminiModel : defaultModel;

  static bool get useProxy => AppConfig.proxyUrl.isNotEmpty;

  /// هل الذكاء الاصطناعي جاهز للاستخدام؟
  static bool get aiReady => useProxy;
}