# Bazar Public Deploy & MQ-2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Menyiapkan backend dan aplikasi Flutter untuk deployment pameran/bazar dengan dukungan UI sensor asap MQ-2 yang akurat, pemisahan akses Guest (View-Only + Feedback) vs Admin (`X-API-Key` terisolasi per origin), allowlist perangkat terpadu, dan opsi post-run `real` (300 dtk) vs `bazar` (60 dtk) berbasis `.env`.

**Architecture:** Flutter menggunakan REST. Tanpa `DummyEngine` atau `/auth/login`. Guest anonim hanya pada deployment bazar. Kunci pertama maupun kunci sesi hanya boleh dikirim ke origin HTTPS tepercaya dari konfigurasi build, tanpa redirect.

**Tech Stack:** Node.js (Express 5, `pg`, `mqtt`, `node:test`), Flutter 3.50 / Dart ^3.12 (`http`, `shared_preferences`, `flutter_test`).

**Spec:** `docs/superpowers/specs/2026-11-25-bazar-public-deploy-design.md`

## Global Constraints

- Bahasa antarmuka pengguna (UI) dan pesan error API menggunakan Bahasa Indonesia.
- Jangan mengubah topik atau format payload MQTT pada `firmware/bathfan/bathfan.ino` (`cmd/config` tetap `retain: true`, perintah lain `retain: false`).
- `DEFAULT_CONFIG.post_run_sec` diatur dari `.env` melalui `APP_PROFILE` (`bazar` = 60, `real` = 300, default `real`) atau `DEFAULT_POST_RUN_SEC` (angka eksplisit 0..3600).
- `GET /api/config` wajib bebas efek samping (*side-effect-free*, dilarang melakukan `INSERT` ke database).
- Permintaan publik di Flutter (`getPublic`, `postPublic`) dilarang menyertakan header `X-API-Key`.

## Review Focus

1. **Perangkat/data lama tanpa MQ-2 (`smoke: null, smoke_ready: false`)**: harus tampil *"Sensor MQ-2 tidak tersedia"*, bukan terjebak di *"Pemanasan"* selamanya.
2. **Perangkat offline dengan sampel terakhir normal/alarm**: harus mendahulukan status *"Offline"* beserta usia data terakhir sebelum klaim *"Normal"*.
3. **Probe alamat server baru (`GET /health`) saat kunci Admin origin lama masih tersimpan**: kunci Admin tidak boleh ikut terkirim ke origin baru.
4. **Admin logout atau ganti alamat server di tengah aksi dua langkah (`_setMode('manual')` atau form jadwal)**: langkah mutasi kedua harus dibatalkan oleh pemeriksaan `kSessionEpoch`.
5. **Mutasi `PUT/DELETE /api/schedules/:id` untuk jadwal milik perangkat di luar `ALLOWED_DEVICES`**: harus ditolak dan tidak mengubah baris jadwal perangkat lain.

---

### Task 1: Konfigurasi Backend, Allowlist Terpadu, & Skema Feedback (`backend/db.js`, `backend/scheduler.js`, `backend/index.js`)

**Files:**
- Modify: `backend/db.js`
- Modify: `backend/scheduler.js`
- Modify: `backend/index.js`
- Modify: `backend/.env.example`
- Modify: `firmware/bathfan/bathfan.ino` (validasi TLS, tanpa perubahan kontrak MQTT)
- Create: `backend/config.js`
- Test: `backend/test/backend.test.js`

**Interfaces:**
- Produces (`backend/config.js`):
  - `getAllowedDevices(env = process.env) -> string[]`
  - `isAllowedDevice(device: string, env = process.env) -> boolean`
  - `getDefaultPostRunSec(env = process.env) -> number` (`60` bila `APP_PROFILE=bazar`, `300` bila `APP_PROFILE=real` atau default, atau nilai integer `DEFAULT_POST_RUN_SEC`)
  - `getDefaultConfig(env = process.env) -> { hum_on: 70, hum_off: 60, post_run_sec: number, max_pwm: 100, smoke_on: 250, smoke_off: 100 }`

