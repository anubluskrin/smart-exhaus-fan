import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'constants.dart';

class DeviceConfig {
  final double humOn;
  final double humOff;
  final int postRunSec;
  final int maxPwm;

  const DeviceConfig({
    required this.humOn,
    required this.humOff,
    required this.postRunSec,
    required this.maxPwm,
  });

  factory DeviceConfig.fromJson(Map<String, dynamic> j) => DeviceConfig(
        humOn: (j['hum_on'] as num).toDouble(),
        humOff: (j['hum_off'] as num).toDouble(),
        postRunSec: (j['post_run_sec'] as num).toInt(),
        maxPwm: (j['max_pwm'] as num).toInt(),
      );

  DeviceConfig copyWith({
    double? humOn,
    double? humOff,
    int? postRunSec,
    int? maxPwm,
  }) =>
      DeviceConfig(
        humOn: humOn ?? this.humOn,
        humOff: humOff ?? this.humOff,
        postRunSec: postRunSec ?? this.postRunSec,
        maxPwm: maxPwm ?? this.maxPwm,
      );

  bool same(DeviceConfig? o) =>
      o != null &&
      o.humOn == humOn &&
      o.humOff == humOff &&
      o.postRunSec == postRunSec &&
      o.maxPwm == maxPwm;
}

String durationText(int s) {
  if (s < 60) return '$s detik';
  final m = s ~/ 60;
  final r = s % 60;
  return r == 0 ? '$m menit' : '$m menit $r detik';
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  DeviceConfig? _saved;
  DeviceConfig? _defaults;
  DeviceConfig? _edit;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
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
    try {
      final res = await http
          .get(Uri.parse('$kBaseUrl/api/config'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cfg = DeviceConfig.fromJson(data['config'] as Map<String, dynamic>);
      final def =
          DeviceConfig.fromJson(data['defaults'] as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _saved = cfg;
        _defaults = def;
        _edit = cfg;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Tidak bisa mengambil pengaturan');
    }
  }

  Future<void> _save() async {
    final e = _edit;
    if (e == null) return;
    setState(() => _busy = true);
    try {
      final res = await http
          .put(
            Uri.parse('$kBaseUrl/api/config'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'hum_on': e.humOn,
              'hum_off': e.humOff,
              'post_run_sec': e.postRunSec,
              'max_pwm': e.maxPwm,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        _snack(_message(res));
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cfg = DeviceConfig.fromJson(data['config'] as Map<String, dynamic>);
      if (!mounted) return;
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
    if (d == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Kembalikan ke bawaan?'),
        content: Text(
          'Fan menyala di atas ${d.humOn.round()} %, mati di bawah ${d.humOff.round()} %, '
          'post-run ${durationText(d.postRunSec)}, kecepatan maksimum ${d.maxPwm} %.',
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
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final res = await http
          .post(
            Uri.parse('$kBaseUrl/api/config/reset'),
            headers: {'Content-Type': 'application/json'},
            body: '{}',
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        _snack(_message(res));
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cfg = DeviceConfig.fromJson(data['config'] as Map<String, dynamic>);
      if (!mounted) return;
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

  Widget _tile({
    required String title,
    required String valueText,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
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
            onChanged: _busy ? null : onChanged,
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
    final e = _edit;
    final children = <Widget>[
      const Text(
        'Pengaturan',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Perubahan dikirim ke perangkat dan berlaku dalam beberapa detik.',
        style: TextStyle(fontSize: 13, color: kMuted),
      ),
      const SizedBox(height: 16),
    ];

    if (e == null) {
      children.add(
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Text(_error ?? 'Memuat...', style: const TextStyle(color: kMuted)),
          ),
        ),
      );
    } else {
      final d = _defaults!;
      final changed = !e.same(_saved);
      final gapOk = e.humOn - e.humOff >= 5;
      final atDefault = !changed && e.same(d);
      final prMax = e.postRunSec > 600 ? 3600.0 : 600.0;

      children.addAll([
        _tile(
          title: 'Fan menyala di atas',
          valueText: '${e.humOn.round()} %',
          hint: 'Bawaan ${d.humOn.round()} %. Rentang 45 sampai 85 %.',
          value: e.humOn,
          min: 45,
          max: 85,
          divisions: 40,
          onChanged: (v) => setState(() => _edit = e.copyWith(humOn: v.roundToDouble())),
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
          onChanged: (v) => setState(() => _edit = e.copyWith(humOff: v.roundToDouble())),
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
          onChanged: (v) => setState(() => _edit = e.copyWith(postRunSec: v.round())),
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
          onChanged: (v) => setState(() => _edit = e.copyWith(maxPwm: v.round())),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: (_busy || !changed || !gapOk) ? null : _save,
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