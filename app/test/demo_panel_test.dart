import 'package:bathfan_app/demo_models.dart';
import 'package:bathfan_app/demo_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'verdict requires observed threshold, response and recovery with stable config',
    () {
      DemoSnapshot sample(int elapsed, String phase, {int version = 1}) =>
          DemoSnapshot(
            'run',
            'shower',
            null,
            phase,
            'together',
            1,
            10,
            elapsed,
            configVersion: version,
            humidityThreshold: 70,
          );
      final evidence = DemoEvidence(sample(0, 'shower'));
      void observe(
        int elapsed,
        String phase,
        double humidity,
        int pwm,
        String state, {
        int version = 1,
      }) {
        evidence.observe(
          sample(elapsed, phase, version: version),
          humidity: humidity,
          smoke: 0,
          alarm: false,
          pwm: pwm,
          state: state,
          autoControl: true,
        );
      }

      observe(0, 'shower', 55, 0, 'IDLE');
      observe(5, 'shower', 75, 45, 'RUNNING');
      observe(10, 'recovery', 55, 30, 'POSTRUN');
      observe(15, 'settling', 55, 30, 'POSTRUN');
      expect(
        evidence.finish('completed', finalIdle: true),
        startsWith('Lulus'),
      );
      observe(16, 'settling', 55, 0, 'IDLE', version: 2);
      expect(evidence.finish('completed'), contains('konfigurasi berubah'));
      expect(evidence.finish('stopped'), startsWith('Tidak dinilai'));
    },
  );
  test('preset start has no sensor or actuator fields', () {
    final body = const DemoPreset().toStartBody('fan01', 'id');
    expect(body, {
      'device': 'fan01',
      'run_id': 'id',
      'kind': 'shower',
      'minutes': 10,
      'speed': 10,
    });
  });

  testWidgets('broker acceptance waits for matching device telemetry', (
    tester,
  ) async {
    final request = ValueNotifier<DemoRequest?>(
      const DemoRequest('wanted', false),
    );
    addTearDown(request.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: request,
            builder: (_, value, _) => DemoPanel(
              snapshot: null,
              request: value,
              online: true,
              ready: true,
              mode: 'auto',
              power: true,
              standby: false,
              onStart: (_) {},
              onStop: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Menunggu ESP32'), findsOneWidget);
    request.value = const DemoRequest('wanted', false, expired: true);
    await tester.pump();
    expect(find.text('Belum terkonfirmasi'), findsOneWidget);
  });
}