- [ ] **Step 1: Tulis unit test untuk `backend/config.js` dan filter `scheduler.js` di `backend/test/backend.test.js`**

```javascript
const test = require('node:test');
const assert = require('node:assert/strict');
const { getAllowedDevices, isAllowedDevice, getDefaultPostRunSec } = require('../config');

test('getDefaultPostRunSec memilih 300 untuk real dan 60 untuk bazar', () => {
  assert.equal(getDefaultPostRunSec({}), 300);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'real' }), 300);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'bazar' }), 60);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'real', DEFAULT_POST_RUN_SEC: '120' }), 120);
});

test('isAllowedDevice memvalidasi format dan daftar ALLOWED_DEVICES', () => {
  const env = { ALLOWED_DEVICES: 'fan01, fan02' };
  assert.deepEqual(getAllowedDevices(env), ['fan01', 'fan02']);
  assert.equal(isAllowedDevice('fan01', env), true);
  assert.equal(isAllowedDevice('fan99', env), false);
  assert.equal(isAllowedDevice('../bad', env), false);
});
```

- [ ] **Step 2: Jalankan test dan pastikan gagal karena `backend/config.js` belum ada**

Run: `node --test backend/test/backend.test.js`
Expected: FAIL dengan `Cannot find module '../config'`

- [ ] **Step 3: Implementasikan `backend/config.js`, perbarui `backend/db.js`, `backend/scheduler.js`, `backend/index.js`, dan `backend/.env.example`**

- Di `backend/config.js`: ekspor `DEVICE_RE`, `getAllowedDevices`, `isAllowedDevice`, `getDefaultPostRunSec`, dan `getDefaultConfig`.
- Di `backend/db.js`:
  - Dukung `DATABASE_URL` cloud dan `PG*` lokal. Di cloud wajib TLS dengan CA tepercaya dan verifikasi hostname; tolak opsi connection string yang menurunkan verifikasi. Jangan log URL berkredensial.
  - Ganti seed `fan01` tanpa kolom post-run di `db.js` dengan provisioning perangkat allowlist dan default profil eksplisit `ON CONFLICT DO NOTHING`. Jika tidak, DB baru tetap memakai 300 detik di bazar. Uji DB baru dan DB yang sudah menyimpan konfigurasi kustom.
  - Tambahkan pembuatan tabel `feedback (id BIGSERIAL PRIMARY KEY, device_id TEXT NOT NULL, name TEXT, rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5), comment TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now())`.
- Di `backend/scheduler.js`: filter query dengan `device_id = ANY($1::text[])`, ganti seed `byDevice` hardcoded `fan01` dengan allowlist, dan periksa ID sebelum publish. Uji tick awal dan heartbeat dengan allowlist hanya `fan02`: tidak ada publikasi untuk `fan01`.
- Di `backend/index.js`: periksa allowlist dan ukuran payload sebelum parse; abaikan JSON yang bukan objek, tipe/rentang kelembapan dan PWM yang salah, serta mode tidak dikenal. Uji bahwa pesan invalid tidak menghentikan subscriber atau masuk DB, dan telemetri lama tanpa MQ-2 tetap diterima.
- Di firmware: ganti `net.setInsecure()` dengan CA EMQX dan verifikasi hostname; sinkronisasi waktu tanpa memblokir loop kontrol. Sertifikat/waktu tidak valid → MQTT tetap terputus, kontrol lokal tetap berjalan, tanpa fallback insecure.
- Di `backend/.env.example`: dokumentasikan `PORT`, `APP_PROFILE=real`, `DEFAULT_POST_RUN_SEC=`, `ALLOWED_DEVICES=fan01`, `TRUST_PROXY=0`, `DATABASE_URL=` dan opsi CA. Batasi `PORT` dan default post-run ke integer valid (nilai `0` post-run sah); profil tidak dikenal, allowlist eksplisit kosong/invalid atau kunci Admin <24 karakter menggagalkan startup sebelum membuka listener/worker.

- [ ] **Step 4: Jalankan test untuk memastikan lulus**

