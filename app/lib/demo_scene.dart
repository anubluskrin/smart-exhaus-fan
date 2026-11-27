import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'constants.dart';
import 'demo_models.dart';

class DemoScene extends StatefulWidget {
  final DemoSnapshot snapshot;
  final double? humidity;
  final double? temperature;
  final int? smokeDelta;
  final bool smokeAlert, online, isActive;
  final int fanPwm;
  final List<DemoTrendPoint> trend;
  const DemoScene({
    super.key,
    required this.snapshot,
    required this.humidity,
    this.temperature,
    required this.smokeDelta,
    required this.smokeAlert,
    required this.fanPwm,
    required this.online,
    required this.isActive,
    this.trend = const [],
  });

  @override
  State<DemoScene> createState() => _DemoSceneState();
}

class _DemoSceneState extends State<DemoScene>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant DemoScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.id != widget.snapshot.id) _motion.reset();
    _sync();
  }

  void _sync() {
    final animate =
        widget.online &&
        widget.isActive &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !_motion.isAnimating) {
      _motion.repeat();
    } else if (!animate && _motion.isAnimating) {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = switch (widget.snapshot.phase) {
      'shower' => 'Air mengalir',
      'recovery' => 'Pemulihan',
      'smoking' => 'Asap simulasi',
      'settling' when widget.smokeAlert => 'Menunggu udara bersih',
      _ => 'Pemulihan fan',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sensor simulasi · Fan fisik',
              style: TextStyle(color: kAccent, fontWeight: FontWeight.bold),
            ),
            Text(
              widget.online ? phase : 'Koneksi terputus',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 138,
              width: double.infinity,
              child: CustomPaint(
                painter: _ScenePainter(
                  widget,
                  _motion,
                  MediaQuery.disableAnimationsOf(context),
                ),
              ),
            ),
            Text(
              'PWM dilaporkan: ${widget.fanPwm}%${widget.online ? '' : ' · bacaan terakhir'}',
            ),
            Text(
              [
                if (widget.humidity != null)
                  '${widget.humidity!.toStringAsFixed(1)}% RH',
                if (widget.temperature != null)
                  '${widget.temperature!.toStringAsFixed(1)} °C',
                if (widget.smokeDelta != null)
                  'Asap Δ ${widget.smokeDelta} ADC',
              ].join(' · '),
            ),
            if (widget.snapshot.smoke)
              const Text(
                'Profil sintetis · bukan estimasi kadar asap atau jumlah perokok',
                style: TextStyle(color: kMuted),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScenePainter extends CustomPainter {
  final DemoScene scene;
  final Animation<double> motion;
  final bool still;
  _ScenePainter(this.scene, this.motion, this.still) : super(repaint: motion);

  @override
  void paint(Canvas canvas, Size size) {
    final t = still ? 0.0 : motion.value;
    final s = scene.snapshot;
    final paint = Paint();
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / 300, size.height / 138);
    paint.color = const Color(0xff162e47);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 300, 112),
        const Radius.circular(12),
      ),
      paint,
    );
    if (!s.smoke) {
      paint.color = const Color(0xff597b99);
      canvas.drawCircle(const Offset(99, 41), 13, paint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(80, 56, 38, 49),
          const Radius.circular(17),
        ),
        paint,
      );
      if (s.phase == 'shower') {
        paint.color = const Color(0xff8ad8ff);
        paint.strokeWidth = 2;
        for (var i = 0; i < 13; i++) {
          final y = 22 + (t * 320 + i * 17) % 78;
          canvas.drawLine(
            Offset(45 + i * 8, y),
            Offset(48 + i * 8, y + 7),
            paint,
          );
        }
      }
      paint.color = const Color(0xffb3def1).withValues(
        alpha: (((scene.humidity ?? 55) - 55) / 40)
            .clamp(0.12, 0.65)
            .toDouble(),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(28, 12, 143, 96),
          const Radius.circular(8),
        ),
        paint,
      );
    } else {
      final density = ((scene.smokeDelta ?? 0) / 1000)
          .clamp(0.0, 0.72)
          .toDouble();
      for (var i = 0; i < s.people; i++) {
        final x = 45.0 + i * 51;
        paint.color = kMuted;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 95, 23, 5),
            const Radius.circular(2),
          ),
          paint,
        );
        final age = s.sourceAge(i);
        if (age < 0 || age >= 120 || s.phase != 'smoking') continue;
        for (var j = 0; j < 5; j++) {
          final rise = (t * 4 + j / 5) % 1;
          paint.color = const Color(
            0xffc6e4f5,
          ).withValues(alpha: density * (1 - rise));
          canvas.drawCircle(
            Offset(x + 21 + math.sin(rise * 9 + i) * 9, 92 - rise * 73),
            5 + rise * 15,
            paint,
          );
        }
      }
    }
    canvas.save();
    canvas.translate(243, 56);
    if (scene.fanPwm > 0) {
      canvas.rotate(t * math.pi * 2 * (1 + scene.fanPwm ~/ 10));
    }
    paint.color = kAccent;
    for (var i = 0; i < 4; i++) {
      canvas.drawOval(const Rect.fromLTWH(1, -7, 24, 14), paint);
      canvas.rotate(math.pi / 2);
    }
    canvas.restore();

    if (scene.trend.length > 1) {
      final path = Path();
      for (var i = 0; i < scene.trend.length; i++) {
        final point = scene.trend[i];
        final normalized = s.smoke
            ? (point.smoke ?? 0) / 1440
            : (point.humidity ?? 55) / 100;
        final x = 8 + 284 * i / (scene.trend.length - 1);
        final y = 135 - 20 * normalized.clamp(0.0, 1.0).toDouble();
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = kAccent
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) =>
      oldDelegate.scene != scene || oldDelegate.still != still;
}
