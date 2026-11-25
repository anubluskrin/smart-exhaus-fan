require('dotenv').config();
const fs = require('node:fs');
const mqtt = require('mqtt');
const { pool: defaultPool, init, cleanupOldFeedback } = require('./db');
const { startApi } = require('./api');
const { startScheduler } = require('./scheduler');
const { isAllowedDevice, validateStartupEnv } = require('./config');

const MAX_TELEMETRY_BYTES = 4096;
const TELEMETRY_TOPIC_RE = /^bathfan\/([^/]+)\/telemetry$/;
const FEEDBACK_CLEANUP_MS = 6 * 60 * 60 * 1000;

const INSERT_SQL = `
  INSERT INTO telemetry
    (device_id, humidity, temperature, fan_pwm, mode, state, power,
     smoke, smoke_alert, smoke_ready)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
`;

function parseTelemetryPayload(payload) {
  const byteLength = Buffer.isBuffer(payload)
    ? payload.length
    : Buffer.byteLength(String(payload ?? ''), 'utf8');

  if (byteLength === 0 || byteLength > MAX_TELEMETRY_BYTES) {
    return null;
  }

  let data;
  try {
    data = JSON.parse(Buffer.isBuffer(payload) ? payload.toString('utf8') : String(payload));
  } catch (_) {
    return null;
  }

  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return null;
  }

  if (typeof data.hum !== 'number' || !Number.isFinite(data.hum) || data.hum < 0 || data.hum > 100) {
    return null;
  }
  if (typeof data.temp !== 'number' || !Number.isFinite(data.temp) || data.temp < -40 || data.temp > 125) {
    return null;
  }

  let pwm = 0;
  if (data.pwm !== undefined) {
    if (typeof data.pwm !== 'number' || !Number.isFinite(data.pwm) || data.pwm < 0 || data.pwm > 100) {
      return null;
    }
    pwm = Math.round(data.pwm);
  }

  let mode = 'auto';
  if (data.mode !== undefined) {
    if (data.mode !== 'auto' && data.mode !== 'manual') {
      return null;
    }
    mode = data.mode;
  }

  let state = null;
  if (data.state !== undefined && data.state !== null) {
    if (typeof data.state !== 'string' || data.state.length > 32) {
      return null;
    }
    state = data.state;
  }

  let power = true;
  if (data.power !== undefined) {
    if (typeof data.power !== 'boolean') {
      return null;
    }
    power = data.power;
  }

  let smoke = null;
  if (data.smoke !== undefined && data.smoke !== null) {
    if (
      typeof data.smoke !== 'number' ||
      !Number.isFinite(data.smoke) ||
      data.smoke < -4095 ||
      data.smoke > 4095
    ) {
      return null;
    }
    smoke = Math.round(data.smoke);
  }

  const smokeAlert = data.smoke_alert === undefined ? false : data.smoke_alert;
  const smokeReady = data.smoke_ready === undefined ? false : data.smoke_ready;
  if (typeof smokeAlert !== 'boolean' || typeof smokeReady !== 'boolean') {
    return null;
  }

  return {
    hum: data.hum,
    temp: data.temp,
    pwm,
    mode,
    state,
    power,
    smoke,
    smoke_alert: smokeAlert,
    smoke_ready: smokeReady,
  };
}

async function handleTelemetryMessage(topic, payload, { pool = defaultPool, env = process.env } = {}) {
  const match = TELEMETRY_TOPIC_RE.exec(String(topic || ''));
  if (!match) return false;
  const deviceId = match[1];
  if (!isAllowedDevice(deviceId, env)) {
    return false;
  }

  const parsed = parseTelemetryPayload(payload);
  if (!parsed) {
    console.error(`Telemetri tidak valid untuk [${deviceId}], dilewati`);
    return false;
  }

  try {
    await pool.query(INSERT_SQL, [
      deviceId,
      parsed.hum,
      parsed.temp,
      parsed.pwm,
      parsed.mode,
      parsed.state,
      parsed.power,
      parsed.smoke,
      parsed.smoke_alert,
      parsed.smoke_ready,
    ]);
    console.log(
      `Tersimpan [${deviceId}] hum=${parsed.hum} temp=${parsed.temp} pwm=${parsed.pwm} state=${parsed.state}`
    );
    return true;
  } catch (e) {
    console.error('Gagal menyimpan:', e.message);
    return false;
  }
}

function readMqttCa(env = process.env) {
  if (env.MQTT_CA_CERT && String(env.MQTT_CA_CERT).trim() !== '') {
    return String(env.MQTT_CA_CERT).replace(/\\n/g, '\n');
  }
  if (env.MQTT_CA_FILE && String(env.MQTT_CA_FILE).trim() !== '') {
    return fs.readFileSync(String(env.MQTT_CA_FILE).trim(), 'utf8');
  }
  return undefined;
}

async function main() {
  const startup = validateStartupEnv(process.env);
  await init(defaultPool, process.env);
  console.log(`Database PostgreSQL siap (profil=${startup.profile}, post_run=${startup.postRunSec}s)`);

  await cleanupOldFeedback(defaultPool, 30);
  const cleanupTimer = setInterval(() => {
    cleanupOldFeedback(defaultPool, 30).catch((e) => {
      console.error('Gagal membersihkan feedback lama:', e.message);
    });
  }, FEEDBACK_CLEANUP_MS);
  if (typeof cleanupTimer.unref === 'function') cleanupTimer.unref();

  const ca = readMqttCa(process.env);
  const client = mqtt.connect(
    `mqtts://${process.env.MQTT_HOST}:${process.env.MQTT_PORT}`,
    {
      username: process.env.MQTT_USER,
      password: process.env.MQTT_PASS,
      clientId: 'backend-bathfan-' + Math.random().toString(16).slice(2, 8),
      rejectUnauthorized: true,
      ...(ca ? { ca } : {}),
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
    handleTelemetryMessage(topic, payload, { pool: defaultPool, env: process.env });
  });

  client.on('error', (err) => {
    console.error('Error MQTT:', err.message);
  });

  startApi(client, { pool: defaultPool, env: process.env });
  startScheduler(client, { pool: defaultPool, env: process.env });
}

if (require.main === module) {
  main().catch((e) => {
    console.error('Gagal memulai backend:', e.message);
    process.exit(1);
  });
}

module.exports = { handleTelemetryMessage, parseTelemetryPayload, main };