Run: `node --test backend/test/backend.test.js`
Expected: PASS

---

### Task 2: Otorisasi Guest vs Admin, Kompatibilitas MQ-2, Cache History, & Endpoint Feedback (`backend/api.js`)

**Files:**
- Modify: `backend/api.js`
- Modify: `backend/test/backend.test.js`

**Interfaces:**
- Consumes: `getAllowedDevices`, `isAllowedDevice`, `getDefaultConfig` dari `backend/config.js`
- Produces (`backend/api.js`):
  - `createApp(mqttClient, { pool, env } = {}) -> express.Application`
  - `startApi(mqttClient, options) -> http.Server`

- [ ] **Step 1: Tambahkan integration test di `backend/test/backend.test.js` untuk semua batas keamanan API**

Uji skenario berikut menggunakan mock `pool` dan mock `mqttClient`:
1. `GET /health` selalu publik. Dalam `bazar`, uji daftar metode+rute Guest persis seperti spesifikasi §3.3; dalam `real`/default, request anonim ke setiap `/api/*` ditolak. `row.smoke = null` tetap `null`. Kunci valid dapat membaca/mengontrol pada kedua profil.
2. `GET /api/config` untuk perangkat yang belum memiliki baris di `device_config` mengembalikan `defaults` tanpa mengeksekusi query `INSERT` ke database.
3. Setiap mutasi Guest (`POST /api/mode`, `POST /api/speed`, `POST /api/power`, `POST/PUT/DELETE /api/schedules*`, `PUT /api/config`, `POST /api/config/reset`) tanpa `X-API-Key` ditolak dengan `401` tanpa mengubah DB atau memublikasikan MQTT.
4. `PUT /api/schedules/:id` dan `DELETE /api/schedules/:id` menyertakan filter `device_id = ANY($...)` dari `ALLOWED_DEVICES` dan menolak perangkat di luar allowlist.
5. `POST /api/feedback` memvalidasi `rating` (1..5) dan `comment` (1..500 karakter) serta menerapkan rate limit.
6. Kunci salah pada verify maupun kontrol mengonsumsi kuota autentikasi yang sama; akses anonim Guest yang sah tidak mengonsumsinya. Uji 401/429, pemulihan setelah jendela habis, `GET /api/feedback` tidak tersedia, serta variasi metode pada rute Guest tetap terlindungi.
7. Dua request history serentak dengan key cache sama hanya membuat satu query; range/device invalid tidak membuat key. Bucket pemanasan saja menghasilkan asap null tanpa kehilangan kelembapan/PWM. Budget baca mengizinkan polling wajar dari HP yang berbagi NAT stand.

- [ ] **Step 2: Jalankan test dan pastikan gagal pada implementasi `api.js` lama**

Run: `node --test backend/test/backend.test.js`
Expected: FAIL (`createApp is not a function` / Guest `GET` ditolak 401)

- [ ] **Step 3: Refactor `backend/api.js` untuk memisahkan `createApp` dan menerapkan kebijakan keamanan**

