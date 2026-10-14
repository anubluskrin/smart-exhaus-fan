import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'air_flow.dart';
import 'constants.dart';
import 'stats_page.dart';

// Dengan "adb reverse", HP menjangkau backend lewat localhost.
// (Untuk emulator Android, ganti menjadi http://10.0.2.2:3000)
const String kBaseUrl = 'http://localhost:3000';

const Color kBg = Color(0xFF0B1D3A);
const Color kCard = Color(0xFF112A4F);
const Color kLine = Color(0xFF1F3F6E);
const Color kMuted = Color(0xFF8FA9D0);
const Color kAccent = Color(0xFF7DB8FF);

Color humidityColor(double h) {
  if (h < 60) return const Color(0xFF7DB8FF); // nyaman
  if (h < 70) return const Color(0xFFFACC15); // waspada
  if (h < 90) return const Color(0xFFFB923C); // tinggi
  return const Color(0xFFEF4444); // kritis
}

String humidityLabel(double h) {
  if (h < 60) return 'nyaman';
  if (h < 70) return 'waspada';
  if (h < 90) return 'tinggi';
  return 'kritis';
}

class FanStatus {
  final bool online;
  final int lastSeenSec;
  final double? humidity;
  final double? temperature;
  final int? fanPwm;
  final String? mode;
  final String? state;

  FanStatus({
    required this.online,
    required this.lastSeenSec,
    this.humidity,
    this.temperature,
    this.fanPwm,
    this.mode,
    this.state,
  });

  factory FanStatus.fromJson(Map<String, dynamic> j) {
    final latest = j['latest'] as Map<String, dynamic>?;
    return FanStatus(
      online: j['online'] == true,
      lastSeenSec: (j['last_seen_sec_ago'] as num?)?.toInt() ?? 0,
      humidity: (latest?['humidity'] as num?)?.toDouble(),
      temperature: (latest?['temperature'] as num?)?.toDouble(),
      fanPwm: (latest?['fan_pwm'] as num?)?.toInt(),
      mode: latest?['mode'] as String?,
      state: latest?['state'] as String?,
    );
  }
}

void main() => runApp(const BathfanApp());

