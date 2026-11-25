import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/app_colors.dart';
import '../../core/database.dart';
import '../common/coming_soon_screen.dart';
import '../projects/projects_screen.dart';
import '../scan/scan_to_excel_screen.dart';
import '../scan/document_scanner_screen.dart';
import '../map/map_screen.dart';
import '../audio_report/audio_report_screen.dart';
import '../reports/reports_screen.dart';
import '../visits/visits_screen.dart';
import '../settings/settings_screen.dart';

class _Service {
  final String title;
  final String subtitle;
  final IconData icon;
  const _Service(this.title, this.subtitle, this.icon);
}

const _services = <_Service>[
  _Service('الخرائط', 'نقاط GPS وحدود ومساحات', Icons.map_rounded),
  _Service('التقرير الصوتي', 'تسجيل ميداني وتلخيص AI', Icons.mic_rounded),
  _Service('الزيارات', 'سجل الزيارات الميدانية المشترك',
      Icons.assignment_turned_in_rounded),
  _Service('الاستبيانات', 'تصوير وتحويل إلى Excel', Icons.fact_check_rounded),
  _Service('التقارير', 'تقارير احترافية جاهزة', Icons.description_rounded),
  _Service('المسح الضوئي', 'تحويل الأوراق إلى PDF', Icons.document_scanner_rounded),
  _Service('المشاريع', 'سجل كل أعمالك', Icons.folder_special_rounded),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, int> _stats = {};

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final s = await AppDatabase.instance.stats();
      if (mounted) setState(() => _stats = s);
    } catch (_) {}
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _loadStats();
  }

  Widget _stat(String label, String key, IconData icon) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.gold, size: 20),
          const SizedBox(height: 4),
          Text('${_stats[key] ?? 0}',
              style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          Text(label,
              style: GoogleFonts.cairo(
                  color: AppColors.goldLight, fontSize: 11)),
        ],
      ),
    ),
  );

  Widget _header() => Container(
    width: double.infinity,
    padding: EdgeInsets.fromLTRB(
        24, MediaQuery.of(context).padding.top + 24, 24, 24),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [AppColors.navyLight, AppColors.navyDark],
      ),
      borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.gold.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.gold.withOpacity(0.6)),
              ),
              child: const Icon(Icons.location_on_rounded,
                  color: AppColors.gold, size: 24),
            ),
            const SizedBox(width: 12),
            Text('FieldPro',
                style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.settings_rounded,
                  color: AppColors.gold),
              onPressed: () => _open(const SettingsScreen()),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text('أهلاً بك',
            style: GoogleFonts.cairo(
                fontSize: 15, color: AppColors.goldLight)),
        Text('م. سعيد الصوراني',
            style: GoogleFonts.cairo(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        const SizedBox(height: 14),
        Row(
          children: [
            _stat('مشاريع', 'projects', Icons.folder_special_rounded),
            const SizedBox(width: 8),
            _stat('نقاط', 'points', Icons.location_on_rounded),
            const SizedBox(width: 8),
            _stat('مناطق', 'areas', Icons.polyline_rounded),
            const SizedBox(width: 8),
            _stat('ملفات', 'files', Icons.insert_drive_file_rounded),
          ],
        ),
      ],
    ),
  );

  Widget _page(String title) {
    switch (title) {
      case 'المشاريع':
        return const ProjectsScreen();
      case 'الاستبيانات':
        return const ScanToExcelScreen();
      case 'المسح الضوئي':
        return const DocumentScannerScreen();
      case 'الخرائط':
        return const MapScreen();
      case 'التقارير':
        return const ReportsScreen();
      case 'التقرير الصوتي':
        return const AudioReportScreen();
      case 'الزيارات':
        return const VisitsScreen();
      default:
        return ComingSoonScreen(title: title);
    }
  }

  Widget _card(_Service s) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(24),
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _open(_page(s.title)),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
                color: AppColors.navy.withOpacity(0.07),
                blurRadius: 18,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.navyLight, AppColors.navyDark],
                ),
              ),
              child: Icon(s.icon, color: AppColors.gold, size: 28),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title,
                    style: GoogleFonts.cairo(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDark)),
                const SizedBox(height: 2),
                Text(s.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                        fontSize: 12, color: AppColors.textMuted)),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            _header(),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.95,
                ),
                itemCount: _services.length,
                itemBuilder: (_, i) => _card(_services[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}