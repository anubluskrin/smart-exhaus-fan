const express = require('express');
const path = require('path');
const { pool } = require('./db');

const PORT = 3000;
const ONLINE_THRESHOLD_SEC = 20;

// rentang waktu: durasi (detik) dan lebar kelompok rata-rata (detik)
const RANGES = {
  '1h': { seconds: 3600, bucket: 10 },
  '24h': { seconds: 86400, bucket: 60 },
  '7d': { seconds: 604800, bucket: 600 },
};

const DEVICE_RE = /^[A-Za-z0-9_-]{1,32}$/;

const LATEST_SQL = `
  SELECT humidity, temperature, fan_pwm, mode, state, power, created_at
  FROM telemetry
  WHERE device_id = $1
  ORDER BY id DESC
  LIMIT 1
`;

const HISTORY_SQL = `
  SELECT
    to_timestamp((floor(extract(epoch FROM created_at) / $3::int) * $3::int)::double precision) AS t,
    ROUND(AVG(humidity)::numeric, 1)::float8 AS humidity,
    ROUND(AVG(temperature)::numeric, 1)::float8 AS temperature,
    ROUND(AVG(fan_pwm)::numeric)::int AS fan_pwm
  FROM telemetry
  WHERE device_id = $1 AND created_at >= $2
  GROUP BY 1
  ORDER BY 1
`;

function startApi(mqttClient) {
  const app = express();
  app.use(express.json());
  app.use(express.static(path.join(__dirname, '..', 'dashboard')));

  app.get('/api/status', async (req, res) => {
    const device = req.query.device || 'fan01';
    if (!DEVICE_RE.test(device)) {
      return res.status(400).json({ error: 'nama perangkat tidak valid' });
    }
    try {
      const { rows } = await pool.query(LATEST_SQL, [device]);
      if (rows.length === 0) {
        return res.json({ device, online: false, latest: null });
      }
      const row = rows[0];
      const ageSec = (Date.now() - row.created_at.getTime()) / 1000;
      res.json({
        device,
        online: ageSec < ONLINE_THRESHOLD_SEC,
        last_seen_sec_ago: Math.round(ageSec),
        latest: {
          humidity: row.humidity,
          temperature: row.temperature,
          fan_pwm: row.fan_pwm,
          mode: row.mode,
          state: row.state,
          power: row.power ?? true,
          time: row.created_at,
        },
      });
    } catch (e) {
      console.error('Gagal membaca status:', e.message);
      res.status(500).json({ error: 'gagal membaca database' });
    }
  });

  app.get('/api/history', async (req, res) => {
    const device = req.query.device || 'fan01';
    if (!DEVICE_RE.test(device)) {
      return res.status(400).json({ error: 'nama perangkat tidak valid' });
    }
    const range = RANGES[req.query.range] ? req.query.range : '1h';
    const { seconds, bucket } = RANGES[range];
    const since = new Date(Date.now() - seconds * 1000);
    try {
      const { rows } = await pool.query(HISTORY_SQL, [device, since, bucket]);
      res.json({ device, range, count: rows.length, points: rows });
    } catch (e) {
      console.error('Gagal membaca riwayat:', e.message);
      res.status(500).json({ error: 'gagal membaca database' });
    }
  });

  function publishCommand(device, sub, payload, res) {
    if (!DEVICE_RE.test(device)) {
      return res.status(400).json({ error: 'nama perangkat tidak valid' });
    }
    if (!mqttClient.connected) {
      return res.status(503).json({ error: 'Backend belum terhubung ke broker' });
    }
    const topic = `bathfan/${device}/cmd/${sub}`;
    mqttClient.publish(topic, JSON.stringify(payload), { qos: 1 }, (err) => {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ ok: true, topic, payload });
    });
  }

  app.post('/api/mode', (req, res) => {
    const body = req.body || {};
    const device = body.device || 'fan01';
    const mode = body.mode;
    if (mode !== 'auto' && mode !== 'manual') {
      return res.status(400).json({ error: 'mode harus auto atau manual' });
    }
    publishCommand(device, 'mode', { mode }, res);
  });

  app.post('/api/speed', (req, res) => {
    const body = req.body || {};
    const device = body.device || 'fan01';
    const pwm = Number(body.pwm);
    if (!Number.isInteger(pwm) || pwm < 0 || pwm > 100) {
      return res.status(400).json({ error: 'pwm harus bilangan bulat 0 sampai 100' });
    }
    publishCommand(device, 'speed', { pwm }, res);
  });

  app.post('/api/power', (req, res) => {
    const body = req.body || {};
    const device = body.device || 'fan01';
    if (typeof body.on !== 'boolean') {
      return res.status(400).json({ error: 'on harus true atau false' });
    }
    publishCommand(device, 'power', { on: body.on }, res);
  });

  app.listen(PORT, () => {
    console.log(`API berjalan di http://localhost:${PORT}`);
  });
}

module.exports = { startApi };