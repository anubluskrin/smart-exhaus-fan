import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'air_flow.dart';
import 'api_http.dart' as http;
import 'constants.dart';
import 'demo_models.dart';
import 'demo_panel.dart';
import 'demo_scene.dart';
import 'feedback_page.dart';
import 'schedules_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

class FanStatus {
  final bool online;
  final int lastSeenSec;
  final bool hasLatest;
  final double? humidity;
  final double? temperature;
  final int? fanPwm;
  final String? mode;
  final String? state;
  final bool power;
  final int? smoke;
  final bool smokeAlert;
  final bool smokeReady;
  final DateTime? sampleTime;
  final String device;
  final DemoSnapshot? demo;
  final bool demoAvailable, sensorOk, standby;

  FanStatus({
    required this.online,
    required this.lastSeenSec,
    this.hasLatest = true,
    this.humidity,
    this.temperature,
    this.fanPwm,
    this.mode,
    this.state,
    this.power = true,
    this.smoke,
    this.smokeAlert = false,
    this.smokeReady = false,
    this.sampleTime,
    this.device = 'fan01',
    this.demo,
    this.demoAvailable = false,
    this.sensorOk = false,
    this.standby = false,
  });

  factory FanStatus.fromJson(Map<String, dynamic> j) {
    final latest = j['latest'] as Map<String, dynamic>?;
    return FanStatus(
      online: j['online'] == true,
      lastSeenSec: (j['last_seen_sec_ago'] as num?)?.toInt() ?? 0,
      hasLatest: latest != null,
      humidity: (latest?['humidity'] as num?)?.toDouble(),
      temperature: (latest?['temperature'] as num?)?.toDouble(),
      fanPwm: (latest?['fan_pwm'] as num?)?.toInt(),
      mode: latest?['mode'] as String?,
      state: latest?['state'] as String?,
      power: (latest?['power'] as bool?) ?? true,
      smoke: (latest?['smoke'] as num?)?.toInt(),
      smokeAlert: latest?['smoke_alert'] == true,
      smokeReady: latest?['smoke_ready'] == true,
      sampleTime: DateTime.tryParse((latest?['time'] as String?) ?? '')?.toLocal(),
      device: j['device'] as String? ?? 'fan01',
      demo: DemoSnapshot.fromJson(latest?['demo']),
      demoAvailable: j['demo_available'] == true,
      sensorOk: latest?['sensor_ok'] == true,
      standby: latest?['standby'] == true,
    );
  }
}

enum SmokeUiState { noData, offline, unavailable, warmingUp, alert, normal }

class SmokeUiInfo {
  final SmokeUiState state;
  final String title;
  final String detail;
  final Color color;

  const SmokeUiInfo({
    required this.state,
    required this.title,
    required this.detail,
    required this.color,
  });
}

String formatAgeShort(int sec) {
  final clamped = math.max(0, sec);
  if (clamped < 60) return '$clamped dtk';
  final mins = clamped ~/ 60;
  if (mins < 60) return '$mins mnt';
  return '${mins ~/ 60} jam ${mins % 60} mnt';
}

int effectiveAgeSec(FanStatus s, DateTime fetchedAt, DateTime now) {
  final extra = math.max(0, now.difference(fetchedAt).inSeconds);
  return math.max(0, s.lastSeenSec) + extra;
}

bool isEffectivelyOnline(
  FanStatus? s,
  DateTime? fetchedAt,
  DateTime now, {
  bool hasRefreshError = false,
}) {
  if (s == null || !s.hasLatest || !s.online || hasRefreshError || fetchedAt == null) {
    return false;
  }
  return effectiveAgeSec(s, fetchedAt, now) < 20;
}

