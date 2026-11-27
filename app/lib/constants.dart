import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_http.dart' as api_http;

const String _kDefinedAdminOrigin = String.fromEnvironment(
  'ADMIN_API_ORIGIN',
  defaultValue: '',
);
const String _kDefinedDefaultBaseUrl = String.fromEnvironment(
  'DEFAULT_BASE_URL',
  defaultValue: '',
);
const String _kBaseUrlPref = 'base_url';
const String _kLegacyApiKeyPref = 'api_key';
const String _kSecureOriginKey = 'bathfan_admin_origin';
const String _kSecureApiKey = 'bathfan_admin_api_key';

abstract class SecureKvStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _FlutterSecureKvStorage implements SecureKvStorage {
  const _FlutterSecureKvStorage();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true,
      migrateWithBackup: false,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

SecureKvStorage _secureStorage = const _FlutterSecureKvStorage();

bool _effectiveDebugMode = kDebugMode;
bool _hasExplicitAdminOriginConfig = _kDefinedAdminOrigin.trim().isNotEmpty;
String _trustedAdminOrigin = parseTrustedAdminOrigin(
  _kDefinedAdminOrigin,
  isDebugMode: kDebugMode,
);
String kBaseUrl = _computeDefaultBaseUrl(isDebugMode: kDebugMode);
String kAdminOrigin = '';
String kApiKey = '';
int kSessionEpoch = 0;

final ValueNotifier<int> sessionNotifier = ValueNotifier<int>(0);
Future<void>? _sessionQueue;

bool get isEffectiveDebugMode => _effectiveDebugMode;

bool get canConfigureAdmin =>
    _trustedAdminOrigin.isNotEmpty ||
    (_effectiveDebugMode && !_hasExplicitAdminOriginConfig);

String get kTrustedAdminOrigin {
  if (_hasExplicitAdminOriginConfig) return _trustedAdminOrigin;
  if (_effectiveDebugMode && kBaseUrl.isNotEmpty) {
    final u = Uri.tryParse(kBaseUrl);
    if (u != null && isAllowedAdminTransport(u, isDebugMode: true)) {
      return originOfUri(u);
    }
  }
  return '';
}

String get kDefaultBaseUrl => _computeDefaultBaseUrl(isDebugMode: _effectiveDebugMode);

bool get isAdminSession {
  final trusted = kTrustedAdminOrigin;
  return trusted.isNotEmpty &&
      kApiKey.isNotEmpty &&
      kAdminOrigin == trusted &&
      originOf(kBaseUrl) == trusted;
}

void _bumpEpoch() {
  kSessionEpoch += 1;
  sessionNotifier.value = kSessionEpoch;
}

Future<T> _serializeSession<T>(Future<T> Function() action) {
  final prev = _sessionQueue;
  final done = Completer<void>();
  _sessionQueue = done.future;

  Future<T> run() async {
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      return await action();
    } finally {
      if (identical(_sessionQueue, done.future)) {
        _sessionQueue = null;
      }
      done.complete();
    }
  }

  return run();
}

String _computeDefaultBaseUrl({required bool isDebugMode}) {
  if (_kDefinedDefaultBaseUrl.isNotEmpty) {
    final normalized = normalizeBaseUrl(
      _kDefinedDefaultBaseUrl,
      isDebugMode: isDebugMode,
    );
    if (normalized != null) return normalized;
  }
  return _trustedAdminOrigin;
}

final RegExp _ipv4Re = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

bool isPrivateOrLoopbackHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower == '::1') return true;
  final m = _ipv4Re.firstMatch(lower);
  if (m == null) return false;
  final a = int.parse(m.group(1)!);
  final b = int.parse(m.group(2)!);
  final c = int.parse(m.group(3)!);
  final d = int.parse(m.group(4)!);
  if (a > 255 || b > 255 || c > 255 || d > 255) return false;

  if (a == 127) return true; // 127.0.0.0/8 loopback
  if (a == 10) return true; // 10.0.0.0/8 privat (termasuk 10.0.2.2)
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  return false;
}

String _formatCanonicalOrigin(Uri u) {
  final scheme = u.scheme.toLowerCase();
  final host = u.host.toLowerCase();
  final formattedHost = host.contains(':') ? '[$host]' : host;
  final defaultPort = scheme == 'https' ? 443 : 80;
  final portPart = u.hasPort && u.port != defaultPort ? ':${u.port}' : '';
  return '$scheme://$formattedHost$portPart';
}

String originOfUri(Uri u) {
  final scheme = u.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return '';
  if (u.host.isEmpty || u.userInfo.isNotEmpty) return '';
  return _formatCanonicalOrigin(u);
}

