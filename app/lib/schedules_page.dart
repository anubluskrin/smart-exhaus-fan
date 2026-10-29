import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'constants.dart';

class Schedule {
  final int id;
  final String name;
  final String start;
  final String end;
  final List<int> days;
  final bool enabled;

  const Schedule({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
    required this.days,
    required this.enabled,
  });

  factory Schedule.fromJson(Map<String, dynamic> j) => Schedule(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String,
        start: j['start_time'] as String,
        end: j['end_time'] as String,
        days: (j['days'] as List).map((e) => (e as num).toInt()).toList(),
        enabled: j['enabled'] == true,
      );

  Schedule copyWith({bool? enabled}) => Schedule(
        id: id,
        name: name,
        start: start,
        end: end,
        days: days,
        enabled: enabled ?? this.enabled,
      );
}

String daysText(List<int> d) {
  final s = [...d]..sort();
  if (s.length == 7) return 'Setiap hari';
  if (s.join(',') == '1,2,3,4,5') return 'Senin – Jumat';
  if (s.join(',') == '6,7') return 'Sabtu – Minggu';
  const n = ['', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
  return s.map((x) => n[x]).join(', ');
}

class SchedulesPage extends StatefulWidget {
  const SchedulesPage({super.key});

  @override
  State<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends State<SchedulesPage> {
  List<Schedule>? _items;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    try {
      final res = await http
          .get(Uri.parse('$kBaseUrl/api/schedules'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['schedules'] as List)
          .map((e) => Schedule.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _items = list;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Tidak bisa mengambil jadwal');
    }
  }

  void _replace(Schedule n) {
    if (!mounted) return;
    setState(() {
      _items = _items?.map((x) => x.id == n.id ? n : x).toList();
    });
  }

  Future<void> _toggle(Schedule s, bool value) async {
    _replace(s.copyWith(enabled: value));
    try {
      final res = await http
          .put(
            Uri.parse('$kBaseUrl/api/schedules/${s.id}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'enabled': value}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    } catch (_) {
      _replace(s);
      _snack('Gagal mengubah jadwal');
    }
  }

  Future<void> _delete(Schedule s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hapus jadwal?'),
        content: Text('Jadwal "${s.name}" akan dihapus.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await http
          .delete(Uri.parse('$kBaseUrl/api/schedules/${s.id}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      await _load();
    } catch (_) {
      _snack('Gagal menghapus jadwal');
    }
  }

  Widget _item(Schedule s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: kLine),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF15325C), Color(0xFF0F2646)],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: s.enabled ? Colors.white : kMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${s.start} – ${s.end}',
                  style: const TextStyle(fontSize: 13, color: kMuted),
                ),
                Text(
                  daysText(s.days),
                  style: const TextStyle(fontSize: 13, color: kMuted),
                ),
              ],
            ),
          ),
          Switch(
            value: s.enabled,
            onChanged: (v) => _toggle(s, v),
            activeTrackColor: kAccent,
            activeThumbColor: Colors.white,
            inactiveTrackColor: kLine,
            inactiveThumbColor: kMuted,
          ),
          IconButton(
            tooltip: 'Hapus jadwal',
            onPressed: () => _delete(s),
            icon: const Icon(Icons.delete_outline, color: kMuted),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final children = <Widget>[
      const Text(
        'Jadwal Standby',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Saat Standby, fan tidak menyala otomatis kecuali kelembapan mencapai 90 %.',
        style: TextStyle(fontSize: 13, color: kMuted),
      ),
      const SizedBox(height: 16),
    ];

    if (items == null) {
      children.add(
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 40),
            child: Text(
              _error ?? 'Memuat...',
              style: const TextStyle(color: kMuted),
            ),
          ),
        ),
      );
    } else if (items.isEmpty) {
      children.add(
        const Center(
          child: Padding(
            padding: EdgeInsets.only(top: 40),
            child: Text('Belum ada jadwal', style: TextStyle(color: kMuted)),
          ),
        ),
      );
    } else {
      for (final s in items) {
        children.add(_item(s));
        children.add(const SizedBox(height: 12));
      }
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