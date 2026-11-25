import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../core/app_config.dart';
import '../../core/app_settings.dart';

class NeedCategory {
  final String name;
  final int count;
  final List<String> examples;
  NeedCategory(this.name, this.count, this.examples);
}

class GeminiService {
  static String get model => AppSettings.effectiveModel;

  /// عبر الخادم الوسيط إن لم يوجد مفتاح شخصي، وإلا مباشرة لـ Google
  static String get _base => AppSettings.useProxy
      ? AppConfig.proxyUrl.replaceAll(RegExp(r'/+$'), '')
      : 'https://generativelanguage.googleapis.com';

  static Uri get _url =>
      Uri.parse('$_base/v1beta/models/$model:generateContent');

  static Map<String, String> get _auth => AppSettings.useProxy
      ? {'x-app-token': AppConfig.appToken}
      : {'x-goog-api-key': AppSettings.effectiveGemini};

  static Map<String, String> get _headers =>
      {'Content-Type': 'application/json', ..._auth};

  static Exception _fail(http.Response res) {
    final code = res.statusCode;
    var hint = '';
    if (code == 401 && AppSettings.useProxy) {
      hint = ' (الخدمة غير مفعّلة، راجع مسؤول التطبيق)';
    } else if (code == 404) {
      hint = ' (الموديل غير متاح)';
    } else if (code == 429) {
      hint = ' (تجاوز حد الاستخدام، حاول بعد قليل)';
    } else if (code == 400 || code == 403) {
      hint = ' (مشكلة بالمفتاح أو الطلب)';
    }
    final body = res.body.length > 300 ? res.body.substring(0, 300) : res.body;
    return Exception('خطأ بالذكاء الاصطناعي $code$hint\n$body');
  }

  static void _needKey() {
    if (!AppSettings.aiReady) {
      throw Exception('خدمة الذكاء الاصطناعي غير مفعّلة بعد');
    }
  }

  static String _textOf(Map<String, dynamic> data) {
    final c = (data['candidates'] as List?) ?? [];
    if (c.isEmpty) {
      throw Exception(
          'لم يرجع الذكاء الاصطناعي نتيجة (${data['promptFeedback'] ?? 'محتوى محظور أو صوت غير مفهوم'})');
    }
    final parts = (c[0]['content']?['parts'] as List?) ?? [];
    final sb = StringBuffer();
    for (final p in parts) {
      if (p is Map && p['thought'] != true && p['text'] != null) {
        sb.write(p['text']);
      }
    }
    return sb.toString();
  }

