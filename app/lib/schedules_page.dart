import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'api_http.dart' as http;
import 'constants.dart';
import 'schedule_form.dart';

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
  final bool isActive;
  const SchedulesPage({super.key, this.isActive = true});

  @override
  State<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends State<SchedulesPage> {
  List<Schedule>? _items;
  String? _error;
  Timer? _timer;
  String _activeOrigin = originOf(kBaseUrl);

  @override
  void initState() {
    super.initState();
    sessionNotifier.addListener(_onSessionChange);
    _syncPolling(immediate: widget.isActive);
  }

  @override
  void didUpdateWidget(covariant SchedulesPage oldWidget) {
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
        _items = null;
        _error = null;
      });
      if (widget.isActive) _load();
    } else {
      setState(() {});
      if (widget.isActive && _items == null) _load();
    }
  }

  void _syncPolling({required bool immediate}) {
    _timer?.cancel();
    _timer = null;
    if (!widget.isActive) return;
    if (immediate) _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    if (kBaseUrl.isEmpty) {
      if (mounted) setState(() => _error = 'Alamat server belum diatur');
      return;
    }
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);
    try {
      final res = await http
          .getForSession(Uri.parse('$kBaseUrl/api/schedules'))
          .timeout(const Duration(seconds: 8));
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      if (res.statusCode == 401) {
        setState(() {
          _items = null;
          _error = 'Jadwal memerlukan akses Admin di Pengaturan';
        });
        return;
      }
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['schedules'] as List)
          .map((e) => Schedule.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      setState(() {
        _items = list;
        _error = null;
      });
    } catch (_) {
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
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
    if (!isAdminSession) return;
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);

    _replace(s.copyWith(enabled: value));
    try {
      final res = await http
          .putAdmin(
            Uri.parse('$kBaseUrl/api/schedules/${s.id}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'enabled': value}),
          )
          .timeout(const Duration(seconds: 8));
      if (!mounted || epoch != kSessionEpoch || origin != originOf(kBaseUrl)) return;
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    } catch (_) {
      if (epoch == kSessionEpoch && origin == originOf(kBaseUrl)) {
        _replace(s);
      }
      _snack('Gagal mengubah jadwal');
    }
  }

  Future<void> _delete(Schedule s) async {
    if (!isAdminSession) return;
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);

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
    if (ok != true ||
        !mounted ||
        epoch != kSessionEpoch ||
        !isAdminSession ||
        origin != originOf(kBaseUrl)) {
      return;
    }

    try {
      final res = await http
          .deleteAdmin(Uri.parse('$kBaseUrl/api/schedules/${s.id}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      await _load();
    } catch (_) {
      _snack('Gagal menghapus jadwal');
    }
  }

  Future<void> _openForm([Schedule? s]) async {
    if (!isAdminSession) return;
    final epoch = kSessionEpoch;
    final origin = originOf(kBaseUrl);

    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormPage(
          editing: s != null,
          name: s?.name ?? '',
          start: s?.start ?? '22:00',
          end: s?.end ?? '05:00',
          days: s?.days ?? const [1, 2, 3, 4, 5, 6, 7],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (epoch != kSessionEpoch || !isAdminSession || origin != originOf(kBaseUrl)) {
      _snack('Sesi berubah, penyimpanan dibatalkan');
      return;
    }

    try {
      final uri = s == null
          ? Uri.parse('$kBaseUrl/api/schedules')
          : Uri.parse('$kBaseUrl/api/schedules/${s.id}');
      final headers = {'Content-Type': 'application/json'};
      final body = jsonEncode(result);
      final res = await (s == null
              ? http.postAdmin(uri, headers: headers, body: body)
              : http.putAdmin(uri, headers: headers, body: body))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 && res.statusCode != 201) {
        throw Exception('HTTP ${res.statusCode}');
      }
      await _load();
    } catch (_) {
      _snack('Gagal menyimpan jadwal');
    }
  }

  Widget _item(Schedule s, bool admin) {
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
            onChanged: admin ? (v) => _toggle(s, v) : null,
            activeTrackColor: kAccent,
            activeThumbColor: Colors.white,
            inactiveTrackColor: kLine,
            inactiveThumbColor: kMuted,
          ),
          if (admin) ...[
            IconButton(
              tooltip: 'Ubah jadwal',
              onPressed: () => _openForm(s),
              icon: const Icon(Icons.edit_outlined, color: kMuted),
            ),
            IconButton(
              tooltip: 'Hapus jadwal',
              onPressed: () => _delete(s),
              icon: const Icon(Icons.delete_outline, color: kMuted),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final admin = isAdminSession;
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
      const SizedBox(height: 10),
      if (!admin)
        const Text(
          'Mode Pengunjung: daftar jadwal hanya dapat dilihat.',
          style: TextStyle(fontSize: 12, color: kMuted),
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
        children.add(_item(s, admin));
        children.add(const SizedBox(height: 12));
      }
    }

    if (admin) {
      children.add(
        OutlinedButton.icon(
          onPressed: () => _openForm(),
          icon: const Icon(Icons.add),
          label: const Text('Tambah jadwal'),
          style: OutlinedButton.styleFrom(
            foregroundColor: kAccent,
            side: const BorderSide(color: kAccent, width: 2),
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      );
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
