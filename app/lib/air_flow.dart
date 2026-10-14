import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Garis-garis udara yang mengalir dari bawah ke atas.
/// [color] mengikuti kelembapan, [speed] (0 sampai 1) mengikuti kecepatan fan.
class AirFlow extends StatefulWidget {
  final Color color;
  final double speed;

  const AirFlow({super.key, required this.color, required this.speed});

  @override
  State<AirFlow> createState() => _AirFlowState();
}

class _AirFlowState extends State<AirFlow> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final pxPerSec = 12 + 200 * widget.speed.clamp(0.0, 1.0);
    _offset.value += dt * pxPerSec;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hormati pengaturan "kurangi gerakan" di HP.
    _ticker.muted = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _FlowPainter(_offset, widget.color),
        ),
      ),
    );
  }
}

class _FlowPainter extends CustomPainter {
  final ValueNotifier<double> offset;
  final Color color;

  _FlowPainter(this.offset, this.color) : super(repaint: offset);

  static const int _lines = 7;
  static const double _dash = 18;
  static const double _gap = 32;

  @override
  void paint(Canvas canvas, Size size) {
    const period = _dash + _gap;

    for (int i = 0; i < _lines; i++) {
      final baseX = size.width * (i + 0.5) / _lines;
      final amp = 10.0 + (i % 3) * 6;
      final phase = i * 0.9;

      final path = Path()..moveTo(baseX, size.height + 20);
      for (double y = size.height + 20; y >= -20; y -= 6) {
        final x = baseX +
            amp * math.sin(y / size.height * 2 * math.pi * 1.4 + phase);
        path.lineTo(x, y);
      }

      final paint = Paint()
        ..color = color.withValues(alpha: 0.35 + (i % 3) * 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + (i % 3) * 0.8
        ..strokeCap = StrokeCap.round;

      final shift = (offset.value + i * 13) % period;
      for (final metric in path.computeMetrics()) {
        for (double s = shift - period; s < metric.length; s += period) {
          final a = math.max(0.0, s);
          final b = math.min(metric.length, s + _dash);
          if (b > a) {
            canvas.drawPath(metric.extractPath(a, b), paint);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FlowPainter old) => old.color != color;
}