import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/app_colors.dart';
import '../../core/database.dart';
import '../common/coming_soon_screen.dart';
import '../map/map_screen.dart';
import '../reports/reports_screen.dart';
import '../scan/document_scanner_screen.dart';
import '../scan/scan_to_excel_screen.dart';
import 'project.dart';
import 'project_files_screen.dart';

class ProjectDetailScreen extends StatefulWidget {
  final Project project;
  const ProjectDetailScreen({super.key, required this.project});

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  int _points = 0;
  int _areas = 0;
  int _files = 0;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    final id = widget.project.id!;
    final p = await AppDatabase.instance.countPoints(id);
    final a = await AppDatabase.instance.countAreas(id);
    final f = await AppDatabase.instance.countFiles(id);
    if (mounted) {
      setState(() {
        _points = p;
        _areas = a;
        _files = f;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final sections = <(String, IconData, String)>[
      ('الاستبيانات', Icons.fact_check_rounded, ''),
      ('الخرائط والنقاط', Icons.map_rounded,
      '$_points نقطة  •  $_areas منطقة'),
      ('التقارير', Icons.description_rounded, ''),
      ('المسح الضوئي', Icons.document_scanner_rounded, ''),
      ('الملفات المحفوظة', Icons.folder_copy_rounded, '$_files ملف'),
    ];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text(project.name,
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (project.client.isNotEmpty || project.location.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.navy,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (project.client.isNotEmpty)
                      Text('الجهة: ${project.client}',
                          style: GoogleFonts.cairo(color: Colors.white)),
                    if (project.location.isNotEmpty)
                      Text('الموقع: ${project.location}',
                          style:
                          GoogleFonts.cairo(color: AppColors.goldLight)),
                  ],
                ),
              ),
            for (final s in sections)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  tileColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                  leading: Icon(s.$2, color: AppColors.gold),
                  title: Text(s.$1,
                      style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark)),
                  subtitle: s.$3.isEmpty
                      ? null
                      : Text(s.$3, style: GoogleFonts.cairo(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () async {
                    Widget page;
                    switch (s.$1) {
                      case 'الخرائط والنقاط':
                        page = MapScreen(
                            projectId: project.id, projectName: project.name);
                        break;
                      case 'الملفات المحفوظة':
                        page = ProjectFilesScreen(projectId: project.id!);
                        break;
                      case 'الاستبيانات':
                        page = ScanToExcelScreen(projectId: project.id);
                        break;
                      case 'المسح الضوئي':
                        page = DocumentScannerScreen(projectId: project.id);
                        break;
                      case 'التقارير':
                        page = ReportsScreen(initialProject: project);
                        break;
                      default:
                        page = ComingSoonScreen(title: s.$1);
                    }
                    await Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => page));
                    _loadCounts();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}