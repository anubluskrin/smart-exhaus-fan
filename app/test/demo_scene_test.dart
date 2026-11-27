import 'package:bathfan_app/demo_models.dart';
import 'package:bathfan_app/demo_scene.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('late join uses the reported phase and smoke preset', () {
    final s = DemoSnapshot.fromJson({
      'v': 1,
      'run_id': 'example',
      'kind': 'smoke',
      'phase': 'smoking',
      'people': 3,
      'elapsed_s': 4,
      'speed': 10,
      'pattern': 'staggered',
    })!;
    expect(s.active, isTrue);
    expect(s.people, 3);
    expect(s.sourceAge(0), 40);
    expect(s.sourceAge(2), -20);
  });

  testWidgets('stale scene freezes and reports loss of connection', (
    tester,
  ) async {
    final s = DemoSnapshot.fromJson({
      'v': 1,
      'run_id': 'example',
      'kind': 'smoke',
      'phase': 'settling',
    })!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DemoScene(
            snapshot: s,
            humidity: 55,
            smokeDelta: 5,
            smokeAlert: true,
            fanPwm: 0,
            online: false,
            isActive: true,
          ),
        ),
      ),
    );
    expect(find.text('Koneksi terputus'), findsOneWidget);
    expect(find.text('Sensor simulasi · Fan fisik'), findsOneWidget);
  });

  testWidgets(
    'reduced motion keeps online scene readable without a running ticker',
    (tester) async {
      final s = DemoSnapshot.fromJson({
        'v': 1,
        'run_id': 'example',
        'kind': 'smoke',
        'phase': 'settling',
      })!;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: DemoScene(
                snapshot: s,
                humidity: 55,
                smokeDelta: 5,
                smokeAlert: true,
                fanPwm: 0,
                online: true,
                isActive: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(milliseconds: 500),
      );
      expect(find.text('Menunggu udara bersih'), findsOneWidget);
      expect(find.text('PWM dilaporkan: 0%'), findsOneWidget);
    },
  );
}
