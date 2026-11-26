# Lab Skenario Bazar — sensor simulasi, fan fisik

**Status:** rancangan untuk review, 26 November 2026. Basis: branch `deploy`, commit `20d2e3c`. Melengkapi [desain bazar](2026-11-25-bazar-public-deploy-design.md). Pengecualian baru ini hanya untuk firmware demo dan instalasi bazar. Simulator lokal Flutter dan penulis telemetri HTTP tetap tidak diperlukan.

## Pengalaman di meja pameran

Tim menyiapkan dua HP dengan APK terpasang dan satu ESP32 demo. Dalam dua ketukan setelah membuka panel, operator dapat memilih preset lalu memulai. Pengunjung melihat fan fisik dan cerita yang sama di Dashboard tanpa login, memasang aplikasi, atau menekan apa pun. HP Guest yang baru membuka aplikasi di tengah demo langsung mengikuti keadaan perangkat.

```text
HP TIM · Panel Skenario                  HP GUEST · Dashboard
[Mandi 10 menit ▾] [Cepat 10× ▾]         SENSOR SIMULASI · FAN FISIK
Air mengalir: 1 menit nyata              Mandi · Air mengalir
Pemulihan dan post-run: terpisah         [siluet, shower, kaca mulai berembun]
[Mulai]                                  Kelembapan 74%   Suhu 29°C
                                         PWM dilaporkan 48%    [tren singkat]
Menunggu ESP32 / Berjalan                Fan mulai berputar · mode Auto
[Hentikan simulasi]                      Statistik lengkap di tab Statistik
```

Contoh angka di sketsa bukan hasil yang dijanjikan. **PWM adalah perintah yang dilaporkan firmware, bukan RPM atau bukti rotor berputar.** Verifikasi rotor dilakukan di meja. UI Indonesia; warna didampingi teks/ikon. Panel menampilkan mode/daya/Standby aktual dan memberi tahu bila skenario tidak akan menghasilkan respons Auto biasa. Mulai tidak mengubah mode, daya, jadwal, ambang, atau kecepatan maksimum.

## Pendekatan dan batas

- Flutter-only mudah dipamerkan, tetapi tidak menguji fan. Mengirim angka dari HP/backend pada setiap tick bergantung pada jaringan dan dapat mencemari history. **Pilihan: kirim satu perintah preset, hitung kurva pada ESP32, jalankan pengendali fan asli.** Flutter hanya operator dan visualisasi.
- DHT virtual menggantikan input suhu/kelembapan. Delta asap virtual masuk **setelah** pemrosesan ADC/baseline, **sebelum** histeresis alarm. Jangan mengirim `fan_pwm`, relay, `smoke_alert`, setpoint bebas, atau perintah daya dari preset. Ini menguji kontrol dan jalur IoT, bukan kalibrasi sensor. Tidak ada klaim ppm atau hubungan fisiologis dengan jumlah perokok.
- V1: Mandi dan Asap, satu run per perangkat, dua kecepatan. Kombinasi skenario dan editor kurva bebas ditunda. Build firmware biasa dan profil backend `real` tidak dapat mengaktifkan demo. Jika menggunakan ID default `fan01`, jalankan pada broker khusus bazar yang tidak membawa topik perangkat operasional dengan ID sama.

## Kurva preset dan dua jam

Angka berikut adalah **pilihan desain awal** agar hasil bisa diulang, bukan hasil pengukuran. Satu sampel tiap tick pembacaan firmware (saat ini 2 detik nyata). Interpolasi linier antartitik; nilai di luar fase ditahan di endpoint. Baseline virtual: RH 55%, 26 °C, Δ ADC 0. Tidak ada acak per frame.

| Preset | Masukan operator | Kurva waktu virtual |
|---|---|---|
| **Mandi** | Durasi `5/10/20` menit, default 10 | Selama seperempat pertama, RH `55→85%` dan suhu `26→30 °C`; tahan sampai durasi habis. Shower mati; selama 120 detik virtual turun ke baseline. Delta tetap 0. |
| **Asap** | `1/2/3` orang, `tipis/sedang/tebal`, `bersamaan/bergantian`; default 2, sedang, bergantian | Tiap sumber menghasilkan satu pulsa delta: naik linier 30 detik virtual, tahan 30, turun selama 60. Puncak per sumber `160/320/480` sesuai intensitas; jumlahkan pulsa aktif. Awal pulsa bersamaan di detik 0, atau berjarak 30 detik. RH/suhu tetap baseline. Intensitas tipis satu orang boleh **tidak** melewati ambang. |

