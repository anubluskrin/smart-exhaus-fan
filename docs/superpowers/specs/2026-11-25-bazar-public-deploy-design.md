# Desain Deployment Bazar & Penguatan Keamanan (Smart Exhaust Fan)

**Tanggal:** 2026-11-25

**Konteks:** Demo alat fisik IoT di stand bazar secara *live* (ESP32 ↔ EMQX Cloud ↔ Cloud Backend ↔ Aplikasi Flutter).

## 1. Tujuan & Konteks Penggunaan (Why)

Pada pameran/bazar:
- Alat fisik ESP32 (DHT + MQ-2 + Fan 4-pin + Relay) menyala dan terhubung ke internet di meja stand.
- **HP Pengunjung (Guest):** Hanya melihat status *real-time* (`Dashboard`), grafik (`Statistik`), jadwal (`Jadwal`), dan konfigurasi ambang secara *read-only*, serta dapat mengirimkan masukan pengunjung (**Feedback**).
- **HP Tim (Admin):** Menyimpan `X-API-Key` pada *origin* backend tepercaya untuk mengendalikan fan secara langsung (Power, Mode Auto/Manual, Kecepatan PWM, CRUD Jadwal, dan Pengaturan Ambang). Pengunjung yang ingin mencoba kontrol fisik meminjam HP tim di tempat.

## 2. Non-Goals & Penghapusan Kompleksitas (YAGNI)

- **Tanpa `DummyEngine` / Simulator Lokal di Aplikasi:** Karena demo selalu terhubung ke alat fisik melalui Backend, simulator lokal di aplikasi dihapus untuk menghindari duplikasi logika firmware C++ di Dart dan menghilangkan *race condition* perpindahan mode *Admin → Dummy*.
- **Tanpa `/auth/login` Pembagi `API_KEY` Induk:** Tidak ada endpoint login username/password yang mengembalikan `API_KEY` melalui jaringan. Autentikasi Admin dilakukan dengan memasukkan `X-API-Key` langsung di HP tim pada *origin* tepercaya.

## 3. Keputusan Rancangan Teknis

### 3.1 Konfigurasi Bawaan `post_run_sec` (`real` vs `bazar`)
- Kasus nyata (*real*): `post_run_sec = 300` detik (5 menit), sesuai spesifikasi laporan dan `db.js`.
- Kasus pameran (*bazar*): `post_run_sec = 60` detik (1 menit), agar pengunjung bazar tidak menunggu 5 menit saat mengamati transisi *post-run*.
- Diatur melalui variabel lingkungan `.env` di backend:
  - `APP_PROFILE=real|bazar` (default `real` → `300` detik; jika `bazar` → `60` detik), atau override eksplisit melalui `DEFAULT_POST_RUN_SEC`.
  - Nilai perangkat yang sudah tersimpan di tabel `device_config` tidak ditimpa saat startup; nilai bawaan ini dipakai untuk perangkat baru dan tombol **Kembalikan ke bawaan** (`POST /api/config/reset`).

### 3.2 Isolasi Kredensial, Origin, & Transport di Flutter
- **`app/lib/api_http.dart`:**
  - Permintaan publik (`getPublic`, `postPublic`) membuang header `X-API-Key` tanpa membedakan kapitalisasi. `/health` hanya menguji keterjangkauan, bukan menetapkan kepercayaan.
  - Tetapkan satu `ADMIN_API_ORIGIN` HTTPS pada build HP tim (alamat, bukan rahasia). Origin kosong/nonvalid menonaktifkan Admin. Alamat yang diketik Guest tidak dapat menjadi origin tepercaya lewat probe. Verifikasi pertama hanya mengirim kunci ke `GET /api/admin/verify` pada origin build tersebut, bila sama dengan origin aktif. Semua permintaan berkunci menolak redirect (termasuk saat verifikasi); metode Admin biasa juga mensyaratkan sesi aktif pada origin itu.
  - Simpan pasangan origin–kunci dalam penyimpanan aman berbasis Android Keystore, bukan `SharedPreferences`. Hapus kunci lama dari preferensi saat upgrade tanpa mengimpornya; pengguna tim memasukkan ulang kunci. Jangan isi otomatis field dari kunci tersimpan, menaruh kunci di APK, atau mencatatnya di log.
- **Uji Koneksi & Ganti Origin (`app/lib/constants.dart`, `app/lib/settings_page.dart`):**
  - Probe koneksi memanggil `GET /health` menggunakan `getPublic` (tanpa kunci).
  - Mengganti origin atau logout membatalkan sesi di memori dan menaikkan `kSessionEpoch` sebelum operasi asinkron. Serialkan perubahan sesi tersimpan; hasil verifikasi terlambat tidak boleh mengaktifkan kembali sesi lama.
  - Aksi multi-langkah (`_setMode('manual')` di `main.dart` dan simpan form di `schedules_page.dart`) menangkap `kSessionEpoch` di awal dan membatalkan request kedua jika `kSessionEpoch` berubah.
- **Keamanan Transport (`normalizeBaseUrl` & `network_security_config.xml`):**
  - Tolak skema `http://` untuk domain/IP publik (wajib `https://`).
  - Release menolak seluruh HTTP. Hanya build debug boleh HTTP untuk permintaan tanpa rahasia ke `localhost`, loopback atau IPv4 privat yang diparse sebagai alamat IP, bukan dicocokkan dari awalan hostname. Tolak userinfo, query, fragmen dan path selain `/`. Uji kontrol Admin lokal melalui HTTPS.

