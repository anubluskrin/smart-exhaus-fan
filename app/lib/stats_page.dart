import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api_http.dart' as http;
import 'constants.dart';

const Color kFanColor = Color(0xFFFBBF24);
const Color kSmokeColor = Color(0xFF34D399);
const Color kSmokeAlertColor = Color(0xFFEF4444);

class HistoryPoint {
  final DateTime t;
  final double humidity;
  final double temperature;
  final int fanPwm;
  final int? smoke;
  final bool smokeAlert;

  HistoryPoint(
    this.t,
    this.humidity,
    this.temperature,
    this.fanPwm, {
    this.smoke,
    this.smokeAlert = false,
  });
}

class SmokeAxisBounds {
  final double minY;
  final double maxY;
  const SmokeAxisBounds(this.minY, this.maxY);
}

SmokeAxisBounds computeSmokeYAxisBounds(Iterable<int?> values) {
  int? minVal;
  int? maxVal;
  for (final v in values) {
    if (v == null) continue;
    minVal = minVal == null ? v : math.min(minVal, v);
    maxVal = maxVal == null ? v : math.max(maxVal, v);
  }
  if (minVal == null || maxVal == null) {
    return const SmokeAxisBounds(0, 300);
  }
  final rawMin = math.min(0, minVal);
  final rawMax = math.max(300, maxVal);
  final minY = (rawMin / 50).floor() * 50.0;
  final maxY = (rawMax / 50).ceil() * 50.0;
  return SmokeAxisBounds(minY, maxY <= minY ? minY + 100 : maxY);
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
  final bool isActive;
  const StatsPage({super.key, this.isActive = true});

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
  String _activeOrigin = originOf(kBaseUrl);

  @override
  void initState() {
    super.initState();
    sessionNotifier.addListener(_onSessionChange);
    _syncPolling(immediate: widget.isActive);
  }

  @override
  void didUpdateWidget(covariant StatsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _syncPolling(immediate: widget.isActive);
    }
  }

  @override
  void dispose() {
    sessionNotifier.removeListener(_onSessionChange);
    _timer?.cancel();
    super.dispose();
  }

  void _onSessionChange() {
    if (!mounted) return;
    final nextOrigin = originOf(kBaseUrl);
    final originChanged = nextOrigin != _activeOrigin;
    if (originChanged || !isAdminSession) {
      setState(() {
        _activeOrigin = nextOrigin;
        _points = [];
        _loaded = false;
        _error = null;
      });
      if (widget.isActive) _load();
    } else if (widget.isActive && _points.isEmpty) {
      _load();
    }
  }

  void _syncPolling({required bool immediate}) {
    _timer?.cancel();
    _timer = null;
    if (!widget.isActive) return;
    if (immediate) _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  Future<void> _load() async {
    if (kBaseUrl.isEmpty) {
      if (mounted) setState(() => _error = 'Alamat server belum diatur');
      return;
    }
    final id = ++_reqId;
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);
    final r = _ranges[_rangeIndex];

    try {
      final res = await http
          .getForSession(Uri.parse('$kBaseUrl/api/history?range=${r.key}'))
          .timeout(const Duration(seconds: 8));
      if (!mounted || id != _reqId || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) {
        return;
      }
      if (res.statusCode == 401) {
        setState(() {
          _points = [];
          _loaded = false;
          _error = 'Riwayat memerlukan akses Admin di Pengaturan';
        });
        return;
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['points'] as List).map((e) {
        final m = e as Map<String, dynamic>;
        return HistoryPoint(
          DateTime.parse(m['t'] as String).toLocal(),
          (m['humidity'] as num).toDouble(),
          (m['temperature'] as num).toDouble(),
          (m['fan_pwm'] as num).toInt(),
          smoke: (m['smoke'] as num?)?.toInt(),
          smokeAlert: m['smoke_alert'] == true,
        );
      }).toList();
      if (!mounted || id != _reqId || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) {
        return;
      }
      setState(() {
        _points = list;
        _loaded = true;
        _error = null;
      });
    } catch (_) {
      if (!mounted || id != _reqId || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) {
        return;
      }
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

    final hasSmokeData = _points.any((p) => p.smoke != null || p.smokeAlert);
    final smokeBounds = computeSmokeYAxisBounds(_points.map((p) => p.smoke));

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
            const SizedBox(height: 16),
            _card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sensor Asap (MQ-2 Delta)',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 190,
                    width: double.infinity,
                    child: _points.isEmpty || !hasSmokeData
                        ? Center(
                            child: Text(
                              _points.isEmpty
                                  ? emptyText
                                  : 'Belum ada data MQ-2 siap ukur pada rentang ini',
                              style: const TextStyle(color: kMuted),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : CustomPaint(
                            painter: _SmokeChartPainter(
                              points: _points,
                              tMin: tMin,
                              tMax: now,
                              bucketSec: r.bucketSec,
                              dateLabels: r.key == '7d',
                              bounds: smokeBounds,
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 14,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      _legend(kSmokeColor, 'Delta MQ-2'),
                      _legend(kSmokeAlertColor, 'Pernah alarm pada rentang ini'),
                    ],
                  ),
                ],
              ),
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

class _SmokeChartPainter extends CustomPainter {
  final List<HistoryPoint> points;
  final DateTime tMin;
  final DateTime tMax;
  final int bucketSec;
  final bool dateLabels;
  final SmokeAxisBounds bounds;

  _SmokeChartPainter({
    required this.points,
    required this.tMin,
    required this.tMax,
    required this.bucketSec,
    required this.dateLabels,
    required this.bounds,
  });

  static const double _left = 40;
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
    final ySpan = bounds.maxY - bounds.minY;

    double xOf(DateTime t) {
      final f = (t.difference(tMin).inMilliseconds / spanMs).clamp(0.0, 1.0);
      return _left + w * f;
    }

    double yOf(double v) {
      final f = ((v - bounds.minY) / ySpan).clamp(0.0, 1.0);
      return _top + h * (1 - f);
    }

    final grid = Paint()
      ..color = kLine
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final v = bounds.minY + (ySpan * i / 4);
      final y = yOf(v);
      canvas.drawLine(Offset(_left, y), Offset(size.width - _right, y), grid);
      _text(canvas, '${v.round()}', Offset(_left - 6, y - 6), alignRight: true);
    }

    if (bounds.minY < 0) {
      final zeroY = yOf(0);
      final zeroPaint = Paint()
        ..color = kMuted.withValues(alpha: 0.45)
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(_left, zeroY), Offset(size.width - _right, zeroY), zeroPaint);
    }

    final mid = tMin.add(Duration(milliseconds: (spanMs / 2).round()));
    final yLabel = size.height - _bottom + 6;
    _text(canvas, _label(tMin), Offset(_left, yLabel));
    _text(canvas, _label(mid), Offset(_left + w / 2 - 14, yLabel));
    _text(canvas, _label(tMax), Offset(size.width - _right, yLabel), alignRight: true);

    final line = Paint()
      ..color = kSmokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dot = Paint()..color = kSmokeColor;

    final segments = <List<Offset>>[];
    DateTime? prev;
    for (final p in points) {
      if (p.smoke == null) {
        prev = null;
        continue;
      }
      final o = Offset(xOf(p.t), yOf(p.smoke!.toDouble()));
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

    // Penanda bucket yang pernah mengalami alarm asap (BOOL_OR(smoke_alert)).
    final alertFill = Paint()..color = kSmokeAlertColor;
    final alertRing = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final p in points) {
      if (!p.smokeAlert) continue;
      final yVal = p.smoke?.toDouble() ?? 0.0;
      final center = Offset(xOf(p.t), yOf(yVal));
      canvas.drawCircle(center, 4.5, alertFill);
      canvas.drawCircle(center, 4.5, alertRing);
    }
  }

  @override
  bool shouldRepaint(covariant _SmokeChartPainter old) => true;
}
