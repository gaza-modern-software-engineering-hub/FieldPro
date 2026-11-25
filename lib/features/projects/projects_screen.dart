import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/app_colors.dart';
import '../../core/database.dart';
import 'project.dart';
import 'project_detail_screen.dart';
import 'package:intl/intl.dart' show DateFormat;
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  late Future<List<Project>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => _future = AppDatabase.instance.getProjects();

  Future<void> _openForm([Project? project]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProjectFormScreen(project: project)),
    );
    if (saved == true) setState(_load);
  }

  Future<void> _delete(Project p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('حذف المشروع', style: GoogleFonts.cairo()),
          content: Text('هل تريد حذف "${p.name}"؟',
              style: GoogleFonts.cairo()),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('إلغاء', style: GoogleFonts.cairo())),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('حذف',
                    style: GoogleFonts.cairo(color: Colors.red))),
          ],
        ),
      ),
    );
    if (ok == true) {
      await AppDatabase.instance.deleteProject(p.id!);
      setState(_load);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text('المشاريع',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.gold,
          foregroundColor: AppColors.navyDark,
          onPressed: () => _openForm(),
          icon: const Icon(Icons.add_rounded),
          label: Text('مشروع جديد',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: FutureBuilder<List<Project>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final projects = snap.data ?? [];
            if (projects.isEmpty) return const _EmptyState();
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
              itemCount: projects.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _ProjectTile(
                project: projects[i],
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        ProjectDetailScreen(project: projects[i]))),
                onEdit: () => _openForm(projects[i]),
                onDelete: () => _delete(projects[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open_rounded,
              size: 72, color: AppColors.gold.withOpacity(0.8)),
          const SizedBox(height: 12),
          Text('لا توجد مشاريع بعد',
              style: GoogleFonts.cairo(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDark)),
          const SizedBox(height: 4),
          Text('اضغط على "مشروع جديد" للبدء',
              style: GoogleFonts.cairo(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Project project;
  final VoidCallback onTap, onEdit, onDelete;
  const _ProjectTile({
    required this.project,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('yyyy/MM/dd').format(project.createdAt);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: AppColors.navy.withOpacity(0.07),
              blurRadius: 16,
              offset: const Offset(0, 6)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(
                    colors: [AppColors.navyLight, AppColors.navyDark],
                  ),
                ),
                child: const Icon(Icons.folder_special_rounded,
                    color: AppColors.gold),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textDark)),
                    Text(
                        [
                          if (project.client.isNotEmpty) project.client,
                          if (project.location.isNotEmpty) project.location,
                        ].join('  •  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                            fontSize: 12, color: AppColors.textMuted)),
                    Text(date,
                        style: GoogleFonts.cairo(
                            fontSize: 11, color: AppColors.textMuted)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'edit',
                      child: Text('تعديل', style: GoogleFonts.cairo())),
                  PopupMenuItem(
                      value: 'delete',
                      child: Text('حذف', style: GoogleFonts.cairo())),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProjectFormScreen extends StatefulWidget {
  final Project? project;
  const ProjectFormScreen({super.key, this.project});

  @override
  State<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _ProjectFormScreenState extends State<ProjectFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.project?.name);
  late final _client = TextEditingController(text: widget.project?.client);
  late final _location = TextEditingController(text: widget.project?.location);
  late final _notes = TextEditingController(text: widget.project?.notes);

  @override
  void dispose() {
    _name.dispose();
    _client.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final old = widget.project;
    final p = Project(
      id: old?.id,
      name: _name.text.trim(),
      client: _client.text.trim(),
      location: _location.text.trim(),
      notes: _notes.text.trim(),
      createdAt: old?.createdAt,
    );
    if (old == null) {
      await AppDatabase.instance.insertProject(p);
    } else {
      await AppDatabase.instance.updateProject(p);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
    labelText: label,
    labelStyle: GoogleFonts.cairo(),
    prefixIcon: Icon(icon, color: AppColors.navyLight),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none),
  );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          title: Text(
              widget.project == null ? 'مشروع جديد' : 'تعديل المشروع',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextFormField(
                controller: _name,
                decoration: _dec('اسم المشروع *', Icons.title_rounded),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'الرجاء إدخال اسم المشروع'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                  controller: _client,
                  decoration: _dec('الجهة / العميل', Icons.business_rounded)),
              const SizedBox(height: 14),
              TextFormField(
                  controller: _location,
                  decoration: _dec('الموقع', Icons.place_rounded)),
              const SizedBox(height: 14),
              TextFormField(
                  controller: _notes,
                  maxLines: 4,
                  decoration: _dec('ملاحظات', Icons.notes_rounded)),
              const SizedBox(height: 24),
              SizedBox(
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navy,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _save,
                  child: Text('حفظ',
                      style: GoogleFonts.cairo(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}