String originOf(String url) {
  if (url.trim().isEmpty) return '';
  final u = Uri.tryParse(url.trim());
  if (u == null) return '';
  return originOfUri(u);
}

bool isAllowedAdminTransport(Uri u, {bool? isDebugMode}) {
  if (u.host.isEmpty || u.userInfo.isNotEmpty) return false;
  final scheme = u.scheme.toLowerCase();
  if (scheme == 'https') return true;
  final debug = isDebugMode ?? _effectiveDebugMode;
  return scheme == 'http' && debug && isPrivateOrLoopbackHost(u.host);
}

String parseTrustedAdminOrigin(String raw, {bool? isDebugMode}) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  if (s.contains('?') || s.contains('#') || s.contains('@') || s.contains(RegExp(r'\s'))) {
    return '';
  }
  final u = Uri.tryParse(s);
  if (u == null) return '';
  if (!isAllowedAdminTransport(u, isDebugMode: isDebugMode)) return '';
  if (u.hasQuery || u.hasFragment) return '';
  if (u.path.isNotEmpty && u.path != '/') return '';
  if (u.hasPort && (u.port < 1 || u.port > 65535)) return '';
  return _formatCanonicalOrigin(u);
}

/// Merapikan dan memvalidasi alamat server.
/// Mengembalikan null jika alamat tidak valid atau menggunakan HTTP publik/release.
String? normalizeBaseUrl(String input, {bool? isDebugMode}) {
  final debug = isDebugMode ?? kDebugMode;
  final s = input.trim();
  if (s.isEmpty) return null;
  if (s.contains('?') || s.contains('#') || s.contains('@') || s.contains(RegExp(r'\s'))) {
    return null;
  }

  String candidate;
  if (s.contains('://')) {
    final lower = s.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return null;
    }
    candidate = s;
  } else {
    final probe = Uri.tryParse('https://$s');
    if (probe == null || probe.host.isEmpty) return null;
    if (debug && isPrivateOrLoopbackHost(probe.host)) {
      candidate = probe.hasPort ? 'http://$s' : 'http://$s:3000';
    } else {
      candidate = 'https://$s';
    }
  }

  final u = Uri.tryParse(candidate);
  if (u == null || u.host.isEmpty) return null;
  if (u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) return null;
  if (u.path.isNotEmpty && u.path != '/') return null;
  if (u.hasPort && (u.port < 1 || u.port > 65535)) return null;

  final scheme = u.scheme.toLowerCase();
  if (scheme == 'https') {
    return _formatCanonicalOrigin(u);
  }
  if (scheme == 'http') {
    if (!debug || !isPrivateOrLoopbackHost(u.host)) return null;
    return _formatCanonicalOrigin(u);
  }
  return null;
}

Future<void> _deleteStoredAdminSession() async {
  try {
    await _secureStorage.delete(_kSecureOriginKey);
    await _secureStorage.delete(_kSecureApiKey);
  } catch (_) {}
}

Future<void> initAppConfig({
  String? trustedAdminOriginOverride,
  bool? isDebugMode,
  SecureKvStorage? secureStorageOverride,
}) async {
  if (secureStorageOverride != null) {
    _secureStorage = secureStorageOverride;
  }
  final debug = isDebugMode ?? kDebugMode;
  _effectiveDebugMode = debug;
  if (trustedAdminOriginOverride != null) {
    _hasExplicitAdminOriginConfig = true;
    _trustedAdminOrigin = parseTrustedAdminOrigin(
      trustedAdminOriginOverride,
      isDebugMode: debug,
    );
  } else {
    _hasExplicitAdminOriginConfig = _kDefinedAdminOrigin.trim().isNotEmpty;
    _trustedAdminOrigin = parseTrustedAdminOrigin(
      _kDefinedAdminOrigin,
      isDebugMode: debug,
    );
  }

  kApiKey = '';
  kAdminOrigin = '';
  kBaseUrl = _computeDefaultBaseUrl(isDebugMode: debug);

  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_kLegacyApiKeyPref)) {
      await prefs.remove(_kLegacyApiKeyPref);
    }
    final savedUrl = prefs.getString(_kBaseUrlPref);
    if (savedUrl != null) {
      final normalized = savedUrl.isEmpty
          ? ''
          : normalizeBaseUrl(savedUrl, isDebugMode: debug);
      if (normalized != null) {
        kBaseUrl = normalized;
      }
    }
  } catch (_) {}

  final trustedOrigin = kTrustedAdminOrigin;
  if (trustedOrigin.isNotEmpty && originOf(kBaseUrl) == trustedOrigin) {
    try {
      final storedOrigin = await _secureStorage.read(_kSecureOriginKey);
      final storedKey = await _secureStorage.read(_kSecureApiKey);
      if (storedOrigin == trustedOrigin &&
          storedKey != null &&
          storedKey.trim().isNotEmpty) {
        kAdminOrigin = storedOrigin!;
        kApiKey = storedKey.trim();
      }
    } catch (_) {
      kAdminOrigin = '';
      kApiKey = '';
    }
  }
  _bumpEpoch();
}

