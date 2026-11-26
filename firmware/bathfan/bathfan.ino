#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include <time.h>
#include "secrets.h"
#include "wifi_setup.h"
#include "smoke_alarm.h"
#ifndef BATHFAN_DEMO_ENABLED
#define BATHFAN_DEMO_ENABLED 0
#endif
#if BATHFAN_DEMO_ENABLED
#include <esp_system.h>
#include "demo_session.h"
#endif

#define DHT_PIN 4
#define DHT_TYPE DHT11
#define FAN_PIN 18
#define PWM_FREQ 25000
#define PWM_RES 8
#define RELAY_PIN 23
#define RELAY_ACTIVE_LOW true   // ubah ke false kalau logikanya terbalik

const char* DEVICE_ID = "fan01";

// Pengaturan logika Auto
float HUM_ON = 70.0;
float HUM_OFF = 60.0;
unsigned long POSTRUN_MS = 10000;
int MAX_PWM = 100;
const int MIN_SPEED = 30;

// Jadwal waktu
const unsigned long READ_INTERVAL_MS = 2000;
const unsigned long PUBLISH_INTERVAL_MS = 5000;

enum State { IDLE, RUNNING, POSTRUN };
State state = IDLE;
unsigned long postrunStart = 0;
unsigned long lastRead = 0;
unsigned long lastPublish = 0;
int currentSpeed = 0;
bool relayOn = false;

// ===== Deteksi asap (MQ-2) =====
#define MQ_PIN 34
const unsigned long MQ_WARMUP_MS = 180000;   // 10 menit (untuk uji cepat: 180000)
float SMOKE_ON_DELTA = 250;                  // kenaikan di atas level dasar untuk menyalakan
float SMOKE_OFF_DELTA = 100;                 // di bawah ini dianggap bersih
float mqAvg = 0, mqBase = 0, smokeDelta = 0;
bool mqInit = false;
bool smokeAlert = false;
float physicalSmokeDelta = 0;
SmokeAlarm physicalAlarm;

float lastHum = 0, lastTemp = 0;
#if BATHFAN_DEMO_ENABLED
DemoSession demo;
SmokeAlarm virtualAlarm;
DemoPhase demoPhase = DemoPhase::Idle;
float physicalHum = 0, physicalTemp = 0;
bool hasValidDht = false;
String topicCmdDemo;
uint32_t demoConfigVersion = 1;
#endif

// Fallback offline
bool wasWifi = false;
int wifiAttemptIdx = 0;
unsigned long lastWifiAttempt = 0;
unsigned long lastMqttAttempt = 0;
unsigned long lastMqttOk = 0;
const unsigned long RECONNECT_INTERVAL_MS = 15000;
const unsigned long MANUAL_OFFLINE_REVERT_MS = 600000;   // 10 menit
unsigned long lastValidRead = 0;
const unsigned long SENSOR_TIMEOUT_MS = 120000;          // 2 menit
bool sensorOk = true;

// Mode kontrol
bool manualMode = false;
int manualSpeed = 0;
bool powerOn = true;
bool standbyActive = false;
unsigned long lastStandbyMsg = 0;
const float HUM_CRITICAL = 90.0;
const unsigned long STANDBY_TIMEOUT_MS = 180000;

DHT dht(DHT_PIN, DHT_TYPE);
WiFiClientSecure net;
PubSubClient mqtt(net);
String topicTelemetry;
String topicCmdAll;
String topicCmdMode;
String topicCmdSpeed;
String topicCmdPower;
String topicCmdStandby;
String topicCmdConfig;

void relayWrite(bool on) {
  relayOn = on;
  digitalWrite(RELAY_PIN, (on ^ RELAY_ACTIVE_LOW) ? HIGH : LOW);
}

void setFanSpeed(int percent) {
  percent = constrain(percent, 0, 100);
  relayWrite(percent > 0);   // relay menutup hanya saat fan harus berputar
  ledcWrite(FAN_PIN, map(percent, 0, 100, 0, 255));
}

