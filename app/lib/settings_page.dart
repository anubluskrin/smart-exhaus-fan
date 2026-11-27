import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api_http.dart' as http;
import 'constants.dart';

class DeviceConfig {
  final double humOn;
  final double humOff;
  final int postRunSec;
  final int maxPwm;
  final int smokeOn;
  final int smokeOff;

  const DeviceConfig({
    required this.humOn,
    required this.humOff,
    required this.postRunSec,
    required this.maxPwm,
    required this.smokeOn,
    required this.smokeOff,
  });

  factory DeviceConfig.fromJson(Map<String, dynamic> j) => DeviceConfig(
        humOn: (j['hum_on'] as num).toDouble(),
        humOff: (j['hum_off'] as num).toDouble(),
        postRunSec: (j['post_run_sec'] as num).toInt(),
        maxPwm: (j['max_pwm'] as num).toInt(),
        smokeOn: (j['smoke_on'] as num?)?.toInt() ?? 250,
        smokeOff: (j['smoke_off'] as num?)?.toInt() ?? 100,
      );

  DeviceConfig copyWith({
    double? humOn,
    double? humOff,
    int? postRunSec,
    int? maxPwm,
    int? smokeOn,
    int? smokeOff,
  }) =>
      DeviceConfig(
        humOn: humOn ?? this.humOn,
        humOff: humOff ?? this.humOff,
        postRunSec: postRunSec ?? this.postRunSec,
        maxPwm: maxPwm ?? this.maxPwm,
        smokeOn: smokeOn ?? this.smokeOn,
        smokeOff: smokeOff ?? this.smokeOff,
      );

  bool same(DeviceConfig? o) =>
      o != null &&
      o.humOn == humOn &&
      o.humOff == humOff &&
      o.postRunSec == postRunSec &&
      o.maxPwm == maxPwm &&
      o.smokeOn == smokeOn &&
      o.smokeOff == smokeOff;
}

String durationText(int s) {
  if (s < 60) return '$s detik';
  final m = s ~/ 60;
  final r = s % 60;
  return r == 0 ? '$m menit' : '$m menit $r detik';
}

class SettingsPage extends StatefulWidget {
  final bool isActive;
  const SettingsPage({super.key, this.isActive = true});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  DeviceConfig? _saved;
  DeviceConfig? _defaults;
  DeviceConfig? _edit;
  String? _error;
  bool _busy = false;

  final TextEditingController _addr = TextEditingController();
  final TextEditingController _key = TextEditingController();
  String? _addrMsg;
  bool _addrOk = false;
  bool _addrBusy = false;
  String? _adminMsg;
  bool _adminOk = false;
  bool _adminBusy = false;
  String _activeOrigin = originOf(kBaseUrl);

