import 'package:flutter/material.dart';

import 'constants.dart';

/// Form jadwal. Mengembalikan data (Map) lewat Navigator.pop, atau null kalau dibatalkan.
class ScheduleFormPage extends StatefulWidget {
  final bool editing;
  final String name;
  final String start;
  final String end;
  final List<int> days;

  const ScheduleFormPage({
    super.key,
    this.editing = false,
    this.name = '',
    this.start = '22:00',
    this.end = '05:00',
    this.days = const [1, 2, 3, 4, 5, 6, 7],
  });

  @override
  State<ScheduleFormPage> createState() => _ScheduleFormPageState();
}

class _ScheduleFormPageState extends State<ScheduleFormPage> {
  static const _dayNames = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];

  late final TextEditingController _name;
  late String _start;
  late String _end;
  late Set<int> _days;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.name);
    _start = widget.start;
    _end = widget.end;
    _days = widget.days.toSet();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  TimeOfDay _parse(String s) {
    final p = s.split(':');
    return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(bool isStart) async {
    final t = await showTimePicker(
      context: context,
      initialTime: _parse(isStart ? _start : _end),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t == null) return;
    setState(() {
      if (isStart) {
        _start = _fmt(t);
      } else {
        _end = _fmt(t);
      }
      _error = null;
    });
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Nama jadwal wajib diisi');
      return;
    }
    if (_start == _end) {
      setState(() => _error = 'Jam mulai dan selesai tidak boleh sama');
      return;
    }
    if (_days.isEmpty) {
      setState(() => _error = 'Pilih minimal satu hari');
      return;
    }
    Navigator.pop(context, {
      'name': name,
      'start_time': _start,
      'end_time': _end,
      'days': (_days.toList()..sort()),
    });
  }

  Widget _timeTile(String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLine),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: kMuted)),
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: kAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overnight = _end.compareTo(_start) < 0;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        title: Text(widget.editing ? 'Ubah jadwal' : 'Tambah jadwal'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
            TextField(
              controller: _name,
              maxLength: 40,
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                labelText: 'Nama jadwal',
                filled: true,
                fillColor: kCard,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: kLine),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _timeTile('Jam mulai', _start, () => _pick(true)),
            const SizedBox(height: 12),
            _timeTile('Jam selesai', _end, () => _pick(false)),
            if (overnight)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Selesai keesokan harinya (melewati tengah malam).',
                  style: TextStyle(fontSize: 12, color: kMuted),
                ),
              ),
            const SizedBox(height: 20),
            const Text('Hari berlaku', style: TextStyle(color: kMuted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (int i = 1; i <= 7; i++)
                  FilterChip(
                    label: Text(_dayNames[i - 1]),
                    selected: _days.contains(i),
                    selectedColor: const Color(0xFF6FA8FF),
                    checkmarkColor: const Color(0xFF08213F),
                    backgroundColor: kCard,
                    side: const BorderSide(color: kLine),
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _days.contains(i)
                          ? const Color(0xFF08213F)
                          : kMuted,
                    ),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _days.add(i);
                      } else {
                        _days.remove(i);
                      }
                      _error = null;
                    }),
                  ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFF87171)),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: const Color(0xFF08213F),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                'Simpan',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}