int humidityToSpeed(float h) {
  int s = map((long)h, (long)HUM_OFF, 90, MIN_SPEED, 100);
  return constrain(s, MIN_SPEED, MAX_PWM);
}

const char* stateName(State s) {
  if (s == IDLE) return "IDLE";
  if (s == RUNNING) return "RUNNING";
  return "POSTRUN";
}

void connectWifi() {
  Serial.print("Menyambung WiFi");
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println(" terhubung");
    // DNS router tidak menjawab, jadi pakai DNS publik.
  WiFi.config(WiFi.localIP(), WiFi.gatewayIP(), WiFi.subnetMask(),
              IPAddress(8, 8, 8, 8), IPAddress(1, 1, 1, 1));
}

// Tahan tombol BOOT (GPIO 0) selama 5 detik saat menyala untuk menghapus WiFi tersimpan.
void checkWifiResetButton() {
  pinMode(0, INPUT_PULLUP);
  if (digitalRead(0) != LOW) return;
  Serial.println("Tombol BOOT terdeteksi. Tahan 5 detik untuk menghapus WiFi tersimpan...");
  unsigned long t0 = millis();
  while (digitalRead(0) == LOW) {
    if (millis() - t0 >= 5000) {
      clearWifi();
      Serial.println("WiFi tersimpan dihapus. Portal akan terbuka kalau WiFi bawaan tidak ditemukan.");
      while (digitalRead(0) == LOW) delay(50);   // tunggu tombol dilepas
      return;
    }
    delay(50);
  }
  Serial.println("Tombol dilepas sebelum 5 detik. Tidak ada yang dihapus.");
}

bool standbyIsActive() {
  return standbyActive && (millis() - lastStandbyMsg < STANDBY_TIMEOUT_MS);
}

void updateSmoke() {
  long sum = 0;
  for (int i = 0; i < 16; i++) { sum += analogRead(MQ_PIN); delay(5); }
  float v = sum / 16.0;
  if (!mqInit) { mqAvg = v; mqBase = v; mqInit = true; }
  mqAvg += (v - mqAvg) * 0.3;

  // Level dasar: selama pemanasan ikut bacaan ke dua arah; sesudahnya turun cepat,
  // naik sangat pelan, dan beku saat ada asap.
  if (millis() < MQ_WARMUP_MS) {
    mqBase += (mqAvg - mqBase) * 0.2;
  } else if (mqAvg < mqBase) {
    mqBase += (mqAvg - mqBase) * 0.1;
  } else if (!physicalAlarm.active && (mqAvg - mqBase) < SMOKE_ON_DELTA) {
    mqBase += (mqAvg - mqBase) * 0.002;
  }
  physicalSmokeDelta = mqAvg - mqBase;

  static int c = 0;
  if (++c % 5 == 0) {
    Serial.printf("MQ rata=%.0f dasar=%.0f delta=%.0f alert=%d\n", mqAvg, mqBase, physicalSmokeDelta, physicalAlarm.active);
  }

}

void continueAfterSmoke(float humidity, uint32_t now) {
  // Kelembapan tinggi: lanjut RUNNING. Selain itu: post-run lalu IDLE.
  state = humidity > HUM_ON ? RUNNING : POSTRUN;
  if (state == POSTRUN) postrunStart = now;
}

