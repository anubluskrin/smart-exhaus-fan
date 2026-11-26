# Lab Skenario Bazar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Operator menjalankan preset mandi/asap tanpa uap atau rokok; pengunjung melihat adegan sesuai telemetri dan respons fan fisik.

**Architecture:** Backend mengotorisasi preset, ESP32 membangkitkan sampel dan tetap menjadi satu-satunya pengendali relay/PWM. PostgreSQL menyimpan sumber tiap sampel. Flutter tidak menjalankan mesin kontrol atau mengirim angka sensor.

**Tech Stack:** Arduino-ESP32 3.x, ArduinoJson, PubSubClient, C++ host tests, Express 5, PostgreSQL, `node:test`, Flutter Android, `CustomPainter`, `flutter_test`.

**Spec:** [Lab Skenario — kontrak, kurva, UX dan kriteria penerimaan](../specs/2026-11-26-lab-skenario-fan-fisik-design.md). Basis `deploy@20d2e3c`. Implementasikan berurutan; jangan deploy firmware pengirim metadata sebelum backend mengenali sumber.

## Global Constraints

- Default off di firmware dan backend; backend hanya `bazar`. Admin HTTPS tetap terikat origin; Guest baca lewat REST. MQTT TLS/ACL, allowlist dan konfigurasi retained lama tetap berlaku. Perintah demo tidak retained.
- Angka preset dan dua jam mengikuti spec. Jangan mempercepat `SMOKE_CLEAR_MS`, post-run, timeout Standby, atau heartbeat. Stop/reboot/disconnect kembali fisik, bukan perintah `power=false`.
- Semua UI Indonesia. Maksimal satu run per ESP32. Tidak menambah tab utama keenam: panel tim dari Dashboard, adegan Guest di Dashboard, filter run di Statistik.
- Buat commit per task sesudah cek hijau; jangan ikutkan secret, artefak build atau konfigurasi mesin lokal. Perintah di bawah dari root repo, kecuali disebut lain.

## Review Focus

1. Pulsa tipis tidak selalu memicu alarm; delta di bawah ambang selama 59 detik belum membersihkan alarm (Task 1–2).
2. Putus/reboot/stop saat fan berputar tidak meninggalkan latch simulasi atau menutupi gangguan sensor fisik (Task 2).
3. Dua Admin, duplikat QoS, serta stop terlambat tidak merestart atau membatalkan run lain (Task 2 dan 4).
4. Idle dengan ID run terakhir tidak mencampurkan sampel fisik ke grafik demo; cache dan query terisolasi (Task 3).
5. Guest masuk di tengah demo, data basi, reduced motion, atau logout selama start tidak memalsukan kondisi fan (Task 5–6).

### Task 1 — Generator kurva deterministik yang bisa diuji tanpa board

**Files:** buat `firmware/bathfan/demo_scenario.h` dan `firmware/tests/demo_scenario_test.cpp`. Simpan test di luar folder sketch agar Arduino tidak mengompilasi `main()` test.

**Interface:** `DemoPreset`, `DemoSample{humidity,temperature,smokeDelta,phase}`, `sampleScenario(const DemoPreset&, uint32_t elapsedRealMs)`. Header C++ tanpa Arduino, jaringan, timer global, atau aktuator.

- [ ] **Red:** uji tabel Mandi 5/10/20, speed 1/10. Mandi 10 menit 10×: di `0 ms` RH 55; `15000 ms` RH 85/suhu 30; `60000 ms` shower berhenti; `72000 ms` RH 55/suhu 26. Uji Asap: satu tipis puncak 160; tiga tebal bersamaan 1440; dua sedang bergantian pada detik virtual 30 menghasilkan 320 dan pada detik 60 menghasilkan 640.
- [ ] **Run:** pada host dengan GNU C++17, `g++ -std=c++17 firmware/tests/demo_scenario_test.cpp -o "$env:TEMP/bathfan-demo-test.exe"`; pertama gagal karena generator belum ada.
- [ ] **Green:** implementasikan envelope dan penjumlahan pulsa sesuai spec. Untuk elapsed setelah akhir, sampel baseline `settling`; penentuan run selesai milik pengendali, bukan generator. Gunakan selisih waktu unsigned, batasi sebelum perkalian speed.
- [ ] Build ulang lalu jalankan `& "$env:TEMP/bathfan-demo-test.exe"`; exit 0. Commit `feat(firmware): add deterministic shower and smoke presets`.