- `startApi` memakai `PORT` hosting, default lokal 3000. `GET /health` hanya `{ ok: true }`. Daftarkan handler publik per metode+rute secara eksplisit untuk profil bazar; semua `/api` lain melewati `requireAdmin` sebelum handler. Jangan mengizinkan semua GET atau mengecualikan prefix `/feedback`. Verifikasi hash kunci dengan pembandingan waktu konstan seperti kode sekarang. Tolak tanpa side effect.
- Parser JSON maksimal 16 KiB; validasi ID perangkat pada semua handler perangkat sebelum akses DB/MQTT. Limiter auth gagal 10/menit/IP; limiter baca publik terpisah (mulai 120/menit/IP, sesuaikan NAT pameran). Beri `429` dengan `Retry-After`; hapus entri kedaluwarsa dan batasi ukuran map. `trust proxy` default mati; percayai alamat/subnet ingress tervalidasi saja, bukan semua `X-Forwarded-For`.
- Tambahkan `GET /api/admin/verify` yang wajib `requireAdmin` dan mengembalikan `{ ok: true, role: 'admin' }`.
- Di `GET /api/status`: ubah `smoke: row.smoke ?? 0` menjadi `smoke: row.smoke ?? null`.
- Di `HISTORY_SQL`: gunakan `AVG(smoke) FILTER (WHERE smoke_ready IS TRUE)` dan `BOOL_OR(COALESCE(smoke_alert, false)) AS smoke_alert`. Cache 5 detik per `(device, range)` kanonik setelah validasi range (`1h|24h|7d`, default `1h` jika tidak diisi). Bagikan promise query yang berjalan; bersihkan saat gagal. Jangan cache respons autentikasi.
- Di `GET /api/config`: gunakan `readConfigWithoutInsert(device)` (`SELECT` murni, fallback ke `DEFAULT_CONFIG`), sedangkan `ensureAndWriteConfig(device, cfg)` (`INSERT ... ON CONFLICT DO UPDATE`) hanya dipanggil pada `PUT /api/config` dan `POST /api/config/reset`.
- Di `syncAllConfigs()`: tambahkan `WHERE device_id = ANY($1)` dengan `allowedDevices`.
- Di `PUT /api/schedules/:id` dan `DELETE /api/schedules/:id`: tambahkan `AND device_id = ANY($...)` menggunakan `allowedDevices`.
- Hanya `POST /api/feedback`: validasi objek JSON, perangkat allowlist, nama opsional ≤40, rating integer 1–5, komentar string trim 1–500. Gunakan SQL berparameter, respons `201` tanpa menggemakan data pribadi. Kuota 5 kiriman/10 menit/IP dan batas total stand (awal 300/jam); hapus feedback paling lambat 30 hari via job terjadwal. Jangan log isi/nama. Tidak ada handler baca feedback.

- [ ] **Step 4: Jalankan seluruh test backend dan pastikan lulus**

Run: `node --test backend/test/backend.test.js`
Expected: PASS

---

### Task 3: Isolasi Kredensial, Origin, & Transport di Flutter (`app/lib/constants.dart`, `app/lib/api_http.dart`, `AndroidManifest.xml`)

**Files:**
- Modify: `app/lib/constants.dart`
- Modify: `app/lib/api_http.dart`
- Modify: `app/android/app/src/main/AndroidManifest.xml`
- Modify: `app/pubspec.yaml` dan lockfile (penyimpanan aman Android)
- Create: `app/android/app/src/main/res/xml/network_security_config.xml`
- Create: `app/android/app/src/debug/res/xml/network_security_config.xml`
- Create: `app/test/security_and_mq2_test.dart`

**Interfaces:**
- Produces (`app/lib/constants.dart`):
  - `int kSessionEpoch` (naik setiap kali alamat server atau sesi Admin berubah)
   - `String kAdminOrigin` (origin sesi yang telah diverifikasi); `ADMIN_API_ORIGIN` adalah origin HTTPS kanonik tetap dari build, bukan dari input pengguna. Kosong/invalid → tidak ada akses Admin.
   - `bool get isAdminSession` (kunci ada dan origin aktif, origin sesi, serta `ADMIN_API_ORIGIN` identik, termasuk port efektif)
   - `String? normalizeBaseUrl(String input)` (domain publik tanpa skema → HTTPS tanpa `:3000`; tolak userinfo, query, fragmen, path selain `/`. HTTP privat hanya untuk debug, dengan parsing IPv4 RFC1918/loopback atau `localhost` persis; bukan pencocokan prefix hostname).
  - `Future<bool> setServerAddress(String normalized)` (jika origin berubah, otomatis menghapus `kApiKey` & `kAdminOrigin` dan menaikkan `kSessionEpoch`)
   - `Future<bool> verifyAndActivateAdmin(String candidateKey)` (hanya target tetap `ADMIN_API_ORIGIN/api/admin/verify`; periksa origin aktif dan epoch sebelum mengirim dan sesudah respons sukses sebelum menyimpan)
  - `Future<void> clearAdminSession()`
