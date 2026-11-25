import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../../core/app_config.dart';
import '../../core/app_settings.dart';

class RemoteAudio {
  final String name;
  final String uri;
  final String mime;
  RemoteAudio(this.name, this.uri, this.mime);
}

class AudioAiException implements Exception {
  final String message;
  final bool retryable;
  final bool thinkingRejected;
  final bool mimeRejected;
  final bool nextModel;
  AudioAiException(this.message,
      {this.retryable = false,
        this.thinkingRejected = false,
        this.mimeRejected = false,
        this.nextModel = false});
  @override
  String toString() => message;
}

/// عميل صوت لـ Gemini: رفع بتقدّم، ثم توليد مبثوث بمهلة أول رد وسلسلة نماذج
class AudioAi {
  bool cancelled = false;
  http.Client? _c;
  HttpClient? _hc;

  http.Client get _cl => _c ??= http.Client();

  String get _base => AppSettings.useProxy
      ? AppConfig.proxyUrl.trim().replaceAll(RegExp(r'/+$'), '')
      : 'https://generativelanguage.googleapis.com';

  Map<String, String> get _auth => AppSettings.useProxy
      ? {'x-app-token': AppConfig.appToken}
      : {'x-goog-api-key': AppSettings.effectiveGemini};

  String get host {
    try {
      return Uri.parse(_base).host;
    } catch (_) {
      return 'generativelanguage.googleapis.com';
    }
  }

  /// سلسلة النماذج: الأسرع أولاً، إلا لو حددت موديلاً بالإعدادات فيكون هو الأول
  List<String> get _chain {
    final out = <String>[];
    void add(String m) {
      final t = m.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    if (AppSettings.geminiModel.trim().isNotEmpty) {
      add(AppSettings.geminiModel);
      add('gemini-flash-lite-latest');
      add(AppSettings.defaultModel);
    } else {
      add('gemini-flash-lite-latest');
      add(AppSettings.defaultModel);
      add('gemini-flash-latest');
    }
    return out;
  }

  void cancel() {
    cancelled = true;
    try {
      _c?.close();
    } catch (_) {}
    try {
      _hc?.close(force: true);
    } catch (_) {}
  }

  void dispose() {
    try {
      _c?.close();
    } catch (_) {}
    _c = null;
    try {
      _hc?.close(force: true);
    } catch (_) {}
    _hc = null;
  }

  void _check() {
    if (cancelled) throw AudioAiException('أُلغيت العملية');
  }

  String _short(Object? e) {
    final s = (e ?? '').toString();
    return s.length > 140 ? s.substring(0, 140) : s;
  }

  Duration _wait(int attempt) =>
      Duration(seconds: attempt == 1 ? 4 : (attempt == 2 ? 12 : 30));

  AudioAiException _err(int code, String body) {
    var hint = '';
    if (code == 401) {
      hint = AppSettings.useProxy
          ? ' (الكلمة السرية بالتطبيق غير مطابقة للخادم)'
          : ' (مفتاح غير صالح)';
    } else if (code == 403) {
      hint = ' (المفتاح مرفوض)';
    } else if (code == 404) {
      hint = ' (الموديل غير متاح)';
    } else if (code == 429) {
      hint = ' (تجاوز حد الاستخدام، حاول بعد قليل)';
    } else if (code == 524) {
      hint = ' (انتهت مهلة الخادم الوسيط)';
    } else if (code == 599) {
      hint = ' (انقطع الاتصال بين الخادم الوسيط وGoogle)';
    } else if (code == 500 || code == 502 || code == 503 || code == 504) {
      hint = ' (الخدمة مشغولة، حاول بعد قليل)';
    }
    final low = body.toLowerCase();
    return AudioAiException(
      'خطأ $code$hint\n${body.length > 200 ? body.substring(0, 200) : body}',
      retryable: code == 429 ||
          code == 500 ||
          code == 502 ||
          code == 503 ||
          code == 504 ||
          code == 524 ||
          code == 599,
      nextModel: code == 404,
      thinkingRejected: code == 400 && low.contains('thinking'),
      mimeRejected:
      code == 400 && (low.contains('mime') || low.contains('unsupported')),
    );
  }

  // ---------------- الرفع ----------------
  Future<RemoteAudio> upload(
      File f, String mime, void Function(double) onProgress) async {
    final len = await f.length();
    if (len < 2000) throw AudioAiException('ملف الصوت فارغ أو تالف');
    Object? last;
    for (var attempt = 1; attempt <= 3; attempt++) {
      _check();
      try {
        return await _uploadOnce(f, len, mime, onProgress);
      } on AudioAiException catch (e) {
        if (cancelled || !e.retryable || attempt == 3) rethrow;
        last = e;
      } on IOException catch (e) {
        last = e;
      } on TimeoutException catch (e) {
        last = e;
      } on http.ClientException catch (e) {
        last = e;
      }
      if (cancelled) throw AudioAiException('أُلغيت العملية');
      onProgress(0);
      await Future.delayed(Duration(seconds: 3 * attempt));
    }
    throw AudioAiException(
        'فشل رفع الصوت (الاتصال ضعيف أو متقطع): ${_short(last)}');
  }

  Future<RemoteAudio> _uploadOnce(
      File f, int len, String mime, void Function(double) onProgress) async {
    final start = await _cl
        .post(
      Uri.parse('$_base/upload/v1beta/files'),
      headers: {
        ..._auth,
        'X-Goog-Upload-Protocol': 'resumable',
        'X-Goog-Upload-Command': 'start',
        'X-Goog-Upload-Header-Content-Length': '$len',
        'X-Goog-Upload-Header-Content-Type': mime,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'file': {'display_name': 'fieldpro_session'}
      }),
    )
        .timeout(const Duration(seconds: 60));
    if (start.statusCode != 200) throw _err(start.statusCode, start.body);
    final upUrl = start.headers['x-goog-upload-url'];
    if (upUrl == null || upUrl.isEmpty) {
      throw AudioAiException('تعذر الحصول على رابط الرفع من الخادم',
          retryable: true);
    }

    final hc = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    _hc = hc;
    String body;
    int status;
    try {
      final req = await hc.postUrl(Uri.parse(upUrl));
      for (final e in _auth.entries) {
        req.headers.set(e.key, e.value);
      }
      req.headers.set('X-Goog-Upload-Offset', '0');
      req.headers.set('X-Goog-Upload-Command', 'upload, finalize');
      req.contentLength = len;
      var sent = 0;
      await for (final chunk in f.openRead()) {
        _check();
        req.add(chunk);
        sent += chunk.length;
        await req.flush().timeout(const Duration(seconds: 90));
        onProgress(sent / len);
      }
      final res = await req.close().timeout(const Duration(minutes: 3));
      status = res.statusCode;
      body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(minutes: 2));
    } finally {
      try {
        hc.close(force: true);
      } catch (_) {}
      _hc = null;
    }
    if (status != 200) throw _err(status, body);

