#include <DHT.h>

#define DHT_PIN 4
#define DHT_TYPE DHT22

DHT dht(DHT_PIN, DHT_TYPE);

void setup() {
  Serial.begin(115200);
  dht.begin();
}

void loop() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();

  if (isnan(h) || isnan(t)) {
    Serial.println("Gagal membaca sensor");
    delay(2000);
    return;
  }

  Serial.printf("Kelembapan: %.1f %% | Suhu: %.1f C\n", h, t);
  delay(2000);
}