void updateControl(float h) {
  int speed = 0;

    if (!powerOn) {
    currentSpeed = 0;
    setFanSpeed(0);
    return;
  }

    if (smokeAlert) {
    state = RUNNING;   // setelah asap hilang, logika kelembapan yang menentukan kapan berhenti
    currentSpeed = MAX_PWM;
    setFanSpeed(MAX_PWM);
    return;
  }

    if (standbyIsActive()) {
    state = IDLE;
    speed = (h >= HUM_CRITICAL) ? humidityToSpeed(h) : 0;
    currentSpeed = speed;
    setFanSpeed(speed);
    return;
  }

  if (manualMode) {
    speed = min(manualSpeed, MAX_PWM);
  } else {
    switch (state) {
      case IDLE:
        speed = 0;
        if (h > HUM_ON) state = RUNNING;
        break;
      case RUNNING:
        speed = humidityToSpeed(h);
        if (h < HUM_OFF) {
          state = POSTRUN;
          postrunStart = millis();
        }
        break;
      case POSTRUN:
        speed = MIN_SPEED;
        if (h > HUM_ON) {
          state = RUNNING;
        } else if (millis() - postrunStart >= POSTRUN_MS) {
          state = IDLE;
          speed = 0;
        }
        break;
    }
  }

  currentSpeed = speed;
  setFanSpeed(speed);
}

#if BATHFAN_DEMO_ENABLED
uint32_t nextDemoGeneration() {
  uint32_t value;
  do { value = esp_random(); } while (value == demo.generation);
  return value;
}

const char* demoPhaseName(DemoPhase phase) {
  switch (phase) {
    case DemoPhase::Shower: return "shower";
    case DemoPhase::Recovery: return "recovery";
    case DemoPhase::Smoking: return "smoking";
    case DemoPhase::Settling: return "settling";
    default: return "idle";
  }
}

void applyVirtualSample(uint32_t now) {
  const DemoSample sample = sampleScenario(demo.preset, demo.elapsed(now));
  lastHum = sample.humidity;
  lastTemp = sample.temperature;
  smokeDelta = sample.smokeDelta;
  demoPhase = sample.phase;
  if (virtualAlarm.update(smokeDelta, true, SMOKE_ON_DELTA, SMOKE_OFF_DELTA, now)) {
    continueAfterSmoke(lastHum, now);
  }
  smokeAlert = virtualAlarm.active;
  updateControl(lastHum);
}

void restorePhysical(uint32_t now) {
  demoPhase = DemoPhase::Idle;
  virtualAlarm = {};
  state = IDLE;
  postrunStart = 0;
  lastHum = physicalHum;
  lastTemp = physicalTemp;
  smokeDelta = physicalSmokeDelta;
  smokeAlert = physicalAlarm.active;
  sensorOk = hasValidDht && now - lastValidRead < SENSOR_TIMEOUT_MS;
  if (!sensorOk && !smokeAlert && (!manualMode || standbyIsActive())) {
    currentSpeed = 0;
    setFanSpeed(0);
    return;
  }
  updateControl(lastHum);
  // IDLE->RUNNING normally applies PWM on the next sensor tick.
  if (state == RUNNING && currentSpeed == 0) updateControl(lastHum);
}

void finishDemo(const char* reason, uint32_t now) {
  demo.finish(reason, nextDemoGeneration());
  restorePhysical(now);
}

bool handleDemoCommand(const JsonDocument& doc) {
  const time_t epoch = time(nullptr);
  if (epoch < 1700000000L || !doc["expires_at"].is<uint32_t>() ||
      !doc["generation"].is<uint32_t>() ||
      !validDemoDeadline(static_cast<uint32_t>(epoch), doc["expires_at"].as<uint32_t>())) return false;
  const char* op = doc["op"] | "";
  const char* id = doc["run_id"] | "";
  const uint32_t nonce = doc["generation"].as<uint32_t>();
  const uint32_t now = millis();
  if (strcmp(op, "stop") == 0) {
    if (doc.size() != 4 || !demo.stop(id, nonce, nextDemoGeneration())) return false;
    restorePhysical(now);
    return true;
  }
  if (strcmp(op, "start") != 0 || !doc["speed"].is<uint8_t>()) return false;
  DemoPreset preset;
  preset.speed = doc["speed"].as<uint8_t>();
  const char* kind = doc["kind"] | "";
  if (strcmp(kind, "shower") == 0 && doc.size() == 7 && doc["minutes"].is<uint8_t>()) {
    preset.minutes = doc["minutes"].as<uint8_t>();
  } else if (strcmp(kind, "smoke") == 0 && doc.size() == 9 && doc["people"].is<uint8_t>()) {
    preset.kind = DemoKind::Smoke;
    preset.people = doc["people"].as<uint8_t>();
    const char* intensity = doc["intensity"] | "";
    if (!strcmp(intensity, "thin")) preset.intensity = DemoIntensity::Thin;
    else if (!strcmp(intensity, "medium")) preset.intensity = DemoIntensity::Medium;
    else if (!strcmp(intensity, "thick")) preset.intensity = DemoIntensity::Thick;
    else return false;
    const char* pattern = doc["pattern"] | "";
    if (!strcmp(pattern, "staggered")) preset.pattern = DemoPattern::Staggered;
    else if (strcmp(pattern, "together")) return false;
  } else {
    return false;
  }
  const bool ready = hasValidDht && now - lastValidRead < SENSOR_TIMEOUT_MS &&
                     mqInit && now >= MQ_WARMUP_MS && !physicalAlarm.active;
  if (!demo.start(preset, id, nonce, nextDemoGeneration(), now, ready)) return false;
  state = IDLE;
  postrunStart = 0;
  virtualAlarm = {};
  applyVirtualSample(now);
  return true;
}
#endif

