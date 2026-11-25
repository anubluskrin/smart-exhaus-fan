#define WIFI_SSID "Wokwi-GUEST"
#define WIFI_PASS ""

#define MQTT_HOST "ISI_ALAMAT_BROKER"
#define MQTT_PORT 8883
#define MQTT_USER "esp32-bathfan"
#define MQTT_PASS "ISI_PASSWORD"

#define SETUP_AP_PASS "ISI_PASSWORD_PORTAL"

// Salin isi sertifikat CA broker EMQX (emqxsl-ca.crt) agar TLS terverifikasi.
#define MQTT_CA_CERT \
"-----BEGIN CERTIFICATE-----\n" \
"ISI_SERTIFIKAT_CA_EMQX\n" \
"-----END CERTIFICATE-----\n"
