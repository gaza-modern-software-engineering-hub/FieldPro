import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../core/app_colors.dart';
import '../../core/database.dart';
import '../../core/export_service.dart';
import 'audio_recorder_service.dart';
import 'session_processor.dart';
import 'session_result.dart';
import 'session_review_screen.dart';

enum _RecState { idle, recording, paused }

class AudioReportScreen extends StatefulWidget {
  const AudioReportScreen({super.key});

  @override
  State<AudioReportScreen> createState() => _AudioReportScreenState();
}

class _AudioReportScreenState extends State<AudioReportScreen> {
  final _rec = AudioRecorderService();
  final _title = TextEditingController();
  final _sw = Stopwatch();
  final _proc = SessionProcessor.instance;
  Timer? _ticker;

  _RecState _state = _RecState.idle;
  List<Recording> _items = [];
  Map<int, String> _trState = {};
  bool _fullTr = false;
  bool _wasBusy = false;

  @override
  void initState() {
    super.initState();
    _wasBusy = _proc.busy;
    _proc.addListener(_onProc);
    _loadPrefs();
    _load();
  }

  @override
  void dispose() {
    _proc.removeListener(_onProc);
    _ticker?.cancel();
    final t = _titleOrDefault();
    if (_state != _RecState.idle) {
      _emergencySave(t, _sw.elapsed.inSeconds);
    } else {
      _rec.dispose();
    }
    _title.dispose();
    super.dispose();
  }

  void _onProc() {
    if (!mounted) return;
    if (_wasBusy && !_proc.busy) _load();
    _wasBusy = _proc.busy;
    setState(() {});
  }

  Future<void> _emergencySave(String t, int secs) async {
    try {
      final p = await _rec.stop();
      if (p != null && secs >= 3) {
        await AppDatabase.instance
            .insertRecording(title: t, path: p, durationSec: secs);
      }
    } catch (_) {}
    await _rec.dispose();
  }

  String _titleOrDefault() => _title.text.trim().isEmpty
      ? 'جلسة ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now())}'
      : _title.text.trim();

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _loadPrefs() async {
    final v = await AppDatabase.instance.getSetting('audio_full_tr');
    if (mounted) setState(() => _fullTr = v == '1');
  }

  bool _hasAudio(Recording r) => r.path.isNotEmpty && File(r.path).existsSync();

