# Gladi Lab Skenario Bazar

**Status:** prosedur siap; kolom observasi dan hasil belum diisi. Hanya untuk perangkat fan tegangan rendah di meja pameran. Jangan gunakan firmware demo pada sistem yang diandalkan untuk ventilasi atau alarm.

## Siapkan

1. Pakai DB, broker credentials dan perangkat khusus bazar. Karena build/app default memakai `fan01`, gunakan broker bazar terpisah bila `fan01` juga dipakai perangkat operasional. Akun broker berbeda tidak memisahkan topic yang sama. Migrasikan backend baru dahulu. Jalankan satu worker always-on; `APP_PROFILE=bazar`, `DEMO_SCENARIOS_ENABLED=false` saat setup. TLS dan ACL tetap aktif; ESP32 hanya subscribe perintah untuk ID sendiri.
2. Kompilasi biasa dan demo. Contoh FQBN `esp32:esp32:esp32`: `arduino-cli compile --fqbn esp32:esp32:esp32 --build-property "compiler.cpp.extra_flags=-DBATHFAN_DEMO_ENABLED=1" firmware/bathfan`. Gunakan FQBN board aktual, ESP32 core 3.x, library dari README dan `secrets.h` lokal. Flash build demo **hanya** ke unit stand. Nyalakan minimal tiga menit sebelum demo untuk warm-up MQ-2; lanjutkan jika sensor siap dan telemetri online.
3. Aktifkan `DEMO_SCENARIOS_ENABLED=true` dan restart worker tunggal. HP tim memakai origin HTTPS tepercaya (`ADMIN_API_ORIGIN`) dan kunci yang dimasukkan manual. HP Guest membuka Dashboard di origin yang sama, tanpa kunci.
4. Gunakan mode Auto, Power On, tidak Standby. Periksa ambang tersimpan: RH on/off 70/60, MQ-2 on/off 250/100 dan post-run 60 detik untuk hasil contoh. Profil bazar tidak menimpa konfigurasi perangkat yang sudah ada. Catat versi build dan config sebelum tiap run.
5. Dari Dashboard Admin buka **Skenario Demo**, pilih **Mandi** atau **Asap**, lalu **Mulai**. Tunggu **Berjalan**, bukan hanya respons HTTP. Biarkan Dashboard Guest tetap di depan. Setelah run pertama, cek **Statistik → Demo terakhir**, lalu kembali ke **Sensor fisik**.

## Catatan hasil

| Kasus | Build/config aktual | Ekspektasi | Observasi | Hasil |
|---|---|---|---|---|
| Mandi 10 menit · 10× | — | Air 60 dtk; kurva pulih 12 dtk; fan nyata ON lalu post-run dan OFF | — | Belum diuji |
| Asap tipis 1 orang | — | Puncak Δ ADC 160; tidak ada alarm dengan ambang 250 | — | Belum diuji |
| Asap tebal 2 orang, bergantian | — | Dua sumber visual; alarm dan fan; bersih setelah ≥60 dtk di bawah ambang | — | Belum diuji |
| Power Off saat alarm | — | Alarm tetap tampak, PWM 0, rotor berhenti | — | Belum diuji |
| Stop saat post-run | — | Sumber kembali fisik, PWM mengikuti kontrol fisik | — | Belum diuji |
| Putus WiFi dan reboot | — | Tidak terkonfirmasi/Offline di HP; run hilang dan tidak restart sendiri | — | Belum diuji |
| Guest masuk di tengah run | — | Fase sama, tanpa tombol kontrol | — | Belum diuji |
| Kurangi gerakan | — | Adegan statis; fase, alarm, dan angka tetap terbaca | — | Belum diuji |
| Firmware biasa | — | Tetap memakai sensor asli; panel demo tidak tampil | — | Belum diuji |
| History | — | Sumber fisik tidak berubah oleh dua run; grafik masing-masing terpisah | — | Belum diuji |

Catat relay dan **putaran rotor yang terlihat**, bukan sekadar PWM. Untuk timer, bedakan waktu internal ESP32 dari jeda sensor/MQTT/poll. Uji alarm fisik dan DHT rusak lewat fixture firmware, bukan asap rokok.

## Rollback

Hentikan simulasi. Tunggu status fisik atau periksa unit langsung bila offline. Matikan flag backend, lalu kembalikan firmware non-demo. Pertahankan reader/migrasi yang memisahkan history selama sampel demo masih tersimpan.

Tes PostgreSQL di komputer: arahkan `BATHFAN_TEST_DATABASE_URL` ke DB khusus uji yang mengizinkan `CREATE SCHEMA`, lalu jalankan `npm test` di `backend/`. Tes membuat dan menghapus skema uji acak. Jangan gunakan DB operasional.
