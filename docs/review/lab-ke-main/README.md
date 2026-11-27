# Review integrasi `lab` → `main`

Target PR: `main`. Branch sumber: `integrasi/lab-ke-main`. Merge `955525a` memakai `main` lokal `912c392` sebagai parent pertama dan `lab` `8fbd1c1` sebagai parent kedua. Tidak ada perubahan pada `main` atau worktree `lab`.

## Yang perlu ditinjau

- Splash Android dan Flutter, navigasi empat tab, serta kartu utama Dashboard mengikuti `main`. Informasi Auto berada dekat pemilih Auto/Manual yang sudah ada. Kartu Demo Skenario terlihat tanpa membuka panel; pilihan dan tombol mengikuti koneksi, kesiapan, dan sesi. Animasi Dashboard berhenti saat telemetri offline.
- Pengunjung dapat melihat progres; hanya Admin bisa memulai atau menghentikan demo. Perintah tidak dianggap berhasil sampai ada konfirmasi ESP32. Riwayat fisik tetap default. Halaman Masukan dihapus, sedangkan `POST /api/feedback` dipertahankan untuk klien lama.
- Konflik diselesaikan pada `.gitignore`, `README.md`, `app/lib/main.dart`, `app/pubspec.yaml`, dan `app/pubspec.lock`. Laporan build Android yang masuk dari `lab` tidak disertakan. Lockfile Flutter dihasilkan ulang; lockfile Node juga diperbarui untuk tiga advisory pada dependensi transitif.
- Alur lokal: `.\scripts\dev-bazar.ps1 -Device <id-adb>`. Aplikasi berjalan dalam mode debug, server menggunakan profil `bazar` di loopback. Produksi tetap memakai `real` secara default; aktuasi demo memerlukan aktivasi eksplisit pada peralatan demo.

## Perbandingan tampilan

Gambar di bawah diambil dari render widget Flutter dengan respons API tiruan, bukan dari ESP32 atau HP. Referensi kiri menggunakan kode UI `main` pada `912c392`.

| Tab | `main` | Integrasi |
|---|---|---|
| Dashboard, belum ada data | [Sebelum](main-dashboard.png) | [Sesudah](dashboard.png) |
| Statistik | [Sebelum](main-statistik.png) | [Sesudah](statistik.png) — pilihan Demo terakhir muncul setelah sesi teramati |
| Jadwal | [Sebelum](main-jadwal.png) | [Sesudah](jadwal.png) — Pengunjung hanya bisa melihat |
| Pengaturan | [Sebelum](main-pengaturan.png) | [Sesudah](pengaturan.png) — kartu akses memisahkan URL dari verifikasi Admin |

| Peran | Offline | Online |
|---|---|---|
| Pengunjung | [Kontrol terkunci](pengunjung-offline.png) | [Hanya lihat](pengunjung-online.png) |
| Admin | [Koneksi hilang saat demo berjalan; kontrol terkunci](admin-offline.png) | [Perangkat siap menerima demo](admin-online.png) |

Untuk mengambil ulang gambar integrasi dari `app/`, ganti `<flutter-sdk>` dengan path SDK setempat:

```powershell
flutter test test/dashboard_integration_test.dart `
  --dart-define=BATHFAN_SCREENSHOTS=../docs/review/lab-ke-main `
  --dart-define=BATHFAN_REVIEW_FONTS=<flutter-sdk>/bin/cache/artifacts/material_fonts
```

## Verifikasi

- **Backend:** 19 tes lulus, termasuk tes riwayat fisik/demo dengan PostgreSQL 18 terisolasi. `npm audit --omit=dev`: 0 temuan. Bind loopback dan `/health` juga diperiksa.
- **Flutter:** 21 tes lulus; mencakup Dashboard sebelum ada telemetri, offline, kesiapan sensor, transisi Admin ke Pengunjung, penguncian kontrol saat refresh gagal, dan polling hanya untuk tab aktif. `flutter analyze --no-fatal-infos` selesai tanpa error/warning; ada info deprecasi impor `flutter/material.dart` dari SDK 3.50.
- **Android:** `flutter build apk --debug` berhasil setelah wrapper Gradle, AGP, dan Kotlin dinaikkan ke minimum Flutter 3.50. SDK mengeluarkan peringatan untuk upgrade berikutnya. Skrip development belum diuji end-to-end dengan HP/emulator.
- **Firmware:** dua suite C++ host lulus (`demo_scenario_test`, `demo_session_test`). Build ESP32 biasa dan demo (`BATHFAN_DEMO_ENABLED=1`) keduanya berhasil dengan Arduino CLI; penggunaan flash masing-masing 82% dan 83%. Belum melakukan flash atau uji pada ESP32 dan kipas fisik.