  Future<void> _load() async {
    try {
      final db = AppDatabase.instance;
      final l = await db.getRecordings();
      final m = <int, String>{};
      for (final r in l) {
        if (r.status != 'done' && r.status != 'manual') continue;
        final done = await db.getSetting('tr_done_${r.id}');
        final up = await db.getSetting('tr_upto_${r.id}');
        var hasText = false;
        try {
          final j = jsonDecode(r.resultJson) as Map<String, dynamic>;
          hasText = (j['transcript'] ?? '').toString().trim().isNotEmpty;
        } catch (_) {}
        if (done == '1' || (done == null && hasText)) {
          m[r.id] = 'done';
        } else if (up != null && up != '0' && hasText) {
          m[r.id] = 'partial';
        }
      }
      if (mounted) {
        setState(() {
          _items = l;
          _trState = m;
        });
      }
    } catch (e) {
      _snack('تعذر قراءة التسجيلات: $e');
    }
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0
        ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
        : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  // ---------------- التسجيل ----------------
  Future<bool> _ensureConsent() async {
    final ok = await AppDatabase.instance.getSetting('audio_consent');
    if (ok == '1') return true;
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('إقرار قبل التسجيل', style: GoogleFonts.cairo()),
          content: Text(
              'تأكد من موافقة جميع المشاركين على تسجيل الجلسة. إذا استخدمت الذكاء الاصطناعي لاحقاً، يُرسل الصوت إلى خدمة Google Gemini لتفريغه وتلخيصه. هل تؤكد حصولك على الموافقات اللازمة؟',
              style: GoogleFonts.cairo(height: 1.6)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('إلغاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('أؤكد',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700))),
          ],
        ),
      ),
    );
    if (r == true) {
      await AppDatabase.instance.setSetting('audio_consent', '1');
      return true;
    }
    return false;
  }

  Future<void> _start() async {
    if (!await _ensureConsent()) return;
    try {
      await _rec.start();
      _sw
        ..reset()
        ..start();
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() => _state = _RecState.recording);
    } catch (e) {
      _snack('تعذر بدء التسجيل: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _pauseResume() async {
    try {
      if (_state == _RecState.recording) {
        await _rec.pause();
        _sw.stop();
        setState(() => _state = _RecState.paused);
      } else if (_state == _RecState.paused) {
        await _rec.resume();
        _sw.start();
        setState(() => _state = _RecState.recording);
      }
    } catch (e) {
      _snack('تعذر الإيقاف المؤقت: $e');
    }
  }

  Future<void> _stopAndSave() async {
    _ticker?.cancel();
    _sw.stop();
    final secs = _sw.elapsed.inSeconds;
    String? path;
    try {
      path = await _rec.stop();
    } catch (e) {
      _snack('تعذر إنهاء التسجيل: $e');
    }
    if (mounted) setState(() => _state = _RecState.idle);

    if (path == null || secs < 3 || !File(path).existsSync()) {
      try {
        if (path != null) File(path).deleteSync();
      } catch (_) {}
      _snack('التسجيل قصير جداً أو فاشل، لم يُحفظ');
      return;
    }
    try {
      await AppDatabase.instance.insertRecording(
          title: _titleOrDefault(), path: path, durationSec: secs);
      _title.clear();
      await _load();
      _snack('تم حفظ التسجيل على الجهاز');
    } catch (e) {
      _snack('تعذر حفظ التسجيل بقاعدة البيانات: $e');
    }
  }

  Future<bool> _askStopOnExit() async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('التسجيل جاري', style: GoogleFonts.cairo()),
          content: Text('هل تريد إيقاف التسجيل وحفظه ثم الخروج؟',
              style: GoogleFonts.cairo()),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('متابعة التسجيل', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('إيقاف وحفظ', style: GoogleFonts.cairo())),
          ],
        ),
      ),
    );
    return r == true;
  }

  // ---------------- المحاضر ----------------
  Future<bool> _confirm(String title, String yes) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title, style: GoogleFonts.cairo()),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('إلغاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(yes, style: GoogleFonts.cairo(color: Colors.red))),
          ],
        ),
      ),
    );
    return r == true;
  }

  Future<void> _newManual() async {
    try {
      final db = AppDatabase.instance;
      final id = await db.insertRecording(
          title: _titleOrDefault(), path: '', durationSec: 0);
      await db.updateRecording(id,
          status: 'manual', resultJson: jsonEncode(SessionResult().toJson()));
      _title.clear();
      await _load();
      final rec = _items.firstWhere((x) => x.id == id);
      if (mounted) await _review(rec);
    } catch (e) {
      _snack('تعذر إنشاء المحضر: $e');
    }
  }

  Future<void> _delete(Recording r) async {
    if (_proc.runningId == r.id) {
      _snack('أوقف المعالجة أولاً');
      return;
    }
    if (!await _confirm(
        r.path.isEmpty ? 'حذف "${r.title}"؟' : 'حذف "${r.title}" مع ملف الصوت؟',
        'حذف')) {
      return;
    }
    try {
      if (r.path.isNotEmpty) {
        final f = File(r.path);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    await AppDatabase.instance.deleteRecording(r.id);
    await _load();
  }

  Future<void> _review(Recording r) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SessionReviewScreen(rec: r)));
    _load();
  }

  // ---------------- الواجهة ----------------
  ({String label, Color color, IconData icon}) _statusOf(Recording r) {
    if (_proc.runningId == r.id) {
      return (
      label: 'جاري المعالجة',
      color: Colors.blue,
      icon: Icons.sync_rounded
      );
    }
    switch (r.status) {
      case 'done':
        return (
        label: 'محضر جاهز',
        color: Colors.green,
        icon: Icons.check_circle_rounded
        );
      case 'manual':
        return (
        label: 'محضر يدوي',
        color: Colors.teal,
        icon: Icons.edit_note_rounded
        );
      case 'failed':
        return (
        label: 'تعذر إعداد المحضر بالذكاء الاصطناعي',
        color: Colors.red,
        icon: Icons.error_rounded
        );
      default:
        return (
        label: 'تسجيل محفوظ',
        color: AppColors.navy,
        icon: Icons.mic_rounded
        );
    }
  }

  Widget _banner() {
    final m = _proc.message;
    if (m == null) return const SizedBox.shrink();
    final err = _proc.messageIsError;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: err
            ? Colors.red.withOpacity(0.08)
            : Colors.green.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(err ? Icons.error_rounded : Icons.check_circle_rounded,
              color: err ? Colors.red : Colors.green),
          const SizedBox(width: 10),
          Expanded(
              child:
              Text(m, style: GoogleFonts.cairo(fontSize: 13, height: 1.5))),
          IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: _proc.clearMessage),
        ],
      ),
    );
  }

  Widget _recorderCard() {
    final recording = _state != _RecState.idle;
    final paused = _state == _RecState.paused;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
              color: AppColors.navy.withOpacity(0.07),
              blurRadius: 18,
              offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        children: [
          TextField(
            controller: _title,
            enabled: !recording,
            decoration: InputDecoration(
              labelText: 'عنوان الجلسة (اختياري)',
              labelStyle: GoogleFonts.cairo(),
              prefixIcon: const Icon(Icons.title_rounded),
              border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 18),
          Text(_fmt(_sw.elapsed),
              style: GoogleFonts.poppins(
                  fontSize: 44,
                  fontWeight: FontWeight.w600,
                  color: recording && !paused
                      ? Colors.red.shade700
                      : AppColors.navyDark)),
          Text(
              !recording
                  ? 'جاهز للتسجيل'
                  : paused
                  ? 'متوقف مؤقتاً'
                  : 'جاري التسجيل... لا تغلق التطبيق ولا تقفل الشاشة',
              style:
              GoogleFonts.cairo(fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 14),
          if (!recording)
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.navyDark,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _start,
                icon: const Icon(Icons.mic_rounded, color: AppColors.gold),
                label: Text('بدء التسجيل الميداني',
                    style: GoogleFonts.cairo(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: OutlinedButton.icon(
                      onPressed: _pauseResume,
                      icon: Icon(paused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded),
                      label: Text(paused ? 'استئناف' : 'إيقاف مؤقت',
                          style:
                          GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _stopAndSave,
                      icon: const Icon(Icons.stop_rounded),
                      label: Text('إنهاء وحفظ',
                          style:
                          GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ],
            ),
          if (!recording) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _newManual,
                icon: const Icon(Icons.edit_note_rounded),
                label: Text('محضر جديد بدون تسجيل',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _progressBlock() {
    final p = _proc;
    final extra = StringBuffer();
    if (p.uploadFraction >= 0) {
      extra.write('  ${(p.uploadFraction * 100).round()}%');
    }
    if (p.outChars > 0) extra.write('  •  ${p.outChars} حرف');
    if (p.queueTotal > 1) {
      extra.write('  •  ملف ${p.queueIndex} من ${p.queueTotal}');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        LinearProgressIndicator(
            value: p.uploadFraction >= 0 ? p.uploadFraction : null),
        const SizedBox(height: 6),
        Text('${p.phase}$extra',
            style: GoogleFonts.cairo(fontSize: 12, height: 1.5)),
        Row(
          children: [
            Text('المدة: ${_fmt(p.elapsed)}',
                style:
                GoogleFonts.cairo(fontSize: 11, color: AppColors.textMuted)),
            const Spacer(),
            TextButton.icon(
              onPressed: p.cancelling ? null : p.cancel,
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: Text('إيقاف', style: GoogleFonts.cairo()),
            ),
          ],
        ),
        Text('تقدر تطلع من الصفحة والعملية تكمل (لا تغلق التطبيق)',
            style:
            GoogleFonts.cairo(fontSize: 10, color: AppColors.textMuted)),
      ],
    );
  }

  Widget _actions(Recording r, bool lockAll) {
    final hasAudio = _hasAudio(r);
    final st = r.status;
    final recBusy = _state != _RecState.idle;

    if (st == 'done' || st == 'manual') {
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.navyDark,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: recBusy ? null : () => _review(r),
              icon: const Icon(Icons.description_rounded),
              label: Text('فتح المحضر وتصدير Word',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
            ),
          ),
          if (hasAudio && st == 'manual')
            TextButton.icon(
              onPressed: lockAll
                  ? null
                  : () => _proc.process(r, fullTranscript: _fullTr),
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text('املأ الفارغ بالذكاء الاصطناعي (يحتاج إنترنت)',
                  style: GoogleFonts.cairo(fontSize: 12)),
            ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 46,
            child: OutlinedButton.icon(
              onPressed: recBusy ? null : () => _review(r),
              icon: const Icon(Icons.edit_note_rounded),
              label: Text('تعبئة المحضر',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
        if (hasAudio) ...[
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 46,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  foregroundColor: AppColors.navyDark,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: lockAll
                    ? null
                    : () => _proc.process(r, fullTranscript: _fullTr),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(st == 'failed' ? 'إعادة المحاولة' : 'بالذكاء الاصطناعي',
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _card(Recording r) {
    final st = _statusOf(r);
    final busyThis = _proc.runningId == r.id;
    final hasAudio = _hasAudio(r);
    final tr = _trState[r.id];
    final lockAll = _state != _RecState.idle || _proc.busy;
    var sizeMb = '';
    if (hasAudio) {
      try {
        sizeMb =
        '${(File(r.path).lengthSync() / 1048576).toStringAsFixed(1)} MB';
      } catch (_) {}
    }
    final canFull = hasAudio && (r.status == 'done' || r.status == 'manual');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: AppColors.navy.withOpacity(0.06),
              blurRadius: 14,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: st.color.withOpacity(0.15),
                child: Icon(st.icon, color: st.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    Text(
                        hasAudio
                            ? '${DateFormat('yyyy/MM/dd HH:mm').format(r.createdAt)}  •  ${_fmt(Duration(seconds: r.durationSec))}  •  $sizeMb'
                            : '${DateFormat('yyyy/MM/dd HH:mm').format(r.createdAt)}  •  بدون تسجيل صوتي',
                        style: GoogleFonts.cairo(
                            fontSize: 11, color: AppColors.textMuted)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'share') {
                    try {
                      await ExportService.shareFile(r.path, 'audio/mp4');
                    } catch (e) {
                      _snack('تعذر المشاركة: $e');
                    }
                  } else if (v == 'transcript') {
                    if (lockAll) {
                      _snack('انتظر انتهاء العملية الجارية');
                      return;
                    }
                    _proc.transcribeOnly(r);
                  } else if (v == 'redo') {
                    if (lockAll) {
                      _snack('انتظر انتهاء العملية الجارية');
                      return;
                    }
                    if (await _confirm(
                        'سيُستبدل المحضر الحالي وتعديلاتك عليه بنسخة جديدة من الذكاء الاصطناعي. متأكد؟',
                        'استبدال')) {
                      _proc.process(r, fullTranscript: _fullTr, overwrite: true);
                    }
                  } else if (v == 'delete') {
                    _delete(r);
                  }
                },
                itemBuilder: (_) => [
                  if (hasAudio)
                    PopupMenuItem(
                        value: 'share',
                        child: Text('مشاركة ملف الصوت',
                            style: GoogleFonts.cairo())),
                  if (canFull)
                    PopupMenuItem(
                        value: 'transcript',
                        child: Text(
                            tr == 'done'
                                ? 'إعادة التفريغ الكامل'
                                : tr == 'partial'
                                ? 'إكمال التفريغ الكامل'
                                : 'تفريغ كامل للنص',
                            style: GoogleFonts.cairo())),
                  if (hasAudio && r.status == 'done')
                    PopupMenuItem(
                        value: 'redo',
                        child: Text('إعادة إعداد المحضر بالذكاء الاصطناعي',
                            style: GoogleFonts.cairo())),
                  PopupMenuItem(
                      value: 'delete',
                      child: Text('حذف', style: GoogleFonts.cairo())),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _chip(st.label, st.color),
              if (tr == 'done') _chip('التفريغ الكامل جاهز', Colors.green),
              if (tr == 'partial') _chip('التفريغ الكامل ناقص', Colors.orange),
            ],
          ),
          if (r.status == 'failed' && r.error.isNotEmpty && !busyThis)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(r.error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(fontSize: 11, color: Colors.red)),
            ),
          if (busyThis)
            _progressBlock()
          else ...[
            const SizedBox(height: 10),
            _actions(r, lockAll),
          ],
        ],
      ),
    );
  }

  Widget _chip(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
        color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
    child: Text(t,
        style: GoogleFonts.cairo(
            fontSize: 11, fontWeight: FontWeight.w700, color: c)),
  );

  @override
  Widget build(BuildContext context) {
    final pending = _items
        .where((r) =>
    (r.status == 'pending' || r.status == 'failed') && _hasAudio(r))
        .toList();
    return PopScope(
      canPop: _state == _RecState.idle,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _askStopOnExit()) {
          await _stopAndSave();
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: Text('التقرير الصوتي',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
            backgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
          ),
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              _banner(),
              _recorderCard(),
              const SizedBox(height: 8),
              ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                tilePadding: const EdgeInsets.symmetric(horizontal: 6),
                title: Text('خيارات الذكاء الاصطناعي',
                    style: GoogleFonts.cairo(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                children: [
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    title: Text('تضمين التفريغ الكامل للنص',
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    subtitle: Text(
                        'مطفأ = أسرع (ملخص ونقاط وقرارات ومهام). مفعّل = يكمل بعده بتفريغ النص كامل على أجزاء، وهو الأبطأ',
                        style: GoogleFonts.cairo(fontSize: 11, height: 1.5)),
                    value: _fullTr,
                    onChanged: (v) async {
                      setState(() => _fullTr = v);
                      await AppDatabase.instance
                          .setSetting('audio_full_tr', v ? '1' : '0');
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text('التسجيلات والمحاضر (${_items.length})',
                        style: GoogleFonts.cairo(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  if (pending.length > 1)
                    TextButton.icon(
                      onPressed: (_proc.busy || _state != _RecState.idle)
                          ? null
                          : () => _proc.processAll(pending.reversed.toList(),
                          fullTranscript: _fullTr),
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                      label: Text('معالجة الكل (${pending.length})',
                          style:
                          GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (_items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text('لا توجد تسجيلات بعد',
                        style: GoogleFonts.cairo(
                            color: AppColors.textMuted, fontSize: 15)),
                  ),
                )
              else
                for (final r in _items) _card(r),
            ],
          ),
        ),
      ),
    );
  }
}