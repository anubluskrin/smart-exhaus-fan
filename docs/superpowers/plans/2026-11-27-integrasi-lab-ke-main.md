# Integrasi `lab` ke `main`

## Prompt untuk agent pelaksana — salin bagian ini

> Kerjakan integrasi branch `lab` ke `main` sesuai checklist di bawah. Gunakan `main` lokal sebagai sumber utama untuk tampilan, splash, dan navigasi. Ambil dari `lab` sistem Pengunjung/Admin, Demo Skenario beserta dukungan server dan firmware, serta informasi mode Auto. Jika mendapat satu nomor task saja, kerjakan hanya task tersebut di branch integrasi yang sama setelah prasyaratnya selesai.
>
> Di Dashboard, kartu Demo Skenario harus langsung terlihat untuk semua role, bahkan sebelum ada data atau saat perangkat offline. Yang bergantung pada koneksi, izin, dan kesiapan perangkat adalah **aksinya**. Gabungkan informasi Auto tanpa membuat pemilih mode kedua. Hapus halaman Masukan; pertahankan tampilan halaman lain seperti `main`. Alur lokal bawaan adalah Flutter debug + server profil `bazar`.
>
> Baca `AGENTS.md` dan README. Kerjakan di worktree terpisah. Selesaikan konflik per bagian, termasuk perubahan `lab` yang masuk otomatis tanpa konflik teks. Serahkan hasil sebagai satu branch siap PR ke `main`, dengan ringkasan, hasil tes, dan screenshot. Biarkan pemilik repo me-review sebelum merge final.

## Checklist eksekusi

Kerjakan berurutan. Saat menyerahkan ke agent berikutnya, catat branch, path worktree, task terakhir yang selesai, dan pemeriksaan yang belum dijalankan.

### 1. Siapkan branch integrasi dan selesaikan konflik Git

- [ ] Periksa `git status --short --branch` dan catat SHA `main` serta `lab`. Saat rencana dibuat, `main` lokal (`912c392`) satu commit di depan `origin/main` dan `lab` berada di `8fbd1c1`. Jika berubah, ulangi `git merge-tree --write-tree --name-only main lab` untuk melihat konflik terbaru.
- [ ] Dari repo asal, jalankan `git worktree add -b integrasi/lab-ke-main ../smart-exhaus-fan-integrasi main`. Jalankan `git merge --no-commit --no-ff lab` **di worktree baru**. Biarkan `laporan-akhir/` dan `poster/` di worktree asal.
- [ ] Lima konflik yang terdeteksi: `.gitignore` (gabungkan aturan yang relevan), `README.md` (pertahankan panduan `main`, tambahkan alur role/demo), `app/lib/main.dart` (mulai dari shell, splash, dan Dashboard `main`), `app/pubspec.yaml` (pertahankan aset `main`, tambahkan dependensi yang dipakai), `app/pubspec.lock` (hasilkan kembali dengan `flutter pub get` di `app/`).
- [ ] Periksa juga file yang masuk otomatis: pertahankan perilaku layanan `lab`, tetapi jangan ikut membawa perubahan tampilan di luar scope atau `app/android/build/reports/problems/problems-report.html`. Pastikan `git diff --name-only --diff-filter=U` kosong. Stage file yang ditinjau, lalu selesaikan merge commit di branch integrasi.

### 2. Pasang sistem Pengunjung/Admin dan dukungan demo

- [ ] Gunakan implementasi `lab` untuk backend, kontrol sesi Flutter, dan firmware demo. Tidak perlu merge `deploy` lagi. Di profil `bazar`, Pengunjung bisa membaca status, riwayat, jadwal, dan konfigurasi. Kontrol perangkat, mutasi jadwal/config, serta start/stop demo tetap membutuhkan Admin terverifikasi **di server**.
- [ ] Hubungkan halaman `main` ke helper `api_http.dart` yang sesuai. Pertahankan origin Admin tepercaya, isolasi API key, guard pergantian sesi, allowlist perangkat, dan pemisahan riwayat fisik/demo. Pertahankan prioritas alarm fisik serta pengembalian input fisik dari firmware `lab`.
- [ ] **Selesai bila:** pembacaan publik berhasil di `bazar`; request kontrol langsung tanpa kunci ditolak dan tidak menerbitkan perintah MQTT; Admin yang sah bisa menjalankan kontrol yang diizinkan. Profil `real` tetap memerlukan autentikasi untuk `/api/*`.

### 3. Tampilkan Demo Skenario secara permanen