### Task 2 — Masukan virtual di firmware, keputusan fan tetap asli

**Files:** ubah `firmware/bathfan/bathfan.ino`, buat `firmware/bathfan/demo_session.h`, `firmware/tests/demo_session_test.cpp`. Bila diperlukan, pindahkan evaluator alarm asli ke `firmware/bathfan/smoke_alarm.h` agar jalur fisik dan virtual memakai fungsi yang sama dengan state terpisah.

**Interface:** `DemoSession` menangani start/stop, nonce, deadline dan alasan akhir; `sampleScenario` dari Task 1. Output data versi `demo.v=1` sesuai spec. `BATHFAN_DEMO_ENABLED` default `0`; aktifkan hanya pada build meja demo.

- [ ] **Red:** dengan jam/nonce deterministik, start A, start B bersamaan, duplikat A, stop A, start B, lalu stop A terlambat. Harapkan satu run aktif, elapsed tidak ter-reset, B tetap aktif. Uji start ditolak saat sensor belum siap, waktu tidak sinkron, nonce salah, atau command kedaluwarsa. Uji otomatis kembali fisik setelah 30 menit, disconnect dan reboot.
- [ ] **Red:** jalankan fixture melalui evaluator yang dipakai firmware: `smokeDelta > smoke_on` menyalakan alarm; tepat pada ambang tidak; 59 detik bersih belum padam, 60 detik padam; bila sempat naik lagi, penghitung diulang. Tambahkan kasus power Off + alarm = PWM 0; alarm fisik/invalidasi DHT nyata selama demo tidak ditutupi nilai virtual. Pada stop ketika data fisik invalid, gunakan fallback fisik dari usia pembacaan nyata, bukan nilai terakhir simulasi.
- [ ] **Run:** build dan jalankan `firmware/tests/demo_session_test.cpp` memakai perintah Task 1 dengan nama file/output `demo_session_test`; pastikan assertion awal gagal sebelum integrasi.
- [ ] **Green:** di tick 2 detik, sampel dan perbarui **kanal fisik** dahulu; masuk ke generator hanya bila run sah. Pisahkan perhitungan baseline dari evaluasi alarm di `updateSmoke()`. Panggil jalur `updateControl` asli dengan input terpilih; periksa jalur `onMessage()` yang juga memanggil kontrol dan publish. Jangan menulis relay/PWM dari `DemoSession`. Reset state kontrol turunan simulasi saat keluar dan evaluasi ulang fisik pada tick yang sama. Simpan timestamp kesehatan fisik terpisah. Saat DHT fisik menjadi tidak sehat (timeout firmware) akhiri run; gunakan alasan terminal `sensor_fault`.
- [ ] **Green:** parse `cmd/demo` hanya pada build demo. Periksa UUID, schema preset, expiry dan nonce di perangkat. Tukar nonce pada transisi. Publish telemetri transisi segera. Periksa ukuran terburuk **termasuk topic/header MQTT**: sketch saat ini `char buf[256]`, buffer MQTT 512. Pakai buffer terbatas, misalnya JSON 768 byte dan MQTT 1024; cek `measureJson`, hasil `serializeJson`, `setBufferSize` dan `publish`. Jangan kirim JSON terpotong. Gunakan ID perangkat bazar sesuai allowlist. Build biasa tidak mengiklankan dukungan.
- [ ] **Verify:** kedua host test exit 0. Dengan Arduino CLI, core ESP32 3.x, library proyek dan `secrets.h` lokal berisi CA yang benar: `arduino-cli compile --fqbn esp32:esp32:esp32 firmware/bathfan`; ulang dengan `--build-property "compiler.cpp.extra_flags=-DBATHFAN_DEMO_ENABLED=1"`. Gunakan FQBN unit aktual jika berbeda. Belum flash ke perangkat operasional. Commit `feat(firmware): drive physical controller from bounded demo sessions`.

