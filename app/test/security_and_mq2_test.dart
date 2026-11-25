import 'dart:async';
import 'dart:convert';

import 'package:bathfan_app/api_http.dart' as api_http;
import 'package:bathfan_app/constants.dart';
import 'package:bathfan_app/feedback_page.dart';
import 'package:bathfan_app/main.dart';
import 'package:bathfan_app/schedules_page.dart';
import 'package:bathfan_app/settings_page.dart';
import 'package:bathfan_app/stats_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecureKvStorage implements SecureKvStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  late _MemorySecureKvStorage secureStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secureStore = _MemorySecureKvStorage();
    api_http.testHttpClient = null;
    resetConfigForTest(secureStorage: secureStore);
  });

  test('normalizeBaseUrl menolak HTTP publik, HTTP di release, prefix palsu, dan komponen URL terlarang', () {
    expect(normalizeBaseUrl('http://example.com', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://localhost:3000', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://127.0.0.1:3000', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://192.168.1.8:3000', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://10.0.2.2:3000', isDebugMode: false), isNull);

    expect(normalizeBaseUrl('http://example.com', isDebugMode: true), isNull);
    expect(normalizeBaseUrl('http://192.168.evil.com:3000', isDebugMode: true), isNull);
    expect(normalizeBaseUrl('http://127.0.0.1.evil.com:3000', isDebugMode: true), isNull);
    expect(normalizeBaseUrl('http://172.32.0.1:3000', isDebugMode: true), isNull);

    expect(normalizeBaseUrl('http://localhost:3000', isDebugMode: true), 'http://localhost:3000');
    expect(normalizeBaseUrl('http://127.0.0.1:3000', isDebugMode: true), 'http://127.0.0.1:3000');
    expect(normalizeBaseUrl('http://10.0.2.2:3000', isDebugMode: true), 'http://10.0.2.2:3000');
    expect(normalizeBaseUrl('192.168.1.8', isDebugMode: true), 'http://192.168.1.8:3000');
    expect(normalizeBaseUrl('http://172.16.5.2:3000', isDebugMode: true), 'http://172.16.5.2:3000');

    expect(normalizeBaseUrl('api.example.com', isDebugMode: false), 'https://api.example.com');
    expect(normalizeBaseUrl('https://api.example.com:443/', isDebugMode: false), 'https://api.example.com');
    expect(normalizeBaseUrl('https://api.example.com:8443/', isDebugMode: false), 'https://api.example.com:8443');

    expect(normalizeBaseUrl('https://user:pass@api.example.com', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('https://api.example.com?x=1', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('https://api.example.com#frag', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('https://api.example.com/api', isDebugMode: false), isNull);
  });

  test('kunci lama di SharedPreferences dihapus saat startup tanpa diimpor menjadi sesi Admin', () async {
    SharedPreferences.setMockInitialValues({
      'base_url': 'https://origin-a.example.com',
      'api_key': 'legacy-shared-secret-key',
    });

    await initAppConfig(
      trustedAdminOriginOverride: 'https://origin-a.example.com',
      isDebugMode: false,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('api_key'), isFalse);
    expect(isAdminSession, isFalse);
    expect(kApiKey, isEmpty);
  });

  test('isolasi origin: getPublic membuang X-API-Key, postAdmin ditolak di origin B, dan ganti origin menghapus sesi', () async {
    const originA = 'https://origin-a.example.com';
    const originB = 'https://origin-b.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    final recorded = <http.BaseRequest>[];
    final mockClient = MockClient((req) async {
      recorded.add(req);
      if (req.url.toString() == '$originA/api/admin/verify') {
        expect(req.followRedirects, isFalse);
        expect(req.headers['X-API-Key'], 'super-secret-admin-key');
        return http.Response(jsonEncode({'ok': true, 'role': 'admin'}), 200);
      }
      if (req.url.toString() == '$originB/health') {
        return http.Response(jsonEncode({'ok': true}), 200);
      }
      return http.Response('unexpected ${req.url}', 500);
    });

    final verified = await verifyAndActivateAdmin('super-secret-admin-key', client: mockClient);
    expect(verified, isTrue);
    expect(isAdminSession, isTrue);

    await api_http.getPublic(
      Uri.parse('$originB/health'),
      headers: {'x-api-key': 'leaked', 'X-API-KEY': 'leaked-upper', 'Accept': 'application/json'},
      client: mockClient,
    );
    final probeReq = recorded.last;
    expect(probeReq.headers.keys.any((k) => k.toLowerCase() == 'x-api-key'), isFalse);

    final beforeCount = recorded.length;
    await expectLater(
      () => api_http.postAdmin(
        Uri.parse('$originB/api/mode'),
        body: jsonEncode({'mode': 'auto'}),
        client: mockClient,
      ),
      throwsA(isA<api_http.AdminSessionException>()),
    );
    expect(recorded.length, beforeCount);

    final epochBefore = kSessionEpoch;
    await setServerAddress(originB, isDebugMode: false);
    expect(kSessionEpoch, greaterThan(epochBefore));
    expect(isAdminSession, isFalse);
    expect(kApiKey, isEmpty);
  });

  test('verifikasi ditolak tanpa request di origin B, tidak mengikuti redirect, dan logout saat verify tertunda tetap Guest', () async {
    const originA = 'https://origin-a.example.com';
    const originB = 'https://origin-b.example.com';

    SharedPreferences.setMockInitialValues({'base_url': originB});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);
    int hits = 0;
    final zeroClient = MockClient((req) async {
      hits += 1;
      return http.Response('nope', 500);
    });
    expect(await verifyAndActivateAdmin('secret', client: zeroClient), isFalse);
    expect(hits, 0);

    await setServerAddress(originA, isDebugMode: false);
    final redirectClient = MockClient((req) async {
      expect(req.followRedirects, isFalse);
      return http.Response('', 302, headers: {'location': '$originB/steal'});
    });
    expect(await verifyAndActivateAdmin('secret', client: redirectClient), isFalse);
    expect(isAdminSession, isFalse);

    final completer = Completer<http.Response>();
    final slowClient = MockClient((req) => completer.future);
    final pendingVerify = verifyAndActivateAdmin('secret', client: slowClient);

    await setServerAddress(originB, isDebugMode: false);
    completer.complete(http.Response(jsonEncode({'ok': true, 'role': 'admin'}), 200));

    expect(await pendingVerify, isFalse);
    expect(isAdminSession, isFalse);

    resetConfigForTest(secureStorage: secureStore);
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);
    expect(isAdminSession, isFalse);
    expect(secureStore.data, isEmpty);
  });

  test('evaluateSmokeUi membedakan data kosong, offline, perangkat lama tanpa MQ-2, pemanasan, alarm, dan normal', () {
    final noData = evaluateSmokeUi(
      FanStatus(online: false, lastSeenSec: 0, hasLatest: false),
    );
    expect(noData.state, SmokeUiState.noData);

    final offlineNormal = evaluateSmokeUi(
      FanStatus(
        online: false,
        lastSeenSec: 45,
        hasLatest: true,
        humidity: 55,
        smoke: 10,
        smokeReady: true,
        smokeAlert: false,
      ),
    );
    expect(offlineNormal.state, SmokeUiState.offline);
    expect(offlineNormal.detail, contains('45 dtk'));

    final legacyOnline = evaluateSmokeUi(
      FanStatus(
        online: true,
        lastSeenSec: 3,
        hasLatest: true,
        humidity: 60,
        smoke: null,
        smokeReady: false,
        smokeAlert: false,
      ),
    );
    expect(legacyOnline.state, SmokeUiState.unavailable);

    final warmup = evaluateSmokeUi(
      FanStatus(
        online: true,
        lastSeenSec: 3,
        hasLatest: true,
        humidity: 60,
        smoke: 15,
        smokeReady: false,
        smokeAlert: false,
      ),
    );
    expect(warmup.state, SmokeUiState.warmingUp);

    final alertZeroPwm = evaluateSmokeUi(
      FanStatus(
        online: true,
        lastSeenSec: 2,
        hasLatest: true,
        humidity: 62,
        fanPwm: 0,
        smoke: 320,
        smokeReady: true,
        smokeAlert: true,
      ),
    );
    expect(alertZeroPwm.state, SmokeUiState.alert);
    expect(alertZeroPwm.detail, contains('0 %'));

    final normal = evaluateSmokeUi(
      FanStatus(
        online: true,
        lastSeenSec: 2,
        hasLatest: true,
        humidity: 54,
        fanPwm: 0,
        smoke: -12,
        smokeReady: true,
        smokeAlert: false,
      ),
    );
    expect(normal.state, SmokeUiState.normal);

    final fetchedAt = DateTime(2026, 11, 25, 12, 0, 0);
    final fresh = FanStatus(online: true, lastSeenSec: 5, hasLatest: true, smoke: 10, smokeReady: true);
    expect(isEffectivelyOnline(fresh, fetchedAt, fetchedAt.add(const Duration(seconds: 10))), isTrue);
    expect(isEffectivelyOnline(fresh, fetchedAt, fetchedAt.add(const Duration(seconds: 15))), isFalse);
  });

  testWidgets('aksi dua langkah _setMode dan respons polling origin lama dibatalkan saat sesi berubah', (tester) async {
    const originA = 'https://origin-a.example.com';
    const originB = 'https://origin-b.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    final speedCompleter = Completer<http.Response>();
    final originAPollCompleter = Completer<http.Response>();
    final sentPaths = <String>[];
    int statusCount = 0;

    api_http.testHttpClient = MockClient((req) async {
      sentPaths.add('${req.method} ${req.url}');
      if (req.url.path == '/api/admin/verify') {
        return http.Response(jsonEncode({'ok': true, 'role': 'admin'}), 200);
      }
      if (req.url.path == '/api/status') {
        statusCount += 1;
        if (statusCount == 1) {
          return http.Response(
            jsonEncode({
              'device': 'fan01',
              'online': true,
              'last_seen_sec_ago': 2,
              'latest': {
                'humidity': 62.0,
                'temperature': 27.5,
                'fan_pwm': 40,
                'mode': 'auto',
                'state': 'RUNNING',
                'power': true,
                'smoke': 12,
                'smoke_alert': false,
                'smoke_ready': true,
              },
            }),
            200,
          );
        }
        if (req.url.toString().startsWith(originA)) {
          return originAPollCompleter.future;
        }
        return http.Response(
          jsonEncode({'device': 'fan01', 'online': false, 'latest': null}),
          200,
        );
      }
      if (req.url.path == '/api/speed') {
        return speedCompleter.future;
      }
      return http.Response(jsonEncode({'ok': true}), 200);
    });

    addTearDown(() => api_http.testHttpClient = null);
    expect(await verifyAndActivateAdmin('admin-secret-key'), isTrue);

    await tester.pumpWidget(const MaterialApp(home: DashboardPage(isActive: true)));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('62,0 %'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Manual'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Manual'));
    await tester.pump();
    expect(sentPaths.any((p) => p.endsWith('/api/speed')), isTrue);

    await clearAdminSession();
    speedCompleter.complete(http.Response(jsonEncode({'ok': true}), 200));
    await tester.pump();

    expect(sentPaths.any((p) => p.endsWith('/api/mode')), isFalse);

    await tester.pump(const Duration(seconds: 3));
    await setServerAddress(originB, isDebugMode: false);
    originAPollCompleter.complete(
      http.Response(
        jsonEncode({
          'device': 'fan01',
          'online': true,
          'last_seen_sec_ago': 1,
          'latest': {
            'humidity': 88.8,
            'temperature': 30.0,
            'fan_pwm': 90,
            'mode': 'auto',
            'state': 'RUNNING',
            'power': true,
            'smoke': 20,
            'smoke_alert': false,
            'smoke_ready': true,
          },
        }),
        200,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('88,8 %'), findsNothing);
  });

  testWidgets('form jadwal yang sudah terbuka tidak mengirim mutasi jika sesi berubah sebelum pop', (tester) async {
    const originA = 'https://origin-a.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    final mutations = <String>[];
    api_http.testHttpClient = MockClient((req) async {
      if (req.url.path == '/api/admin/verify') {
        return http.Response(jsonEncode({'ok': true, 'role': 'admin'}), 200);
      }
      if (req.method == 'GET' && req.url.path == '/api/schedules') {
        return http.Response(jsonEncode({'device': 'fan01', 'schedules': []}), 200);
      }
      mutations.add('${req.method} ${req.url.path}');
      return http.Response(jsonEncode({'ok': true}), 201);
    });

    addTearDown(() => api_http.testHttpClient = null);
    expect(await verifyAndActivateAdmin('admin-secret-key'), isTrue);

    await tester.pumpWidget(const MaterialApp(home: SchedulesPage(isActive: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tambah jadwal'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Malam');

    await clearAdminSession();
    await tester.tap(find.text('Simpan'));
    await tester.pumpAndSettle();

    expect(mutations, isEmpty);
  });

  testWidgets('tab Masukan Guest mengirim sekali tanpa kunci, mengosongkan form pada 201, dan tidak mengulang 429', (tester) async {
    const originA = 'https://origin-a.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    int posts = 0;
    int nextStatus = 201;
    api_http.testHttpClient = MockClient((req) async {
      if (req.url.path == '/api/feedback') {
        posts += 1;
        expect(req.headers.keys.any((k) => k.toLowerCase() == 'x-api-key'), isFalse);
        if (nextStatus == 429) {
          return http.Response(
            jsonEncode({'error': 'terlalu banyak kiriman', 'retry_after_sec': 45}),
            429,
            headers: {'retry-after': '45'},
          );
        }
        return http.Response(jsonEncode({'ok': true, 'id': 1}), 201);
      }
      return http.Response('{}', 404);
    });

    addTearDown(() => api_http.testHttpClient = null);
    await tester.pumpWidget(const MaterialApp(home: FeedbackPage()));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('feedback_name')), 'Pengunjung');
    await tester.enterText(find.byKey(const Key('feedback_comment')), 'Demo alat lancar');
    await tester.tap(find.byKey(const Key('feedback_submit')));
    await tester.pumpAndSettle();

    expect(posts, 1);
    expect(find.textContaining('Terima kasih'), findsOneWidget);
    final nameField = tester.widget<TextField>(find.byKey(const Key('feedback_name')));
    final commentField = tester.widget<TextField>(find.byKey(const Key('feedback_comment')));
    expect(nameField.controller?.text, isEmpty);
    expect(commentField.controller?.text, isEmpty);

    nextStatus = 429;
    await tester.enterText(find.byKey(const Key('feedback_comment')), 'Coba lagi');
    await tester.tap(find.byKey(const Key('feedback_submit')));
    await tester.pumpAndSettle();

    expect(posts, 2);
    expect(find.textContaining('45 detik'), findsOneWidget);
  });

  test('computeSmokeYAxisBounds mencakup nilai delta negatif dan default batas atas', () {
    final neg = computeSmokeYAxisBounds([-35, 10, 80]);
    expect(neg.minY, lessThan(0));
    expect(neg.maxY, greaterThanOrEqualTo(300));

    final allNull = computeSmokeYAxisBounds([null, null]);
    expect(allNull.minY, 0);
    expect(allNull.maxY, 300);
  });

  testWidgets('Dashboard membedakan tampilan firmware lama tanpa MQ-2, pemanasan, dan offline di UI', (tester) async {
    const originA = 'https://origin-a.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    Map<String, dynamic> statusPayload = {
      'device': 'fan01',
      'online': true,
      'last_seen_sec_ago': 2,
      'latest': {
        'humidity': 64.0,
        'temperature': 27.0,
        'fan_pwm': 40,
        'mode': 'auto',
        'state': 'RUNNING',
        'power': true,
        'smoke': null,
        'smoke_alert': false,
        'smoke_ready': false,
      },
    };

    api_http.testHttpClient = MockClient((req) async {
      if (req.url.path == '/api/status') {
        expect(req.headers.keys.any((k) => k.toLowerCase() == 'x-api-key'), isFalse);
        return http.Response(jsonEncode(statusPayload), 200);
      }
      return http.Response('{}', 404);
    });
    addTearDown(() => api_http.testHttpClient = null);

    await tester.pumpWidget(const MaterialApp(home: DashboardPage(isActive: true)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Data MQ-2 tidak tersedia'), findsOneWidget);
    expect(find.text('Pemanasan'), findsNothing);

    // Pemanasan: smoke ada angka tapi smoke_ready false
    statusPayload = {
      'device': 'fan01',
      'online': true,
      'last_seen_sec_ago': 2,
      'latest': {
        'humidity': 64.0,
        'temperature': 27.0,
        'fan_pwm': 40,
        'mode': 'auto',
        'state': 'RUNNING',
        'power': true,
        'smoke': 12,
        'smoke_alert': false,
        'smoke_ready': false,
      },
    };
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Pemanasan'), findsOneWidget);

    // Offline dengan sampel normal
    statusPayload = {
      'device': 'fan01',
      'online': false,
      'last_seen_sec_ago': 35,
      'latest': {
        'humidity': 55.0,
        'temperature': 26.0,
        'fan_pwm': 0,
        'mode': 'auto',
        'state': 'IDLE',
        'power': true,
        'smoke': 5,
        'smoke_alert': false,
        'smoke_ready': true,
      },
    };
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Normal'), findsNothing);
  });

  testWidgets('logout Admin di profil real membersihkan data lama saat 401 di Jadwal, Statistik, dan Pengaturan', (tester) async {
    const originA = 'https://origin-a.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    api_http.testHttpClient = MockClient((req) async {
      if (req.url.path == '/api/admin/verify') {
        return http.Response(jsonEncode({'ok': true, 'role': 'admin'}), 200);
      }
      if (req.headers['X-API-Key'] != 'admin-secret-key') {
        return http.Response(jsonEncode({'error': 'kunci API diperlukan'}), 401);
      }
      if (req.url.path == '/api/schedules') {
        return http.Response(
          jsonEncode({
            'device': 'fan01',
            'schedules': [
              {
                'id': 1,
                'name': 'Jadwal Rahasia',
                'start_time': '22:00',
                'end_time': '05:00',
                'days': [1, 2, 3],
                'enabled': true,
              },
            ],
          }),
          200,
        );
      }
      if (req.url.path == '/api/history') {
        return http.Response(
          jsonEncode({
            'device': 'fan01',
            'range': '1h',
            'count': 1,
            'points': [
              {
                't': '2026-11-25T12:00:00.000Z',
                'humidity': 71.0,
                'temperature': 28.0,
                'fan_pwm': 60,
                'smoke': -15,
                'smoke_alert': true,
              },
            ],
          }),
          200,
        );
      }
      if (req.url.path == '/api/config') {
        return http.Response(
          jsonEncode({
            'device': 'fan01',
            'config': {
              'hum_on': 70,
              'hum_off': 60,
              'post_run_sec': 300,
              'max_pwm': 100,
              'smoke_on': 250,
              'smoke_off': 100,
            },
            'defaults': {
              'hum_on': 70,
              'hum_off': 60,
              'post_run_sec': 300,
              'max_pwm': 100,
              'smoke_on': 250,
              'smoke_off': 100,
            },
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(() => api_http.testHttpClient = null);

    // 1. SchedulesPage
    expect(await verifyAndActivateAdmin('admin-secret-key'), isTrue);
    await tester.pumpWidget(const MaterialApp(home: SchedulesPage(isActive: true)));
    await tester.pumpAndSettle();
    expect(find.text('Jadwal Rahasia'), findsOneWidget);

    await clearAdminSession();
    await tester.pumpAndSettle();
    expect(find.text('Jadwal Rahasia'), findsNothing);
    expect(find.text('Jadwal memerlukan akses Admin di Pengaturan'), findsOneWidget);

    // 2. StatsPage
    expect(await verifyAndActivateAdmin('admin-secret-key'), isTrue);
    await tester.pumpWidget(const MaterialApp(home: StatsPage(isActive: true)));
    await tester.pumpAndSettle();
    expect(find.text('71 %'), findsNWidgets(2));

    await clearAdminSession();
    await tester.pumpAndSettle();
    expect(find.text('71 %'), findsNothing);
    expect(find.text('Riwayat memerlukan akses Admin di Pengaturan'), findsNWidgets(2));

    // 3. SettingsPage
    expect(await verifyAndActivateAdmin('admin-secret-key'), isTrue);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage(isActive: true)));
    await tester.pumpAndSettle();
    final saveBtn = find.text('Simpan pengaturan');
    await tester.scrollUntilVisible(
      saveBtn,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(saveBtn, findsOneWidget);

    final logoutText = find.text('Keluar Mode Admin');
    await tester.scrollUntilVisible(
      logoutText,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(logoutText);
    await tester.pumpAndSettle();
    await tester.tap(logoutText);
    await tester.pumpAndSettle();
    expect(find.text('Simpan pengaturan'), findsNothing);
    final authErr = find.text('Pengaturan perangkat memerlukan akses Admin.');
    await tester.scrollUntilVisible(
      authErr,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(authErr, findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('SettingsPage probe /health tanpa kunci, aktivasi Admin, dan dialog reset dibatalkan saat epoch berubah', (tester) async {
    const originA = 'https://origin-a.example.com';
    const originB = 'https://origin-b.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    final requests = <http.Request>[];
    api_http.testHttpClient = MockClient((req) async {
      requests.add(req);
      if (req.url.path == '/health') {
        expect(req.headers.keys.any((k) => k.toLowerCase() == 'x-api-key'), isFalse);
        return http.Response(jsonEncode({'ok': true}), 200);
      }
      if (req.url.path == '/api/admin/verify') {
        return http.Response(jsonEncode({'ok': true, 'role': 'admin'}), 200);
      }
      if (req.url.path == '/api/config') {
        return http.Response(
          jsonEncode({
            'device': 'fan01',
            'config': {
              'hum_on': 75,
              'hum_off': 60,
              'post_run_sec': 60,
              'max_pwm': 90,
              'smoke_on': 250,
              'smoke_off': 100,
            },
            'defaults': {
              'hum_on': 70,
              'hum_off': 60,
              'post_run_sec': 60,
              'max_pwm': 100,
              'smoke_on': 250,
              'smoke_off': 100,
            },
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    addTearDown(() => api_http.testHttpClient = null);

    await tester.pumpWidget(const MaterialApp(home: SettingsPage(isActive: true)));
    await tester.pumpAndSettle();

    // Aktivasi Admin via UI
    await tester.enterText(
      find.widgetWithText(TextField, 'Kunci Admin'),
      'admin-secret-key',
    );
    await tester.tap(find.text('Aktifkan Mode Admin'));
    await tester.pumpAndSettle();
    expect(isAdminSession, isTrue);

    // Probe alamat B saat sesi Admin A aktif -> /health tidak boleh mengirim X-API-Key
    final addrField = find.byType(TextField).first;
    await tester.enterText(addrField, originB);
    await tester.tap(find.text('Uji koneksi'));
    await tester.pumpAndSettle();
    final healthReqs = requests.where((r) => r.url.toString() == '$originB/health').toList();
    expect(healthReqs.length, 1);
    expect(healthReqs.first.headers.keys.any((k) => k.toLowerCase() == 'x-api-key'), isFalse);

    // Buka dialog reset lalu cabut sesi sebelum konfirmasi -> tidak mengirim /api/config/reset
    final resetBtn = find.text('Kembalikan ke bawaan');
    await tester.scrollUntilVisible(
      resetBtn,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(resetBtn);
    await tester.pumpAndSettle();
    await tester.tap(resetBtn);
    await tester.pumpAndSettle();
    await clearAdminSession();
    await tester.tap(find.text('Kembalikan'));
    await tester.pumpAndSettle();
    expect(requests.any((r) => r.url.path == '/api/config/reset'), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Dashboard menampilkan banner alarm asap dengan PWM terpisah saat smokeAlert aktif', (tester) async {
    const originA = 'https://origin-a.example.com';
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);

    api_http.testHttpClient = MockClient((req) async {
      if (req.url.path == '/api/status') {
        return http.Response(
          jsonEncode({
            'device': 'fan01',
            'online': true,
            'last_seen_sec_ago': 1,
            'latest': {
              'humidity': 60.0,
              'temperature': 27.0,
              'fan_pwm': 0,
              'mode': 'auto',
              'state': 'ASAP',
              'power': true,
              'smoke': 340,
              'smoke_alert': true,
              'smoke_ready': true,
            },
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    addTearDown(() => api_http.testHttpClient = null);

    await tester.pumpWidget(const MaterialApp(home: DashboardPage(isActive: true)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Alarm asap aktif'), findsOneWidget);
    expect(find.textContaining('Fan dilaporkan: 0 %'), findsOneWidget);
  });
}
