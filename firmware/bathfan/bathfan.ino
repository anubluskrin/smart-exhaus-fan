#include <DHT.h>

#define DHT_PIN 4
#define DHT_TYPE DHT22
#define FAN_PIN 18
#define PWM_FREQ 5000
#define PWM_RES 8

DHT dht(DHT_PIN, DHT_TYPE);

void setFanSpeed(int percent) {
  percent = constrain(percent, 0, 100);
  int duty = map(percent, 0, 100, 0, 255);
  ledcWrite(FAN_PIN, duty);
}

int humidityToSpeed(float h) {
  if (h < 60) return 0;
  if (h >= 90) return 100;
  return map((int)h, 60, 90, 30, 100);
}

void setup() {
  Serial.begin(115200);
  dht.begin();
  ledcAttach(FAN_PIN, PWM_FREQ, PWM_RES);
}

void loop() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();

  if (isnan(h) || isnan(t)) {
    Serial.println("Gagal membaca sensor");
    delay(2000);
    return;
  }

  int speed = humidityToSpeed(h);
  setFanSpeed(speed);

  Serial.printf("Kelembapan: %.1f %% | Suhu: %.1f C | Fan: %d %%\n", h, t, speed);
  delay(2000);
}