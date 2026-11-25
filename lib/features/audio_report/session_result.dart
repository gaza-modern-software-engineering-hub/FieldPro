class Recording {
  final int id;
  final String title;
  final String path;
  final int durationSec;
  final String status; // pending | processing | done | failed | manual
  final String resultJson;
  final String error;
  final DateTime createdAt;

  Recording({
    required this.id,
    required this.title,
    required this.path,
    required this.durationSec,
    required this.status,
    required this.resultJson,
    required this.error,
    required this.createdAt,
  });

  factory Recording.fromMap(Map<String, dynamic> m) => Recording(
    id: m['id'] as int,
    title: m['title'] as String,
    path: m['path'] as String,
    durationSec: (m['duration'] ?? 0) as int,
    status: (m['status'] ?? 'pending') as String,
    resultJson: (m['result'] ?? '') as String,
    error: (m['error'] ?? '') as String,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

const kTaskStatuses = ['مفتوحة', 'قيد التنفيذ', 'مغلقة'];

class Attendee {
  String name;
  String org;
  Attendee(this.name, [this.org = '']);

  Map<String, dynamic> toJson() => {'name': name, 'org': org};

  static Attendee fromAny(dynamic v) {
    if (v is Map) {
      return Attendee((v['name'] ?? '').toString(), (v['org'] ?? '').toString());
    }
    return Attendee(v.toString());
  }
}

class SessionTask {
  String who;
  String what;
  String due;
  String status;
  SessionTask(this.who, this.what, this.due, [this.status = 'مفتوحة']);

  Map<String, dynamic> toJson() =>
      {'who': who, 'what': what, 'due': due, 'status': status};

  factory SessionTask.fromJson(Map<String, dynamic> m) => SessionTask(
      (m['who'] ?? '').toString(),
      (m['what'] ?? '').toString(),
      (m['due'] ?? '').toString(),
      kTaskStatuses.contains(m['status']) ? m['status'] as String : 'مفتوحة');

  static SessionTask? fromLine(String line) {
    final p = line.split('|').map((e) => e.trim()).toList();
    if (p.every((e) => e.isEmpty)) return null;
    if (p.length >= 3) {
      return SessionTask(p[0], p.sublist(1, p.length - 1).join(' - '), p.last);
    }
    if (p.length == 2) return SessionTask(p[0], p[1], '');
    return SessionTask('', p[0], '');
  }
}

class SessionResult {
  SessionResult();

  String title = '';
  String summary = '';
  String transcript = '';
  String location = '';
  String site = '';
  String nextMeeting = '';
  String notes = '';
  DateTime? date;
  bool aiGenerated = false;
  List<Attendee> attendees = [];
  List<String> keyPoints = [];
  List<String> decisions = [];
  List<SessionTask> tasks = [];

  bool get isEmpty =>
      title.trim().isEmpty &&
          summary.trim().isEmpty &&
          transcript.trim().isEmpty &&
          location.trim().isEmpty &&
          site.trim().isEmpty &&
          nextMeeting.trim().isEmpty &&
          notes.trim().isEmpty &&
          attendees.isEmpty &&
          keyPoints.isEmpty &&
          decisions.isEmpty &&
          tasks.isEmpty;

  Map<String, dynamic> toJson() => {
    'title': title,
    'summary': summary,
    'transcript': transcript,
    'location': location,
    'site': site,
    'nextMeeting': nextMeeting,
    'notes': notes,
    'date': date?.toIso8601String() ?? '',
    'ai': aiGenerated,
    'attendees': attendees.map((a) => a.toJson()).toList(),
    'keyPoints': keyPoints,
    'decisions': decisions,
    'tasks': tasks.map((t) => t.toJson()).toList(),
  };

  static List<String> _strs(dynamic v) => v is List
      ? v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
      : <String>[];

  factory SessionResult.fromJson(Map<String, dynamic> m) {
    final r = SessionResult();
    r.title = (m['title'] ?? '').toString();
    r.summary = (m['summary'] ?? '').toString();
    r.transcript = (m['transcript'] ?? '').toString();
    r.location = (m['location'] ?? '').toString();
    r.site = (m['site'] ?? '').toString();
    r.nextMeeting = (m['nextMeeting'] ?? '').toString();
    r.notes = (m['notes'] ?? '').toString();
    r.date = DateTime.tryParse((m['date'] ?? '').toString());
    r.aiGenerated = m['ai'] == true;
    final a = m['attendees'];
    if (a is List) {
      r.attendees = a
          .map(Attendee.fromAny)
          .where((e) => e.name.trim().isNotEmpty || e.org.trim().isNotEmpty)
          .toList();
    }
    r.keyPoints = _strs(m['keyPoints']);
    r.decisions = _strs(m['decisions']);
    final t = m['tasks'];
    if (t is List) {
      r.tasks = t
          .whereType<Map>()
          .map((e) => SessionTask.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return r;
  }

  /// يعبّي الحقول الفاضية فقط من نتيجة الذكاء الاصطناعي ولا يمسّ ما كتبه المستخدم
  void fillEmptyFrom(SessionResult o) {
    String pick(String a, String b) => a.trim().isEmpty ? b : a;
    title = pick(title, o.title);
    summary = pick(summary, o.summary);
    transcript = pick(transcript, o.transcript);
    location = pick(location, o.location);
    site = pick(site, o.site);
    nextMeeting = pick(nextMeeting, o.nextMeeting);
    notes = pick(notes, o.notes);
    date ??= o.date;
    if (attendees.isEmpty) attendees = o.attendees;
    if (keyPoints.isEmpty) keyPoints = o.keyPoints;
    if (decisions.isEmpty) decisions = o.decisions;
    if (tasks.isEmpty) tasks = o.tasks;
    aiGenerated = aiGenerated || o.aiGenerated;
  }

  static List<String> splitLines(String s) {
    final out = <String>[];
    for (final raw in s.split('\n')) {
      var l = raw.trim().replaceAll('**', '').replaceAll('##', '');
      l = l.replaceFirst(RegExp(r'^([-*•]|\d+[.)])\s*'), '');
      if (l.isNotEmpty) out.add(l);
    }
    return out;
  }

  static bool _none(String l) =>
      l.startsWith('لا يوجد') || l.startsWith('لا توجد');

  /// يحلّل رد Gemini بالتنسيق ذي العلامات
  factory SessionResult.fromMarked(String raw) {
    final r = SessionResult();
    final re = RegExp(r'\[\[\s*([A-Z]+)\s*\]\]');
    final ms = re.allMatches(raw).toList();
    if (ms.isEmpty) {
      r.summary = raw.replaceAll('**', '').replaceAll('##', '').trim();
      return r;
    }
    final sec = <String, String>{};
    for (var i = 0; i < ms.length; i++) {
      final end = i + 1 < ms.length ? ms[i + 1].start : raw.length;
      sec[ms[i].group(1)!] = raw.substring(ms[i].end, end).trim();
    }
    String g(String k) => (sec[k] ?? '').trim();

    final t = splitLines(g('TITLE'));
    r.title = t.isEmpty ? '' : t.first;
    r.summary = g('SUMMARY').replaceAll('**', '').replaceAll('##', '');
    r.attendees = splitLines(g('ATTENDEES'))
        .where((e) => !_none(e))
        .map((e) {
      final i = e.indexOf(' - ');
      return i > 0
          ? Attendee(e.substring(0, i).trim(), e.substring(i + 3).trim())
          : Attendee(e);
    }).toList();
    r.keyPoints = splitLines(g('POINTS'));
    r.decisions = splitLines(g('DECISIONS'));
    r.tasks = splitLines(g('TASKS'))
        .where((e) => !_none(e))
        .map(SessionTask.fromLine)
        .whereType<SessionTask>()
        .toList();
    r.transcript = g('TRANSCRIPT').replaceAll('**', '');
    r.aiGenerated = true;
    return r;
  }
}