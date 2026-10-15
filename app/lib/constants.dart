import 'package:flutter/material.dart';

// Dengan "adb reverse", HP menjangkau backend lewat localhost.
// (Untuk emulator Android, ganti menjadi http://10.0.2.2:3000)
const String kBaseUrl = 'http://localhost:3000';

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