Future<bool> setServerAddress(String input, {bool? isDebugMode}) async {
  final normalized = input.trim().isEmpty
      ? ''
      : normalizeBaseUrl(input, isDebugMode: isDebugMode ?? _effectiveDebugMode);
  if (normalized == null) return false;

  final previousOrigin = originOf(kBaseUrl);
  final nextOrigin = originOf(normalized);
  final originChanged = previousOrigin != nextOrigin;

  if (originChanged) {
    kApiKey = '';
    kAdminOrigin = '';
  }
  kBaseUrl = normalized;
  _bumpEpoch();

  return _serializeSession(() async {
    if (originChanged) {
      await _deleteStoredAdminSession();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBaseUrlPref, normalized);
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> clearAdminSession() async {
  kApiKey = '';
  kAdminOrigin = '';
  _bumpEpoch();
  await _serializeSession(() async {
    await _deleteStoredAdminSession();
  });
}

Future<bool> verifyAndActivateAdmin(
  String candidateKey, {
  http.Client? client,
}) async {
  final key = candidateKey.trim();
  if (key.isEmpty) return false;

  final targetOrigin = kTrustedAdminOrigin;
  if (targetOrigin.isEmpty || originOf(kBaseUrl) != targetOrigin) {
    return false;
  }

  final startEpoch = kSessionEpoch;
  http.Response res;
  try {
    res = await api_http.verifyAdminRequest(
      Uri.parse('$targetOrigin/api/admin/verify'),
      apiKey: key,
      client: client,
    );
  } catch (_) {
    return false;
  }

  if (res.statusCode != 200) return false;

  return _serializeSession(() async {
    if (kSessionEpoch != startEpoch ||
        originOf(kBaseUrl) != targetOrigin ||
        kTrustedAdminOrigin != targetOrigin) {
      return false;
    }
    try {
      await _secureStorage.write(_kSecureOriginKey, targetOrigin);
      await _secureStorage.write(_kSecureApiKey, key);
    } catch (_) {
      await _deleteStoredAdminSession();
      return false;
    }

    if (kSessionEpoch != startEpoch ||
        originOf(kBaseUrl) != targetOrigin ||
        kTrustedAdminOrigin != targetOrigin) {
      await _deleteStoredAdminSession();
      return false;
    }

    kAdminOrigin = targetOrigin;
    kApiKey = key;
    _bumpEpoch();
    return true;
  });
}

@visibleForTesting
void resetConfigForTest({SecureKvStorage? secureStorage, bool? isDebugMode}) {
  final debug = isDebugMode ?? kDebugMode;
  _effectiveDebugMode = debug;
  _hasExplicitAdminOriginConfig = _kDefinedAdminOrigin.trim().isNotEmpty;
  _trustedAdminOrigin = parseTrustedAdminOrigin(
    _kDefinedAdminOrigin,
    isDebugMode: debug,
  );
  _secureStorage = secureStorage ?? const _FlutterSecureKvStorage();
  kBaseUrl = _computeDefaultBaseUrl(isDebugMode: debug);
  kAdminOrigin = '';
  kApiKey = '';
  kSessionEpoch = 0;
  sessionNotifier.value = 0;
  _sessionQueue = null;
}

const Color kBg = Color(0xFF0B1D3A);
const Color kCard = Color(0xFF112A4F);
const Color kLine = Color(0xFF1F3F6E);
const Color kMuted = Color(0xFF8FA9D0);
const Color kAccent = Color(0xFF7DB8FF);

Color humidityColor(double h) {
  if (h < 60) return const Color(0xFF7DB8FF); // nyaman
  if (h < 70) return const Color(0xFFFACC15); // waspada
  if (h < 90) return const Color(0xFFFB923C); // tinggi
  return const Color(0xFFEF4444); // kritis
}

String humidityLabel(double h) {
  if (h < 60) return 'nyaman';
  if (h < 70) return 'waspada';
  if (h < 90) return 'tinggi';
  return 'kritis';
}