### 3.3 Kebijakan Perangkat (`ALLOWED_DEVICES`) & Endpoint Backend
- **`ALLOWED_DEVICES` (default `fan01`):**
  - Diterapkan seragam di semua endpoint `/api/*`, mutasi jadwal `PUT /api/schedules/:id` dan `DELETE /api/schedules/:id` (`WHERE id = $1 AND device_id = ANY($2)`), query penjadwal di `backend/scheduler.js`, `syncAllConfigs()` di `backend/api.js`, dan subscriber MQTT `bathfan/+/telemetry` di `backend/index.js`.
- **Kontrak Akses Endpoint:**
  - `GET /health` publik di semua profil; respons minimal. **Hanya `APP_PROFILE=bazar`** membuka `GET /api/status`, `GET /api/history`, `GET /api/schedules`, `GET /api/config`, `POST /api/feedback` tanpa kunci. `real` (default) mempertahankan autentikasi semua `/api/*`. Bazar menggunakan DB, identitas broker dan perangkat khusus pameran, bukan riwayat/jadwal pemakaian rumah. Pengunjung cukup diberi alamat HTTPS backend bazar.
  - Khusus Admin (`X-API-Key` wajib): `GET /api/admin/verify`, `POST /api/mode`, `POST /api/speed`, `POST /api/power`, `POST /api/schedules`, `PUT /api/schedules/:id`, `DELETE /api/schedules/:id`, `PUT /api/config`, `POST /api/config/reset`.
- **Perlindungan Query & Bebas Efek Samping:**
  - `GET /api/config` hanya menjalankan `SELECT` (jika baris belum ada di `device_config`, kembalikan `DEFAULT_CONFIG` tanpa `INSERT`).
  - Batasi baca publik per IP, terpisah dari 10 kegagalan autentikasi Admin/menit/IP. Cache history 5 detik hanya memakai perangkat yang diizinkan dan range `1h|24h|7d`; permintaan serentak untuk bucket cache sama berbagi satu query. `trust proxy` mati secara default; percayai hanya proxy ingress yang menimpa header forwarding dan jadikan origin tidak dapat diakses langsung.
  - `POST /api/feedback` hanya menerima JSON terbatas (parser 16 KiB), nama opsional ≤40, rating integer 1–5, komentar setelah trim 1–500; SQL berparameter. Maksimal 5 kiriman/10 menit/IP ditambah kuota total stand dan masa simpan terbatas. Tidak ada endpoint pembacaan feedback; respons sukses hanya konfirmasi.

### 3.3.1 Syarat deploy fisik
- Tepat satu worker MQTT/scheduler selalu aktif, termasuk saat cutover dari laptop; host yang tidur menghentikan heartbeat Standby. Filter allowlist juga pada target publish final (scheduler lama menginisialisasi `fan01` tanpa membaca DB).
- Validasi sertifikat dan hostname PostgreSQL cloud dan EMQX. Firmware saat ini menggunakan `net.setInsecure()`; sebelum demo via internet, pasang CA broker, siapkan waktu untuk validasi, dan uji fallback kontrol lokal saat TLS gagal. ACL broker: ESP32 hanya publish telemetri sendiri/subscribe perintah sendiri; backend kebalikannya untuk perangkat yang diizinkan. Pertahankan payload, topik, dan aturan retain lama.

### 3.4 UI Sensor Asap MQ-2 & Kompatibilitas Data Lama
- **Backend (`backend/api.js`):**
  - `GET /api/status`: kirim `smoke: row.smoke ?? null` (jangan ubah `null` menjadi `0`).
  - `GET /api/history`: rata-ratakan delta hanya untuk `smoke_ready IS TRUE` (filter pada agregat asap, bukan seluruh query). Bucket tanpa sampel siap tetap `smoke: null`, tanpa membuang kelembapan/PWM. Tambahkan `BOOL_OR(COALESCE(smoke_alert, false)) AS smoke_alert` pada tiap bucket waktu.
- **Dashboard (`app/lib/main.dart`):**
  - Urutan evaluasi status MQ-2:
    1. `latest == null` → *"Menunggu data..."*
    2. `!online` → *"Offline · data terakhir `<waktu>`"*
    3. `smoke == null` → *"Sensor MQ-2 tidak tersedia"*
    4. `!smokeReady` → *"Pemanasan sensor"*
    5. `smokeAlert` → *"Bahaya Asap"*
    6. Selain itu → *"Normal"*
  - Banner alarm asap menampilkan status alarm asap dan kecepatan fan (`fan_pwm`) yang dilaporkan sebagai dua fakta terpisah.
- **Statistik (`app/lib/stats_page.dart`):**
   - Grafik riwayat MQ-2 menggunakan sumbu vertikal dinamis yang mencakup nilai negatif bila `smoke < 0` (dengan garis dasar `0`), serta indikator bucket yang pernah mengalami `smoke_alert`.

### 3.5 Navigasi pengunjung
- **Masukan** adalah tujuan navigasi tersendiri, dapat digunakan Guest tanpa membuka pengaturan koneksi/Admin. Beri konfirmasi kiriman atau waktu coba lagi pada `429`; jangan mengulang POST otomatis.
