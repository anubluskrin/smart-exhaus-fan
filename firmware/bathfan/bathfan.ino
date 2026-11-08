#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include "secrets.h"
#include "wifi_setup.h"

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
float lastHum = 0, lastTemp = 0;

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

void connectMqtt() {
  while (!mqtt.connected()) {
    Serial.print("Menyambung MQTT... ");
    String clientId = String("esp32-") + DEVICE_ID;
    if (mqtt.connect(clientId.c_str(), MQTT_USER, MQTT_PASS)) {
      Serial.println("terhubung");
      mqtt.subscribe(topicCmdAll.c_str());
      Serial.printf("Berlangganan: %s\n", topicCmdAll.c_str());
    } else {
      Serial.printf("gagal, rc=%d, coba lagi 5 detik\n", mqtt.state());
      delay(5000);
    }
  }
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

void updateControl(float h) {
  int speed = 0;

    if (!powerOn) {
    currentSpeed = 0;
    setFanSpeed(0);
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

void publishTelemetry() {
  JsonDocument doc;
  doc["hum"] = round(lastHum * 10) / 10.0;
  doc["temp"] = round(lastTemp * 10) / 10.0;
  doc["pwm"] = currentSpeed;
  doc["mode"] = manualMode ? "manual" : "auto";
  doc["power"] = powerOn;
  doc["standby"] = standbyIsActive();
  doc["relay"] = relayOn;
  doc["state"] = !powerOn ? "OFF"
               : (standbyIsActive() ? "STANDBY"
               : (manualMode ? "MANUAL" : stateName(state)));

  char buf[200];
  serializeJson(doc, buf);
  mqtt.publish(topicTelemetry.c_str(), buf);
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
    HUM_ON = on;
    HUM_OFF = off;
    POSTRUN_MS = (unsigned long)pr * 1000UL;
    MAX_PWM = mp;
    Serial.printf("Konfigurasi: on=%.0f off=%.0f postrun=%ld dtk max=%d%%\n",
                  HUM_ON, HUM_OFF, pr, MAX_PWM);
    return;

  } else {
    return;
  }

  updateControl(lastHum);
  publishTelemetry();
}

void setup() {
  Serial.begin(115200);
    // Relay terbuka dulu sebelum pin dijadikan output, supaya fan tidak menyala saat boot.
  digitalWrite(RELAY_PIN, RELAY_ACTIVE_LOW ? HIGH : LOW);
  pinMode(RELAY_PIN, OUTPUT);
  
  dht.begin();
  ledcAttach(FAN_PIN, PWM_FREQ, PWM_RES);

  String base = String("bathfan/") + DEVICE_ID;
  topicTelemetry = base + "/telemetry";
  topicCmdAll = base + "/cmd/#";
  topicCmdMode = base + "/cmd/mode";
  topicCmdSpeed = base + "/cmd/speed";
  topicCmdPower = base + "/cmd/power";
  topicCmdStandby = base + "/cmd/standby";
  topicCmdConfig = base + "/cmd/config";

  checkWifiResetButton();
  connectWifiSmart();
  // DNS router tidak menjawab di sebagian jaringan, jadi pakai DNS publik.
  WiFi.config(WiFi.localIP(), WiFi.gatewayIP(), WiFi.subnetMask(),
              IPAddress(8, 8, 8, 8), IPAddress(1, 1, 1, 1));
              
  net.setInsecure();   // sementara untuk pengembangan, diperketat di Tahap 8
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setBufferSize(512);
  mqtt.setCallback(onMessage);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) connectWifi();
  if (!mqtt.connected()) connectMqtt();
  mqtt.loop();

  unsigned long now = millis();

  if (now - lastRead >= READ_INTERVAL_MS) {
    lastRead = now;
    float h = dht.readHumidity();
    float t = dht.readTemperature();
    if (isnan(h) || isnan(t)) {
      Serial.println("Gagal membaca sensor");
    } else {
      lastHum = h;
      lastTemp = t;
      updateControl(h);
    }
  }

  if (now - lastPublish >= PUBLISH_INTERVAL_MS) {
    lastPublish = now;
    publishTelemetry();
  }
}