void publishTelemetry() {
  if (!mqtt.connected()) return;
  JsonDocument doc;
  doc["hum"] = round(lastHum * 10) / 10.0;
  doc["temp"] = round(lastTemp * 10) / 10.0;
  doc["pwm"] = currentSpeed;
  doc["mode"] = manualMode ? "manual" : "auto";
  doc["power"] = powerOn;
  doc["standby"] = standbyIsActive();
  doc["relay"] = relayOn;
  doc["smoke"] = (int)round(smokeDelta);
  doc["smoke_alert"] = smokeAlert;
  doc["smoke_ready"] = millis() > MQ_WARMUP_MS;
  doc["sensor"] = sensorOk;
  doc["state"] = !powerOn ? "OFF"
               : (smokeAlert ? "ASAP"
               : (standbyIsActive() ? "STANDBY"
               : (manualMode ? "MANUAL" : stateName(state))));

#if BATHFAN_DEMO_ENABLED
  JsonObject info = doc["demo"].to<JsonObject>();
  info["v"] = 1;
  info["generation"] = demo.generation;
  info["phase"] = demoPhaseName(demoPhase);
  if (demo.id[0]) info["run_id"] = demo.id;
  if (demo.active) {
    const DemoPreset& p = demo.preset;
    info["kind"] = p.kind == DemoKind::Shower ? "shower" : "smoke";
    info["speed"] = p.speed;
    info["elapsed_s"] = demo.elapsed(millis()) / 1000;
    info["config_version"] = demoConfigVersion;
    info["hum_on"] = HUM_ON;
    info["smoke_on"] = SMOKE_ON_DELTA;
    if (p.kind == DemoKind::Shower) info["minutes"] = p.minutes;
    else {
      info["people"] = p.people;
      info["intensity"] = p.intensity == DemoIntensity::Thin ? "thin"
                        : p.intensity == DemoIntensity::Medium ? "medium" : "thick";
      info["pattern"] = p.pattern == DemoPattern::Together ? "together" : "staggered";
    }
  } else if (demo.reason) {
    info["end_reason"] = demo.reason;
  }
  char buf[768];
#else
  char buf[256];
#endif
  const size_t bytes = measureJson(doc);
  if (bytes >= sizeof(buf) || serializeJson(doc, buf) != bytes ||
      !mqtt.publish(topicTelemetry.c_str(), buf)) {
    Serial.println("Gagal menerbitkan telemetri");
    return;
  }
  Serial.printf("Terkirim: %s\n", buf);
}

void onMessage(char* topic, byte* payload, unsigned int length) {
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload, length);
  if (err) {
    Serial.println("Perintah ditolak: bukan JSON yang valid");
    return;
  }

  String t = String(topic);

#if BATHFAN_DEMO_ENABLED
  if (t == topicCmdDemo) {
    if (handleDemoCommand(doc)) publishTelemetry();
    return;
  }
