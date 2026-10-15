import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'constants.dart';

const Color kFanColor = Color(0xFFFBBF24);

class HistoryPoint {
  final DateTime t;
  final double humidity;
  final double temperature;
  final int fanPwm;
  HistoryPoint(this.t, this.humidity, this.temperature, this.fanPwm);
}

class _RangeInfo {
  final String key;
  final String label;
  final Duration span;
  final int bucketSec;
  const _RangeInfo(this.key, this.label, this.span, this.bucketSec);
}

const _ranges = [
  _RangeInfo('1h', '1 jam', Duration(hours: 1), 10),
  _RangeInfo('24h', '24 jam', Duration(hours: 24), 60),
  _RangeInfo('7d', '7 hari', Duration(days: 7), 600),
];

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtDuration(int sec) {
  if (sec < 60) return '$sec dtk';
  final m = sec ~/ 60;
  if (m < 60) return '$m m';
  return '${m ~/ 60} j ${m % 60} m';
}

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  int _rangeIndex = 0;
  List<HistoryPoint> _points = [];
  bool _loaded = false;
  String? _error;
  Timer? _timer;
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final id = ++_reqId;
    final r = _ranges[_rangeIndex];
    try {
      final res = await http
          .get(Uri.parse('$kBaseUrl/api/history?range=${r.key}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['points'] as List).map((e) {
        final m = e as Map<String, dynamic>;
        return HistoryPoint(
          DateTime.parse(m['t'] as String).toLocal(),
          (m['humidity'] as num).toDouble(),
          (m['temperature'] as num).toDouble(),
          (m['fan_pwm'] as num).toInt(),
        );
      }).toList();
      if (!mounted || id != _reqId) return;
      setState(() {
        _points = list;
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted || id != _reqId) return;
      setState(() => _error = 'Tidak bisa mengambil data riwayat');
    }
  }

  void _selectRange(int i) {
    if (i == _rangeIndex) return;
    setState(() {
      _rangeIndex = i;
      _points = [];
      _loaded = false;
    });
    _load();
  }

  Widget _card(Widget child, {EdgeInsets? padding}) {
    return Container(
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kLine),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF15325C), Color(0xFF0F2646)],
        ),
      ),
      child: child,
    );
  }

  Widget _chip(int i) {
    final active = i == _rangeIndex;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => _selectRange(i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: active ? null : kCard,
            gradient: active
                ? const LinearGradient(
                    colors: [Color(0xFF6FA8FF), Color(0xFFA9CDFF)],
                  )
                : null,
            border: Border.all(color: kLine),
          ),
          child: Text(
            _ranges[i].label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: active ? const Color(0xFF08213F) : kMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: _card(
        padding: const EdgeInsets.all(12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: kMuted)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: kAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(Color c, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12, color: kMuted)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _ranges[_rangeIndex];
    final now = DateTime.now();
    final tMin = now.subtract(r.span);

    String avg = '--', peak = '--', fan = '--';
    if (_points.isNotEmpty) {
      final hs = _points.map((p) => p.humidity);
      avg = '${(hs.reduce((a, b) => a + b) / _points.length).toStringAsFixed(0)} %';
      peak = '${hs.reduce((a, b) => a > b ? a : b).toStringAsFixed(0)} %';
      final active = _points.where((p) => p.fanPwm > 0).length;
      fan = _fmtDuration(active * r.bucketSec);
    }

    final emptyText = _error ??
        (_loaded ? 'Belum ada data pada rentang ini' : 'Memuat...');

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            const Text(
              'Statistik',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            Row(children: [for (int i = 0; i < _ranges.length; i++) _chip(i)]),
            const SizedBox(height: 16),
            _card(
              Column(
                children: [
                  SizedBox(
                    height: 230,
                    width: double.infinity,
                    child: _points.isEmpty
                        ? Center(
                            child: Text(
                              emptyText,
                              style: const TextStyle(color: kMuted),
                            ),
                          )
                        : CustomPaint(
                            painter: _ChartPainter(
                              points: _points,
                              tMin: tMin,
                              tMax: now,
                              bucketSec: r.bucketSec,
                              dateLabels: r.key == '7d',
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _legend(kAccent, 'Kelembapan (%)'),
                      const SizedBox(width: 18),
                      _legend(kFanColor, 'Fan (%)'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _stat('Rata-rata', avg),
                const SizedBox(width: 10),
                _stat('Puncak', peak),
                const SizedBox(width: 10),
                _stat('Fan aktif', fan),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Durasi fan aktif adalah perkiraan dari data yang terekam.',
              style: TextStyle(fontSize: 11, color: kMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<HistoryPoint> points;
  final DateTime tMin;
  final DateTime tMax;
  final int bucketSec;
  final bool dateLabels;

  _ChartPainter({
    required this.points,
    required this.tMin,
    required this.tMax,
    required this.bucketSec,
    required this.dateLabels,
  });

  static const double _left = 34;
  static const double _right = 8;
  static const double _top = 8;
  static const double _bottom = 22;

  void _text(Canvas c, String s, Offset o, {bool alignRight = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: const TextStyle(color: kMuted, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(alignRight ? o.dx - tp.width : o.dx, o.dy));
  }

  String _label(DateTime t) =>
      dateLabels ? '${_two(t.day)}/${_two(t.month)}' : '${_two(t.hour)}:${_two(t.minute)}';

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - _left - _right;
    final h = size.height - _top - _bottom;
    final spanMs = tMax.difference(tMin).inMilliseconds.toDouble();

    double xOf(DateTime t) {
      final f = (t.difference(tMin).inMilliseconds / spanMs).clamp(0.0, 1.0);
      return _left + w * f;
    }

    double yOf(double v) => _top + h * (1 - v.clamp(0.0, 100.0) / 100);

    final grid = Paint()
      ..color = kLine
      ..strokeWidth = 1;
    for (final v in [0, 25, 50, 75, 100]) {
      final y = yOf(v.toDouble());
      canvas.drawLine(Offset(_left, y), Offset(size.width - _right, y), grid);
      _text(canvas, '$v', Offset(_left - 6, y - 6), alignRight: true);
    }

    final mid = tMin.add(Duration(milliseconds: (spanMs / 2).round()));
    final yLabel = size.height - _bottom + 6;
    _text(canvas, _label(tMin), Offset(_left, yLabel));
    _text(canvas, _label(mid), Offset(_left + w / 2 - 14, yLabel));
    _text(canvas, _label(tMax), Offset(size.width - _right, yLabel), alignRight: true);

    _series(canvas, kAccent, (p) => p.humidity, xOf, yOf);
    _series(canvas, kFanColor, (p) => p.fanPwm.toDouble(), xOf, yOf);
  }

  void _series(
    Canvas canvas,
    Color color,
    double Function(HistoryPoint) value,
    double Function(DateTime) xOf,
    double Function(double) yOf,
  ) {
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dot = Paint()..color = color;

    // Pecah garis di mana data terputus (misalnya backend sempat mati).
    final segments = <List<Offset>>[];
    DateTime? prev;
    for (final p in points) {
      final o = Offset(xOf(p.t), yOf(value(p)));
      if (prev == null || p.t.difference(prev).inSeconds > bucketSec * 3) {
        segments.add([o]);
      } else {
        segments.last.add(o);
      }
      prev = p.t;
    }

    for (final seg in segments) {
      if (seg.length == 1) {
        canvas.drawCircle(seg.first, 2.5, dot);
      } else {
        final path = Path()..moveTo(seg.first.dx, seg.first.dy);
        for (final o in seg.skip(1)) {
          path.lineTo(o.dx, o.dy);
        }
        canvas.drawPath(path, line);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}