Kecepatan `1×/10×` (default `10×`) hanya memajukan kurva. Sesudah kurva, tahan baseline virtual pada fase `settling` agar alarm bisa bersih dan post-run selesai dengan **jam nyata**. Selesai otomatis saat alarm padam dan kontrol Auto kembali `IDLE` dengan PWM 0; bila Off/Manual/Standby, selesai saat kurva habis dan alarm padam. Batas mutlak setiap run **30 menit nyata**; tampilkan `Batas waktu`, bukan `Lulus`, bila konfigurasi membuat run melebihi batas. Tidak ada perubahan global ke `millis()`, SNTP, timeout Standby maupun aturan firmware. Contoh: air Mandi 10 menit pada 10× berjalan 60 detik nyata; pemulihan kurva 12 detik nyata; post-run bazar sesuai config aktual (default 60 detik nyata, mulai saat RH melewati ambang mati).

## Kontrol, konfirmasi, dan kembali ke fisik

1. Build tim menampilkan panel bila sesi Admin HTTPS valid, backend bazar diaktifkan (`DEMO_SCENARIOS_ENABLED=true`) dan status segar menyatakan firmware mendukung demo (`BATHFAN_DEMO_ENABLED`, default off). HP Guest tidak punya tombol mutasi. Pakai allowlist perangkat dan broker ACL yang sudah ada.
2. Admin mengirim `POST /api/demo/start` atau `/api/demo/stop`. Server memvalidasi metode, role, profil, allowlist, payload bertipe tepat dan enum. Gunakan `device`, `run_id` UUID v4 dari aplikasi (satu per aksi start; stop memakai ID yang sama). Start mandi menambah `kind:"shower", minutes:10, speed:10`; start asap menambah `kind:"smoke", people:2, intensity:"medium", pattern:"staggered", speed:10`. Enum wire: `thin|medium|thick`, `together|staggered`. Tolak field ekstra, termasuk nilai sensor/aktuator. Tanpa retry POST otomatis.
3. Backend mengambil **telemetri terbaru**, memeriksa kemampuan/kesegaran dan konflik. Publish `bathfan/{id}/cmd/demo` (QoS 1, **retain false**), dengan `op:start|stop`, `expires_at` Unix detik (+10 detik), dan `generation` dari telemetri. Generation adalah nonce acak ESP32 saat boot dan setelah tiap transisi start/stop/selesai. Firmware memeriksa waktu tersinkron, expiry, nonce dan run ID; duplikat tidak mereset kurva, stop lama tidak membatalkan run baru. ESP32 menentukan pemenang dua start serentak. Stop untuk run aktif diizinkan walau start dibatasi laju. Power Off tetap tersedia.
4. HTTP `202` berarti broker menerima, **belum berarti alat berjalan/berhenti**. Firmware publish telemetri segera setelah transisi, lalu periodik seperti biasa. Admin menunggu `run_id` yang cocok; jika ID lain aktif, tampilkan `Perangkat sedang menjalankan skenario lain`. Tanpa konfirmasi setelah 15 detik: `Belum terkonfirmasi`, baca status lagi, jangan menebak. Status stale ≥20 detik membekukan visual dan memunculkan `Koneksi terputus`.
5. Stop berarti **kembali ke sensor fisik**, bukan memaksa fan mati. Restart selalu fisik; saat broker putus, perangkat mengakhiri demo lokal dan melaporkan hasil saat tersambung lagi jika belum reboot. Jangan simpan run di flash. Selama demo, tetap sampel sensor nyata dengan state baseline/alarm fisik terpisah. Alarm fisik mengakhiri demo dan mengambil alih; input virtual tidak boleh menyamarkan alarm fisik atau menyegarkan timestamp DHT nyata. Start ditolak selama sensor fisik belum siap/sehat atau alarm fisik aktif. Saat keluar, buang latch/timer simulasi dan evaluasi input, prioritas dan fallback fisik pada tick tersebut; tidak mengubah power/manual/Standby yang sudah ada.