#endif
  if (t == topicCmdMode) {
    const char* m = doc["mode"] | "";
    if (strcmp(m, "manual") == 0) {
      manualMode = true;
    } else if (strcmp(m, "auto") == 0) {
      manualMode = false;
      state = IDLE;
    } else {
      Serial.println("Perintah ditolak: mode harus auto atau manual");
      return;
    }
    Serial.printf("Mode diubah: %s\n", m);

  } else if (t == topicCmdSpeed) {
    if (!doc["pwm"].is<int>()) {
      Serial.println("Perintah ditolak: pwm harus berupa angka");
      return;
    }
    manualSpeed = constrain(doc["pwm"].as<int>(), 0, 100);
    Serial.printf("Kecepatan manual: %d %%\n", manualSpeed);

    } else if (t == topicCmdPower) {
    if (!doc["on"].is<bool>()) {
      Serial.println("Perintah ditolak: on harus true atau false");
      return;
    }
    powerOn = doc["on"].as<bool>();
    if (!powerOn) state = IDLE;
    Serial.printf("Daya: %s\n", powerOn ? "ON" : "OFF");

    } else if (t == topicCmdStandby) {
    if (!doc["active"].is<bool>()) {
      Serial.println("Perintah ditolak: active harus true atau false");
      return;
    }
    bool a = doc["active"].as<bool>();
    if (a != standbyActive) {
      Serial.printf("Standby: %s\n", a ? "AKTIF" : "tidak aktif");
    }
    standbyActive = a;
    lastStandbyMsg = millis();

    } else if (t == topicCmdConfig) {
    if (!doc["hum_on"].is<float>() || !doc["hum_off"].is<float>() ||
        !doc["post_run_sec"].is<int>() || !doc["max_pwm"].is<int>()) {
      Serial.println("Konfigurasi ditolak: isi tidak lengkap");
      return;
    }
    float on = doc["hum_on"].as<float>();
    float off = doc["hum_off"].as<float>();
    long pr = doc["post_run_sec"].as<long>();
    int mp = doc["max_pwm"].as<int>();
    if (off < 40 || on > 85 || on - off < 5 || pr < 0 || pr > 3600 ||
        mp < 30 || mp > 100) {
      Serial.println("Konfigurasi ditolak: nilai di luar batas");
      return;
    }
    
    float soN = SMOKE_ON_DELTA, soF = SMOKE_OFF_DELTA;
    if (doc["smoke_on"].is<int>() && doc["smoke_off"].is<int>()) {
      soN = doc["smoke_on"].as<int>();
      soF = doc["smoke_off"].as<int>();
      if (soF < 30 || soN < 100 || soN > 1000 || soN - soF < 50) {
        Serial.println("Konfigurasi asap ditolak: nilai di luar batas");
        return;
      }
    }
#if BATHFAN_DEMO_ENABLED
    if (HUM_ON != on || HUM_OFF != off || POSTRUN_MS != (unsigned long)pr * 1000UL ||
        MAX_PWM != mp || SMOKE_ON_DELTA != soN || SMOKE_OFF_DELTA != soF) ++demoConfigVersion;
#endif
    SMOKE_ON_DELTA = soN;
    SMOKE_OFF_DELTA = soF;

    HUM_ON = on;
    HUM_OFF = off;
    POSTRUN_MS = (unsigned long)pr * 1000UL;
    MAX_PWM = mp;
    Serial.printf("Konfigurasi: on=%.0f off=%.0f postrun=%ld dtk max=%d%%\n",
                  HUM_ON, HUM_OFF, pr, MAX_PWM);
    Serial.printf("Ambang asap: menyala=%.0f bersih=%.0f\n", SMOKE_ON_DELTA, SMOKE_OFF_DELTA);
    return;

  } else {
    return;
  }

  updateControl(lastHum);
  publishTelemetry();
}