  @override
  void initState() {
    super.initState();
    _addr.text = kBaseUrl;
    sessionNotifier.addListener(_onSessionChange);
    if (widget.isActive) _load();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _load();
    }
  }

  @override
  void dispose() {
    sessionNotifier.removeListener(_onSessionChange);
    _addr.dispose();
    _key.dispose();
    super.dispose();
  }

  void _onSessionChange() {
    if (!mounted) return;
    final nextOrigin = originOf(kBaseUrl);
    final originChanged = nextOrigin != _activeOrigin;
    final shouldReset = originChanged || !isAdminSession;
    setState(() {
      if (originChanged) {
        _activeOrigin = nextOrigin;
      }
      if (shouldReset) {
        _saved = null;
        _defaults = null;
        _edit = null;
        _error = null;
      }
    });
    if ((shouldReset || _edit == null) && widget.isActive) {
      _load();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _message(http.Response res) {
    try {
      final m = jsonDecode(res.body) as Map<String, dynamic>;
      if (m['error'] is String) return m['error'] as String;
    } catch (_) {}
    return 'Gagal (HTTP ${res.statusCode})';
  }

  Future<void> _load() async {
    if (kBaseUrl.isEmpty) {
      if (mounted) setState(() => _error = 'Alamat server belum diatur.');
      return;
    }
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);
    try {
      final res = await http
          .getForSession(Uri.parse('$kBaseUrl/api/config'))
          .timeout(const Duration(seconds: 8));
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      if (res.statusCode == 401) {
        setState(() {
          _saved = null;
          _defaults = null;
          _edit = null;
          _error = 'Pengaturan perangkat memerlukan akses Admin.';
        });
        return;
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cfg = DeviceConfig.fromJson(data['config'] as Map<String, dynamic>);
      final def =
          DeviceConfig.fromJson(data['defaults'] as Map<String, dynamic>);
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      setState(() {
        _saved = cfg;
        _defaults = def;
        _edit = cfg;
        _error = null;
      });
    } catch (_) {
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      setState(() => _error = 'Tidak bisa mengambil pengaturan');
    }
  }

  Future<void> _save() async {
    final e = _edit;
    if (e == null || !isAdminSession) return;
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);
    setState(() => _busy = true);
    try {
      final res = await http
          .putAdmin(
            Uri.parse('$kBaseUrl/api/config'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'hum_on': e.humOn,
              'hum_off': e.humOff,
              'post_run_sec': e.postRunSec,
              'max_pwm': e.maxPwm,
              'smoke_on': e.smokeOn,
              'smoke_off': e.smokeOff,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      if (res.statusCode != 200) {
        _snack(_message(res));
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cfg = DeviceConfig.fromJson(data['config'] as Map<String, dynamic>);
      setState(() {
        _saved = cfg;
        _edit = cfg;
      });
      _snack('Pengaturan disimpan');
    } catch (_) {
      _snack('Gagal menyimpan pengaturan');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final d = _defaults;
    if (d == null || !isAdminSession) return;
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Kembalikan ke bawaan?'),
        content: Text(
          'Fan menyala di atas ${d.humOn.round()} %, mati di bawah ${d.humOff.round()} %, '
          'post-run ${durationText(d.postRunSec)}, kecepatan maksimum ${d.maxPwm} %, '
          'asap menyala di atas ${d.smokeOn}, bersih di bawah ${d.smokeOff}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Kembalikan'),
          ),
        ],
      ),
    );
    if (ok != true ||
        !mounted ||
        epoch != kSessionEpoch ||
        !isAdminSession ||
        origin != originOf(kBaseUrl)) {
      return;
    }

    setState(() => _busy = true);
    try {
      final res = await http
          .postAdmin(
            Uri.parse('$kBaseUrl/api/config/reset'),
            headers: {'Content-Type': 'application/json'},
            body: '{}',
          )
          .timeout(const Duration(seconds: 8));
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      if (res.statusCode != 200) {
        _snack(_message(res));
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cfg = DeviceConfig.fromJson(data['config'] as Map<String, dynamic>);
      setState(() {
        _saved = cfg;
        _edit = cfg;
      });
      _snack('Pengaturan dikembalikan ke bawaan');
    } catch (_) {
      _snack('Gagal mereset pengaturan');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<(bool, String)> _probeHealth(String base) async {
    try {
      final res = await http
          .getPublic(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        return (false, 'Server menjawab HTTP ${res.statusCode}');
      }
      final j = jsonDecode(res.body);
      if (j is! Map<String, dynamic> || j['ok'] != true) {
        return (false, 'Alamat ini bukan backend Bathfan');
      }
      return (true, 'Server dapat dijangkau');
    } catch (_) {
      return (false, 'Tidak bisa dijangkau. Periksa alamat dan koneksi');
    }
  }

  Future<void> _testAddress() async {
    if (_addr.text.trim().isEmpty) {
      setState(() {
        _addrOk = false;
        _addrMsg = 'Masukkan alamat server terlebih dahulu.';
      });
      return;
    }
    final n = normalizeBaseUrl(_addr.text);
    if (n == null) {
      setState(() {
        _addrOk = false;
        _addrMsg = kDebugMode
            ? 'Alamat tidak valid (publik wajib https://)'
            : 'Alamat tidak valid (wajib https://)';
      });
      return;
    }
    setState(() {
      _addrBusy = true;
      _addrOk = true;
      _addrMsg = 'Menguji...';
    });
    final r = await _probeHealth(n);
    if (!mounted) return;
    setState(() {
      _addrBusy = false;
      _addrOk = r.$1;
      _addrMsg = r.$2;
    });
  }

  Future<void> _saveAddress() async {
    final input = _addr.text.trim();
    final n = input.isEmpty ? '' : normalizeBaseUrl(input);
    if (n == null) {
      setState(() {
        _addrOk = false;
        _addrMsg = kDebugMode
            ? 'Alamat tidak valid (publik wajib https://)'
            : 'Alamat tidak valid (wajib https://)';
      });
      return;
    }
    setState(() {
      _addrBusy = true;
      _addrOk = true;
      _addrMsg = 'Menyimpan...';
      _adminMsg = null;
    });
    final saved = await setServerAddress(n);
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _addrBusy = false;
        _addrOk = false;
        _addrMsg = 'Gagal menyimpan alamat';
      });
      return;
    }
    _addr.text = n;
    if (n.isEmpty) {
      _key.clear();
      setState(() {
        _addrBusy = false;
        _addrOk = true;
        _addrMsg = 'Alamat dikosongkan. Aplikasi tidak terhubung ke server.';
      });
      return;
    }
    final r = await _probeHealth(n);
    if (!mounted) return;
    setState(() {
      _addrBusy = false;
      _addrOk = r.$1;
      _addrMsg = 'Tersimpan. ${r.$2}';
    });
    _load();
  }

  Future<void> _resetAddress() async {
    if (kDefaultBaseUrl.isEmpty) {
      setState(() {
        _addrOk = false;
        _addrMsg = 'Alamat bawaan belum dikonfigurasi pada build ini.';
      });
      return;
    }
    _addr.text = kDefaultBaseUrl;
    await _saveAddress();
  }

  Future<void> _activateAdmin() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() {
        _adminOk = false;
        _adminMsg = 'Masukkan kunci Admin terlebih dahulu.';
      });
      return;
    }
    setState(() {
      _adminBusy = true;
      _adminMsg = null;
    });

    final ok = await verifyAndActivateAdmin(key);
    if (!mounted) return;
    _key.clear();
    setState(() {
      _adminBusy = false;
      _adminOk = ok;
      _adminMsg = ok
          ? 'Mode Admin aktif.'
          : 'Verifikasi gagal. Pastikan kunci benar dan server cocok.';
    });
    if (ok) _load();
  }

  Future<void> _logoutAdmin() async {
    setState(() {
      _adminBusy = true;
      _adminMsg = null;
    });
    await clearAdminSession();
    if (!mounted) return;
    setState(() {
      _adminBusy = false;
      _adminOk = true;
      _adminMsg = 'Keluar dari Mode Admin.';
    });
    _load();
  }

  Widget _addressCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kLine),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF15325C), Color(0xFF0F2646)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Alamat server', style: TextStyle(fontSize: 15)),
          const SizedBox(height: 4),
          Text(
            kDebugMode
                ? 'Masukkan alamat HTTPS atau IP LAN lokal. Kosongkan lalu simpan untuk memutus koneksi.'
                : 'Masukkan alamat backend HTTPS. Kosongkan lalu simpan untuk memutus koneksi.',
            style: const TextStyle(fontSize: 12, color: kMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _addr,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              filled: true,
              fillColor: kCard,
              hintText: kDebugMode
                  ? 'http://192.168.1.8:3000'
                  : 'https://bathfan-api.example.com',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: kLine),
              ),
            ),
          ),
          if (_addrMsg != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _addrMsg!,
                style: TextStyle(
                  fontSize: 13,
                  color: _addrOk
                      ? const Color(0xFF4ADE80)
                      : const Color(0xFFF87171),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _addrBusy ? null : _testAddress,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kAccent,
                    side: BorderSide(
                      color: _addrBusy ? kLine : kAccent,
                      width: 2,
                    ),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('Uji koneksi'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _addrBusy ? null : _saveAddress,
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: const Color(0xFF08213F),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Simpan',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
          if (kDefaultBaseUrl.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _addrBusy ? null : _resetAddress,
                child: const Text('Pakai alamat bawaan'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _adminCard() {
    final trusted = kTrustedAdminOrigin;
    final activeOrigin = originOf(kBaseUrl);
    final originMatches = trusted.isNotEmpty && activeOrigin == trusted;
    final admin = isAdminSession;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kLine),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF15325C), Color(0xFF0F2646)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Akses Admin (Khusus Tim)',
                  style: TextStyle(fontSize: 15),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                admin ? 'Aktif' : 'Pengunjung',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: admin ? const Color(0xFF4ADE80) : kMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (!canConfigureAdmin)
            const Text(
              'Mode Admin dinonaktifkan pada build ini.',
              style: TextStyle(fontSize: 12, color: kMuted),
            )
          else if (activeOrigin.isEmpty)
            const Text(
              'Atur alamat server terlebih dahulu untuk mengaktifkan Mode Admin.',
              style: TextStyle(fontSize: 12, color: kMuted),
            )
          else if (!originMatches)
            Text(
              'Kunci Admin hanya berlaku pada server resmi: $trusted',
              style: const TextStyle(fontSize: 12, color: kMuted),
            )
          else if (admin) ...[
            const Text(
              'Perangkat ini terhubung sebagai Admin. Kendali fan, jadwal, dan konfigurasi aktif.',
              style: TextStyle(fontSize: 12, color: kMuted),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _adminBusy ? null : _logoutAdmin,
              icon: const Icon(Icons.logout),
              label: const Text('Keluar Mode Admin'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFF87171),
                side: const BorderSide(color: Color(0xFFF87171), width: 1.5),
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ] else ...[
            const Text(
              'Masukkan X-API-Key untuk mengendalikan perangkat pada server resmi.',
              style: TextStyle(fontSize: 12, color: kMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Kunci Admin',
                filled: true,
                fillColor: kCard,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: kLine),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _adminBusy ? null : _activateAdmin,
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: const Color(0xFF08213F),
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                _adminBusy ? 'Memverifikasi...' : 'Aktifkan Mode Admin',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
          if (_adminMsg != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _adminMsg!,
                style: TextStyle(
                  fontSize: 13,
                  color: _adminOk
                      ? const Color(0xFF4ADE80)
                      : const Color(0xFFF87171),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile({
    required String title,
    required String valueText,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double>? onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kLine),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF15325C), Color(0xFF0F2646)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
              Text(
                valueText,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: kAccent,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (_busy || onChanged == null) ? null : onChanged,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(hint, style: const TextStyle(fontSize: 12, color: kMuted)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final admin = isAdminSession;
    final e = _edit;
    final children = <Widget>[
      const Text(
        'Pengaturan',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Perubahan ambang dikirim ke perangkat dan berlaku dalam beberapa detik.',
        style: TextStyle(fontSize: 13, color: kMuted),
      ),
      const SizedBox(height: 16),
      _addressCard(),
      const SizedBox(height: 16),
      _adminCard(),
      const SizedBox(height: 16),
    ];

    if (e == null) {
      children.add(
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 28),
            child: Text(_error ?? 'Memuat...', style: const TextStyle(color: kMuted)),
          ),
        ),
      );
    } else {
      final d = _defaults!;
      final changed = !e.same(_saved);
      final gapOk = e.humOn - e.humOff >= 5;
      final smokeGapOk = e.smokeOn - e.smokeOff >= 50;
      final atDefault = !changed && e.same(d);
      final prMax = e.postRunSec > 600 ? 3600.0 : 600.0;

      if (!admin) {
        children.add(
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Mode Pengunjung: parameter perangkat ditampilkan hanya-baca.',
              style: TextStyle(fontSize: 12, color: kMuted),
            ),
          ),
        );
      }

      children.addAll([
        _tile(
          title: 'Fan menyala di atas',
          valueText: '${e.humOn.round()} %',
          hint: 'Bawaan ${d.humOn.round()} %. Rentang 45 sampai 85 %.',
          value: e.humOn,
          min: 45,
          max: 85,
          divisions: 40,
          onChanged: admin ? (v) => setState(() => _edit = e.copyWith(humOn: v.roundToDouble())) : null,
        ),
        const SizedBox(height: 12),
        _tile(
          title: 'Fan mati di bawah',
          valueText: '${e.humOff.round()} %',
          hint: 'Bawaan ${d.humOff.round()} %. Rentang 40 sampai 80 %.',
          value: e.humOff,
          min: 40,
          max: 80,
          divisions: 40,
          onChanged: admin ? (v) => setState(() => _edit = e.copyWith(humOff: v.roundToDouble())) : null,
        ),
        if (!gapOk)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Selisih batas menyala dan mati minimal 5 poin.',
              style: TextStyle(color: Color(0xFFF87171), fontSize: 13),
            ),
          ),
        const SizedBox(height: 12),
        _tile(
          title: 'Durasi post-run',
          valueText: durationText(e.postRunSec),
          hint: 'Fan tetap menyala pelan setelah kelembapan turun. Bawaan ${durationText(d.postRunSec)}.',
          value: e.postRunSec.toDouble(),
          min: 0,
          max: prMax,
          divisions: (prMax / 10).round(),
          onChanged: admin ? (v) => setState(() => _edit = e.copyWith(postRunSec: v.round())) : null,
        ),
        const SizedBox(height: 12),
        _tile(
          title: 'Kecepatan maksimum',
          valueText: '${e.maxPwm} %',
          hint: 'Bawaan ${d.maxPwm} %. Rentang 30 sampai 100 %.',
          value: e.maxPwm.toDouble(),
          min: 30,
          max: 100,
          divisions: 14,
          onChanged: admin ? (v) => setState(() => _edit = e.copyWith(maxPwm: v.round())) : null,
        ),
        const SizedBox(height: 12),
        _tile(
          title: 'Asap menyala di atas',
          valueText: '${e.smokeOn}',
          hint: 'Kenaikan bacaan MQ-2 di atas udara bersih. Makin kecil makin peka. Bawaan ${d.smokeOn}.',
          value: e.smokeOn.toDouble(),
          min: 100,
          max: 1000,
          divisions: 18,
          onChanged: admin ? (v) => setState(() => _edit = e.copyWith(smokeOn: v.round())) : null,
        ),
        const SizedBox(height: 12),
        _tile(
          title: 'Asap dianggap bersih di bawah',
          valueText: '${e.smokeOff}',
          hint: 'Fan baru berhenti setelah bacaan di bawah ini selama 1 menit. Bawaan ${d.smokeOff}.',
          value: e.smokeOff.toDouble(),
          min: 30,
          max: 500,
          divisions: 47,
          onChanged: admin ? (v) => setState(() => _edit = e.copyWith(smokeOff: v.round())) : null,
        ),
        if (!smokeGapOk)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Selisih ambang asap menyala dan bersih minimal 50.',
              style: TextStyle(color: Color(0xFFF87171), fontSize: 13),
            ),
          ),
        if (admin) ...[
          const SizedBox(height: 20),
          FilledButton(
            onPressed: (_busy || !changed || !gapOk || !smokeGapOk) ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: kAccent,
              foregroundColor: const Color(0xFF08213F),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Simpan pengaturan', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: (_busy || atDefault) ? null : _reset,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Kembalikan ke bawaan'),
            style: OutlinedButton.styleFrom(
              foregroundColor: kAccent,
              side: BorderSide(color: (_busy || atDefault) ? kLine : kAccent, width: 2),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ]);
    }

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: children,
          ),
        ),
      ),
    );
  }
}