## Telemetri dan statistik

- Field MQTT lama tetap. Firmware demo menambah `demo:{v:1,generation,run_id,kind,phase,speed,elapsed_s,people,intensity,pattern,minutes,end_reason}`; field opsi tak relevan dihilangkan. `elapsed_s` detik **nyata** sejak start. `phase` = `idle|shower|recovery|smoking|settling`. Saat idle, `run_id` menunjuk run terakhir jika ada; `end_reason` = `completed|stopped|timeout|disconnected|physical_alarm|sensor_fault` bila diketahui. `sensor_fault` mengakhiri run bila DHT fisik melewati timeout kesehatan firmware. Idle dengan ID lama **tetap sampel fisik**. Field demo absen = perangkat lama/fisik, tanpa panel. Metadata versi tak dikenal/invalid bukan sampel fisik: abaikan paket dan catat diagnosis terbatas.
- DB menyimpan sumber `physical|demo`, metadata dan ID run bersama **sampel yang dilaporkan ESP32**. History default hanya `physical`; `GET /api/history?source=demo&run_id=...&range=1h` hanya untuk run dan perangkat yang diminta di lingkungan demo. Filter sebelum agregasi; masukkan sumber dan ID run ke key cache dan in-flight. `GET /api/status` tetap **terbaru dari kedua sumber** dengan penanda sumber dan metadata; umur paket ESP32 menentukan online. Jangan expose nonce ke Guest: REST status mengirim proyeksi UI, server mengambil nonce langsung dari DB.
- Firmware juga melaporkan versi konfigurasi dan ambang `hum_on`/`smoke_on` selama run agar panel tidak menebak konfigurasi yang sudah diterapkan.
- Indikator operator: `Menunggu ambang`, `Teramati`, `Tidak tercapai`, `Tidak dinilai`. Nilai dari sampel, bukan animasi. Shower Auto: RH di atas ambang dan PWM positif; asap: `smoke_alert`, lalu padam; post-run: amati `POSTRUN` dan kemudian `IDLE`. Ringkasan **Lulus/Gagal** hanya pada run lengkap dengan sampel memadai, mode/config stabil, dan ambang yang memang dilintasi. Bila kepastian hilang (gap >20 detik, stop, timeout, override, config tidak diketahui, atau fase cepat tidak terekam), tampilkan `Tidak dinilai` beserta alasan. Bukti GUI bukan pengukuran durasi presisi; uji fake clock/bench menguji timer.

## Adegan Guest

Gunakan `CustomPainter`/widget 2D, tanpa video atau aset jaringan. Saat `shower`, siluet orang di balik kaca, tetesan turun; saat `recovery/settling`, shower berhenti, embun mengikuti RH. Saat `smoking`, gambar 1–3 sumber sesuai preset; pulsa bergantian memakai waktu perangkat, opasitas mengikuti delta terlapor. Pada fase bersih tetapi alarm masih aktif, tampilkan **Menunggu udara bersih**. Fan beranimasi dari PWM aktual; 0 berarti diam meski asap tampak tebal. Label **Sensor simulasi · Fan fisik** selalu terlihat pada sampel demo. Saat kembali fisik, hapus adegan dan pulihkan Dashboard biasa. Poll hanya tab aktif di foreground; animasi lokal tidak mengeluarkan request. Hormati pengaturan kurangi gerakan dengan frame statis, teks fase dan angka yang sama.

## Bukti penerimaan sebelum bazar

Dengan dua HP, satu backend, satu ESP32 demo: jalankan Mandi 10 menit 10× dan Asap tebal 2 orang; cocokkan adegan, alarm, PWM, relay dan putaran fan yang terlihat. HP Guest kedua yang masuk di tengah run melihat fase sama. Uji stop, Power Off ketika alarm aktif, koneksi putus, reboot, mode biasa dan riwayat terpisah. Untuk alarm sensor fisik yang mengambil alih, gunakan fixture input pada pengujian firmware; tidak perlu menghasilkan asap nyata. Demo pertama menggunakan konfigurasi bazar bawaan, Auto, Power On, tanpa jadwal Standby aktif. Detail langkah dan gate: [rencana eksekusi](../plans/2026-11-26-lab-skenario-fan-fisik.md).