void syncTimeAsync() {
  // Sinkronisasi SNTP non-blocking untuk verifikasi masa berlaku sertifikat TLS.
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
}

bool isTimeSynced() {
  return time(nullptr) >= 1700000000L;
}

void applyDns() {
  // DNS router tidak menjawab di sebagian jaringan, jadi pakai DNS publik.
  WiFi.config(WiFi.localIP(), WiFi.gatewayIP(), WiFi.subnetMask(),
              IPAddress(8, 8, 8, 8), IPAddress(1, 1, 1, 1));
}

void trackWifiState() {
  bool nowOn = (WiFi.status() == WL_CONNECTED);
  if (nowOn && !wasWifi) {
    applyDns();
    syncTimeAsync();
    Serial.println("WiFi tersambung");
  } else if (!nowOn && wasWifi) {
    Serial.println("WiFi putus, fan tetap bekerja dari sensor");
  }
  wasWifi = nowOn;
}

void maintainWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  unsigned long now = millis();
  if (lastWifiAttempt != 0 && now - lastWifiAttempt < RECONNECT_INTERVAL_MS) return;
  lastWifiAttempt = now;

  String s = savedSsid();
  String p = savedPass();
  bool useSaved = s.length() > 0 && (wifiAttemptIdx % 2 == 0);
  wifiAttemptIdx++;
  Serial.printf("Mencoba WiFi: %s\n", useSaved ? s.c_str() : WIFI_SSID);
  WiFi.disconnect();
  if (useSaved) WiFi.begin(s.c_str(), p.c_str());
  else WiFi.begin(WIFI_SSID, WIFI_PASS);
}

void maintainMqtt() {
  if (mqtt.connected()) return;
  if (WiFi.status() != WL_CONNECTED) return;
  unsigned long now = millis();
  if (lastMqttAttempt != 0 && now - lastMqttAttempt < RECONNECT_INTERVAL_MS) return;
  lastMqttAttempt = now;

  if (!isTimeSynced()) {
    syncTimeAsync();
    Serial.println("Menunggu sinkronisasi waktu NTP untuk verifikasi TLS");
    return;
  }

  Serial.print("Menyambung MQTT... ");
  String clientId = String("esp32-") + DEVICE_ID;
  if (mqtt.connect(clientId.c_str(), MQTT_USER, MQTT_PASS)) {
    Serial.println("terhubung");
    mqtt.subscribe(topicCmdAll.c_str());
    Serial.printf("Berlangganan: %s\n", topicCmdAll.c_str());
  } else {
    Serial.printf("gagal, rc=%d (kontrol lokal tetap aktif)\n", mqtt.state());
  }
}

void setup() {
  Serial.begin(115200);
    // Relay terbuka dulu sebelum pin dijadikan output, supaya fan tidak menyala saat boot.
  digitalWrite(RELAY_PIN, RELAY_ACTIVE_LOW ? HIGH : LOW);
  pinMode(RELAY_PIN, OUTPUT);
  
  dht.begin();
  analogReadResolution(12);
  analogSetPinAttenuation(MQ_PIN, ADC_11db);
  ledcAttach(FAN_PIN, PWM_FREQ, PWM_RES);

  String base = String("bathfan/") + DEVICE_ID;
  topicTelemetry = base + "/telemetry";
  topicCmdAll = base + "/cmd/#";
  topicCmdMode = base + "/cmd/mode";
  topicCmdSpeed = base + "/cmd/speed";
  topicCmdPower = base + "/cmd/power";
  topicCmdStandby = base + "/cmd/standby";
  topicCmdConfig = base + "/cmd/config";
#if BATHFAN_DEMO_ENABLED
  topicCmdDemo = base + "/cmd/demo";
  demo.generation = nextDemoGeneration();
#endif

  checkWifiResetButton();
  if (connectWifiSmart()) {
    applyDns();
    syncTimeAsync();
    wasWifi = true;
  } else {
    Serial.println("Mode offline: fan tetap bekerja dari sensor, WiFi dicoba lagi berkala");
  }
              
  net.setCACert(MQTT_CA_CERT);
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
#if BATHFAN_DEMO_ENABLED
  if (!mqtt.setBufferSize(1024)) Serial.println("Buffer MQTT demo tidak tersedia");
#else
  mqtt.setBufferSize(512);
#endif
  mqtt.setSocketTimeout(5);
  mqtt.setCallback(onMessage);
}