### Task 3 — Ingest, status dan history tanpa pencampuran sumber

**Files:** ubah `backend/db.js`, `backend/index.js`, `backend/api.js`; buat `backend/demo_telemetry.js`, `backend/test/demo_telemetry.test.js`.

**Interface:** parser envelope menghasilkan `{source,runId,meta}`; status menambah `latest.source`, `latest.demo` (tanpa `generation`), `demo_available` (flag server + kemampuan firmware). History menerima `source=physical|demo`, untuk demo wajib `run_id`. Gunakan kolom `source TEXT NOT NULL DEFAULT 'physical'`, `demo_run_id UUID`, `demo_meta JSONB`; index `(device_id,source,demo_run_id,created_at)`. ID terminal idle berada di metadata; kolom run untuk filter history demo hanya terisi selama run.

- [ ] **Red:** buat fixture dari paket MQTT firmware biasa, demo aktif, idle dengan ID terminal, metadata rusak dan versi asing. Harapkan sumber `physical/demo/physical/rejected/rejected`. Cek `sensor_fault` diterima, tidak ada `generation` di respons REST. Online tetap berdasarkan paket fisik ESP32 terbaru, bukan kiriman HTTP.
- [ ] **Red:** pada PostgreSQL **uji sekali pakai**, isi sampel physical, run A, run B dalam bucket yang sama (RH 55/85/65). Assert history default = 55; A = 85; B = 65, bahkan bila request berulang/concurrent. Jalankan `node --test backend/test/demo_telemetry.test.js`; pastikan gagal pada skema lama.
- [ ] **Green:** migrasi aditif sebelum mengaktifkan sumber demo. Simpan sampel dan metadata dalam INSERT yang sama. Gunakan SQL berparameter; filter `device/source/run` sebelum `GROUP BY`. Tolak ID/filter tidak valid dan akses history demo di `real`. Key cache **dan** in-flight mencakup perangkat, sumber, run dan range. Untuk status, proyeksikan field UI yang diizinkan saja. Data lama tanpa `demo` tetap physical.
- [ ] **Verify:** beri test integrasi variabel khusus `BATHFAN_TEST_DATABASE_URL`; gagal dengan pesan jelas bila DB uji belum disediakan, jangan fallback ke DB runtime. Jalankan test terarah lalu `(cd backend)` `npm test`; pastikan suite baru termasuk dalam skrip test. Commit `feat(backend): isolate physical and scenario telemetry`.

### Task 4 — Kontrol skenario Admin, tanpa endpoint injeksi

**Files:** buat `backend/demo_routes.js`, `backend/test/demo_routes.test.js`; ubah `backend/api.js`, `backend/config.js`, `backend/.env.example`. Ekspor pendaftaran rute dengan dependensi pool, MQTT, clock, `requireAdmin`, resolver device dan limiter yang ada.

**Interface:** dua POST `/api/demo/start|stop`, payload spec. `202 {run_id,status:"pending"}`, `400` invalid, `401` tanpa key, `403` device terlarang, `404` fitur nonaktif, `409` konflik/not ready, `503` broker/perangkat tidak tersedia. Subscribe/publish terbatas ke identitas bazar; jangan menambah jalur publik.

- [ ] **Red:** table-test kedua route untuk Guest, kunci salah, `real`, flag mati, MCU lama, telemetry ≥20 detik, broker offline, allowlist salah, enum salah, dan override `pwm`. Assert **nol publish**, nol write telemetri. Uji dua start sebelum telemetri berikutnya: perangkat masih menjadi otoritas, bukan ACK broker.
- [ ] **Run:** `node --test backend/test/demo_routes.test.js`; harus gagal saat rute belum terdaftar.
- [ ] **Green:** gunakan `DEMO_SCENARIOS_ENABLED=false` sebagai default, tolak `true` bersama `real` saat startup. Ambil generation dari row terakhir (jangan menerimanya di HTTP). Validasi preset per jenis; stop hanya menerima `device/run_id`. Publish QoS 1 non-retained, expiry 10 detik; jangan enqueue untuk perangkat offline. Batasi start misalnya 6/menit/device; stop tidak menghabiskan kuota start. Respons `202` setelah callback publish sukses, tanpa mengubah status menjadi aktif.
- [ ] **Verify:** test positif memeriksa topic, expiry, nonce, QoS, retain dan respons; cek stop tetap tersedia ketika limit start tercapai. `node --test backend/test/demo_routes.test.js`, lalu `npm test` di `backend/`. Commit `feat(api): authorize bounded scenario commands for bazar devices`.

