import 'package:flutter/material.dart';

import 'constants.dart';
import 'demo_models.dart';

class DemoPanel extends StatefulWidget {
  final DemoSnapshot? snapshot;
  final DemoRequest? request;
  final bool online;
  final String? startBlocker, error;
  final String? verdict;
  final ValueChanged<DemoPreset>? onStart;
  final ValueChanged<String>? onStop;
  const DemoPanel({
    super.key,
    required this.snapshot,
    required this.request,
    required this.online,
    this.startBlocker,
    this.error,
    this.verdict,
    required this.onStart,
    required this.onStop,
  });

  @override
  State<DemoPanel> createState() => _DemoPanelState();
}

class _DemoPanelState extends State<DemoPanel> {
  bool _smoke = false;
  int _minutes = 10, _people = 2, _speed = 10;
  String _intensity = 'medium', _pattern = 'staggered';

  Widget _choice<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T>? change,
  ) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final item in options.entries)
          DropdownMenuItem(value: item.key, child: Text(item.value)),
      ],
      onChanged: change == null
          ? null
          : (next) {
              if (next != null) change(next);
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.snapshot;
    final active = run?.active == true;
    final pending = widget.request;
    final start = widget.onStart;
    final stop = widget.onStop;
    final runId = run?.id;
    final ready = start != null;
    const ink = Color(0xFF08213F);
    final disabled = kMuted.withValues(alpha: 0.6);
    final status = switch (pending) {
      _ when !widget.online => widget.startBlocker ?? 'Perangkat offline',
      DemoRequest(expired: false, stop: true) => 'Menunggu ESP32 berhenti',
      DemoRequest(expired: false) => 'Menunggu ESP32',
      _ when active => 'Berjalan',
      DemoRequest(expired: true) => 'Belum terkonfirmasi',
      _ => widget.startBlocker ?? run?.terminalLabel ?? 'Siap',
    };
    final curveSeconds =
        (_smoke
            ? 120 + (_pattern == 'staggered' ? 30 * (_people - 1) : 0)
            : _minutes * 60 + 120) ~/
        _speed;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: kCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: kLine),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.science_outlined, color: kAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Demo Skenario',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Simulasi bacaan sensor mandi atau asap.',
              style: TextStyle(color: kMuted),
            ),
            const SizedBox(height: 8),
            Text(
              status,
              style: TextStyle(
                color: widget.online && active ? kAccent : kMuted,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: ButtonStyle(
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) return disabled;
                  return states.contains(WidgetState.selected) ? ink : kAccent;
                }),
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (!states.contains(WidgetState.selected)) return null;
                  return states.contains(WidgetState.disabled)
                      ? kLine
                      : kAccent;
                }),
                side: const WidgetStatePropertyAll(BorderSide(color: kLine)),
              ),
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Mandi'),
                  icon: Icon(Icons.shower_outlined),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Asap'),
                  icon: Icon(Icons.air_outlined),
                ),
              ],
              selected: {_smoke},
              onSelectionChanged: ready
                  ? (choice) => setState(() => _smoke = choice.single)
                  : null,
            ),
            if (_smoke) ...[
              _choice<int>('Jumlah orang (sintetis)', _people, const {
                1: '1',
                2: '2',
                3: '3',
              }, ready ? (v) => setState(() => _people = v) : null),
              _choice<String>('Intensitas', _intensity, const {
                'thin': 'Tipis',
                'medium': 'Sedang',
                'thick': 'Tebal',
              }, ready ? (v) => setState(() => _intensity = v) : null),
              _choice<String>('Pola', _pattern, const {
                'together': 'Bersamaan',
                'staggered': 'Bergantian',
              }, ready ? (v) => setState(() => _pattern = v) : null),
            ] else
              _choice<int>('Durasi mandi virtual', _minutes, const {
                5: '5 menit',
                10: '10 menit',
                20: '20 menit',
              }, ready ? (v) => setState(() => _minutes = v) : null),
            _choice<int>('Kecepatan kurva', _speed, const {
              1: '1×',
              10: '10×',
            }, ready ? (v) => setState(() => _speed = v) : null),
            const SizedBox(height: 8),
            Text(
              _smoke
                  ? 'Kurva asap: $curveSeconds detik nyata.'
                  : 'Air mengalir: ${_minutes * 60 ~/ _speed} detik nyata · pemulihan: ${120 ~/ _speed} detik.',
            ),
            const Text(
              'Timer alarm dan post-run tetap memakai waktu nyata.',
              style: TextStyle(color: kMuted),
            ),
            if (widget.error != null) Text(widget.error!),
            if (widget.verdict != null) Text(widget.verdict!),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: ink,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: ready
                  ? () => start(
                      DemoPreset(
                        smoke: _smoke,
                        minutes: _minutes,
                        people: _people,
                        speed: _speed,
                        intensity: _intensity,
                        pattern: _pattern,
                      ),
                    )
                  : null,
              child: const Text('Mulai'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: kAccent,
                side: BorderSide(color: stop == null ? kLine : kAccent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: stop != null && runId != null
                  ? () => stop(runId)
                  : null,
              child: const Text('Hentikan simulasi'),
            ),
          ],
        ),
      ),
    );
  }
}
