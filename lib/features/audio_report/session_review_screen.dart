import 'dart:convert';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../core/app_colors.dart';
import '../../core/app_settings.dart';
import '../../core/database.dart';
import '../../core/export_service.dart';
import 'session_docx.dart';
import 'session_result.dart';

class _AttRow {
  final TextEditingController name;
  final TextEditingController org;
  _AttRow([String n = '', String o = ''])
      : name = TextEditingController(text: n),
        org = TextEditingController(text: o);
  void dispose() {
    name.dispose();
    org.dispose();
  }
}

class _TaskRow {
  final TextEditingController what;
  final TextEditingController who;
  final TextEditingController due;
  String status;
  _TaskRow([String w = '', String o = '', String d = '', this.status = 'مفتوحة'])
      : what = TextEditingController(text: w),
        who = TextEditingController(text: o),
        due = TextEditingController(text: d);
  void dispose() {
    what.dispose();
    who.dispose();
    due.dispose();
  }
}

class SessionReviewScreen extends StatefulWidget {
  final Recording rec;
  const SessionReviewScreen({super.key, required this.rec});

  @override
  State<SessionReviewScreen> createState() => _SessionReviewScreenState();
}

class _SessionReviewScreenState extends State<SessionReviewScreen> {
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _site = TextEditingController();
  final _summary = TextEditingController();
  final _next = TextEditingController();
  final _notes = TextEditingController();
  final _transcript = TextEditingController();
  final List<_AttRow> _att = [];
  final List<TextEditingController> _points = [];
  final List<TextEditingController> _decisions = [];
  final List<_TaskRow> _tasks = [];
  late DateTime _date;
  bool _aiFlag = false;
  bool _dirty = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    SessionResult r;
    try {
      final j = widget.rec.resultJson.trim();
      r = j.isEmpty
          ? SessionResult()
          : SessionResult.fromJson(jsonDecode(j) as Map<String, dynamic>);
    } catch (_) {
      r = SessionResult();
    }
    _aiFlag = r.aiGenerated;
    _date = r.date ?? widget.rec.createdAt;
    _title.text = r.title.isEmpty ? widget.rec.title : r.title;
    _location.text = r.location;
    _site.text = r.site;
    _summary.text = r.summary;
    _next.text = r.nextMeeting;
    _notes.text = r.notes;
    _transcript.text = r.transcript;
    for (final a in r.attendees) {
      _att.add(_AttRow(a.name, a.org));
    }
    for (final p in r.keyPoints) {
      _points.add(TextEditingController(text: p));
    }
    for (final d in r.decisions) {
      _decisions.add(TextEditingController(text: d));
    }
    for (final t in r.tasks) {
      _tasks.add(_TaskRow(t.what, t.who, t.due, t.status));
    }
    if (_att.isEmpty) _att.add(_AttRow());
    if (_points.isEmpty) _points.add(TextEditingController());
    if (_decisions.isEmpty) _decisions.add(TextEditingController());
    if (_tasks.isEmpty) _tasks.add(_TaskRow());
  }

  @override
  void dispose() {
    for (final c in [_title, _location, _site, _summary, _next, _notes, _transcript]) {
      c.dispose();
    }
    for (final a in _att) {
      a.dispose();
    }
    for (final c in _points) {
      c.dispose();
    }
    for (final c in _decisions) {
      c.dispose();
    }
    for (final t in _tasks) {
      t.dispose();
    }
    super.dispose();
  }

  void _touch() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  SessionResult _collect() {
    final r = SessionResult();
    r.title = _title.text.trim();
    r.date = _date;
    r.location = _location.text.trim();
    r.site = _site.text.trim();
    r.summary = _summary.text.trim();
    r.nextMeeting = _next.text.trim();
    r.notes = _notes.text.trim();
    r.transcript = _transcript.text.trim();
    r.aiGenerated = _aiFlag;
    r.attendees = [
      for (final a in _att)
        if (a.name.text.trim().isNotEmpty || a.org.text.trim().isNotEmpty)
          Attendee(a.name.text.trim(), a.org.text.trim())
    ];
    r.keyPoints = [
      for (final c in _points)
        if (c.text.trim().isNotEmpty) c.text.trim()
    ];
    r.decisions = [
      for (final c in _decisions)
        if (c.text.trim().isNotEmpty) c.text.trim()
    ];
    r.tasks = [
      for (final t in _tasks)
        if (t.what.text.trim().isNotEmpty || t.who.text.trim().isNotEmpty)
          SessionTask(t.who.text.trim(), t.what.text.trim(), t.due.text.trim(),
              t.status)
    ];
    return r;
  }

  Future<SessionResult> _save({bool quiet = false}) async {
    final r = _collect();
    final st = widget.rec.status;
    await AppDatabase.instance.updateRecording(widget.rec.id,
        title: r.title.isEmpty ? widget.rec.title : r.title,
        resultJson: jsonEncode(r.toJson()),
        status: (st == 'pending' || st == 'failed') ? 'manual' : null,
        error: st == 'failed' ? '' : null);
    if (mounted) setState(() => _dirty = false);
    if (!quiet) _snack('تم حفظ المحضر');
    return r;
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final r = await _save(quiet: true);
      if (r.isEmpty) {
        _snack('المحضر فاضي، عبّي شي منه أولاً');
        return;
      }
      final bytes = SessionDocx.build(
        r: r,
        company: AppSettings.company,
        date: widget.rec.createdAt,
        durationSec: widget.rec.durationSec,
        logoPath: AppSettings.logoPath,
      );
      if (bytes.isEmpty) throw Exception('تعذر إنشاء الملف');
      final base = (r.title.isEmpty ? 'محضر_اجتماع' : r.title)
          .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      if (!mounted) return;
      await showExportSheet(
        context,
        baseName: base,
        ext: 'docx',
        bytes: bytes,
        mime:
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        mimeType: MimeType.microsoftWord,
      );
    } catch (e) {
      _snack('تعذر التصدير: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context,
        initialDate: _date,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (d == null) return;
    setState(() {
      _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute);
      _dirty = true;
    });
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_date));
    if (t == null) return;
    setState(() {
      _date = DateTime(_date.year, _date.month, _date.day, t.hour, t.minute);
      _dirty = true;
    });
  }

  Future<void> _pickSite() async {
    final db = AppDatabase.instance;
    final projects = await db.getProjects();
    if (!mounted) return;
    if (projects.isEmpty) {
      _snack('ما عندك مواقع أو مجلدات بعد');
      return;
    }
    final labels = <String>[];
    for (final p in projects) {
      final sp = p.id == null ? null : await db.getSiteProfile(p.id!);
      labels.add(sp != null && sp.code.trim().isNotEmpty
          ? '${sp.code.trim()} - ${p.name}'
          : p.name);
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const SizedBox(height: 12),
              Center(
                  child: Text('اختر الموقع',
                      style: GoogleFonts.cairo(
                          fontSize: 17, fontWeight: FontWeight.w700))),
              for (final l in labels)
                ListTile(
                  leading:
                  const Icon(Icons.holiday_village_rounded, color: AppColors.navy),
                  title: Text(l, style: GoogleFonts.cairo()),
                  onTap: () => Navigator.pop(ctx, l),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _site.text = picked;
        _dirty = true;
      });
    }
  }

  Future<void> _askLeave() async {
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تعديلات غير محفوظة', style: GoogleFonts.cairo()),
          content: Text('هل تريد حفظ المحضر قبل الخروج؟',
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

  // ---------------- عناصر الواجهة ----------------
  Widget _section(String title,
      {Widget? trailing, required List<Widget> children}) =>
      Container(
        margin: const EdgeInsets.only(bottom: 14),
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
            Row(children: [
              Expanded(
                child: Text(title,
                    style: GoogleFonts.cairo(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              if (trailing != null) trailing,
            ]),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      );

  Widget _tf(TextEditingController c, String label,
      {int minLines = 1, int? maxLines = 1, String? hint}) =>
      TextField(
        controller: c,
        minLines: minLines,
        maxLines: maxLines,
        onChanged: (_) => _touch(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          labelStyle: GoogleFonts.cairo(fontSize: 13),
          hintStyle: GoogleFonts.cairo(fontSize: 12),
          alignLabelWithHint: true,
          filled: true,
          fillColor: const Color(0xFFF4F6F9),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
        ),
      );

  Widget _addBtn(String label, VoidCallback f) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton.icon(
      onPressed: f,
      icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
      label: Text(label,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
    ),
  );

  Widget _delBtn(VoidCallback f) => IconButton(
    icon: const Icon(Icons.close_rounded, color: Colors.red),
    onPressed: f,
  );

  Widget _listSection(String title, List<TextEditingController> list,
      String addLabel, String hint) {
    return _section(title, children: [
      for (var i = 0; i < list.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  child: _tf(list[i], hint, minLines: 1, maxLines: 4)),
              _delBtn(() {
                setState(() {
                  list.removeAt(i).dispose();
                  if (list.isEmpty) list.add(TextEditingController());
                  _dirty = true;
                });
              }),
            ],
          ),
        ),
      _addBtn(addLabel, () {
        setState(() {
          list.add(TextEditingController());
          _dirty = true;
        });
      }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
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
            title: Text('المحضر',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
            actions: [
              IconButton(
                tooltip: 'حفظ',
                icon: const Icon(Icons.save_rounded),
                onPressed: _busy ? null : () => _save(),
              ),
            ],
          ),
          body: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                    color: AppColors.gold.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(14)),
                child: Text(
                    'عبّي اللي بدك فيه بس. الأقسام الفاضية ما بتظهر بملف Word.',
                    style: GoogleFonts.cairo(fontSize: 12)),
              ),
              _section('بيانات الاجتماع', children: [
                _tf(_title, 'عنوان الاجتماع'),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today_rounded, size: 18),
                      label: Text(DateFormat('yyyy/MM/dd').format(_date),
                          style: GoogleFonts.cairo()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule_rounded, size: 18),
                      label: Text(DateFormat('HH:mm').format(_date),
                          style: GoogleFonts.cairo()),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                _tf(_location, 'المكان'),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _tf(_site, 'الموقع')),
                  IconButton(
                    tooltip: 'اختيار من مواقعي',
                    icon: const Icon(Icons.folder_open_rounded,
                        color: AppColors.navy),
                    onPressed: _pickSite,
                  ),
                ]),
              ]),
              _section('الحضور', children: [
                for (var i = 0; i < _att.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: _tf(_att[i].name, 'الاسم')),
                        const SizedBox(width: 8),
                        Expanded(
                            flex: 2, child: _tf(_att[i].org, 'الجهة / الصفة')),
                        _delBtn(() {
                          setState(() {
                            _att.removeAt(i).dispose();
                            if (_att.isEmpty) _att.add(_AttRow());
                            _dirty = true;
                          });
                        }),
                      ],
                    ),
                  ),
                _addBtn('إضافة مشارك', () {
                  setState(() {
                    _att.add(_AttRow());
                    _dirty = true;
                  });
                }),
              ]),
              _section('الملخص', children: [
                _tf(_summary, 'ملخص الاجتماع', minLines: 3, maxLines: null),
              ]),
              _listSection('أبرز النقاط', _points, 'إضافة نقطة', 'النقطة'),
              _listSection('القرارات والاتفاقات', _decisions, 'إضافة قرار', 'القرار'),
              _section('المهام والمتابعة', children: [
                for (var i = 0; i < _tasks.length; i++)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        border: Border.all(color: Colors.black12),
                        borderRadius: BorderRadius.circular(14)),
                    child: Column(
                      children: [
                        _tf(_tasks[i].what, 'المهمة', minLines: 1, maxLines: 4),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(child: _tf(_tasks[i].who, 'المسؤول')),
                          const SizedBox(width: 8),
                          Expanded(child: _tf(_tasks[i].due, 'الموعد')),
                        ]),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _tasks[i].status,
                              isDense: true,
                              decoration: InputDecoration(
                                labelText: 'الحالة',
                                labelStyle: GoogleFonts.cairo(fontSize: 13),
                                isDense: true,
                                filled: true,
                                fillColor: const Color(0xFFF4F6F9),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none),
                              ),
                              items: [
                                for (final s in kTaskStatuses)
                                  DropdownMenuItem(
                                      value: s,
                                      child: Text(s,
                                          style: GoogleFonts.cairo(fontSize: 13)))
                              ],
                              onChanged: (v) => setState(() {
                                _tasks[i].status = v ?? _tasks[i].status;
                                _dirty = true;
                              }),
                            ),
                          ),
                          _delBtn(() {
                            setState(() {
                              _tasks.removeAt(i).dispose();
                              if (_tasks.isEmpty) _tasks.add(_TaskRow());
                              _dirty = true;
                            });
                          }),
                        ]),
                      ],
                    ),
                  ),
                _addBtn('إضافة مهمة', () {
                  setState(() {
                    _tasks.add(_TaskRow());
                    _dirty = true;
                  });
                }),
              ]),
              _section('الاجتماع القادم وملاحظات', children: [
                _tf(_next, 'الاجتماع القادم (التاريخ والمكان)'),
                const SizedBox(height: 10),
                _tf(_notes, 'ملاحظات', minLines: 2, maxLines: null),
              ]),
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18)),
                child: ExpansionTile(
                  shape: const Border(),
                  title: Text('نص التفريغ الكامل (اختياري)',
                      style: GoogleFonts.cairo(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  children: [
                    _tf(_transcript, 'النص', minLines: 6, maxLines: null),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _save(),
                        icon: const Icon(Icons.save_rounded),
                        label: Text('حفظ',
                            style:
                            GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.gold,
                          foregroundColor: AppColors.navyDark,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: _busy ? null : _export,
                        icon: _busy
                            ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                            CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.description_rounded),
                        label: Text('تصدير Word',
                            style:
                            GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}