- [ ] Pakai kembali `demo_panel.dart`, `demo_models.dart`, dan `demo_scene.dart` seperlunya. Letakkan kartu langsung di Dashboard `main`, tanpa tombol pembuka dan tanpa syarat render berdasarkan role, telemetri, atau flag. Pertahankan informasi utama Dashboard di atas kartu.
- [ ] Bedakan izin **Mulai** dan **Hentikan**. Mulai memerlukan Admin, perangkat online, demo tersedia, sensor siap, tanpa alarm fisik, tanpa sesi aktif atau perintah tertunda. Hentikan memerlukan Admin, perangkat online, sesi aktif yang teridentifikasi, dan tidak sedang menunggu konfirmasi stop; jangan gunakan syarat kesiapan Mulai untuk Hentikan.
- [ ] Nonaktifkan pemilihan preset dan aksi yang tidak tersedia. Tampilkan satu alasan yang sesuai dengan keadaan, misalnya “Menunggu data perangkat”, “Perangkat offline”, “Hanya Admin yang dapat memulai demo”, atau “Demo tidak tersedia pada perangkat ini”. Cek kembali sesi dan perangkat di handler sebelum mengirim perintah.
- [ ] **Selesai bila:** membuka Dashboard saat ESP32 mati tetap menampilkan kartu; mengetuk kontrol nonaktif tidak menghasilkan request. Jika koneksi putus atau sesi berganti dari Admin ke Pengunjung saat kartu terbuka, aksi langsung terkunci. Status “Berjalan” mengikuti konfirmasi perangkat.

### 4. Satukan tampilan Auto tanpa mengubah identitas Dashboard

- [ ] Pertahankan satu pemilih Auto/Manual dari `main`. Saat Auto aktif, tampilkan penjelasan dari `lab` di dekat pemilih itu. Gunakan kartu demo untuk preset dan progres simulasi; jangan ulangi pemilih mode atau seluruh ringkasan daya/kipas di sana.
- [ ] Jika membantu keterbacaan, gunakan ilustrasi kipas yang sudah tersedia. Animasi mengikuti telemetri, berhenti saat offline, dan tetap dapat dipahami dalam bentuk statis saat pengguna mengurangi gerakan.
- [ ] **Selesai bila:** pengguna bisa membedakan mode perangkat dari skenario simulasi; satu status tidak tampil sebagai dua kontrol. Splash, palet, urutan informasi utama, dan gaya kartu masih mengikuti `main`.

### 5. Hapus halaman Masukan dan periksa navigasi

- [ ] Hapus `feedback_page.dart`, tab, import, serta referensi UI-nya. Pertahankan endpoint `POST /api/feedback` untuk kompatibilitas klien lama.
- [ ] Sisakan **Dashboard · Statistik · Jadwal · Pengaturan**. Periksa indeks tab, halaman yang dibuka, dan polling tab aktif. Pertahankan tampilan ketiga halaman di luar Dashboard, dengan penyesuaian seperlunya untuk akses role.
- [ ] Perbarui README, `AGENTS.md`, dan [runbook demo](../../demo-scenario-bench.md) agar konsisten. Khusus runbook: firmware biasa sekarang menampilkan **kartu nonaktif**, dan Pengunjung dapat melihat sesi berjalan tanpa bisa mengontrolnya.

### 6. Siapkan cara menjalankan lokal dan bukti review

- [ ] Sediakan satu perintah dari root repo untuk menjalankan backend lokal dengan `APP_PROFILE=bazar` dan aplikasi dengan `flutter run --debug`; dokumentasikan prasyarat serta alamat API emulator/HP. `bazar` adalah profil server, bukan flag bawaan Flutter. Pertahankan default produksi `real`, kredensial lokal di luar Git, dan aktivasi demo fisik secara eksplisit.
- [ ] Jalankan `npm test` di `backend/`, `flutter analyze` dan `flutter test` di `app/`, serta tes di `firmware/tests/`. Untuk pengujian DB dan ESP32 gunakan prosedur di runbook. Catat tes yang lulus, gagal, atau belum dijalankan beserta alasannya.
- [ ] Tambahkan atau sesuaikan widget test untuk kartu yang selalu terlihat, kontrol nonaktif tanpa request, dan transisi koneksi/role. Gunakan matriks berikut untuk pemeriksaan UI:

| Kondisi | Hasil yang harus terlihat |
|---|---|
| Awal aplikasi, belum ada telemetri | Kartu terlihat; tidak ada aksi demo aktif. |
| Pengunjung offline / online | Kartu terlihat pada keduanya; semua aksi terkunci. Saat online, progres sesi aktif dapat dibaca. |
| Admin offline, termasuk setelah sesi aktif | Kartu terlihat; Mulai, Hentikan, dan pilihan preset nonaktif. |
| Admin online, demo dinonaktifkan atau sensor belum siap | Kartu menjelaskan alasannya; Mulai nonaktif. |
| Admin online, siap, belum ada sesi | Preset dan Mulai aktif. Satu ketukan mengirim satu perintah. |
| Admin online, sesi berjalan | Mulai nonaktif; Hentikan tersedia sampai perintah stop dikirim. |

- [ ] Bandingkan screenshot keempat tab dengan `main`. Lampirkan contoh Dashboard untuk Pengunjung dan Admin, masing-masing online/offline. Ringkas resolusi konflik dan hasil pemeriksaan di deskripsi PR; bedakan hasil widget test dari hasil uji dengan ESP32 fisik.