  /// اختبار سريع للاتصال والموديل
  static Future<String> ping() async {
    _needKey();
    final res = await http
        .post(
      _url,
      headers: _headers,
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': 'أجب بكلمة واحدة فقط: جاهز'}
            ]
          }
        ],
      }),
    )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw _fail(res);
    return _textOf(jsonDecode(res.body)).trim();
  }

  static Future<List<NeedCategory>> categorize(List<String> texts) async {
    _needKey();
    final counts = <String, int>{};
    for (final t in texts) {
      final s = t.trim();
      if (s.isEmpty) continue;
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final unique = counts.keys.toList();
    if (unique.isEmpty) throw Exception('العمود المختار فارغ');
    if (unique.length > 300) {
      throw Exception(
          'عدد النصوص الفريدة (${unique.length}) كبير، الحد الحالي 300');
    }

    final numbered = [
      for (var i = 0; i < unique.length; i++) '$i: ${unique[i]}'
    ].join('\n');

    final prompt = '''
أنت محلل بيانات لاستبيان احتياجات سكان. فيما يلي قائمة مرقمة بإجابات نصية.
جمّع الإجابات المتشابهة في المعنى تحت فئات واضحة وقصيرة بالعربية
(مثل: المياه، الكهرباء، الصحة، التعليم، الطرق...).
كل رقم يجب أن يظهر في فئة واحدة فقط. لا تخترع أرقاماً.
أعد JSON فقط بهذا الشكل:
{"categories":[{"name":"اسم الفئة","items":[0,3,5]}]}

الإجابات:
$numbered
''';

    final res = await http
        .post(
      _url,
      headers: _headers,
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'temperature': 0.2,
        },
      }),
    )
        .timeout(const Duration(seconds: 90));

    if (res.statusCode != 200) throw _fail(res);

    final text = _textOf(jsonDecode(res.body));
    final parsed = jsonDecode(text);

    final used = <int>{};
    final result = <NeedCategory>[];
    for (final c in parsed['categories'] as List) {
      var total = 0;
      final examples = <String>[];
      for (final idx in c['items'] as List) {
        final i = idx as int;
        if (i < 0 || i >= unique.length || !used.add(i)) continue;
        total += counts[unique[i]]!;
        if (examples.length < 3) examples.add(unique[i]);
      }
      if (total > 0) {
        result.add(NeedCategory(c['name'] as String, total, examples));
      }
    }

    var rest = 0;
    for (var i = 0; i < unique.length; i++) {
      if (!used.contains(i)) rest += counts[unique[i]]!;
    }
    if (rest > 0) result.add(NeedCategory('أخرى', rest, []));

    result.sort((a, b) => b.count.compareTo(a.count));
    return result;
  }

  static Future<String> writeReport(
      List<NeedCategory> cats, String title) async {
    _needKey();
    final total = cats.fold<int>(0, (s, c) => s + c.count);
    final data = cats
        .map((c) =>
    '- ${c.name}: ${c.count} (${(c.count / total * 100).toStringAsFixed(1)}%)')
        .join('\n');

    final prompt = '''
اكتب تقريراً رسمياً باللغة العربية الفصحى عن نتائج استبيان احتياجات بعنوان "$title".
اعتمد فقط على الأرقام التالية ولا تخترع أي رقم أو معلومة غير موجودة.
البنية المطلوبة: مقدمة، منهجية مختصرة، النتائج الرئيسية (مع النسب)،
تحليل الأولويات، التوصيات، خاتمة.
إجمالي الإجابات: $total

نتائج الفئات:
$data
''';

    final res = await http
        .post(
      _url,
      headers: _headers,
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ],
        'generationConfig': {'temperature': 0.4},
      }),
    )
        .timeout(const Duration(seconds: 120));

    if (res.statusCode != 200) throw _fail(res);
    return _textOf(jsonDecode(res.body));
  }

  /// يقرأ صورة استبيان ويرجع جدولاً: الصف الأول = العناوين
  static Future<List<List<String>>> imageToTable(
      Uint8List bytes, String mime) async {
    _needKey();
    const prompt = '''
هذه صورة لورقة استبيان أو جدول. استخرج كل البيانات كجدول.
- الصف الأول يكون عناوين الأعمدة.
- كل صف في الصورة يصبح صفاً في الجدول.
- انسخ النص كما هو مكتوب بالعربية دون تغيير المعنى.
- حوّل الأرقام العربية-الهندية (٠١٢٣٤٥٦٧٨٩) إلى أرقام إنجليزية (0123456789).
- إن كانت خانة غير مقروءة اتركها فارغة "" ولا تخمّن.
- إن كانت الورقة نموذجاً واحداً (أسئلة وإجابات)، اجعل عمودين: "السؤال" و"الإجابة".
أعد JSON فقط بهذا الشكل:
{"rows":[["عنوان1","عنوان2"],["قيمة","قيمة"]]}
''';

    final res = await http
        .post(
      _url,
      headers: _headers,
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
              {
                'inline_data': {
                  'mime_type': mime,
                  'data': base64Encode(bytes),
                }
              }
            ]
          }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'temperature': 0.1,
        },
      }),
    )
        .timeout(const Duration(seconds: 120));

    if (res.statusCode != 200) throw _fail(res);
    final text = _textOf(jsonDecode(res.body));
    final parsed = jsonDecode(text);
    return (parsed['rows'] as List)
        .map<List<String>>(
            (r) => (r as List).map((c) => c?.toString() ?? '').toList())
        .toList();
  }
}