- Produces (`app/lib/api_http.dart`):
  - `Future<h.Response> getPublic(Uri url, {Map<String, String>? headers, h.Client? client})`
  - `Future<h.Response> postPublic(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding, h.Client? client})`
   - `Future<h.Response> getAdmin(Uri url, {Map<String, String>? headers, h.Client? client})` (tanpa parameter override origin/kunci)
  - `Future<h.Response> postAdmin(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding, h.Client? client})`
  - `Future<h.Response> putAdmin(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding, h.Client? client})`
  - `Future<h.Response> deleteAdmin(Uri url, {Map<String, String>? headers, h.Client? client})`

- [ ] **Step 1: Tulis unit test di `app/test/security_and_mq2_test.dart` untuk isolasi origin dan validasi URL**

Uji dengan `MockClient` / custom `http.BaseClient`:
1. Tolak HTTP publik pada kedua build, HTTP LAN pada release, serta hostname publik berawalan `192.168.` pada jalur pengecualian debug. Pertahankan `adb reverse` untuk baca Guest debug.
2. Setelah verifikasi sukses di origin A, `getPublic` ke `/health` origin B **tidak** membawa kunci, termasuk jika caller memasok `x-api-key` dalam kapitalisasi berbeda.
3. Pemanggilan `postAdmin` ke `https://origin-b.example.com/api/mode` melempar error/ditolak sebelum keluar jaringan karena origin tidak cocok dengan `kAdminOrigin`.
4. Mengganti alamat server ke origin B melalui `setServerAddress` otomatis menghapus sesi Admin dan menaikkan `kSessionEpoch`.
5. Dengan B aktif, upaya verifikasi pertama mengirim **nol** request berkunci. Pada A, respons redirect saat verify atau mutasi tidak diikuti. Logout/pindah origin saat verify tertunda tetap Guest setelah respons A diterima dan sesudah restart.

- [ ] **Step 2: Implementasikan isolasi origin di `app/lib/constants.dart` dan `app/lib/api_http.dart`, serta `network_security_config.xml`**

- Di `api_http.dart`: hilangkan header kunci dari header pemanggil secara case-insensitive. Hanya jalur Admin yang memasangnya sesudah memeriksa tujuan. Set `request.followRedirects = false` sebelum `send`, termasuk verifikasi pertama; tangani 3xx sebagai gagal.
- Hapus `api_key` lama dari SharedPreferences tanpa mengirimkannya. Simpan pasangan origin/kunci terverifikasi di secure storage berbasis Keystore; prefs hanya untuk URL. Serialkan aktivasi/penghapusan; logout/perubahan origin mengosongkan sesi di memori dan menaikkan epoch sebelum `await`. Gagal membaca/menulis sesi → Guest.
- Manifest utama: `android:networkSecurityConfig="@xml/network_security_config"` dengan base policy cleartext mati. Resource override debug hanya untuk pengembangan lokal; wrapper Dart tetap menolak HTTP nonlokal dan semua kunci di HTTP.

- [ ] **Step 3: Jalankan `flutter test` untuk memverifikasi**

Run: `cd app && flutter test test/security_and_mq2_test.dart`
Expected: PASS

---

### Task 4: UI Sensor Asap MQ-2, Guard Sesi Multi-Langkah, Mode Guest vs Admin, & Form Feedback (`app/lib/main.dart`, `app/lib/stats_page.dart`, `app/lib/schedules_page.dart`, `app/lib/settings_page.dart`)

**Files:**
- Modify: `app/lib/main.dart`
- Modify: `app/lib/stats_page.dart`
- Modify: `app/lib/schedules_page.dart`
- Modify: `app/lib/settings_page.dart`
- Create: `app/lib/feedback_page.dart`
- Modify: `app/test/security_and_mq2_test.dart`

**Interfaces:**
- Produces (`app/lib/main.dart`):
  - `enum SmokeUiState { noData, offline, unavailable, warmingUp, alert, normal }`
  - `SmokeUiInfo evaluateSmokeUi(FanStatus? s)` (fungsi murni yang dapat diuji unit test untuk kelima kondisi urutan label MQ-2)