class BathfanApp extends StatelessWidget {
  const BathfanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Exhaust Fan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent),
      ),
      home: const HomeShell(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  FanStatus? _status;
  String? _error;
  Timer? _timer;
  String? _pendingMode;
  double _manualSpeed = 50;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

    Future<bool> _post(String path, Map<String, dynamic> body) async {
    try {
      final res = await http
          .post(
            Uri.parse('$kBaseUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Perintah gagal dikirim')),
        );
      }
      return false;
    }
  }

  Future<void> _setMode(String mode) async {
    setState(() => _pendingMode = mode);
    if (mode == 'manual') {
      // Mulai dari kecepatan saat ini, supaya fan tidak mendadak berhenti.
      final current = (_status?.fanPwm ?? 0).toDouble();
      setState(() => _manualSpeed = current);
      await _post('/api/speed', {'pwm': current.round()});
    }
    final ok = await _post('/api/mode', {'mode': mode});
    if (!ok && mounted) {
      setState(() => _pendingMode = null);
      return;
    }
    // Setelah beberapa detik, tampilan kembali mengikuti data dari perangkat.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _pendingMode = null);
    });
  }

  Future<void> _sendSpeed(double v) async {
    await _post('/api/speed', {'pwm': v.round()});
  }

  Future<void> _refresh() async {
    try {
      final res = await http
          .get(Uri.parse('$kBaseUrl/api/status'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _status = FanStatus.fromJson(data);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Tidak bisa menghubungi backend');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final h = s?.humidity;
    final color = h == null ? kAccent : humidityColor(h);
    final mode = _pendingMode ?? s?.mode ?? 'auto';

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: ListView(
            children: [
              const Text(
                'Kamar Mandi',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              _subtitle(s),
              const SizedBox(height: 16),
              _hero(s, color),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _fanCard(s)),
                  const SizedBox(width: 12),
                  Expanded(child: _infoCard(s)),
                ],
              ),
              const SizedBox(height: 16),
              _modeSelector(mode),
              if (mode == 'manual') ...[
                const SizedBox(height: 16),
                _speedCard(),
              ],

              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Color(0xFFF87171)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

    Widget _modeSelector(String mode) {
    Widget item(String value, String label) {
      final active = mode == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => _setMode(value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: active
                  ? const LinearGradient(
                      colors: [Color(0xFF6FA8FF), Color(0xFFA9CDFF)],
                    )
                  : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: active ? const Color(0xFF08213F) : kMuted,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kLine),
      ),
      child: Row(children: [item('auto', 'Auto'), item('manual', 'Manual')]),
    );
  }

  Widget _speedCard() {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Kecepatan manual', style: TextStyle(fontSize: 15)),
              Text(
                '${_manualSpeed.round()} %',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: kAccent,
                ),
              ),
            ],
          ),
          Slider(
            value: _manualSpeed,
            min: 0,
            max: 100,
            divisions: 20,
            onChanged: (v) => setState(() => _manualSpeed = v),
            onChangeEnd: _sendSpeed,
          ),
        ],
      ),
    );
  }

  Widget _subtitle(FanStatus? s) {
    final online = s?.online ?? false;
    return Text.rich(
      TextSpan(
        style: const TextStyle(fontSize: 13, color: kMuted),
        children: [
          const TextSpan(text: 'fan01 · '),
          TextSpan(
            text: online ? '● Online' : '● Offline',
            style: TextStyle(
              color: online ? const Color(0xFF4ADE80) : const Color(0xFFF87171),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero(FanStatus? s, Color color) {
    final h = s?.humidity;
    final number = h == null ? '--' : h.toStringAsFixed(1).replaceAll('.', ',');
    return Container(
      width: double.infinity,
      height: 300,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: kLine),
        gradient: RadialGradient(
          center: Alignment.bottomCenter,
          radius: 1.1,
          colors: [color.withValues(alpha: 0.45), kBg],
        ),
      ),
      child: Stack(
        children: [
                    Positioned.fill(
            child: AirFlow(color: color, speed: (s?.fanPwm ?? 0) / 100),
          ),
          const Positioned(
            top: 20,
            left: 20,
            child: Text(
              'Kelembapan',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Positioned(
            top: 14,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                s?.state ?? '--',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    children: [
                      TextSpan(text: number, style: const TextStyle(fontSize: 68)),
                      const TextSpan(text: ' %', style: TextStyle(fontSize: 26)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  h == null ? 'Menunggu data...' : 'Kelembapan ${humidityLabel(h)}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  s?.temperature == null
                      ? ''
                      : 'Suhu ${s!.temperature!.toStringAsFixed(1).replaceAll('.', ',')} °C',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFD6E4FA)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.all(14),
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

  Widget _fanCard(FanStatus? s) {
    final pwm = s?.fanPwm;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Kecepatan fan', style: TextStyle(fontSize: 13, color: kMuted)),
          const SizedBox(height: 4),
          Text(
            pwm == null ? '--' : '$pwm %',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: kAccent,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (pwm ?? 0) / 100,
              minHeight: 8,
              backgroundColor: kLine,
              color: kAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(FanStatus? s) {
    final mode = s?.mode;
    final modeText = mode == null
        ? '--'
        : mode[0].toUpperCase() + mode.substring(1);
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Mode', style: TextStyle(fontSize: 13, color: kMuted)),
          const SizedBox(height: 4),
          Text(
            modeText,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: kAccent,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            s == null ? '' : 'Data ${s.lastSeenSec} dtk lalu',
            style: const TextStyle(fontSize: 13, color: kMuted),
          ),
        ],
      ),
    );
  }
}


// navbar

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          DashboardPage(),
          StatsPage(),
          _ComingSoon('Jadwal Standby'),
          _ComingSoon('Pengaturan'),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: const Color(0xFF0D2347),
        indicatorColor: kLine,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.water_drop_outlined),
            selectedIcon: Icon(Icons.water_drop),
            label: 'Dashboard',
          ),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Statistik'),
          NavigationDestination(icon: Icon(Icons.schedule), label: 'Jadwal'),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Pengaturan',
          ),
        ],
      ),
    );
  }
}

class _ComingSoon extends StatelessWidget {
  final String title;
  const _ComingSoon(this.title);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Text(
            '$title\n(segera hadir)',
            textAlign: TextAlign.center,
            style: const TextStyle(color: kMuted, fontSize: 16),
          ),
        ),
      ),
    );
  }
}