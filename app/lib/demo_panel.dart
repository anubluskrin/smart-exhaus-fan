import 'package:flutter/material.dart';

import 'demo_models.dart';

class DemoPanel extends StatefulWidget {
  final DemoSnapshot? snapshot;
  final DemoRequest? request;
  final bool online, ready, power, standby;
  final String? mode, error;
  final String? verdict;
  final ValueChanged<DemoPreset> onStart;
  final ValueChanged<String> onStop;
  const DemoPanel({
    super.key,
    required this.snapshot,
    required this.request,
    required this.online,
    required this.ready,
    required this.mode,
    required this.power,
    required this.standby,
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
    final busy = pending != null && !pending.expired;
    final ready = widget.ready && widget.online && !active && !busy;
    final curveSeconds =
        (_smoke
            ? 120 + (_pattern == 'staggered' ? 30 * (_people - 1) : 0)
            : _minutes * 60 + 120) ~/
        _speed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Panel Skenario',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              'Daya ${widget.power ? 'On' : 'Off'} · ${widget.mode ?? '–'}${widget.standby ? ' · Standby' : ''}',
            ),
            if (!widget.power || widget.mode != 'auto' || widget.standby)
              const Text('Respons fan dapat berbeda dari skenario Auto biasa.'),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Mandi')),
                ButtonSegment(value: true, label: Text('Asap')),
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
            Text(
              _smoke
                  ? 'Kurva asap: $curveSeconds detik nyata.'
                  : 'Air mengalir: ${_minutes * 60 ~/ _speed} detik nyata · pemulihan: ${120 ~/ _speed} detik.',
            ),
            const Text('Timer alarm dan post-run tetap memakai waktu nyata.'),
            if (!widget.online)
              const Text('Koneksi terputus')
            else if (busy)
              Text(pending.stop ? 'Menunggu ESP32 berhenti' : 'Menunggu ESP32')
            else if (pending?.expired == true)
              const Text('Belum terkonfirmasi')
            else if (active)
              const Text('Berjalan')
            else
              Text(
                widget.ready
                    ? run?.terminalLabel ?? 'Siap'
                    : 'Menunggu sensor fisik siap',
              ),
            if (widget.error != null) Text(widget.error!),
            if (widget.verdict != null) Text(widget.verdict!),
            FilledButton(
              onPressed: ready
                  ? () => widget.onStart(
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
              onPressed: active && widget.online && !(busy && pending.stop)
                  ? () => widget.onStop(run!.id!)
                  : null,
              child: const Text('Hentikan simulasi'),
            ),
          ],
        ),
      ),
    );
  }
}