    final info = (jsonDecode(body)['file'] ?? {}) as Map;
    final name = (info['name'] ?? '').toString();
    final uri = (info['uri'] ?? '').toString();
    var state = (info['state'] ?? '').toString();
    if (name.isEmpty || uri.isEmpty) {
      throw AudioAiException('رد غير متوقع بعد رفع الملف', retryable: true);
    }

    var tries = 0;
    while (state != 'ACTIVE') {
      _check();
      if (state == 'FAILED') {
        throw AudioAiException('فشل الخادم بتجهيز الصوت');
      }
      if (++tries > 100) throw AudioAiException('انتهت مهلة تجهيز الصوت');
      await Future.delayed(const Duration(seconds: 3));
      final st = await _cl
          .get(Uri.parse('$_base/v1beta/$name'), headers: _auth)
          .timeout(const Duration(seconds: 30));
      if (st.statusCode != 200) throw _err(st.statusCode, st.body);
      state = (jsonDecode(st.body)['state'] ?? '').toString();
    }
    return RemoteAudio(name, uri, mime);
  }

  Future<void> delete(RemoteAudio a) async {
    try {
      await http
          .delete(Uri.parse('$_base/v1beta/${a.name}'), headers: _auth)
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  // ---------------- التوليد ----------------
  Map<String, dynamic>? _thinkingConfig(String model, String level) {
    final m = model.toLowerCase();
    final pro = m.contains('pro');
    if (m.contains('gemini-3')) {
      return {'thinkingLevel': (pro && level == 'minimal') ? 'low' : level};
    }
    if (m.contains('gemini-2.5')) {
      return {
        'thinkingBudget':
        level == 'minimal' ? (pro ? 128 : 0) : (pro ? 512 : 1024)
      };
    }
    return null;
  }

  Future<String> _generate(List<Map<String, dynamic>> parts,
      {required String thinking,
        required int audioSec,
        void Function(int)? onChars,
        void Function(String)? onStatus}) async {
    final deadline = Duration(seconds: math.min(480, 75 + audioSec ~/ 20));
    final chain = _chain;
    AudioAiException? lastErr;
    Object? lastOther;

    for (var mi = 0; mi < chain.length; mi++) {
      final m = chain[mi];
      var useThinking = true;
      var attempt = 0;
      while (attempt < 2) {
        _check();
        try {
          return await _streamOnce(
              m, parts, thinking, useThinking, deadline, onChars);
        } on AudioAiException catch (e) {
          if (cancelled) rethrow;
          if (e.thinkingRejected && useThinking) {
            useThinking = false;
            continue;
          }
          if (e.nextModel) {
            lastErr = e;
            break;
          }
          if (!e.retryable) rethrow;
          lastErr = e;
        } on IOException catch (e) {
          lastOther = e;
        } on TimeoutException catch (e) {
          lastOther = e;
        } on http.ClientException catch (e) {
          lastOther = e;
        }
        if (cancelled) throw AudioAiException('أُلغيت العملية');
        attempt++;
        if (attempt < 2) {
          onStatus?.call('الخدمة مشغولة، إعادة المحاولة...');
          await Future.delayed(_wait(attempt));
        }
      }
      if (mi + 1 < chain.length) {
        onStatus?.call('جاري تجربة نموذج بديل أسرع...');
      }
    }
    throw AudioAiException(
        'فشلت المعالجة بكل النماذج المتاحة.\n${lastErr?.message ?? _short(lastOther)}');
  }

  Future<String> _streamOnce(
      String m,
      List<Map<String, dynamic>> parts,
      String thinking,
      bool useThinking,
      Duration deadline,
      void Function(int)? onChars) async {
    final gen = <String, dynamic>{'temperature': 0.2};
    if (useThinking) {
      final t = _thinkingConfig(m, thinking);
      if (t != null) gen['thinkingConfig'] = t;
    }
    final req = http.Request('POST',
        Uri.parse('$_base/v1beta/models/$m:streamGenerateContent?alt=sse'));
    req.headers.addAll({..._auth, 'Content-Type': 'application/json'});
    req.body = jsonEncode({
      'contents': [
        {'parts': parts}
      ],
      'generationConfig': gen,
    });

    final sw = Stopwatch()..start();
    final res = await _cl.send(req).timeout(deadline, onTimeout: () {
      throw AudioAiException('تأخر النموذج بالرد', nextModel: true);
    });
    if (res.statusCode != 200) {
      final b = await res.stream
          .bytesToString()
          .timeout(const Duration(seconds: 30));
      throw _err(res.statusCode, b);
    }

    final sb = StringBuffer();
    String? finish;
    var gotData = false;
    final lines = res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final it = StreamIterator<String>(lines);
    try {
      while (true) {
        _check();
        final Duration remaining =
        gotData ? const Duration(seconds: 150) : deadline - sw.elapsed;
        if (remaining <= Duration.zero) {
          throw AudioAiException('تأخر النموذج بالرد', nextModel: true);
        }
        final bool has = await it.moveNext().timeout(remaining, onTimeout: () {
          throw AudioAiException(
              gotData ? 'انقطع بث الرد' : 'تأخر النموذج بالرد',
              retryable: gotData,
              nextModel: !gotData);
        });
        if (!has) break;
        final line = it.current;
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') continue;
        Map<String, dynamic> j;
        try {
          j = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        gotData = true;
        if (j['error'] != null) {
          final er = j['error'];
          final code = er is Map ? ((er['code'] as num?)?.toInt() ?? 0) : 0;
          final msg =
          er is Map ? (er['message'] ?? '').toString() : er.toString();
          throw _err(code == 0 ? 599 : code, msg);
        }
        final cands = (j['candidates'] as List?) ?? const [];
        if (cands.isEmpty) {
          if (j['promptFeedback'] != null && sb.isEmpty) {
            throw AudioAiException(
                'رفض النموذج المحتوى: ${j['promptFeedback']}');
          }
          continue;
        }
        final c = cands.first as Map;
        final cp = (c['content']?['parts'] as List?) ?? const [];
        for (final p in cp) {
          if (p is Map && p['thought'] != true && p['text'] != null) {
            sb.write(p['text']);
          }
        }
        if (c['finishReason'] != null) finish = c['finishReason'].toString();
        onChars?.call(sb.length);
      }
    } finally {
      await it.cancel();
    }
    final text = sb.toString();
    if (text.trim().isEmpty) {
      throw AudioAiException('الرد فارغ (${finish ?? 'بدون سبب'})',
          retryable: true);
    }
    return text;
  }

  // ---------------- المحضر ----------------
  static const _minutesPrompt = '''
أنت كاتب محاضر محترف لجلسات تنسيقية ميدانية. استمع للتسجيل كاملاً (قد يكون بلهجة عامية وبه ضجيج) ثم اكتب محضراً دقيقاً وعملياً.

قواعد صارمة:
- اعتمد فقط على ما قيل فعلاً. لا تخترع أسماء أو أرقاماً أو قرارات أو مواعيد.
- اكتب بالعربية الفصحى المبسطة الرسمية، والأسماء والأرقام كما نُطقت.
- أي جزء غير واضح اكتبه [غير واضح] ولا تخمّن.
- لا تستخدم رموز Markdown (لا ** ولا #).
- كن موجزاً: الملخص حتى 3 فقرات قصيرة، وكل نقطة بسطر واحد.
- التزم بالتنسيق التالي حرفياً. كل علامة على سطر مستقل وبنفس الترتيب:

[[TITLE]]
عنوان قصير للجلسة (سطر واحد)
[[ATTENDEES]]
اسم أو صفة كل مشارك ذُكر في التسجيل، سطر لكل واحد يبدأ بـ "- ". اكتب "لا يوجد" إن لم يُذكر أحد.
[[SUMMARY]]
ملخص تنفيذي من فقرة إلى ثلاث فقرات.
[[POINTS]]
أبرز النقاط والموضوعات التي نوقشت، سطر لكل نقطة يبدأ بـ "- ".
[[DECISIONS]]
القرارات والاتفاقات، سطر لكل قرار يبدأ بـ "- ". إن لم توجد اكتب "- لم تُذكر قرارات صريحة".
[[TASKS]]
المهام والتوصيات، سطر لكل مهمة بصيغة: المسؤول | المهمة | الموعد . استخدم "غير محدد" إن لم يُذكر المسؤول أو الموعد. اكتب "لا يوجد" إن لم توجد مهام.
''';

  Future<String> minutes(RemoteAudio a,
      {String context = '',
        int audioSec = 0,
        void Function(int)? onChars,
        void Function(String)? onStatus}) async {
    final prompt = context.trim().isEmpty
        ? _minutesPrompt
        : '$_minutesPrompt\nسياق الجلسة (للمساعدة بكتابة الأسماء صح فقط):\n$context';
    List<Map<String, dynamic>> parts(String mime) => [
      {
        'file_data': {'mime_type': mime, 'file_uri': a.uri}
      },
      {'text': prompt},
    ];
    try {
      return await _generate(parts(a.mime),
          thinking: 'low',
          audioSec: audioSec,
          onChars: onChars,
          onStatus: onStatus);
    } on AudioAiException catch (e) {
      if (!e.mimeRejected) rethrow;
      return await _generate(parts('audio/aac'),
          thinking: 'low',
          audioSec: audioSec,
          onChars: onChars,
          onStatus: onStatus);
    }
  }

  // ---------------- التفريغ الكامل (جزء) ----------------
  String _mmss(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  Future<String> transcribeSegment(RemoteAudio a, int fromSec, int? toSec,
      {int audioSec = 0,
        void Function(int)? onChars,
        void Function(String)? onStatus}) async {
    final range = toSec == null
        ? 'من الدقيقة ${_mmss(fromSec)} حتى نهاية التسجيل'
        : 'من الدقيقة ${_mmss(fromSec)} إلى الدقيقة ${_mmss(toSec)} فقط';
    final prompt = '''
فرّغ الكلام المسموع في التسجيل $range.

القواعد:
- نسخ حرفي لما قيل، فقرة لكل متحدث مع وسم المتحدث (المتحدث 1، المتحدث 2...) إن أمكن التمييز.
- صحّح الإملاء دون تغيير المعنى.
- المقاطع غير المسموعة اكتب مكانها [غير واضح].
- لا تلخّص ولا تضف مقدمة أو شرحاً، ولا تستخدم رموز Markdown.
- ابدأ مباشرة بالنص.
''';
    List<Map<String, dynamic>> parts(String mime) => [
      {
        'file_data': {'mime_type': mime, 'file_uri': a.uri}
      },
      {'text': prompt},
    ];
    String t;
    try {
      t = await _generate(parts(a.mime),
          thinking: 'minimal',
          audioSec: audioSec,
          onChars: onChars,
          onStatus: onStatus);
    } on AudioAiException catch (e) {
      if (!e.mimeRejected) rethrow;
      t = await _generate(parts('audio/aac'),
          thinking: 'minimal',
          audioSec: audioSec,
          onChars: onChars,
          onStatus: onStatus);
    }
    return t.replaceAll('**', '').replaceAll('##', '').trim();
  }
}