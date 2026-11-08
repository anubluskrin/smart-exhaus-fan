import 'dart:convert';

import 'package:http/http.dart' as h;

import 'constants.dart';

export 'package:http/http.dart' show Response;

/// Menambahkan kunci API ke setiap permintaan (kecuali sudah ditentukan sendiri).
Map<String, String> _withKey(Map<String, String>? headers) {
  final m = <String, String>{...?headers};
  if (!m.containsKey('X-API-Key') && kApiKey.isNotEmpty) {
    m['X-API-Key'] = kApiKey;
  }
  return m;
}

Future<h.Response> get(Uri url, {Map<String, String>? headers}) =>
    h.get(url, headers: _withKey(headers));

Future<h.Response> post(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    h.post(url, headers: _withKey(headers), body: body, encoding: encoding);

Future<h.Response> put(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    h.put(url, headers: _withKey(headers), body: body, encoding: encoding);

Future<h.Response> delete(Uri url,
        {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
    h.delete(url, headers: _withKey(headers), body: body, encoding: encoding);