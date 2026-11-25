import 'dart:async';
import 'dart:convert';

import 'package:bathfan_app/api_http.dart' as api_http;
import 'package:bathfan_app/constants.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    resetConfigForTest();
  });

  test('normalizeBaseUrl menolak HTTP publik, HTTP di release, prefix palsu, dan komponen URL terlarang', () {
    // Release menolak semua HTTP termasuk localhost & LAN
    expect(normalizeBaseUrl('http://example.com', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://localhost:3000', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://127.0.0.1:3000', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://192.168.1.8:3000', isDebugMode: false), isNull);
    expect(normalizeBaseUrl('http://10.0.2.2:3000', isDebugMode: false), isNull);

    // Debug menolak HTTP publik dan domain publik berawalan 192.168.
    expect(normalizeBaseUrl('http://example.com', isDebugMode: true), isNull);
    expect(normalizeBaseUrl('http://192.168.evil.com:3000', isDebugMode: true), isNull);
    expect(normalizeBaseUrl('http://127.0.0.1.evil.com:3000', isDebugMode: true), isNull);
    expect(normalizeBaseUrl('http://172.32.0.1:3000', isDebugMode: true), isNull);

    // Debug mengizinkan HTTP privat / loopback (termasuk adb reverse localhost)
    expect(normalizeBaseUrl('http://localhost:3000', isDebugMode: true), 'http://localhost:3000');
    expect(normalizeBaseUrl('http://127.0.0.1:3000', isDebugMode: true), 'http://127.0.0.1:3000');
    expect(normalizeBaseUrl('http://10.0.2.2:3000', isDebugMode: true), 'http://10.0.2.2:3000');
    expect(normalizeBaseUrl('192.168.1.8', isDebugMode: true), 'http://192.168.1.8:3000');
    expect(normalizeBaseUrl('http://172.16.5.2:3000', isDebugMode: true), 'http://172.16.5.2:3000');

    // Domain publik tanpa skema -> HTTPS tanpa :3000
    expect(normalizeBaseUrl('api.example.com', isDebugMode: false), 'https://api.example.com');
    expect(normalizeBaseUrl('https://api.example.com:443/', isDebugMode: false), 'https://api.example.com');
    expect(normalizeBaseUrl('https://api.example.com:8443/', isDebugMode: false), 'https://api.example.com:8443');

    // Tolak userinfo, query, fragmen, path selain '/'
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

    // 1. getPublic ke origin B tidak boleh membawa X-API-Key bahkan bila caller menyertakannya
    await api_http.getPublic(
      Uri.parse('$originB/health'),
      headers: {'x-api-key': 'leaked', 'X-API-KEY': 'leaked-upper', 'Accept': 'application/json'},
      client: mockClient,
    );
    final probeReq = recorded.last;
    expect(probeReq.headers.keys.any((k) => k.toLowerCase() == 'x-api-key'), isFalse);

    // 2. postAdmin ke origin B ditolak sebelum menyentuh jaringan
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

    // 3. Pindah alamat ke origin B menghapus sesi Admin dan menaikkan epoch
    final epochBefore = kSessionEpoch;
    await setServerAddress(originB, isDebugMode: false);
    expect(kSessionEpoch, greaterThan(epochBefore));
    expect(isAdminSession, isFalse);
    expect(kApiKey, isEmpty);
  });

  test('verifikasi ditolak tanpa request di origin B, tidak mengikuti redirect, dan logout saat verify tertunda tetap Guest', () async {
    const originA = 'https://origin-a.example.com';
    const originB = 'https://origin-b.example.com';

    // 1. Saat origin B aktif, verifyAndActivateAdmin mengirim 0 request
    SharedPreferences.setMockInitialValues({'base_url': originB});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);
    int hits = 0;
    final zeroClient = MockClient((req) async {
      hits += 1;
      return http.Response('nope', 500);
    });
    expect(await verifyAndActivateAdmin('secret', client: zeroClient), isFalse);
    expect(hits, 0);

    // 2. Redirect 302 pada verify atau mutasi tidak diikuti dan dianggap gagal
    await setServerAddress(originA, isDebugMode: false);
    final redirectClient = MockClient((req) async {
      expect(req.followRedirects, isFalse);
      return http.Response('', 302, headers: {'location': '$originB/steal'});
    });
    expect(await verifyAndActivateAdmin('secret', client: redirectClient), isFalse);
    expect(isAdminSession, isFalse);

    // 3. Logout / pindah origin saat verify masih tertunda tetap Guest sesudah respons tiba & sesudah restart
    final completer = Completer<http.Response>();
    final slowClient = MockClient((req) => completer.future);
    final pendingVerify = verifyAndActivateAdmin('secret', client: slowClient);

    await setServerAddress(originB, isDebugMode: false);
    completer.complete(http.Response(jsonEncode({'ok': true, 'role': 'admin'}), 200));

    expect(await pendingVerify, isFalse);
    expect(isAdminSession, isFalse);

    // Simulasi restart aplikasi kembali ke origin A: kunci tidak boleh tersimpan
    resetConfigForTest();
    SharedPreferences.setMockInitialValues({'base_url': originA});
    await initAppConfig(trustedAdminOriginOverride: originA, isDebugMode: false);
    expect(isAdminSession, isFalse);
  });
}
