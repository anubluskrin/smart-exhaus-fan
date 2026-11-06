import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Dengan "adb reverse", HP menjangkau backend lewat localhost.
// (Untuk emulator Android, ganti menjadi http://10.0.2.2:3000)
const String kDefaultBaseUrl = 'http://192.168.110.42:3000';

// Alamat backend yang sedang dipakai. Bisa diubah dari layar Pengaturan.
String kBaseUrl = kDefaultBaseUrl;

const String _kPrefKey = 'base_url';

/// Merapikan alamat yang diketik pengguna. Mengembalikan null kalau tidak valid.
String? normalizeBaseUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'http://$s';
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) return null;
  if (u.scheme != 'http' && u.scheme != 'https') return null;
  if (u.path.isNotEmpty) return null; // hanya alamat server, tanpa jalur
  if (!u.hasPort && u.scheme == 'http') s = '$s:3000';
  return s;
}

Future<void> loadBaseUrl() async {
  try {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_kPrefKey);
    if (saved != null && normalizeBaseUrl(saved) != null) kBaseUrl = saved;
  } catch (_) {}
}

Future<bool> saveBaseUrl(String normalized) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPrefKey, normalized);
    kBaseUrl = normalized;
    return true;
  } catch (_) {
    return false;
  }
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