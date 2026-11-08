#pragma once
#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <Preferences.h>
#include "secrets.h"   // WIFI_SSID, WIFI_PASS, SETUP_AP_PASS

static Preferences wifiPrefs;

String savedSsid() {
  wifiPrefs.begin("wifi", false);
  String s = wifiPrefs.getString("ssid", "");
  wifiPrefs.end();
  return s;
}

String savedPass() {
  wifiPrefs.begin("wifi", false);
  String s = wifiPrefs.getString("pass", "");
  wifiPrefs.end();
  return s;
}

void saveWifi(const String& ssid, const String& pass) {
  wifiPrefs.begin("wifi", false);
  wifiPrefs.putString("ssid", ssid);
  wifiPrefs.putString("pass", pass);
  wifiPrefs.end();
}

void clearWifi() {
  wifiPrefs.begin("wifi", false);
  wifiPrefs.clear();
  wifiPrefs.end();
}

String htmlEscape(const String& s) {
  String o;
  o.reserve(s.length() + 8);
  for (size_t i = 0; i < s.length(); i++) {
    char c = s[i];
    if (c == '&') o += "&amp;";
    else if (c == '<') o += "&lt;";
    else if (c == '>') o += "&gt;";
    else if (c == '"') o += "&quot;";
    else if (c == '\'') o += "&#39;";
    else o += c;
  }
  return o;
}

// Mencoba tersambung. Mengembalikan true kalau berhasil sebelum waktu habis.
bool wifiTry(const String& ssid, const String& pass, unsigned long timeoutMs) {
  if (ssid.length() == 0) return false;
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true);
  delay(100);
  WiFi.begin(ssid.c_str(), pass.c_str());
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < timeoutMs) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  return WiFi.status() == WL_CONNECTED;
}

// Membuka WiFi "Bathfan-Setup" dan halaman pengaturan.
// Kalau pengguna menyimpan WiFi baru, ESP32 restart sendiri (fungsi tidak kembali).
// Kalau waktu habis tanpa penyimpanan, fungsi kembali.
void runSetupPortal(unsigned long maxMs) {
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP("Bathfan-Setup", SETUP_AP_PASS);
  IPAddress apIp = WiFi.softAPIP();
  Serial.printf("Portal aktif: sambungkan ke \"Bathfan-Setup\", lalu buka http://%s\n",
                apIp.toString().c_str());

  DNSServer dns;
  dns.start(53, "*", apIp);

  String options;
  int n = WiFi.scanNetworks();
  for (int i = 0; i < n && i < 20; i++) {
    String name = htmlEscape(WiFi.SSID(i));
    if (name.length() == 0) continue;
    options += "<option value=\"" + name + "\">" + name + " (" + String(WiFi.RSSI(i)) + " dBm)</option>";
  }

  WebServer server(80);
  bool saved = false;

  server.on("/", HTTP_GET, [&]() {
    String page =
      "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
      "<title>Bathfan: Pengaturan WiFi</title>"
      "<style>body{font-family:sans-serif;margin:20px;background:#0b1d3a;color:#f2f7ff}"
      "input,select,button{width:100%;padding:12px;margin:6px 0 14px;font-size:16px;"
      "border-radius:10px;border:1px solid #1f3f6e;box-sizing:border-box}"
      "button{background:#7db8ff;color:#08213f;font-weight:bold;border:0}"
      "small{color:#8fa9d0}</style></head><body>"
      "<h2>Pengaturan WiFi</h2>"
      "<small>Pilih jaringan <b>2,4 GHz</b>. ESP32 tidak mendukung 5 GHz.</small>"
      "<form method=\"POST\" action=\"/save\">"
      "<label>Pilih jaringan</label><select name=\"pick\"><option value=\"\">(pilih)</option>" + options + "</select>"
      "<label>Atau ketik nama jaringan</label><input name=\"ssid\" maxlength=\"32\" autocomplete=\"off\">"
      "<label>Password</label><input name=\"pass\" type=\"password\" maxlength=\"63\">"
      "<button type=\"submit\">Simpan dan sambungkan</button></form></body></html>";
    server.send(200, "text/html", page);
  });

  server.on("/save", HTTP_POST, [&]() {
    String ssid = server.arg("ssid");
    ssid.trim();
    if (ssid.length() == 0) ssid = server.arg("pick");
    String pass = server.arg("pass");
    bool okSsid = ssid.length() >= 1 && ssid.length() <= 32;
    bool okPass = pass.length() == 0 || (pass.length() >= 8 && pass.length() <= 63);
    if (!okSsid || !okPass) {
      server.send(400, "text/html; charset=utf-8",
        "<html><body style=\"font-family:sans-serif;margin:20px\"><h3>Data tidak valid</h3>"
        "<p>Nama jaringan wajib diisi, dan password harus 8 sampai 63 karakter "
        "(atau kosong untuk jaringan terbuka).</p><a href=\"/\">Kembali</a></body></html>");
      return;
    }
    saveWifi(ssid, pass);
    saved = true;
    server.send(200, "text/html; charset=utf-8",
      "<html><body style=\"font-family:sans-serif;margin:20px\"><h3>Tersimpan</h3>"
      "<p>ESP32 akan restart dan mencoba tersambung. Kamu boleh menutup halaman ini.</p></body></html>");
  });

  // Semua alamat lain diarahkan ke halaman utama (perilaku portal).
  server.onNotFound([&]() {
    server.sendHeader("Location", String("http://") + apIp.toString(), true);
    server.send(302, "text/plain", "");
  });

  server.begin();
  unsigned long t0 = millis();
  while (!saved && millis() - t0 < maxMs) {
    dns.processNextRequest();
    server.handleClient();
    delay(2);
  }
  server.stop();
  dns.stop();

  if (saved) {
    delay(1500);
    ESP.restart();
  }
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
}

// Dipanggil dari setup(). Tidak kembali sebelum WiFi tersambung.
void connectWifiSmart() {
  while (true) {
    String s = savedSsid();
    String p = savedPass();
    if (s.length() > 0) {
      Serial.printf("Mencoba WiFi tersimpan: %s\n", s.c_str());
      if (wifiTry(s, p, 20000)) return;
    }
    Serial.printf("Mencoba WiFi bawaan (secrets.h): %s\n", WIFI_SSID);
    if (wifiTry(WIFI_SSID, WIFI_PASS, 20000)) return;

    Serial.println("Membuka portal pengaturan WiFi (3 menit)...");
    runSetupPortal(180000);
  }
}