import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as h;

import 'constants.dart';

export 'package:http/http.dart' show Response;

class AdminSessionException implements Exception {
  final String message;
  const AdminSessionException(this.message);
  @override
  String toString() => 'AdminSessionException: $message';
}

class AdminRedirectException implements Exception {
  final int statusCode;
  const AdminRedirectException(this.statusCode);
  @override
  String toString() => 'AdminRedirectException: HTTP $statusCode';
}

@visibleForTesting
h.Client? testHttpClient;

Map<String, String> _stripKeyHeaders(Map<String, String>? headers) {
  final out = <String, String>{};
  if (headers == null) return out;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != 'x-api-key') {
      out[entry.key] = entry.value;
    }
  }
  return out;
}

Future<h.Response> _send(
  String method,
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  bool followRedirects = true,
  h.Client? client,
}) async {
  final req = h.Request(method, url)..followRedirects = followRedirects;
  if (headers != null) req.headers.addAll(headers);
  if (encoding != null) req.encoding = encoding;
  if (body != null) {
    if (body is String) {
      req.body = body;
    } else if (body is List<int>) {
      req.bodyBytes = body;
    } else if (body is Map<String, String>) {
      req.bodyFields = body;
    } else {
      throw ArgumentError.value(body, 'body', 'Tipe body tidak didukung');
    }
  }

  final effectiveClient = client ?? testHttpClient;
  final ownsClient = effectiveClient == null;
  final c = effectiveClient ?? h.Client();
  try {
    final streamed = await c.send(req);
    return await h.Response.fromStream(streamed);
  } finally {
    if (ownsClient) c.close();
  }
}

/// Permintaan baca publik: tidak pernah menyertakan header X-API-Key.
Future<h.Response> getPublic(
  Uri url, {
  Map<String, String>? headers,
  h.Client? client,
}) {
  return _send(
    'GET',
    url,
    headers: _stripKeyHeaders(headers),
    client: client,
  );
}

/// Permintaan POST publik (misalnya masukan pengunjung): tidak pernah menyertakan X-API-Key.
Future<h.Response> postPublic(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  h.Client? client,
}) {
  return _send(
    'POST',
    url,
    headers: _stripKeyHeaders(headers),
    body: body,
    encoding: encoding,
    client: client,
  );
}

void _assertTrustedAdminUrl(Uri url) {
  if (url.scheme.toLowerCase() != 'https') {
    throw const AdminSessionException('Kredensial Admin hanya boleh dikirim melalui HTTPS');
  }
  final trusted = kTrustedAdminOrigin;
  if (trusted.isEmpty || originOfUri(url) != trusted) {
    throw const AdminSessionException('Tujuan tidak cocok dengan origin Admin tepercaya');
  }
}

Future<h.Response> _sendAdmin(
  String method,
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  h.Client? client,
}) async {
  if (!isAdminSession) {
    throw const AdminSessionException('Sesi Admin tidak aktif');
  }
  _assertTrustedAdminUrl(url);

  final safeHeaders = _stripKeyHeaders(headers);
  safeHeaders['X-API-Key'] = kApiKey;

  final res = await _send(
    method,
    url,
    headers: safeHeaders,
    body: body,
    encoding: encoding,
    followRedirects: false,
    client: client,
  );
  if (res.statusCode >= 300 && res.statusCode < 400) {
    throw AdminRedirectException(res.statusCode);
  }
  return res;
}

/// Verifikasi kunci pertama kali ke endpoint /api/admin/verify pada origin tepercaya tanpa redirect.
Future<h.Response> verifyAdminRequest(
  Uri url, {
  required String apiKey,
  h.Client? client,
}) async {
  _assertTrustedAdminUrl(url);
  final key = apiKey.trim();
  if (key.isEmpty) {
    throw const AdminSessionException('Kunci Admin kosong');
  }
  final res = await _send(
    'GET',
    url,
    headers: {'X-API-Key': key},
    followRedirects: false,
    client: client,
  );
  if (res.statusCode >= 300 && res.statusCode < 400) {
    throw AdminRedirectException(res.statusCode);
  }
  return res;
}

Future<h.Response> getAdmin(
  Uri url, {
  Map<String, String>? headers,
  h.Client? client,
}) =>
    _sendAdmin('GET', url, headers: headers, client: client);

Future<h.Response> postAdmin(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  h.Client? client,
}) =>
    _sendAdmin('POST', url, headers: headers, body: body, encoding: encoding, client: client);

Future<h.Response> putAdmin(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  h.Client? client,
}) =>
    _sendAdmin('PUT', url, headers: headers, body: body, encoding: encoding, client: client);

Future<h.Response> deleteAdmin(
  Uri url, {
  Map<String, String>? headers,
  h.Client? client,
}) =>
    _sendAdmin('DELETE', url, headers: headers, client: client);

/// Memilih getAdmin saat sesi Admin aktif, atau getPublic saat sesi Guest.
Future<h.Response> getForSession(
  Uri url, {
  Map<String, String>? headers,
  h.Client? client,
}) {
  if (isAdminSession) {
    return getAdmin(url, headers: headers, client: client);
  }
  return getPublic(url, headers: headers, client: client);
}
