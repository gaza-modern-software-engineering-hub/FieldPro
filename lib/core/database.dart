import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../features/projects/project.dart';
import '../features/map/map_point.dart';
import '../features/map/map_area.dart';
import '../features/audio_report/session_result.dart';
import '../features/site/site_profile.dart';
import '../features/visits/visit_models.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Future<Database>? _opening;

  Future<Database> get db => _opening ??= _open();

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'fieldpro.db');
    return openDatabase(
      path,
      version: 11,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            client TEXT,
            location TEXT,
            notes TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await _createPoints(db);
        await _createAreas(db);
        await _createSettings(db);
        await _createFiles(db);
        await _createRecordings(db);
        await _createSiteProfiles(db);
        await _createVisits(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) await _createPoints(db);
        if (oldV < 3) {
          await db.execute(
              'ALTER TABLE points ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0');
          await _createAreas(db);
        }
        if (oldV < 4) {
          await db.execute('ALTER TABLE points ADD COLUMN project_id INTEGER');
          await db.execute('ALTER TABLE areas ADD COLUMN project_id INTEGER');
        }
        if (oldV < 5) await _createSettings(db);
        if (oldV < 6) await _createFiles(db);
        if (oldV < 7) {
          await db.execute(
              "ALTER TABLE points ADD COLUMN photo TEXT NOT NULL DEFAULT ''");
        }
        if (oldV < 8) {
          await db.execute(
              'ALTER TABLE areas ADD COLUMN color INTEGER NOT NULL DEFAULT 0');
        }
        if (oldV < 9) await _createRecordings(db);
        if (oldV < 10) await _createSiteProfiles(db);
        if (oldV < 11) await _createVisits(db);
      },
    );
  }

  Future<void> _createPoints(Database db) => db.execute('''
    CREATE TABLE points (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id INTEGER,
      name TEXT NOT NULL,
      note TEXT,
      lat REAL NOT NULL,
      lng REAL NOT NULL,
      favorite INTEGER NOT NULL DEFAULT 0,
      photo TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''');

  Future<void> _createAreas(Database db) => db.execute('''
    CREATE TABLE areas (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id INTEGER,
      name TEXT NOT NULL,
      coords TEXT NOT NULL,
      area REAL NOT NULL,
      perimeter REAL NOT NULL,
      color INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''');

  Future<void> _createSettings(Database db) => db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');

  Future<void> _createFiles(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id INTEGER,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      path TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');

  Future<void> _createRecordings(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS recordings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      path TEXT NOT NULL,
      duration INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'pending',
      result TEXT NOT NULL DEFAULT '',
      error TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''');

  Future<void> _createSiteProfiles(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS site_profiles (
      project_id INTEGER PRIMARY KEY,
      code TEXT NOT NULL DEFAULT '',
      district TEXT NOT NULL DEFAULT '',
      manager TEXT NOT NULL DEFAULT '',
      phone TEXT NOT NULL DEFAULT '',
      households INTEGER NOT NULL DEFAULT 0,
      individuals INTEGER NOT NULL DEFAULT 0,
      area_override REAL NOT NULL DEFAULT 0,
      notes TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT ''
    )
  ''');

  Future<void> _createVisits(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS visits (
        id TEXT PRIMARY KEY,
        site_code TEXT NOT NULL DEFAULT '',
        site_name TEXT NOT NULL DEFAULT '',
        purpose TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'completed',
        visitor TEXT NOT NULL DEFAULT '',
        visited_at TEXT NOT NULL,
        lat REAL,
        lng REAL,
        accuracy REAL,
        notes TEXT NOT NULL DEFAULT '',
        photo_ids TEXT NOT NULL DEFAULT '[]',
        deleted INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        seq INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS visit_photos (
        id TEXT PRIMARY KEY,
        visit_id TEXT NOT NULL,
        path TEXT NOT NULL DEFAULT '',
        uploaded INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ---------- المشاريع ----------
  Future<int> insertProject(Project p) async {
    final d = await db;
    return d.insert('projects', p.toMap());
  }

  Future<List<Project>> getProjects() async {
    final d = await db;
    final rows = await d.query('projects', orderBy: 'id DESC');
    return rows.map(Project.fromMap).toList();
  }

  Future<void> updateProject(Project p) async {
    final d = await db;
    await d.update('projects', p.toMap(), where: 'id = ?', whereArgs: [p.id]);
  }

  Future<void> deleteProject(int id) async {
    final d = await db;
    await d.delete('points', where: 'project_id = ?', whereArgs: [id]);
    await d.delete('areas', where: 'project_id = ?', whereArgs: [id]);
    await d.delete('files', where: 'project_id = ?', whereArgs: [id]);
    await d.delete('site_profiles', where: 'project_id = ?', whereArgs: [id]);
    await d.delete('projects', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> _count(String table, int projectId) async {
    final d = await db;
    return Sqflite.firstIntValue(await d.rawQuery(
        'SELECT COUNT(*) FROM $table WHERE project_id = ?',
        [projectId])) ??
        0;
  }

  Future<int> countPoints(int projectId) => _count('points', projectId);
  Future<int> countAreas(int projectId) => _count('areas', projectId);
  Future<int> countFiles(int projectId) => _count('files', projectId);

  Future<Map<String, int>> stats() async {
    final d = await db;
    Future<int> c(String sql) async =>
        Sqflite.firstIntValue(await d.rawQuery(sql)) ?? 0;
    return {
      'projects': await c('SELECT COUNT(*) FROM projects'),
      'points': await c('SELECT COUNT(*) FROM points'),
      'areas': await c('SELECT COUNT(*) FROM areas'),
      'files': await c('SELECT COUNT(*) FROM files'),
    };
  }

  // ---------- بطاقة الموقع ----------
  Future<SiteProfile?> getSiteProfile(int projectId) async {
    final d = await db;
    final r = await d.query('site_profiles',
        where: 'project_id = ?', whereArgs: [projectId]);
    return r.isEmpty ? null : SiteProfile.fromMap(r.first);
  }

  Future<void> saveSiteProfile(SiteProfile p) async {
    final d = await db;
    await d.insert('site_profiles', p.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------- النقاط ----------
  Future<int> insertPoint(MapPoint p) async {
    final d = await db;
    return d.insert('points', p.toMap());
  }

  Future<void> insertPointsBatch(List<MapPoint> list) async {
    if (list.isEmpty) return;
    final d = await db;
    await d.transaction((txn) async {
      final b = txn.batch();
      for (final p in list) {
        b.insert('points', p.toMap());
      }
      await b.commit(noResult: true);
    });
  }

  Future<List<MapPoint>> getPoints({int? projectId}) async {
    final d = await db;
    final rows = await d.query('points',
        where: projectId == null ? 'project_id IS NULL' : 'project_id = ?',
        whereArgs: projectId == null ? null : [projectId],
        orderBy: 'id DESC');
    return rows.map(MapPoint.fromMap).toList();
  }

  Future<bool> pointNameExists(String name, {int? projectId}) async {
    final d = await db;
    final r = await d.query('points',
        where: projectId == null
            ? 'LOWER(name) = ? AND project_id IS NULL'
            : 'LOWER(name) = ? AND project_id = ?',
        whereArgs: projectId == null
            ? [name.trim().toLowerCase()]
            : [name.trim().toLowerCase(), projectId]);
    return r.isNotEmpty;
  }

  Future<void> updatePoint(int id,
      {required String name, required String note, String? photo}) async {
    final d = await db;
    await d.update(
        'points',
        {'name': name, 'note': note, if (photo != null) 'photo': photo},
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<void> setFavorite(int id, bool fav) async {
    final d = await db;
    await d.update('points', {'favorite': fav ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deletePoint(int id) async {
    final d = await db;
    await d.delete('points', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- الحدود ----------
  Future<int> insertArea(MapArea a) async {
    final d = await db;
    return d.insert('areas', a.toMap());
  }

  Future<void> insertAreasBatch(List<MapArea> list) async {
    if (list.isEmpty) return;
    final d = await db;
    await d.transaction((txn) async {
      final b = txn.batch();
      for (final a in list) {
        b.insert('areas', a.toMap());
      }
      await b.commit(noResult: true);
    });
  }

  Future<List<MapArea>> getAreas({int? projectId}) async {
    final d = await db;
    final rows = await d.query('areas',
        where: projectId == null ? 'project_id IS NULL' : 'project_id = ?',
        whereArgs: projectId == null ? null : [projectId],
        orderBy: 'id DESC');
    return rows.map(MapArea.fromMap).toList();
  }

  Future<void> setAreaColor(int id, int color) async {
    final d = await db;
    await d.update('areas', {'color': color},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteArea(int id) async {
    final d = await db;
    await d.delete('areas', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- الملفات ----------
  Future<int> insertFile(
      {int? projectId,
        required String name,
        required String type,
        required String path}) async {
    final d = await db;
    return d.insert('files', {
      'project_id': projectId,
      'name': name,
      'type': type,
      'path': path,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getFiles(int projectId) async {
    final d = await db;
    return d.query('files',
        where: 'project_id = ?', whereArgs: [projectId], orderBy: 'id DESC');
  }

  Future<void> deleteFileRecord(int id) async {
    final d = await db;
    await d.delete('files', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- التسجيلات الصوتية ----------
  Future<int> insertRecording(
      {required String title,
        required String path,
        required int durationSec}) async {
    final d = await db;
    return d.insert('recordings', {
      'title': title,
      'path': path,
      'duration': durationSec,
      'status': 'pending',
      'result': '',
      'error': '',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Recording>> getRecordings() async {
    final d = await db;
    final rows = await d.query('recordings', orderBy: 'id DESC');
    return rows.map(Recording.fromMap).toList();
  }

  Future<void> updateRecording(int id,
      {String? title, String? status, String? resultJson, String? error}) async {
    final d = await db;
    final m = <String, Object?>{
      if (title != null) 'title': title,
      if (status != null) 'status': status,
      if (resultJson != null) 'result': resultJson,
      if (error != null) 'error': error,
    };
    if (m.isEmpty) return;
    await d.update('recordings', m, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteRecording(int id) async {
    final d = await db;
    await d.delete('recordings', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- الزيارات الميدانية ----------
  Future<List<Visit>> getVisits() async {
    final d = await db;
    final rows = await d.query('visits',
        where: 'deleted = 0', orderBy: 'visited_at DESC');
    return rows.map(Visit.fromMap).toList();
  }

  Future<Visit?> getVisit(String id) async {
    final d = await db;
    final r = await d.query('visits', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Visit.fromMap(r.first);
  }

  /// حفظ زيارة محلياً (جديدة أو معدّلة) وتعليمها للرفع
  Future<void> saveVisitLocal(Visit v) async {
    final d = await db;
    final ex = await d
        .query('visits', columns: ['id'], where: 'id = ?', whereArgs: [v.id]);
    final m = v.toLocalMap();
    if (ex.isEmpty) {
      m['dirty'] = 1;
      await d.insert('visits', m);
    } else {
      m.remove('dirty');
      m.remove('seq');
      await d.update('visits', m, where: 'id = ?', whereArgs: [v.id]);
      await d.rawUpdate(
          'UPDATE visits SET dirty = dirty + 1 WHERE id = ?', [v.id]);
    }
  }

  Future<void> softDeleteVisit(String id) async {
    final d = await db;
    await d.rawUpdate(
        'UPDATE visits SET deleted = 1, dirty = dirty + 1 WHERE id = ?', [id]);
  }

  Future<List<Visit>> dirtyVisits() async {
    final d = await db;
    final rows =
    await d.query('visits', where: 'dirty > 0', orderBy: 'created_at ASC');
    return rows.map(Visit.fromMap).toList();
  }

  Future<void> markVisitPushed(String id, int dirtyAtPush) async {
    final d = await db;
    await d.rawUpdate(
        'UPDATE visits SET dirty = 0 WHERE id = ? AND dirty = ?',
        [id, dirtyAtPush]);
  }

  /// يحذف زيارة محلياً (بعد رفع حذفها) ويرجع مسارات صورها لتُحذف من الجهاز
  Future<List<String>> removeVisitLocal(String id) async {
    final d = await db;
    final ph =
    await d.query('visit_photos', where: 'visit_id = ?', whereArgs: [id]);
    await d.delete('visit_photos', where: 'visit_id = ?', whereArgs: [id]);
    await d.delete('visits', where: 'id = ? AND dirty = 0', whereArgs: [id]);
    return [
      for (final p in ph)
        if ((p['path'] ?? '').toString().isNotEmpty) p['path'].toString()
    ];
  }

  /// يطبّق زيارات وصلت من الخادم ولا يمسّ زيارة فيها تعديل محلي لم يُرفع
  Future<List<String>> applyRemoteVisits(List<Map<String, dynamic>> rows) async {
    final d = await db;
    final paths = <String>[];
    await d.transaction((txn) async {
      for (final r in rows) {
        final id = (r['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final ex = await txn.query('visits',
            columns: ['dirty'], where: 'id = ?', whereArgs: [id]);
        final dirty = ex.isEmpty ? 0 : ((ex.first['dirty'] as int?) ?? 0);
        if (dirty > 0) continue;
        if ((r['deleted'] ?? 0) == 1) {
          final ph = await txn
              .query('visit_photos', where: 'visit_id = ?', whereArgs: [id]);
          for (final p in ph) {
            final s = (p['path'] ?? '').toString();
            if (s.isNotEmpty) paths.add(s);
          }
          await txn.delete('visit_photos',
              where: 'visit_id = ?', whereArgs: [id]);
          await txn.delete('visits', where: 'id = ?', whereArgs: [id]);
          continue;
        }
        final m = Visit.fromMap(r).toLocalMap();
        m['seq'] = (r['seq'] as num?)?.toInt() ?? 0;
        m['dirty'] = 0;
        if (ex.isEmpty) {
          await txn.insert('visits', m);
        } else {
          await txn.update('visits', m, where: 'id = ?', whereArgs: [id]);
        }
      }
    });
    return paths;
  }

  Future<void> addPhoto(String id, String visitId, String path,
      {required bool uploaded}) async {
    final d = await db;
    await d.insert(
        'visit_photos',
        {
          'id': id,
          'visit_id': visitId,
          'path': path,
          'uploaded': uploaded ? 1 : 0
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getPhotos(String visitId) async {
    final d = await db;
    return d.query('visit_photos', where: 'visit_id = ?', whereArgs: [visitId]);
  }

  Future<Map<String, dynamic>?> getPhoto(String id) async {
    final d = await db;
    final r = await d.query('visit_photos', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> setPhotoUploaded(String id) async {
    final d = await db;
    await d.update('visit_photos', {'uploaded': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deletePhotoRow(String id) async {
    final d = await db;
    await d.delete('visit_photos', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> pendingSyncCount() async {
    final d = await db;
    final a = Sqflite.firstIntValue(
        await d.rawQuery('SELECT COUNT(*) FROM visits WHERE dirty > 0')) ??
        0;
    final b = Sqflite.firstIntValue(await d.rawQuery(
        "SELECT COUNT(*) FROM visit_photos WHERE uploaded = 0 AND path != ''")) ??
        0;
    return a + b;
  }

  // ---------- الإعدادات ----------
  Future<String?> getSetting(String key) async {
    final d = await db;
    final r = await d.query('settings', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    final d = await db;
    await d.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}