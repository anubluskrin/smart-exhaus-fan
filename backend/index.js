require('dotenv').config();
const mqtt = require('mqtt');
const db = require('./db');

const insertTelemetry = db.prepare(`
  INSERT INTO telemetry
    (device_id, humidity, temperature, fan_pwm, mode, state, created_at)
  VALUES
    (@device_id, @humidity, @temperature, @fan_pwm, @mode, @state, @created_at)
`);

const client = mqtt.connect(
  `mqtts://${process.env.MQTT_HOST}:${process.env.MQTT_PORT}`,
  {
    username: process.env.MQTT_USER,
    password: process.env.MQTT_PASS,
    clientId: 'backend-bathfan-' + Math.random().toString(16).slice(2, 8),
  }
);

client.on('connect', () => {
  console.log('Backend terhubung ke broker');
  client.subscribe('bathfan/+/telemetry', (err) => {
    if (err) console.error('Gagal berlangganan:', err.message);
    else console.log('Berlangganan: bathfan/+/telemetry');
  });
});

client.on('message', (topic, payload) => {
  // topic berbentuk bathfan/<id>/telemetry
  const parts = topic.split('/');
  const deviceId = parts[1];

  let data;
  try {
    data = JSON.parse(payload.toString());
  } catch (e) {
    console.error('Pesan bukan JSON yang valid, dilewati');
    return;
  }

  if (typeof data.hum !== 'number' || typeof data.temp !== 'number') {
    console.error('Data tidak lengkap, dilewati:', payload.toString());
    return;
  }

  try {
    insertTelemetry.run({
      device_id: deviceId,
      humidity: data.hum,
      temperature: data.temp,
      fan_pwm: Number.isFinite(data.pwm) ? data.pwm : 0,
      mode: typeof data.mode === 'string' ? data.mode : 'auto',
      state: typeof data.state === 'string' ? data.state : null,
      created_at: new Date().toISOString(),
    });
    console.log(
      `Tersimpan [${deviceId}] hum=${data.hum} temp=${data.temp} pwm=${data.pwm} state=${data.state}`
    );
  } catch (e) {
    console.error('Gagal menyimpan:', e.message);
  }
});

client.on('error', (err) => {
  console.error('Error MQTT:', err.message);
});

const { startApi } = require('./api');
startApi();