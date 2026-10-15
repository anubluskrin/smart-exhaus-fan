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

    // ===== Jadwal Standby =====
  const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
  const MAX_SCHEDULES = 20;

  function parseSchedule(body, partial) {
    const out = {};
    if (!partial || body.name !== undefined) {
      const n = typeof body.name === 'string' ? body.name.trim() : '';
      if (n.length < 1 || n.length > 40) {
        return { error: 'name harus 1 sampai 40 karakter' };
      }
      out.name = n;
    }
    for (const k of ['start_time', 'end_time']) {
      if (!partial || body[k] !== undefined) {
        if (typeof body[k] !== 'string' || !TIME_RE.test(body[k])) {
          return { error: `${k} harus berformat HH:MM` };
        }
        out[k] = body[k];
      }
    }
    if (!partial || body.days !== undefined) {
      const d = body.days;
      const valid =
        Array.isArray(d) &&
        d.length > 0 &&
        d.every((x) => Number.isInteger(x) && x >= 1 && x <= 7);
      if (!valid) return { error: 'days harus daftar angka 1 sampai 7' };
      out.days = [...new Set(d)].sort((a, b) => a - b);
    }
    if (!partial || body.enabled !== undefined) {
      if (typeof body.enabled !== 'boolean') {
        return { error: 'enabled harus true atau false' };
      }
      out.enabled = body.enabled;
    }
    return { value: out };
  }

  const fmtSchedule = (r) => ({
    id: Number(r.id),
    device_id: r.device_id,
    name: r.name,
    start_time: r.start_time.slice(0, 5),
    end_time: r.end_time.slice(0, 5),
    days: r.days,
    enabled: r.enabled,
  });

  const SCHEDULE_COLS =
    'id, device_id, name, start_time::text AS start_time, end_time::text AS end_time, days, enabled';

  app.get('/api/schedules', async (req, res) => {
    const device = req.query.device || 'fan01';
    if (!DEVICE_RE.test(device)) {
      return res.status(400).json({ error: 'nama perangkat tidak valid' });
    }
    try {
      const { rows } = await pool.query(
        `SELECT ${SCHEDULE_COLS} FROM schedules WHERE device_id = $1 ORDER BY start_time, id`,
        [device]
      );
      res.json({ device, schedules: rows.map(fmtSchedule) });
    } catch (e) {
      console.error('Gagal membaca jadwal:', e.message);
      res.status(500).json({ error: 'gagal membaca database' });
    }
  });

  app.post('/api/schedules', async (req, res) => {
    const body = req.body || {};
    const device = body.device || 'fan01';
    if (!DEVICE_RE.test(device)) {
      return res.status(400).json({ error: 'nama perangkat tidak valid' });
    }
    const parsed = parseSchedule({ enabled: true, ...body }, false);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const v = parsed.value;
    if (v.start_time === v.end_time) {
      return res.status(400).json({ error: 'jam mulai dan selesai tidak boleh sama' });
    }
    try {
      const count = await pool.query(
        'SELECT COUNT(*)::int AS n FROM schedules WHERE device_id = $1',
        [device]
      );
      if (count.rows[0].n >= MAX_SCHEDULES) {
        return res.status(400).json({ error: `maksimal ${MAX_SCHEDULES} jadwal` });
      }
      const { rows } = await pool.query(
        `INSERT INTO schedules (device_id, name, start_time, end_time, days, enabled)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING ${SCHEDULE_COLS}`,
        [device, v.name, v.start_time, v.end_time, v.days, v.enabled]
      );
      res.status(201).json(fmtSchedule(rows[0]));
    } catch (e) {
      console.error('Gagal menambah jadwal:', e.message);
      res.status(500).json({ error: 'gagal menyimpan jadwal' });
    }
  });

  app.put('/api/schedules/:id', async (req, res) => {
    if (!/^\d+$/.test(req.params.id)) {
      return res.status(400).json({ error: 'id tidak valid' });
    }
    const parsed = parseSchedule(req.body || {}, true);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const keys = Object.keys(parsed.value);
    if (keys.length === 0) {
      return res.status(400).json({ error: 'tidak ada yang diubah' });
    }
    const sets = keys.map((k, i) => `${k} = $${i + 1}`);
    const vals = keys.map((k) => parsed.value[k]);
    try {
      const { rows } = await pool.query(
        `UPDATE schedules SET ${sets.join(', ')} WHERE id = $${keys.length + 1}
         RETURNING ${SCHEDULE_COLS}`,
        [...vals, req.params.id]
      );
      if (rows.length === 0) {
        return res.status(404).json({ error: 'jadwal tidak ditemukan' });
      }
      res.json(fmtSchedule(rows[0]));
    } catch (e) {
      if (e.code === '23514') {
        return res.status(400).json({ error: 'jam mulai dan selesai tidak boleh sama' });
      }
      console.error('Gagal mengubah jadwal:', e.message);
      res.status(500).json({ error: 'gagal menyimpan jadwal' });
    }
  });

  app.delete('/api/schedules/:id', async (req, res) => {
    if (!/^\d+$/.test(req.params.id)) {
      return res.status(400).json({ error: 'id tidak valid' });
    }
    try {
      const r = await pool.query('DELETE FROM schedules WHERE id = $1', [req.params.id]);
      if (r.rowCount === 0) {
        return res.status(404).json({ error: 'jadwal tidak ditemukan' });
      }
      res.json({ ok: true });
    } catch (e) {
      console.error('Gagal menghapus jadwal:', e.message);
      res.status(500).json({ error: 'gagal menghapus jadwal' });
    }
  });

  app.listen(PORT, () => {
    console.log(`API berjalan di http://localhost:${PORT}`);
  });
}

module.exports = { startApi };