SmokeUiInfo evaluateSmokeUi(
  FanStatus? s, {
  bool? effectiveOnline,
  int? ageSec,
}) {
  if (s == null || !s.hasLatest) {
    return const SmokeUiInfo(
      state: SmokeUiState.noData,
      title: 'Belum ada data',
      detail: 'Menunggu data sensor pertama dari perangkat.',
      color: kMuted,
    );
  }

  final online = effectiveOnline ?? s.online;
  if (!online) {
    final age = ageSec ?? s.lastSeenSec;
    return SmokeUiInfo(
      state: SmokeUiState.offline,
      title: 'Offline',
      detail: 'Bacaan terakhir ${formatAgeShort(age)} lalu.',
      color: const Color(0xFFF87171),
    );
  }

  if (s.smoke == null) {
    return const SmokeUiInfo(
      state: SmokeUiState.unavailable,
      title: 'Data MQ-2 tidak tersedia',
      detail: 'Perangkat/data ini tidak menyertakan bacaan sensor asap.',
      color: kMuted,
    );
  }

  if (!s.smokeReady) {
    return SmokeUiInfo(
      state: SmokeUiState.warmingUp,
      title: 'Pemanasan',
      detail: 'Sensor MQ-2 kalibrasi awal (delta ${s.smoke}).',
      color: const Color(0xFFFACC15),
    );
  }

  if (s.smokeAlert) {
    return SmokeUiInfo(
      state: SmokeUiState.alert,
      title: 'Asap terdeteksi',
      detail: 'Alarm asap aktif (delta ${s.smoke}) · Fan dilaporkan ${s.fanPwm ?? 0} %',
      color: const Color(0xFFEF4444),
    );
  }

  return SmokeUiInfo(
    state: SmokeUiState.normal,
    title: 'Normal',
    detail: 'Udara bersih (delta ${s.smoke}).',
    color: const Color(0xFF4ADE80),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initAppConfig();
  runApp(const BathfanApp());
}

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
  final bool isActive;
  final ValueChanged<({String device, String id})>? onDemoRun;
  const DashboardPage({super.key, this.isActive = true, this.onDemoRun});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  FanStatus? _status;
  DateTime? _fetchedAt;
  String? _error;
  Timer? _timer;
  Timer? _pendingModeTimer;
  Timer? _pendingPowerTimer;
  String? _pendingMode;
  double _manualSpeed = 50;
  bool? _pendingPower;
  String _activeOrigin = originOf(kBaseUrl);
  int _refreshId = 0;
  bool _refreshInFlight = false;
  bool _showDemoPanel = false;
  DemoRequest? _demoRequest;
  Timer? _demoDeadline;
  String? _demoError, _trendRun;
  DateTime? _trendTime;
  final _demoTrend = <DemoTrendPoint>[];
  DemoEvidence? _demoEvidence;
  String? _demoVerdict;

  @override
  void initState() {
    super.initState();
    sessionNotifier.addListener(_onSessionChange);
    _syncPolling(immediate: widget.isActive);
  }

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _syncPolling(immediate: widget.isActive);
    }
  }

  @override
  void dispose() {
    sessionNotifier.removeListener(_onSessionChange);
    _timer?.cancel();
    _pendingModeTimer?.cancel();
    _pendingPowerTimer?.cancel();
    _demoDeadline?.cancel();
    super.dispose();
  }

  void _onSessionChange() {
    if (!mounted) return;
    final nextOrigin = originOf(kBaseUrl);
    final originChanged = nextOrigin != _activeOrigin;
    final clearedProtected = originChanged || !isAdminSession;
    _refreshId++;
    _refreshInFlight = false;
    _demoDeadline?.cancel();
    setState(() {
      _demoRequest = null;
      _demoError = null;
      _showDemoPanel = false;
      _demoEvidence = null;
      _demoVerdict = null;
      if (originChanged) {
        _activeOrigin = nextOrigin;
      }
      if (clearedProtected) {
        _status = null;
        _fetchedAt = null;
        _error = null;
        _demoTrend.clear();
        _trendRun = null;
        _trendTime = null;
      }
      _pendingMode = null;
      _pendingPower = null;
    });
    if ((originChanged || (!isAdminSession && widget.isActive)) && widget.isActive) {
      _refresh();
    }
  }

  void _syncPolling({required bool immediate}) {
    _refreshId++;
    _refreshInFlight = false;
    _timer?.cancel();
    _timer = null;
    if (!widget.isActive) return;
    if (immediate) _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<bool> _postAdmin(String path, Map<String, dynamic> body) async {
    if (!isAdminSession || kBaseUrl.isEmpty) return false;
    try {
      final res = await http
          .postAdmin(
            Uri.parse('$kBaseUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Perintah gagal dikirim')),
        );
      }
      return false;
    }
  }

  Future<void> _setMode(String mode) async {
    if (!isAdminSession) return;
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);

    setState(() => _pendingMode = mode);
    if (mode == 'manual') {
      // Mulai dari kecepatan saat ini, supaya fan tidak mendadak berhenti.
      final current = (_status?.fanPwm ?? 0).toDouble();
      setState(() => _manualSpeed = current);
      final speedOk = await _postAdmin('/api/speed', {'pwm': current.round()});
      if (!speedOk ||
          !mounted ||
          kSessionEpoch != epoch ||
          !isAdminSession ||
          originOf(kBaseUrl) != origin) {
        if (mounted) setState(() => _pendingMode = null);
        return;
      }
    }

    final ok = await _postAdmin('/api/mode', {'mode': mode});
    if (!ok && mounted) {
      setState(() => _pendingMode = null);
      return;
    }
    // Setelah beberapa detik, tampilan kembali mengikuti data dari perangkat.
    _pendingModeTimer?.cancel();
    _pendingModeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && kSessionEpoch == epoch) {
        setState(() => _pendingMode = null);
      }
    });
  }

  Future<void> _setPower(bool on) async {
    if (!isAdminSession) return;
    final epoch = kSessionEpoch;
    setState(() => _pendingPower = on);
    final ok = await _postAdmin('/api/power', {'on': on});
    if (!ok && mounted) {
      setState(() => _pendingPower = null);
      return;
    }
    _pendingPowerTimer?.cancel();
    _pendingPowerTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && kSessionEpoch == epoch) {
        setState(() => _pendingPower = null);
      }
    });
  }

  Future<void> _sendSpeed(double v) async {
    if (!isAdminSession) return;
    await _postAdmin('/api/speed', {'pwm': v.round()});
  }

  Future<void> _refresh() async {
    if (_refreshInFlight) return;
    if (kBaseUrl.isEmpty) {
      if (mounted) {
        setState(() => _error = 'Alamat server belum diatur di Pengaturan.');
      }
      return;
    }
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);
    final requestId = ++_refreshId;
    _refreshInFlight = true;
    bool current() => mounted && requestId == _refreshId &&
        epoch == kSessionEpoch && origin == originOf(kBaseUrl);
    try {
      final res = await http
          .getForSession(Uri.parse('$kBaseUrl/api/status'))
          .timeout(const Duration(seconds: 5));

      if (!current()) {
        return;
      }

      if (res.statusCode == 401) {
        setState(() {
          _status = null;
          _fetchedAt = null;
          _error = 'Server membutuhkan kunci Admin di tab Pengaturan.';
        });
        return;
      }

      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (!current()) {
        return;
      }
      final status = FanStatus.fromJson(data);
      setState(() {
        _status = status;
        _observeDemo(status);
        _fetchedAt = DateTime.now();
        _error = null;
      });
      final runId = status.demo?.id;
      if (runId != null) widget.onDemoRun?.call((device: status.device, id: runId));
    } catch (e) {
      if (!current()) {
        return;
      }
      setState(() => _error = 'Gagal memperbarui data ($e)');
    } finally {
      if (_refreshId == requestId) _refreshInFlight = false;
    }
  }

  void _observeDemo(FanStatus status) {
    final run = status.demo;
    final pending = _demoRequest;
    if (!status.online) _demoEvidence?.invalidate('koneksi terputus');
    if (status.online && run?.active == true) {
      if (_trendRun != run!.id) {
        _trendRun = run.id;
        _trendTime = null;
        _demoTrend.clear();
      }
      if (_showDemoPanel) {
        if (_demoEvidence?.runId != run.id) {
          _demoEvidence = DemoEvidence(run);
          _demoVerdict = null;
        }
        _demoEvidence!.observe(run, humidity: status.humidity, smoke: status.smoke,
          alarm: status.smokeAlert, pwm: status.fanPwm, state: status.state,
          autoControl: status.power && status.mode == 'auto' && !status.standby);
      }
      if (_trendTime != status.sampleTime) {
        _trendTime = status.sampleTime;
        _demoTrend.add((humidity: status.humidity, smoke: status.smoke));
        if (_demoTrend.length > 120) _demoTrend.removeAt(0);
      }
    }
    if (status.online && run?.endReason != null && run?.id == _demoEvidence?.runId) {
      _demoVerdict = _demoEvidence?.finish(run?.endReason, finalIdle: run?.finalIdle == true);
      _demoEvidence = null;
    }
    if (pending == null || run == null || !status.online) return;
    final confirmed = run.id == pending.id &&
        (pending.stop ? !run.active && run.endReason != null : run.active || run.endReason != null);
    final conflict = run.active && run.id != pending.id;
    if (confirmed || conflict) {
      _demoDeadline?.cancel();
      _demoRequest = null;
      _demoError = conflict ? 'Perangkat sedang menjalankan skenario lain' : null;
    }
  }

  bool get _demoAdminAllowed =>
      isAdminSession && (isEffectiveDebugMode || kBaseUrl.startsWith('https://'));

  Future<void> _sendDemo({DemoPreset? preset, String? stopId}) async {
    final status = _status;
    if (!_demoAdminAllowed || status == null || !status.demoAvailable ||
        (_demoRequest?.expired == false) || !widget.isActive ||
        !isEffectivelyOnline(status, _fetchedAt, DateTime.now())) {
      return;
    }
    final id = stopId ?? newDemoId();
    final action = DemoRequest(id, stopId != null);
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);
    bool current() => mounted && kSessionEpoch == epoch && originOf(kBaseUrl) == origin &&
        identical(_demoRequest, action);
    setState(() {
      _demoRequest = action;
      _demoError = null;
    });
    _demoDeadline?.cancel();
    _demoDeadline = Timer(const Duration(seconds: 15), () {
      if (!current()) return;
      setState(() => _demoRequest = DemoRequest(id, action.stop, expired: true));
      if (widget.isActive) _refresh();
    });
    try {
      final body = preset?.toStartBody(status.device, id) ?? {'device': status.device, 'run_id': id};
      final response = await http.postAdmin(
        Uri.parse('$kBaseUrl/api/demo/${action.stop ? 'stop' : 'start'}'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body),
      ).timeout(const Duration(seconds: 8));
      if (!current()) return;
      if (response.statusCode != 202) {
        _demoDeadline?.cancel();
        setState(() {
          _demoRequest = null;
          _demoError = 'Perintah tidak dikonfirmasi server (${response.statusCode})';
        });
      }
      if (widget.isActive) _refresh();
    } catch (_) {
      if (current() && widget.isActive) _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final now = DateTime.now();
    final online = isEffectivelyOnline(
      s,
      _fetchedAt,
      now,
      hasRefreshError: _error != null,
    );
    final ageSec = (s != null && _fetchedAt != null)
        ? effectiveAgeSec(s, _fetchedAt!, now)
        : (s?.lastSeenSec ?? 0);
    final smokeUi = evaluateSmokeUi(s, effectiveOnline: online, ageSec: ageSec);

    final h = s?.humidity;
    final color = h == null ? kAccent : humidityColor(h);
    final mode = _pendingMode ?? s?.mode ?? 'auto';
    final power = _pendingPower ?? s?.power ?? true;
    final standby = online && power && s?.state == 'STANDBY';
    final showSmokeBanner = s != null && s.hasLatest && online && s.smokeAlert;
    final admin = isAdminSession;
    final demoAdmin = _demoAdminAllowed;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: ListView(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Kamar Mandi',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _subtitle(s, online, ageSec),
                      ],
                    ),
                  ),
                  _powerButton(power, enabled: admin),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: admin
                        ? kAccent.withValues(alpha: 0.16)
                        : kCard,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: admin ? kAccent.withValues(alpha: 0.5) : kLine,
                    ),
                  ),
                  child: Text(
                    admin ? 'Mode Admin (Kendali Aktif)' : 'Mode Pengunjung (Lihat Saja)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: admin ? kAccent : kMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (demoAdmin && (s?.demoAvailable == true || _showDemoPanel)) ...[
                OutlinedButton.icon(onPressed: () => setState(() => _showDemoPanel = !_showDemoPanel),
                  icon: const Icon(Icons.science_outlined), label: const Text('Skenario Demo')),
                if (_showDemoPanel) DemoPanel(
                  snapshot: s?.demo, request: _demoRequest, online: online,
                  ready: s?.demoAvailable == true && s?.sensorOk == true && s?.smokeReady == true && s?.smokeAlert != true,
                  mode: s?.mode, power: s?.power ?? false, standby: s?.standby ?? false,
                  error: _demoError,
                  verdict: _demoEvidence?.progress ?? _demoVerdict ??
                    (s?.demo?.endReason == null ? null : 'Tidak dinilai · run tidak teramati'),
                  onStart: (preset) => _sendDemo(preset: preset),
                  onStop: (id) => _sendDemo(stopId: id),
                ),
              ],
              if (s != null && s.demo?.active == true)
                DemoScene(snapshot: s.demo!, humidity: s.humidity, temperature: s.temperature, smokeDelta: s.smoke,
                  smokeAlert: s.smokeAlert, fanPwm: s.fanPwm ?? 0, online: online,
                  isActive: widget.isActive, trend: List.of(_demoTrend))
              else
                _hero(s, power ? color : const Color(0xFF4B5F7F), online),
              const SizedBox(height: 16),
              if (showSmokeBanner) ...[
                _smokeBanner(s),
                const SizedBox(height: 16),
              ],
              if (standby) ...[
                _standbyBanner(),
                const SizedBox(height: 16),
              ],
              _smokeCard(smokeUi, s),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _fanCard(s)),
                  const SizedBox(width: 12),
                  Expanded(child: _infoCard(s, ageSec)),
                ],
              ),
              const SizedBox(height: 16),
              IgnorePointer(
                ignoring: !admin,
                child: Opacity(
                  opacity: admin ? 1 : 0.5,
                  child: _modeSelector(mode, enabled: admin),
                ),
              ),
              if (mode == 'manual') ...[
                const SizedBox(height: 16),
                IgnorePointer(
                  ignoring: !admin || standby,
                  child: Opacity(
                    opacity: (!admin || standby) ? 0.4 : 1,
                    child: _speedCard(enabled: admin && !standby),
                  ),
                ),
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

  Widget _modeSelector(String mode, {required bool enabled}) {
    Widget item(String value, String label) {
      final active = mode == value;
      return Expanded(
        child: GestureDetector(
          onTap: enabled ? () => _setMode(value) : null,
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

  Widget _speedCard({required bool enabled}) {
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
            onChanged: enabled ? (v) => setState(() => _manualSpeed = v) : null,
            onChangeEnd: enabled ? _sendSpeed : null,
          ),
        ],
      ),
    );
  }

  Widget _powerButton(bool on, {required bool enabled}) {
    const dark = Color(0xFF08213F);
    return Semantics(
      button: true,
      enabled: enabled,
      label: on ? 'Matikan fan' : 'Nyalakan fan',
      child: GestureDetector(
        onTap: enabled ? () => _setPower(!on) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.55,
          child: Container(
            height: 44,
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: on ? null : kCard,
              gradient: on
                  ? const LinearGradient(
                      colors: [Color(0xFF6FA8FF), Color(0xFFA9CDFF)],
                    )
                  : null,
              border: Border.all(color: kLine),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  on ? 'On' : 'Off',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: on ? dark : kMuted,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: on ? Colors.white : kLine,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.power_settings_new,
                    size: 18,
                    color: on ? dark : kMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _smokeBanner(FanStatus s) {
    const color = Color(0xFFEF4444);
    final deltaText = s.smoke == null ? '--' : '${s.smoke}';
    final pwmText = s.fanPwm == null ? '--' : '${s.fanPwm} %';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.7)),
        color: color.withValues(alpha: 0.14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Alarm asap aktif',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sensor MQ-2 mendeteksi asap (delta $deltaText). '
                  'Daya: ${s.power ? 'ON' : 'OFF'} · Fan dilaporkan: $pwmText.',
                  style: const TextStyle(fontSize: 13, color: Color(0xFFFCA5A5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _smokeCard(SmokeUiInfo info, FanStatus? s) {
    final timeStr = s?.sampleTime == null
        ? null
        : '${s!.sampleTime!.hour.toString().padLeft(2, '0')}:'
            '${s.sampleTime!.minute.toString().padLeft(2, '0')}:'
            '${s.sampleTime!.second.toString().padLeft(2, '0')}';

    return _card(
      Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: info.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Sensor Asap (MQ-2)', style: TextStyle(fontSize: 13, color: kMuted)),
                    Text(
                      info.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: info.color,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  timeStr != null && info.state == SmokeUiState.offline
                      ? '${info.detail} (pukul $timeStr)'
                      : info.detail,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _standbyBanner() {
    const color = Color(0xFFA9B8FF);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.6)),
        color: color.withValues(alpha: 0.12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.bedtime_outlined, color: color),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Standby aktif',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                SizedBox(height: 2),
                Text(
                  'Fan tidak menyala otomatis, kecuali kelembapan mencapai 90 %.',
                  style: TextStyle(fontSize: 13, color: kMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _subtitle(FanStatus? s, bool online, int ageSec) {
    final statusText = s == null || !s.hasLatest
        ? '● Menunggu data'
        : (online
            ? '● Online'
            : '● Offline (${formatAgeShort(ageSec)} lalu)');
    final statusColor = s == null || !s.hasLatest
        ? kMuted
        : (online ? const Color(0xFF4ADE80) : const Color(0xFFF87171));
    return Text.rich(
      TextSpan(
        style: const TextStyle(fontSize: 13, color: kMuted),
        children: [
          const TextSpan(text: 'fan01 · '),
          TextSpan(
            text: statusText,
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero(FanStatus? s, Color color, bool online) {
    final h = s?.humidity;
    final number = h == null ? '--' : h.toStringAsFixed(1).replaceAll('.', ',');
    final subLabel = h == null
        ? 'Menunggu data...'
        : (online
            ? 'Kelembapan ${humidityLabel(h)}'
            : 'Kelembapan ${humidityLabel(h)} (bacaan terakhir)');

    return Container(
      width: double.infinity,
      height: 290,
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
            child: AirFlow(
              color: color,
              speed: online ? ((s?.fanPwm ?? 0) / 100) : 0,
            ),
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
                online ? (s?.state ?? '--') : (s?.hasLatest == true ? 'OFFLINE' : '--'),
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
                  subLabel,
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

  Widget _infoCard(FanStatus? s, int ageSec) {
    final mode = s?.mode;
    final modeText = mode == null || mode.isEmpty
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
            s == null || !s.hasLatest ? '' : 'Data ${formatAgeShort(ageSec)} lalu',
            style: const TextStyle(fontSize: 13, color: kMuted),
          ),
        ],
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _foreground = true;
  final _lastDemo = ValueNotifier<({String device, String id})?>(null);
  String _demoOrigin = originOf(kBaseUrl);

  void _clearDemoOnOriginChange() {
    final next = originOf(kBaseUrl);
    if (_demoOrigin == next) return;
    _demoOrigin = next;
    _lastDemo.value = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sessionNotifier.addListener(_clearDemoOnOriginChange);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sessionNotifier.removeListener(_clearDemoOnOriginChange);
    _lastDemo.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final next = state == AppLifecycleState.resumed;
    if (next != _foreground && mounted) {
      setState(() => _foreground = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          DashboardPage(isActive: _foreground && _index == 0, onDemoRun: (run) => _lastDemo.value = run),
          ValueListenableBuilder(valueListenable: _lastDemo,
            builder: (_, run, _) => StatsPage(isActive: _foreground && _index == 1, latestDemo: run)),
          SchedulesPage(isActive: _foreground && _index == 2),
          const FeedbackPage(),
          SettingsPage(isActive: _foreground && _index == 4),
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
          NavigationDestination(icon: Icon(Icons.feedback_outlined), label: 'Masukan'),
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
