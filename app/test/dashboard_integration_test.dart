import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bathfan_app/api_http.dart' as api;
import 'package:bathfan_app/constants.dart';
import 'package:bathfan_app/demo_panel.dart';
import 'package:bathfan_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore implements SecureKvStorage {
  final _values = <String, String>{};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

void main() {
  const screenshotDir = String.fromEnvironment('BATHFAN_SCREENSHOTS');
  const fontDir = String.fromEnvironment('BATHFAN_REVIEW_FONTS');

  testWidgets('Demo actions follow connection and role without hiding the card', (
    tester,
  ) async {
    const origin = 'https://review.example.test';
    const boundaryKey = ValueKey('review-boundary');
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => api.testHttpClient = null);
    SharedPreferences.setMockInitialValues({'base_url': origin});
    resetConfigForTest(secureStorage: _MemoryStore());
    await initAppConfig(trustedAdminOriginOverride: origin, isDebugMode: false);
    if (fontDir.isNotEmpty) {
      await tester.runAsync(() async {
        final loader = FontLoader('Roboto');
        for (final weight in ['regular', 'medium', 'bold']) {
          loader.addFont(
            File(
              '$fontDir/roboto-$weight.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              '$fontDir/materialicons-regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await Future.wait([loader.load(), icons.load()]);
      });
    }

    var hasData = false;
    var online = false;
    var demoAvailable = true;
    var sensorReady = true;
    var readFails = false;
    String? runId;
    final commands = <String>[];
    final reads = <String>[];
    final config = {
      'hum_on': 70,
      'hum_off': 60,
      'post_run_sec': 60,
      'max_pwm': 100,
      'smoke_on': 250,
      'smoke_off': 100,
    };

    api.testHttpClient = MockClient((req) async {
      final path = req.url.path;
      http.Response reply(Object body, [int status = 200]) =>
          http.Response(jsonEncode(body), status);
      if (path == '/api/admin/verify') {
        return reply({'ok': true, 'role': 'admin'});
      }
      if (req.method != 'GET') {
        expect(req.headers['X-API-Key'], 'fixture-key');
        commands.add(path);
        if (path == '/api/demo/start') {
          runId = (jsonDecode(req.body) as Map)['run_id'] as String;
        }
        return reply({'status': 'pending'}, 202);
      }
      reads.add(path);
      return switch (path) {
        '/api/status' when readFails => reply({}, 503),
        '/api/status' => reply({
          'device': 'fan01',
          'online': online,
          'demo_available': demoAvailable,
          'last_seen_sec_ago': online ? 2 : 35,
          'latest': !hasData
              ? null
              : {
                  'humidity': 74.3,
                  'temperature': 29.1,
                  'fan_pwm': 48,
                  'mode': 'auto',
                  'power': true,
                  'smoke': 6,
                  'smoke_ready': sensorReady,
                  'sensor_ok': sensorReady,
                  'state': 'RUNNING',
                  if (runId != null)
                    'demo': {
                      'v': 1,
                      'kind': 'shower',
                      'phase': 'shower',
                      'elapsed_s': 9,
                      'run_id': runId,
                      'speed': 10,
                    },
                },
        }),
        '/api/history' => reply({'points': []}),
        '/api/schedules' => reply({'schedules': []}),
        '/api/config' => reply({'config': config, 'defaults': config}),
        _ => reply({}, 404),
      };
    });

    Future<void> capture(String name) async {
      if (screenshotDir.isEmpty) return;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final dir = await Directory(screenshotDir).create(recursive: true);
        await File(
          '${dir.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    Future<void> poll() async {
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    }

    final card = find.byType(DemoPanel);
    final start = find.widgetWithText(FilledButton, 'Mulai');
    final stop = find.widgetWithText(OutlinedButton, 'Hentikan simulasi');
    void checkActions({required bool canStart, required bool canStop}) {
      expect(card, findsOneWidget);
      expect(tester.widget<FilledButton>(start).onPressed != null, canStart);
      expect(tester.widget<OutlinedButton>(stop).onPressed != null, canStop);
      expect(
        tester
                .widget<SegmentedButton<bool>>(
                  find.byType(SegmentedButton<bool>),
                )
                .onSelectionChanged !=
            null,
        canStart,
      );
    }

    // The production widget tree uses the original splash and four-tab shell.
    await tester.pumpWidget(
      const RepaintBoundary(key: boundaryKey, child: BathfanApp()),
    );
    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Masukan'), findsNothing);
    expect(find.text('Demo Skenario').hitTestable(), findsOneWidget);
    await capture('dashboard');

    await tester.ensureVisible(card);
    await tester.pump();
    expect(find.text('Menunggu data perangkat'), findsOneWidget);
    checkActions(canStart: false, canStop: false);
    final dashboardScroll = find
        .descendant(
          of: find.byType(DashboardPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Auto'),
      250,
      scrollable: dashboardScroll,
    );
    expect(find.text('Auto'), findsOneWidget);
    await tester.ensureVisible(card);
    await tester.pump();

    hasData = true;
    await poll();
    expect(find.text('Perangkat offline'), findsOneWidget);
    checkActions(canStart: false, canStop: false);
    await capture('pengunjung-offline');

    online = true;
    await poll();
    expect(find.text('Hanya Admin yang dapat memulai demo'), findsOneWidget);
    checkActions(canStart: false, canStop: false);
    await tester.ensureVisible(start);
    await tester.tap(start);
    expect(commands, isEmpty);
    await capture('pengunjung-online');

    expect(await verifyAndActivateAdmin('fixture-key'), isTrue);
    demoAvailable = false;
    await poll();
    expect(find.text('Demo tidak tersedia pada perangkat ini'), findsOneWidget);
    checkActions(canStart: false, canStop: false);

    demoAvailable = true;
    sensorReady = false;
    await poll();
    expect(find.text('Menunggu sensor fisik siap'), findsOneWidget);
    checkActions(canStart: false, canStop: false);

    sensorReady = true;
    await poll();
    checkActions(canStart: true, canStop: false);
    await capture('admin-online');
    await tester.tap(start);
    await tester.pump();
    await tester.pump();
    expect(commands, ['/api/demo/start']);
    expect(find.text('Berjalan'), findsOneWidget);
    checkActions(canStart: false, canStop: true);

    // Failed polling with the last successful sample still online locks Stop too.
    readFails = true;
    await poll();
    checkActions(canStart: false, canStop: false);
    await capture('admin-offline');
    await tester.ensureVisible(stop);
    await tester.tap(stop);
    expect(commands, ['/api/demo/start']);

    readFails = false;
    sensorReady = false;
    await poll();
    checkActions(canStart: false, canStop: true);
    await tester.tap(stop);
    await tester.pump();
    expect(commands, ['/api/demo/start', '/api/demo/stop']);
    checkActions(canStart: false, canStop: false);
    await clearAdminSession();
    await tester.pump();
    await tester.pump();
    expect(find.text('Berjalan'), findsOneWidget);
    checkActions(canStart: false, canStop: false);
    await tester.tap(stop);
    expect(commands, ['/api/demo/start', '/api/demo/stop']);

    for (final tab in {
      'Statistik': '/api/history',
      'Jadwal': '/api/schedules',
      'Pengaturan': '/api/config',
    }.entries) {
      reads.clear();
      await tester.tap(find.widgetWithText(NavigationDestination, tab.key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await poll();
      expect(reads, isNotEmpty);
      expect(reads.toSet(), {tab.value});
      await capture(tab.key.toLowerCase());
    }
    await tester.pumpWidget(const SizedBox());
  });
}