- [ ] **Step 1: Tambahkan unit & widget test di `app/test/security_and_mq2_test.dart` untuk label MQ-2 dan pembatalan aksi dua langkah**

Uji:
1. `evaluateSmokeUi` mengembalikan status berbeda untuk:
   - `latest == null` → `SmokeUiState.noData`
   - `online == false` (walau sampel terakhir normal/alarm) → `SmokeUiState.offline` beserta informasi waktu bacaan terakhir
   - `online == true, smoke == null, smokeReady == false` (firmware lama tanpa MQ-2) → `SmokeUiState.unavailable` (bukan pemanasan!)
   - `online == true, smoke == 15, smokeReady == false` → `SmokeUiState.warmingUp`
   - `online == true, smoke == 320, smokeReady == true, smokeAlert == true` → `SmokeUiState.alert` (banner menyebut alarm dan kecepatan fan terpisah)
   - `online == true, smoke == 12, smokeReady == true, smokeAlert == false` → `SmokeUiState.normal`
2. Saat aksi dua langkah (`_setMode('manual')`) sedang menunggu langkah pertama (`POST /api/speed`) dan `kSessionEpoch` berubah (misalnya logout Admin atau pindah alamat server), langkah kedua (`POST /api/mode`) tidak dikirim.
3. Form jadwal/dialog reset yang sudah terbuka tidak dapat melakukan mutasi setelah sesi berubah. Respons polling dari origin lama tidak mengisi Dashboard origin baru. Bila polling terhenti, sampel berusia ≥20 detik tidak tetap ditampilkan sebagai status live.
4. Buka tab Masukan sebagai Guest; submit sekali tanpa kunci. `201` menampilkan konfirmasi; `429` tidak menyebabkan kirim ulang otomatis.

- [ ] **Step 2: Implementasikan pembaruan di `main.dart`, `stats_page.dart`, `schedules_page.dart`, dan `settings_page.dart`**

- **`app/lib/main.dart`:**
  - Tambahkan field `hasLatest`, `smoke`, `smokeAlert`, `smokeReady` pada `FanStatus`.
   - Untuk status, history, jadwal dan config: gunakan `getPublic` pada sesi Guest dan `getAdmin` pada sesi Admin agar profil `real` tetap bisa dibaca setelah verifikasi. Probe selalu `getPublic`. Mutasi hanya lewat helper Admin. Migrasikan semua pemanggil wrapper lama.
   - Di `_setMode`: tangkap epoch sebelum langkah pertama; batalkan langkah kedua jika pengiriman speed gagal, epoch berubah atau sesi Admin habis. Terapkan guard serupa setelah menunggu dialog hapus/reset. Abaikan hasil polling tertunda dan kosongkan data lama saat origin berubah; tampilkan waktu sampel dan status kedaluwarsa saat refresh gagal.
  - Tampilkan kartu status MQ-2 dan banner alarm asap (yang memisahkan informasi status alarm asap dan kecepatan fan `fanPwm` yang dilaporkan).
   - Nonaktifkan kontrol Power, Mode, dan Slider Manual ketika `!isAdminSession`, serta tampilkan badge *"Mode Pengunjung (Lihat Saja)"*.
   - Tambahkan `FeedbackPage` sebagai tujuan **Masukan** di `HomeShell`. Jalankan polling hanya pada tab aktif ketika app di foreground; muat ulang saat kembali aktif.
- **`app/lib/stats_page.dart`:**
   - Parse `smoke` (`int?`) dan `smoke_alert` (`bool`) pada `HistoryPoint`; beri celah pada grafik bila delta `null`, tanpa mengubah statistik kelembapan/PWM.
  - Tambahkan kartu grafik **Kualitas Udara / Asap (MQ-2)** dengan sumbu Y yang mencakup nilai negatif (mis. `min(0, minDelta)` sampai `max(300, maxDelta)`), garis nol, dan penanda titik/bucket di mana `smokeAlert == true` dengan keterangan *"Penanda merah: pernah terjadi alarm asap pada rentang waktu tersebut"*.
