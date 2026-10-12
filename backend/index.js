require('dotenv').config();
const mqtt = require('mqtt');
const { pool, init } = require('./db');
const { startApi } = require('./api');

const INSERT_SQL = `
  INSERT INTO telemetry
    (device_id, humidity, temperature, fan_pwm, mode, state)
  VALUES ($1, $2, $3, $4, $5, $6)
`;

async function main() {
  await init();
  console.log('Database PostgreSQL siap');

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

  client.on('message', async (topic, payload) => {
    // topic berbentuk bathfan/<id>/telemetry
    const deviceId = topic.split('/')[1];

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
      await pool.query(INSERT_SQL, [
        deviceId,
        data.hum,
        data.temp,
        Number.isFinite(data.pwm) ? data.pwm : 0,
        typeof data.mode === 'string' ? data.mode : 'auto',
        typeof data.state === 'string' ? data.state : null,
      ]);
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

  startApi(client);
}

main().catch((e) => {
  console.error('Gagal memulai backend:', e.message);
  process.exit(1);
});