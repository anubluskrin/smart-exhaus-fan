#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include "secrets.h"

#define DHT_PIN 4
#define DHT_TYPE DHT22
#define FAN_PIN 18
#define PWM_FREQ 5000
#define PWM_RES 8

const char* DEVICE_ID = "fan01";

// Pengaturan logika Auto
const float HUM_ON = 70.0;
const float HUM_OFF = 60.0;
const unsigned long POSTRUN_MS = 10000;
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
float lastHum = 0, lastTemp = 0;

// Mode kontrol
bool manualMode = false;
int manualSpeed = 0;
bool powerOn = true;

DHT dht(DHT_PIN, DHT_TYPE);
WiFiClientSecure net;
PubSubClient mqtt(net);
String topicTelemetry;
String topicCmdAll;
String topicCmdMode;
String topicCmdSpeed;
String topicCmdPower;

void setFanSpeed(int percent) {
  percent = constrain(percent, 0, 100);
  ledcWrite(FAN_PIN, map(percent, 0, 100, 0, 255));
}

int humidityToSpeed(float h) {
  int s = map((long)h, (long)HUM_OFF, 90, MIN_SPEED, 100);
  return constrain(s, MIN_SPEED, 100);
}

const char* stateName(State s) {
  if (s == IDLE) return "IDLE";
  if (s == RUNNING) return "RUNNING";
  return "POSTRUN";
}

void connectWifi() {
  Serial.print("Menyambung WiFi");
  WiFi.begin(WIFI_SSID, WIFI_PASS, 6);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println(" terhubung");
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

void updateControl(float h) {
  int speed = 0;

    if (!powerOn) {
    currentSpeed = 0;
    setFanSpeed(0);
    return;
  }

  if (manualMode) {
    speed = manualSpeed;
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
  doc["state"] = !powerOn ? "OFF" : (manualMode ? "MANUAL" : stateName(state));

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

  } else {
    return;
  }

  updateControl(lastHum);
  publishTelemetry();
}

void setup() {
  Serial.begin(115200);
  dht.begin();
  ledcAttach(FAN_PIN, PWM_FREQ, PWM_RES);

  String base = String("bathfan/") + DEVICE_ID;
  topicTelemetry = base + "/telemetry";
  topicCmdAll = base + "/cmd/#";
  topicCmdMode = base + "/cmd/mode";
  topicCmdSpeed = base + "/cmd/speed";
  topicCmdPower = base + "/cmd/power";

  connectWifi();
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