### Task 5 — Panel tim dan konfirmasi dari perangkat

**Files:** buat `app/lib/demo_models.dart`, `app/lib/demo_panel.dart`, `app/test/demo_panel_test.dart`; ubah `app/lib/main.dart`. Reuse `api_http.dart`, origin dan epoch saat ini. Pisahkan parser dari widget.

**Interface:** `DemoSnapshot.fromJson`, `DemoPreset.toStartBody`, widget `DemoPanel`. Gunakan `Random.secure()` untuk UUID v4 bila belum ada helper proyek. Poll status yang sudah ada menjadi sumber data panel dan Guest; jangan buat loop terpisah per widget.

- [ ] **Red:** widget test Guest/firmware lama tidak memiliki kontrol. Admin memilih preset default, dua ketukan memulai setelah panel dibuka; double tap membuat satu POST. `202` menampilkan `Menunggu ESP32`, run ID cocok menampilkan `Berjalan`; mismatch, timeout 15 detik, logout/pindah origin dan stop tak terkonfirmasi masing-masing punya status berbeda.
- [ ] **Run:** di `app/`, `flutter test test/demo_panel_test.dart`; pastikan gagal pada widget/mapper yang belum ada.
- [ ] **Green:** panel ringkas dengan preset chip, opsi kondisional, estimasi waktu kurva terpisah dari settling, dan tombol stop yang tidak tersapu perubahan grafik. Kirim `postAdmin`, tangkap epoch/origin sebelum await dan abaikan callback lama. Jangan memberi efek UI `fan menyala` setelah POST. Stop targetkan ID aktif dari perangkat. Jika run berakhir, pertahankan ringkasan di panel sampai operator memilih run baru.
- [ ] **Verify:** evaluasi milestone secara lokal hanya selama panel mengamati run. Gunakan config dan status aktual, tandai `Tidak dinilai` pada syarat bukti di spec; buka panel di tengah run juga tidak memberi verdict penuh. Uji alur normal, pulsa tipis subambang, config berubah dan sampel hilang. Ulangi widget test sampai PASS. Commit `feat(app): add admin scenario panel with device confirmation`.

### Task 6 — Adegan Guest dan Statistik per run

**Files:** buat `app/lib/demo_scene.dart`, `app/test/demo_scene_test.dart`; ubah `app/lib/main.dart`, `app/lib/stats_page.dart`. Gunakan controller animasi lokal, `TickerMode`, `MediaQuery.disableAnimationsOf`, dan flag aktif/foreground yang sudah mengendalikan polling.

**Interface:** `DemoScene(snapshot, humidity, smokeDelta, smokeAlert, fanPwm, online, isActive)`. Projector frame murni agar kepadatan, fase, jumlah sumber, dan gerakan fan bisa diuji tanpa membandingkan piksel. Pertahankan run terakhir yang diamati untuk memilih `Demo terakhir` di Statistik; default tetap `Sensor fisik`.