void loop() {
  unsigned long now = millis();

  trackWifiState();
#if BATHFAN_DEMO_ENABLED
  if (demo.active && (!mqtt.connected() || WiFi.status() != WL_CONNECTED)) {
    finishDemo("disconnected", now);
  }
#endif
  maintainWifi();
  maintainMqtt();
  if (mqtt.connected()) {
    mqtt.loop();
    lastMqttOk = now;
  }
  // MQTT callbacks may start a run after the initial loop timestamp.
  now = millis();
#if BATHFAN_DEMO_ENABLED
  if (demo.active && (!mqtt.connected() || demo.expired(now))) {
    finishDemo(mqtt.connected() ? "timeout" : "disconnected", now);
    publishTelemetry();
  }
#endif

  // Offline lama di mode Manual: kembali ke Auto, karena tidak ada yang bisa mengubahnya.
  if (manualMode && !mqtt.connected() && now - lastMqttOk > MANUAL_OFFLINE_REVERT_MS) {
    manualMode = false;
    state = IDLE;
    Serial.println("Offline lama: kembali ke mode Auto");
  }

  if (now - lastRead >= READ_INTERVAL_MS) {
    lastRead = now;
    updateSmoke();
    const bool smokeCleared = physicalAlarm.update(
      physicalSmokeDelta, millis() >= MQ_WARMUP_MS, SMOKE_ON_DELTA, SMOKE_OFF_DELTA, now);
    float h = dht.readHumidity();
    float t = dht.readTemperature();
#if BATHFAN_DEMO_ENABLED
    if (isfinite(h) && isfinite(t)) {
      lastValidRead = now;
      physicalHum = h;
      physicalTemp = t;
      hasValidDht = true;
    }
    if (demo.active) {
      if (physicalAlarm.active || now - lastValidRead >= SENSOR_TIMEOUT_MS) {
        finishDemo(physicalAlarm.active ? "physical_alarm" : "sensor_fault", now);
        publishTelemetry();
      } else {
        const DemoPhase previous = demoPhase;
        const State previousState = state;
        const bool previousAlarm = smokeAlert;
        applyVirtualSample(now);
        const bool autoControl = powerOn && !manualMode && !standbyIsActive();
        if (previous == DemoPhase::Settling && !smokeAlert &&
            (!autoControl || (state == IDLE && currentSpeed == 0))) {
          finishDemo("completed", now);
          publishTelemetry();
        } else if (demoPhase != previous || state != previousState || smokeAlert != previousAlarm) {
          publishTelemetry();
        }
      }
    } else
#endif
    {
    smokeDelta = physicalSmokeDelta;
    smokeAlert = physicalAlarm.active;
    if (smokeCleared) continueAfterSmoke(lastHum, now);
    if (isnan(h) || isnan(t)) {
      Serial.println("Gagal membaca sensor");
      if (smokeAlert) updateControl(lastHum);   // asap tetap dijaga walau DHT gagal
    } else {
      lastValidRead = now;
      lastHum = h;
      lastTemp = t;
      updateControl(h);
    }
    }
  }

  // Sensor mati lebih dari 2 menit: kelembapan tidak diketahui, jadi fan dimatikan.
  sensorOk = (now - lastValidRead < SENSOR_TIMEOUT_MS);
  if (!sensorOk && !smokeAlert && powerOn && (!manualMode || standbyIsActive())) {
    state = IDLE;
    currentSpeed = 0;
    setFanSpeed(0);
  }

  if (now - lastPublish >= PUBLISH_INTERVAL_MS) {
    lastPublish = now;
    publishTelemetry();
  }
}