- **`app/lib/schedules_page.dart`:**
   - Muat jadwal mengikuti kebijakan baca sesuai sesi di atas.
  - Sembunyikan/nonaktifkan tombol Tambah, Edit, Hapus, dan Switch jadwal bila `!isAdminSession`.
  - Di `_openForm`: tangkap `final epoch = kSessionEpoch;` sebelum `await Navigator.of(context).push(...)`, dan batalkan `postAdmin`/`putAdmin` bila `epoch != kSessionEpoch || !isAdminSession`.
- **`app/lib/settings_page.dart`:**
  - Kartu **Alamat Server**: tombol *Uji koneksi* memanggil `GET /health` via `getPublic` (tanpa mengirim kunci Admin!). Menyimpan alamat baru memanggil `setServerAddress(n)`.
   - Kartu **Akses Admin (Khusus Tim)**: input kosong/tersamarkan dan tombol *Aktifkan Mode Admin* hanya pada origin build tepercaya (`verifyAndActivateAdmin`); kosongkan controller setelah digunakan. Tombol *Keluar Mode Admin* memanggil `clearAdminSession()`.
   - Bagian **Pengaturan Ambang Perangkat**: ditampilkan *read-only* untuk Guest dan dapat diedit/disimpan/direset oleh Admin.
- **`app/lib/feedback_page.dart`:** form nama opsional, rating 1–5, komentar. Pada bazar cukup `postPublic`; pada deployment real yang membutuhkan autentikasi, kirim hanya atas aksi Admin dengan `postAdmin`. Jangan simpan draft/identitas pengunjung sebelumnya setelah sukses di HP bersama.

- [ ] **Step 3: Jalankan `flutter analyze` dan `flutter test`**

Run: `cd app && flutter analyze && flutter test`
Expected: `No issues found!` dan semua test PASS.

---

### Task 5: Pembaruan Dokumentasi Kontrak API (`README.md` & `AGENTS.md`)

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`

- [ ] **Step 1: Perbarui `AGENTS.md` dan `README.md`**

- Salin matriks metode+rute eksplisit dari spesifikasi §3.3, termasuk pengecualian khusus profil bazar. Jangan dokumentasikan semua GET sebagai publik. Catat bahwa sesi Admin mengakses GET terproteksi lewat wrapper Admin di profil real.
- Dokumentasikan variabel `.env` baru (`APP_PROFILE=real|bazar`, `DEFAULT_POST_RUN_SEC`, `ALLOWED_DEVICES`, `TRUST_PROXY`, `DATABASE_URL`) dan konsekuensi tombol **Kembalikan ke bawaan** terhadap `post_run_sec`.
- Runbook bazar: DB dan identitas EMQX terpisah dari rumah, kunci Admin baru (secret hosting, bukan APK), ACL publish/subscribe per perangkat, TLS terverifikasi dari HP hingga DB dan dari ESP32 ke EMQX. Atur `ADMIN_API_ORIGIN` saat build HP tim. Hentikan worker laptop sebelum menyalakan satu replika always-on di hosting; untuk rollback, hentikan worker cloud lebih dulu. Rotasi kunci setelah pameran dan hapus data feedback sesuai retensi.

- [ ] **Step 2: Verifikasi akhir seluruh test backend dan Flutter**

Run: `node --test backend/test/backend.test.js && cd app && flutter analyze && flutter test`
Expected: Semua pengujian backend dan Flutter lulus tanpa error.

- [ ] **Step 3: Uji staging sebelum membawa perangkat ke stand.** Pakai DB sekali pakai untuk memeriksa seed/default, query history, dan filter mutasi jadwal pada baris nyata (tidak hanya kecocokan string SQL mock). Dari dua HP di WiFi stand, periksa IP/kuota melalui ingress, polling dan tab Masukan. Pastikan hanya satu worker menyimpan telemetri dan mengirim heartbeat. Dengan perangkat uji, periksa bahwa CA yang benar menghubungkan MQTT, CA salah ditolak sementara kontrol lokal tetap berjalan, dan reconnect memulihkan `cmd/config` retained tanpa mengulang perintah daya lama.