- [ ] **Red:** uji shower mengalir saat `shower`, mati saat `recovery`, embun turun bersama RH. Tiga sumber saat `people=3`; puncak bergantian tidak serentak. Alarm masih aktif saat delta rendah memberi teks `Menunggu udara bersih`. PWM 0 menghentikan fan meski asap tebal. Paket pertama di tengah run langsung menggambar fase yang dilaporkan.
- [ ] **Run:** di `app/`, `flutter test test/demo_scene_test.dart`; pastikan gagal sebelum widget tersedia.
- [ ] **Green:** gambar siluet, kaca, shower, 1–3 sumber asap dan ikon fan. Jadikan gerak dekoratif interpolasi antarsampel: jangan meramalkan alarm, fase, atau PWM. Teks dan angka terbaca pada layar kecil; ketika stale ≥20 detik/foreground mati/tab tersembunyi, bekukan ticker. Reduced motion memakai frame statis. Saat physical aktif, kembalikan kartu Dashboard biasa.
- [ ] **Green:** grafik ringkas Dashboard memakai buffer sampel teramati per run (kosongkan saat run/origin berubah); untuk histori lengkap gunakan filter Task 3. Pilihan sumber di Statistik membatalkan respons lama melalui request ID. Uji dua run, sampel null dan kembali physical; tidak ada garis menyambung antar-run.
- [ ] **Verify:** uji freeze/resume, reduced motion, label **Sensor simulasi · Fan fisik**, statistik per run dan nol request jaringan dari painter. Jalankan `flutter analyze` dan `flutter test` di `app/`. Commit `feat(app): visualize device-reported shower and smoke scenarios`.

### Task 7 — Gladi dua HP dan rollback

**Files:** perbarui `README.md` dan `AGENTS.md` pada commit implementasi; tambah `docs/demo-scenario-bench.md` berisi tabel `kasus | build | konfigurasi aktual | ekspektasi | observasi | hasil`.

- [ ] **Siapkan:** staging satu worker, DB bersih, firmware demo, TLS/ACL terverifikasi, HP tim Admin dan HP Guest tanpa key. Rollout backend/migrasi dahulu, lalu APK dan firmware. Pastikan board merespons sebelum menyalakan flag. Cek versi Arduino dan toolchain host di runbook.
- [ ] **Gladi:** Mandi 5/10/20 pada jam virtual (seluruhnya pada host; minimal 10 menit 10× pada board). Di meja ukur 60 detik air mengalir untuk contoh 10 menit. Jalankan Asap tipis satu orang dan tebal dua orang bergantian. Catat tiap transisi/poll, RH/Δ, PWM terlapor, posisi relay dan putaran fan yang benar-benar terlihat; toleransi observasi = tick sensor + periode publish/poll, bukan perubahan timer.
- [ ] **Gangguan:** uji Guest baca saja; power Off saat alarm; stop saat POSTRUN; WiFi hilang; reboot; Guest masuk tengah run; pengaturan reduced motion; jalankan firmware biasa. Pastikan tidak ada run lama hidup lagi, grafik rumah tetap bersih dan state fisik kembali. Uji alarm fisik dan DHT gagal via fixture, bukan asap sungguhan.
- [ ] **Rollback:** stop dan tunggu status physical (bila offline, cek board di meja), matikan flag, kembalikan firmware non-demo. Pertahankan migrasi aditif dan reader yang memahami sumber selama histori demo masih ada; jangan rollback ke backend lama yang merata-ratakan kedua sumber. Commit `docs: add two-phone scenario demo and rollback runbook` sesudah hasil aktual tercatat.

**Selesai** bila unit, integrasi DB, widget dan bench di atas lulus. Test runner hijau saja tidak membuktikan rotor bergerak.

## Catatan eksekusi

- Dua test C++ host lulus. Test Flutter mencakup Guest yang membuka Dashboard saat demo sudah berjalan. Tes integrasi PostgreSQL 18 dijalankan pada cluster sementara dan membuktikan bucket fisik serta dua run terpisah. Suite harian menandai tes DB sebagai `skip` jika `BATHFAN_TEST_DATABASE_URL` tidak disediakan.
- Ruling: jalur MQTT ingest menunggu INSERT melalui callback `handleMessage` agar sampel terminal tidak tertukar dengan sampel aktif yang lebih lama.
- Ruling: ESP32 demo melaporkan revisi konfigurasi dan ambang yang diterapkan; panel tidak menentukan lulus berdasarkan konfigurasi DB yang mungkin belum sampai ke perangkat.
- Hasil flash, koneksi ke broker dengan CA sebenarnya, serta pengamatan relay/rotor belum tercatat. Ikuti [runbook gladi](../../demo-scenario-bench.md) sebelum demo publik.
