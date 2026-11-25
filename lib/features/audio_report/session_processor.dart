import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/app_settings.dart';
import '../../core/database.dart';
import 'audio_ai.dart';
import 'session_result.dart';

/// مدير معالجة الصوت: يعيش خارج الشاشة، فالطلوع من الصفحة لا يوقف العملية
class SessionProcessor extends ChangeNotifier {
  SessionProcessor._();
  static final SessionProcessor instance = SessionProcessor._();

  int? runningId;
  String title = '';
  String phase = '';
  double uploadFraction = -1;
  int outChars = 0;
  int segDone = 0;
  int segTotal = 0;
  bool inTranscript = false;
  int queueIndex = 0;
  int queueTotal = 0;
  bool cancelling = false;
  String? message;
  bool messageIsError = false;

  final Stopwatch _sw = Stopwatch();
  Timer? _tick;
  AudioAi? _ai;

  bool get busy => runningId != null;
  Duration get elapsed => _sw.elapsed;

  static const _segSec = 600;

  void clearMessage() {
    message = null;
    notifyListeners();
  }

  void _phase(String p) {
    phase = p;
    notifyListeners();
  }

  void cancel() {
    if (!busy) return;
    cancelling = true;
    phase = 'جاري الإيقاف...';
    _ai?.cancel();
    notifyListeners();
  }

  /// overwrite=false: يعبّي الحقول الفاضية فقط ولا يمسّ ما كتبه المستخدم
  Future<bool> process(Recording r,
      {required bool fullTranscript, bool overwrite = false}) {
    queueIndex = 0;
    queueTotal = 0;
    return _run(r,
        minutes: true, transcript: fullTranscript, overwrite: overwrite);
  }

  Future<bool> transcribeOnly(Recording r) {
    queueIndex = 0;
    queueTotal = 0;
    return _run(r, minutes: false, transcript: true, overwrite: false);
  }

