import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/app_colors.dart';
import '../home/home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..forward();
    _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
    _scale = Tween(begin: 0.8, end: 1.0)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutBack));

    Future.delayed(const Duration(milliseconds: 3200), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
      ));
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.navyLight, AppColors.navy, AppColors.navyDark],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: Column(
              children: [
                const Spacer(flex: 3),
                ScaleTransition(scale: _scale, child: const _Logo(size: 150)),
                const SizedBox(height: 28),
                Text('FieldPro',
                    style: GoogleFonts.poppins(
                        fontSize: 40,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                        color: Colors.white)),
                const SizedBox(height: 6),
                Text('SURVEY  •  MAP  •  REPORT',
                    style: GoogleFonts.poppins(
                        fontSize: 12,
                        letterSpacing: 3,
                        color: AppColors.goldLight)),
                const Spacer(flex: 4),
                Container(
                    width: 40,
                    height: 2,
                    color: AppColors.gold.withOpacity(0.7)),
                const SizedBox(height: 14),
                Text('Developed by',
                    style: GoogleFonts.poppins(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        color: Colors.white54)),
                const SizedBox(height: 4),
                Text('Eng. Saeed Al-Sourani',
                    style: GoogleFonts.poppins(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.gold)),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  final double size;
  const _Logo({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.navyLight, AppColors.navyDark],
        ),
        border: Border.all(color: AppColors.gold.withOpacity(0.8), width: 2),
        boxShadow: [
          BoxShadow(
              color: AppColors.gold.withOpacity(0.25),
              blurRadius: 40,
              spreadRadius: 2),
        ],
      ),
      child: CustomPaint(painter: _LogoPainter()),
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;

    // حدود الموقع (Polygon)
    final pts = [
      Offset(w * .18, w * .72),
      Offset(w * .40, w * .87),
      Offset(w * .82, w * .75),
      Offset(w * .72, w * .56),
      Offset(w * .28, w * .58),
    ];
    final poly = Path()..addPolygon(pts, true);
    canvas.drawPath(
        poly,
        Paint()
          ..color = Colors.white.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.02
          ..strokeJoin = StrokeJoin.round);
    for (final p in pts) {
      canvas.drawCircle(p, w * 0.028, Paint()..color = AppColors.goldLight);
    }

    // دبوس الخريطة
    final cx = w * .5, cy = w * .34, r = w * .2;
    final pin = Path.combine(
      PathOperation.union,
      Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r)),
      Path()
        ..moveTo(cx - r * .86, cy + r * .5)
        ..lineTo(cx, cy + r * 2.0)
        ..lineTo(cx + r * .86, cy + r * .5)
        ..close(),
    );
    canvas.drawPath(
        pin,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.goldLight, AppColors.gold],
          ).createShader(Rect.fromLTWH(0, 0, w, w)));
    canvas.drawCircle(
        Offset(cx, cy), r * .42, Paint()..color = AppColors.navyDark);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}