  Future<void> processAll(List<Recording> list,
      {required bool fullTranscript}) async {
    if (busy || list.isEmpty) return;
    queueTotal = list.length;
    for (var i = 0; i < list.length; i++) {
      queueIndex = i + 1;
      final ok = await _run(list[i],
          minutes: true, transcript: fullTranscript, overwrite: false);
      if (!ok) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    queueIndex = 0;
    queueTotal = 0;
    notifyListeners();
  }

  Future<void> _checkNet(AudioAi ai) async {
    const msg =
        'لا يوجد اتصال بالإنترنت. التسجيل محفوظ ويمكنك المعالجة لاحقاً';
    try {
      final r = await InternetAddress.lookup(ai.host)
          .timeout(const Duration(seconds: 6));
      if (r.isEmpty) throw AudioAiException(msg);
    } on SocketException {
      throw AudioAiException(msg);
    } on TimeoutException {
      throw AudioAiException(msg);
    }
  }

  Future<SessionResult?> _existing(int id) async {
    final list = await AppDatabase.instance.getRecordings();
    final cur = list.where((x) => x.id == id);
    if (cur.isEmpty) return null;
    final j = cur.first.resultJson.trim();
    if (j.isEmpty) return null;
    try {
      return SessionResult.fromJson(jsonDecode(j) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _run(Recording r,
      {required bool minutes,
        required bool transcript,
        required bool overwrite}) async {
    if (busy) return false;
    runningId = r.id;
    title = r.title;
    cancelling = false;
    message = null;
    outChars = 0;
    segDone = 0;
    segTotal = 0;
    uploadFraction = -1;
    inTranscript = false;
    phase = 'جاري التحقق...';
    _sw
      ..reset()
      ..start();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();

    final ai = AudioAi();
    _ai = ai;
    RemoteAudio? remote;
    final db = AppDatabase.instance;
    var minutesSaved = !minutes;
    var ok = false;
    final prevStatus = r.status;

    try {
      if (!AppSettings.aiReady) {
        throw AudioAiException('خدمة الذكاء الاصطناعي غير مفعّلة بعد');
      }
      await _checkNet(ai);
      if (r.path.isEmpty) {
        throw AudioAiException('هذا المحضر بدون تسجيل صوتي');
      }
      final file = File(r.path);
      if (!await file.exists()) {
        throw AudioAiException('ملف الصوت غير موجود على الجهاز');
      }
      if (minutes && prevStatus != 'manual') {
        await db.updateRecording(r.id, status: 'processing', error: '');
      }

      _phase('جاري رفع الصوت...');
      remote = await ai.upload(file, 'audio/mp4', (f) {
        uploadFraction = f;
        notifyListeners();
      });
      uploadFraction = -1;

      if (minutes) {
        _phase('جاري كتابة المحضر...');
        final text = await ai.minutes(remote,
            audioSec: r.durationSec,
            onStatus: _phase,
            onChars: (n) {
              outChars = n;
              notifyListeners();
            });
        final res = SessionResult.fromMarked(text);
        if (res.isEmpty) throw AudioAiException('لم يُستخرج محتوى من التسجيل');
        if (res.title.isEmpty) res.title = r.title;
        res.date ??= r.createdAt;
        var out = res;
        if (!overwrite) {
          final prev = await _existing(r.id);
          if (prev != null && !prev.isEmpty) {
            prev.fillEmptyFrom(res);
            out = prev;
          }
        }
        await db.updateRecording(r.id,
            status: 'done', resultJson: jsonEncode(out.toJson()), error: '');
        await db.setSetting('tr_upto_${r.id}', '0');
        await db.setSetting('tr_done_${r.id}', '0');
        minutesSaved = true;
      }

      if (transcript) {
        inTranscript = true;
        await _transcribe(ai, remote, r);
      }
      ok = true;
      message = transcript
          ? 'اكتمل المحضر والتفريغ الكامل'
          : 'المحضر جاهز. افتحه للمراجعة والتصدير';
      messageIsError = false;
    } on AudioAiException catch (e) {
      await _fail(r, e.message, minutesSaved, minutes, prevStatus);
    } catch (e) {
      await _fail(r, e.toString(), minutesSaved, minutes, prevStatus);
    } finally {
      if (remote != null) await ai.delete(remote);
      ai.dispose();
      _ai = null;
      _tick?.cancel();
      _sw.stop();
      runningId = null;
      uploadFraction = -1;
      inTranscript = false;
      notifyListeners();
    }
    return ok;
  }

  Future<void> _fail(Recording r, String msg, bool minutesSaved,
      bool minutesRequested, String prevStatus) async {
    final db = AppDatabase.instance;
    final wasCancel = cancelling || msg.contains('أُلغيت');
    if (minutesRequested && !minutesSaved && prevStatus != 'manual') {
      await db.updateRecording(r.id,
          status: wasCancel ? 'pending' : 'failed',
          error: wasCancel ? '' : msg);
    }
    if (wasCancel) {
      message = 'تم إيقاف العملية. اللي خلص انحفظ، وتقدر تكمل لاحقاً';
      messageIsError = false;
    } else if (inTranscript && minutesSaved) {
      message =
      'المحضر جاهز، لكن التفريغ الكامل توقف:\n$msg\nالأجزاء اللي خلصت انحفظت، اضغط "إكمال التفريغ" لاحقاً';
      messageIsError = true;
    } else {
      message = msg;
      messageIsError = true;
    }
  }

  Future<void> _saveTranscript(int id, String text) async {
    final db = AppDatabase.instance;
    final list = await db.getRecordings();
    final cur = list.where((x) => x.id == id);
    if (cur.isEmpty) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(cur.first.resultJson) as Map<String, dynamic>;
    } catch (_) {
      m = SessionResult().toJson();
    }
    m['transcript'] = text;
    await db.updateRecording(id, resultJson: jsonEncode(m));
  }

  Future<void> _transcribe(AudioAi ai, RemoteAudio remote, Recording r) async {
    final db = AppDatabase.instance;
    final dur = r.durationSec;
    final total = dur <= 0 ? 1 : ((dur + _segSec - 1) ~/ _segSec);
    segTotal = total;

    var from = 0;
    var text = '';
    final done = await db.getSetting('tr_done_${r.id}');
    final up = int.tryParse(await db.getSetting('tr_upto_${r.id}') ?? '0') ?? 0;
    if (done != '1' && up > 0) {
      from = up;
      final list = await db.getRecordings();
      final cur = list.where((x) => x.id == r.id);
      if (cur.isNotEmpty) {
        try {
          final m = jsonDecode(cur.first.resultJson) as Map<String, dynamic>;
          text = (m['transcript'] ?? '').toString();
        } catch (_) {}
      }
      if (text.trim().isEmpty) from = 0;
    }

    await db.setSetting('tr_done_${r.id}', '0');
    final buf = StringBuffer(text);
    var t = from;
    var index = from ~/ _segSec;
    while (true) {
      if (cancelling) throw AudioAiException('أُلغيت العملية');
      final end = t + _segSec;
      final last = dur <= 0 || end >= dur;
      segDone = index;
      outChars = 0;
      _phase('جاري التفريغ الكامل: جزء ${index + 1} من $total');
      final part = await ai.transcribeSegment(remote, t, last ? null : end,
          audioSec: dur,
          onStatus: _phase,
          onChars: (n) {
            outChars = n;
            notifyListeners();
          });
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(part);
      await _saveTranscript(r.id, buf.toString());
      t = end;
      index++;
      await db.setSetting('tr_upto_${r.id}', last ? '0' : '$t');
      if (last) break;
    }
    await db.setSetting('tr_done_${r.id}', '1');
    segDone = total;
  }
}