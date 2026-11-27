const express = require('express');
const crypto = require('node:crypto');
const { pool: defaultPool } = require('./db');
const { isRunId } = require('./demo_telemetry');
const { registerDemoRoutes } = require('./demo_routes');
const {
  DEVICE_RE,
  getDefaultConfig,
  getPort,
  getTrustProxy,
  validateStartupEnv,
} = require('./config');

const ONLINE_THRESHOLD_SEC = 20;
const HISTORY_CACHE_TTL_MS = 5000;
const MAX_HISTORY_CACHE_ENTRIES = 100;

// rentang waktu: durasi (detik) dan lebar kelompok rata-rata (detik)
const RANGES = {
  '1h': { seconds: 3600, bucket: 10 },
  '24h': { seconds: 86400, bucket: 60 },
  '7d': { seconds: 604800, bucket: 600 },
};

const LATEST_SQL = `
  SELECT humidity, temperature, fan_pwm, mode, state, power,
         smoke, smoke_alert, smoke_ready, created_at, source, demo_meta, relay, standby, sensor_ok
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
    ROUND(AVG(fan_pwm)::numeric)::int AS fan_pwm,
    ROUND(AVG(smoke) FILTER (WHERE smoke_ready IS TRUE)::numeric)::int AS smoke,
    BOOL_OR(COALESCE(smoke_alert, false)) AS smoke_alert
  FROM telemetry
  WHERE device_id = $1 AND created_at >= $2 AND source = $4
    AND demo_run_id IS NOT DISTINCT FROM $5::uuid
  GROUP BY 1
  ORDER BY 1
`;

function parsePositiveInt(raw, fallback, min, max, label) {
  if (raw === undefined || String(raw).trim() === '') return fallback;
  const s = String(raw).trim();
  if (!/^\d+$/.test(s)) {
    throw new Error(`${label} tidak valid: "${raw}"`);
  }
  const n = Number(s);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new Error(`${label} harus antara ${min} dan ${max}: ${n}`);
  }
  return n;
}

function createWindowLimiter({ max, windowMs, maxEntries = 10000, nowFn = () => Date.now() }) {
  const entries = new Map(); // key -> { n, resetAt }

  function prune(now) {
    for (const [k, v] of entries) {
      if (v.resetAt <= now) entries.delete(k);
    }
    while (entries.size >= maxEntries) {
      const oldest = entries.keys().next().value;
      if (oldest === undefined) break;
      entries.delete(oldest);
    }
  }

  function retryAfterSec(key) {
    const now = nowFn();
    const cur = entries.get(key);
    if (!cur || cur.resetAt <= now) return 0;
    if (cur.n < max) return 0;
    return Math.max(1, Math.ceil((cur.resetAt - now) / 1000));
  }

  function record(key) {
    const now = nowFn();
    let cur = entries.get(key);
    if (!cur || cur.resetAt <= now) {
      if (entries.size >= maxEntries) prune(now);
      cur = { n: 0, resetAt: now + windowMs };
    }
    cur.n += 1;
    entries.delete(key);
    entries.set(key, cur);
    return cur;
  }

  function tryConsume(key) {
    const blocked = retryAfterSec(key);
    if (blocked > 0) return blocked;
    record(key);
    return 0;
  }

  return { retryAfterSec, record, tryConsume, prune };
}

function isPlainObject(v) {
  return Boolean(v) && typeof v === 'object' && !Array.isArray(v);
}

function createApp(mqttClient, { pool = defaultPool, env = process.env, nowFn = () => Date.now() } = {}) {
  const startup = validateStartupEnv(env);
  const isBazar = startup.profile === 'bazar';
  const allowedDevices = startup.allowedDevices;
  const allowedSet = new Set(allowedDevices);
  const defaultConfig = getDefaultConfig(env);
  const configKeys = Object.keys(defaultConfig);

  const publicReadLimit = parsePositiveInt(
    env.PUBLIC_READ_LIMIT_PER_MIN,
    120,
    1,
    10000,
    'PUBLIC_READ_LIMIT_PER_MIN'
  );
  const feedbackHourlyLimit = parsePositiveInt(
    env.FEEDBACK_HOURLY_LIMIT,
    300,
    1,
    100000,
    'FEEDBACK_HOURLY_LIMIT'
  );

  const app = express();
  app.set('trust proxy', getTrustProxy(env));
  app.use(express.json({ limit: '16kb' }));

  app.use((err, req, res, next) => {
    if (err && err.type === 'entity.too.large') {
      return res.status(413).json({ error: 'ukuran permintaan melebihi batas 16 KiB' });
    }
    if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
      return res.status(400).json({ error: 'format JSON tidak valid' });
    }
    return next(err);
  });

  // ===== Rate limiters terpisah =====
  const authFailLimiter = createWindowLimiter({
    max: 10,
    windowMs: 60 * 1000,
    nowFn,
  });
  const publicReadLimiter = createWindowLimiter({
    max: publicReadLimit,
    windowMs: 60 * 1000,
    nowFn,
  });
  const feedbackIpLimiter = createWindowLimiter({
    max: 5,
    windowMs: 10 * 60 * 1000,
    nowFn,
  });
  const feedbackStandLimiter = createWindowLimiter({
    max: feedbackHourlyLimit,
    windowMs: 60 * 60 * 1000,
    nowFn,
  });

  const pruneTimer = setInterval(() => {
    const now = nowFn();
    authFailLimiter.prune(now);
    publicReadLimiter.prune(now);
    feedbackIpLimiter.prune(now);
    feedbackStandLimiter.prune(now);
  }, 60 * 1000);
  if (typeof pruneTimer.unref === 'function') pruneTimer.unref();

  const keyHash = crypto.createHash('sha256').update(env.API_KEY).digest();

  function sendRateLimited(res, retryAfterSec, message) {
    res.set('Retry-After', String(retryAfterSec));
    res.set('Cache-Control', 'no-store');
    return res.status(429).json({
      error: message,
      retry_after_sec: retryAfterSec,
    });
  }

  function requireAdmin(req, res, next) {
    res.set('Cache-Control', 'no-store');
    const ip = req.ip || 'unknown';
    const blocked = authFailLimiter.retryAfterSec(ip);
    if (blocked > 0) {
      return sendRateLimited(res, blocked, 'terlalu banyak percobaan, coba lagi nanti');
    }

    const given = req.get('X-API-Key') || '';
    const givenHash = crypto.createHash('sha256').update(given).digest();
    if (given.length > 0 && crypto.timingSafeEqual(givenHash, keyHash)) {
      return next();
    }

    authFailLimiter.record(ip);
    return res.status(401).json({ error: 'kunci API tidak ada atau salah' });
  }

  function enforcePublicReadLimit(req, res, next) {
    const ip = req.ip || 'unknown';
    const blocked = publicReadLimiter.tryConsume(ip);
    if (blocked > 0) {
      return sendRateLimited(res, blocked, 'batas pembacaan tercapai, coba lagi sebentar');
    }
    return next();
  }

  function resolveDevice(rawDevice, res) {
    if (rawDevice !== undefined && typeof rawDevice !== 'string') {
      res.status(400).json({ error: 'nama perangkat tidak valid' });
      return null;
    }
    const device = rawDevice === undefined || rawDevice === '' ? 'fan01' : rawDevice;
    if (!DEVICE_RE.test(device)) {
      res.status(400).json({ error: 'nama perangkat tidak valid' });
      return null;
    }
    if (!allowedSet.has(device)) {
      res.status(403).json({ error: 'perangkat tidak diizinkan' });
      return null;
    }
    return device;
  }

  // ===== Endpoint kesehatan (selalu publik, minimal) =====
  app.get('/health', (req, res) => {
    res.json({ ok: true });
  });

  // ===== Handler baca & masukan =====
  async function handleStatus(req, res) {
    const device = resolveDevice(req.query.device, res);
    if (!device) return;
    try {
      const { rows } = await pool.query(LATEST_SQL, [device]);
      if (rows.length === 0) {
        return res.json({ device, online: false, latest: null });
      }
      const row = rows[0];
      const ageSec = (nowFn() - new Date(row.created_at).getTime()) / 1000;
      const { generation, ...publicDemo } = row.demo_meta ?? {};
      return res.json({
        device,
        online: ageSec < ONLINE_THRESHOLD_SEC,
        ...(row.demo_meta ? { demo_available: startup.demoEnabled && ageSec < ONLINE_THRESHOLD_SEC } : {}),
        last_seen_sec_ago: Math.max(0, Math.round(ageSec)),
        latest: {
          humidity: row.humidity,
          temperature: row.temperature,
          fan_pwm: row.fan_pwm,
          mode: row.mode,
          state: row.state,
          power: row.power ?? true,
          smoke: row.smoke ?? null,
          smoke_alert: row.smoke_alert ?? false,
          smoke_ready: row.smoke_ready ?? false,
          ...(row.demo_meta ? {
            source: row.source, demo: publicDemo, relay: row.relay, standby: row.standby,
            sensor_ok: row.sensor_ok,
          } : {}),
          time: row.created_at,
        },
      });
    } catch (e) {
      console.error('Gagal membaca status:', e.message);
      return res.status(500).json({ error: 'gagal membaca database' });
    }
  }

  const historyCache = new Map(); // key -> { expiresAt, data }
  const historyInFlight = new Map(); // key -> Promise

  async function fetchHistory(device, range, source, runId) {
    const key = `${device}:${range}:${source}:${runId ?? ''}`;
    const now = nowFn();
    const cached = historyCache.get(key);
    if (cached && cached.expiresAt > now) {
      return cached.data;
    }

    if (historyInFlight.has(key)) {
      return historyInFlight.get(key);
    }

    const { seconds, bucket } = RANGES[range];
    const since = new Date(now - seconds * 1000);

    const promise = (async () => {
      const { rows } = await pool.query(HISTORY_SQL, [device, since, bucket, source, runId]);
      const data = { device, range, count: rows.length, points: rows };
      if (historyCache.size >= MAX_HISTORY_CACHE_ENTRIES) {
        const oldest = historyCache.keys().next().value;
        if (oldest !== undefined) historyCache.delete(oldest);
      }
      historyCache.set(key, { expiresAt: nowFn() + HISTORY_CACHE_TTL_MS, data });
      return data;
    })();

    historyInFlight.set(key, promise);
    try {
      return await promise;
    } finally {
      historyInFlight.delete(key);
    }
  }

  async function handleHistory(req, res) {
    const device = resolveDevice(req.query.device, res);
    if (!device) return;

    const rawRange = req.query.range;
    if (rawRange !== undefined && typeof rawRange !== 'string') {
      return res.status(400).json({ error: 'range tidak valid' });
    }
    const range = rawRange === undefined || rawRange === '' ? '1h' : rawRange;
    if (!Object.prototype.hasOwnProperty.call(RANGES, range)) {
      return res.status(400).json({ error: 'range harus 1h, 24h, atau 7d' });
    }
    const source = req.query.source ?? 'physical';
    const runId = req.query.run_id;
    if ((source !== 'physical' && source !== 'demo') ||
        (source === 'demo' ? !isRunId(runId) : runId !== undefined)) {
      return res.status(400).json({ error: 'sumber atau ID skenario tidak valid' });
    }
    if (source === 'demo' && !isBazar) return res.status(404).json({ error: 'riwayat demo tidak tersedia' });

    try {
      const payload = await fetchHistory(device, range, source, runId ?? null);
      return res.json(payload);
    } catch (e) {
      console.error('Gagal membaca riwayat:', e.message);
      return res.status(500).json({ error: 'gagal membaca database' });
    }
  }

  const SCHEDULE_COLS =
    'id, device_id, name, start_time::text AS start_time, end_time::text AS end_time, days, enabled';

  const fmtSchedule = (r) => ({
    id: Number(r.id),
    device_id: r.device_id,
    name: r.name,
    start_time: r.start_time.slice(0, 5),
    end_time: r.end_time.slice(0, 5),
    days: r.days,
    enabled: r.enabled,
  });

  async function handleGetSchedules(req, res) {
    const device = resolveDevice(req.query.device, res);
    if (!device) return;
    try {
      const { rows } = await pool.query(
        `SELECT ${SCHEDULE_COLS} FROM schedules WHERE device_id = $1 ORDER BY start_time, id`,
        [device]
      );
      return res.json({ device, schedules: rows.map(fmtSchedule) });
    } catch (e) {
      console.error('Gagal membaca jadwal:', e.message);
      return res.status(500).json({ error: 'gagal membaca database' });
    }
  }

  async function readConfigWithoutInsert(device) {
    const { rows } = await pool.query(
      `SELECT hum_on, hum_off, post_run_sec, max_pwm, smoke_on, smoke_off
       FROM device_config WHERE device_id = $1`,
      [device]
    );
    if (rows.length === 0) {
      return { ...defaultConfig };
    }
    return rows[0];
  }

  async function handleGetConfig(req, res) {
    const device = resolveDevice(req.query.device, res);
    if (!device) return;
    try {
      const config = await readConfigWithoutInsert(device);
      return res.json({ device, config, defaults: { ...defaultConfig } });
    } catch (e) {
      console.error('Gagal membaca pengaturan:', e.message);
      return res.status(500).json({ error: 'gagal membaca database' });
    }
  }

  async function handlePostFeedback(req, res) {
    const ip = req.ip || 'unknown';
    const ipWait = feedbackIpLimiter.retryAfterSec(ip);
    if (ipWait > 0) {
      return sendRateLimited(res, ipWait, 'terlalu banyak kiriman masukan, coba lagi nanti');
    }
    const standWait = feedbackStandLimiter.retryAfterSec('stand');
    if (standWait > 0) {
      return sendRateLimited(res, standWait, 'kuota masukan sedang penuh, coba lagi nanti');
    }

    if (!isPlainObject(req.body)) {
      return res.status(400).json({ error: 'permintaan harus berupa objek JSON' });
    }

    const device = resolveDevice(req.body.device, res);
    if (!device) return;

    let name = null;
    if (req.body.name !== undefined && req.body.name !== null) {
      if (typeof req.body.name !== 'string') {
        return res.status(400).json({ error: 'name harus berupa teks' });
      }
      const trimmedName = req.body.name.trim();
      if (trimmedName.length > 40) {
        return res.status(400).json({ error: 'name maksimal 40 karakter' });
      }
      name = trimmedName.length > 0 ? trimmedName : null;
    }

    const rating = req.body.rating;
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
      return res.status(400).json({ error: 'rating harus bilangan bulat 1 sampai 5' });
    }

    if (typeof req.body.comment !== 'string') {
      return res.status(400).json({ error: 'comment wajib diisi' });
    }
    const comment = req.body.comment.trim();
    if (comment.length < 1 || comment.length > 500) {
      return res.status(400).json({ error: 'comment harus 1 sampai 500 karakter' });
    }

    feedbackIpLimiter.record(ip);
    feedbackStandLimiter.record('stand');

    try {
      const { rows } = await pool.query(
        `INSERT INTO feedback (device_id, name, rating, comment)
         VALUES ($1, $2, $3, $4)
         RETURNING id, created_at`,
        [device, name, rating, comment]
      );
      return res.status(201).json({
        ok: true,
        id: Number(rows[0].id),
        created_at: rows[0].created_at,
      });
    } catch (e) {
      console.error('Gagal menyimpan masukan:', e.message);
      return res.status(500).json({ error: 'gagal menyimpan masukan' });
    }
  }

  // ===== Pendaftaran rute publik (hanya untuk profil bazar) =====
  if (isBazar) {
    app.get('/api/status', enforcePublicReadLimit, handleStatus);
    app.get('/api/history', enforcePublicReadLimit, handleHistory);
    app.get('/api/schedules', enforcePublicReadLimit, handleGetSchedules);
    app.get('/api/config', enforcePublicReadLimit, handleGetConfig);
    app.post('/api/feedback', handlePostFeedback);
  }

  // Semua rute /api lain (dan seluruh rute /api di profil real) wajib kunci Admin
  app.use('/api', requireAdmin);
  registerDemoRoutes(app, {
    pool, mqttClient, enabled: startup.demoEnabled, nowFn, resolveDevice,
    limiter: createWindowLimiter({ max: 6, windowMs: 60000, nowFn }),
  });

  app.get('/api/admin/verify', (req, res) => {
    res.json({ ok: true, role: 'admin' });
  });

  if (!isBazar) {
    app.get('/api/status', handleStatus);
    app.get('/api/history', handleHistory);
    app.get('/api/schedules', handleGetSchedules);
    app.get('/api/config', handleGetConfig);
    app.post('/api/feedback', handlePostFeedback);
  }

  function publishCommand(device, sub, payload, res) {
    if (!mqttClient.connected) {
      return res.status(503).json({ error: 'Backend belum terhubung ke broker' });
    }
    const topic = `bathfan/${device}/cmd/${sub}`;
    return mqttClient.publish(topic, JSON.stringify(payload), { qos: 1, retain: false }, (err) => {
      if (err) return res.status(500).json({ error: err.message });
      return res.json({ ok: true, topic, payload });
    });
  }

  app.post('/api/mode', (req, res) => {
    const body = isPlainObject(req.body) ? req.body : {};
    const device = resolveDevice(body.device, res);
    if (!device) return;
    const mode = body.mode;
    if (mode !== 'auto' && mode !== 'manual') {
      return res.status(400).json({ error: 'mode harus auto atau manual' });
    }
    return publishCommand(device, 'mode', { mode }, res);
  });

  app.post('/api/speed', (req, res) => {
    const body = isPlainObject(req.body) ? req.body : {};
    const device = resolveDevice(body.device, res);
    if (!device) return;
    const pwm = Number(body.pwm);
    if (!Number.isInteger(pwm) || pwm < 0 || pwm > 100) {
      return res.status(400).json({ error: 'pwm harus bilangan bulat 0 sampai 100' });
    }
    return publishCommand(device, 'speed', { pwm }, res);
  });

  app.post('/api/power', (req, res) => {
    const body = isPlainObject(req.body) ? req.body : {};
    const device = resolveDevice(body.device, res);
    if (!device) return;
    if (typeof body.on !== 'boolean') {
      return res.status(400).json({ error: 'on harus true atau false' });
    }
    return publishCommand(device, 'power', { on: body.on }, res);
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

  app.post('/api/schedules', async (req, res) => {
    const body = isPlainObject(req.body) ? req.body : {};
    const device = resolveDevice(body.device, res);
    if (!device) return;

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
      return res.status(201).json(fmtSchedule(rows[0]));
    } catch (e) {
      console.error('Gagal menambah jadwal:', e.message);
      return res.status(500).json({ error: 'gagal menyimpan jadwal' });
    }
  });

  app.put('/api/schedules/:id', async (req, res) => {
    if (!/^\d+$/.test(req.params.id)) {
      return res.status(400).json({ error: 'id tidak valid' });
    }
    const body = isPlainObject(req.body) ? req.body : {};
    const parsed = parseSchedule(body, true);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const keys = Object.keys(parsed.value);
    if (keys.length === 0) {
      return res.status(400).json({ error: 'tidak ada yang diubah' });
    }
    const sets = keys.map((k, i) => `${k} = $${i + 1}`);
    const vals = keys.map((k) => parsed.value[k]);
    const idPos = keys.length + 1;
    const allowPos = keys.length + 2;
    try {
      const { rows } = await pool.query(
        `UPDATE schedules SET ${sets.join(', ')}
         WHERE id = $${idPos} AND device_id = ANY($${allowPos}::text[])
         RETURNING ${SCHEDULE_COLS}`,
        [...vals, req.params.id, allowedDevices]
      );
      if (rows.length === 0) {
        return res.status(404).json({ error: 'jadwal tidak ditemukan' });
      }
      return res.json(fmtSchedule(rows[0]));
    } catch (e) {
      if (e.code === '23514') {
        return res.status(400).json({ error: 'jam mulai dan selesai tidak boleh sama' });
      }
      console.error('Gagal mengubah jadwal:', e.message);
      return res.status(500).json({ error: 'gagal menyimpan jadwal' });
    }
  });

  app.delete('/api/schedules/:id', async (req, res) => {
    if (!/^\d+$/.test(req.params.id)) {
      return res.status(400).json({ error: 'id tidak valid' });
    }
    try {
      const r = await pool.query(
        'DELETE FROM schedules WHERE id = $1 AND device_id = ANY($2::text[])',
        [req.params.id, allowedDevices]
      );
      if (r.rowCount === 0) {
        return res.status(404).json({ error: 'jadwal tidak ditemukan' });
      }
      return res.json({ ok: true });
    } catch (e) {
      console.error('Gagal menghapus jadwal:', e.message);
      return res.status(500).json({ error: 'gagal menghapus jadwal' });
    }
  });

  // ===== Pengaturan perangkat =====
  function checkConfig(c) {
    if (!Number.isFinite(c.hum_on) || !Number.isFinite(c.hum_off)) {
      return 'hum_on dan hum_off harus angka';
    }
    if (c.hum_off < 40) return 'hum_off minimal 40';
    if (c.hum_on > 85) return 'hum_on maksimal 85';
    if (c.hum_on - c.hum_off < 5) {
      return 'selisih hum_on dan hum_off minimal 5';
    }
    if (!Number.isInteger(c.post_run_sec) || c.post_run_sec < 0 || c.post_run_sec > 3600) {
      return 'post_run_sec harus bilangan bulat 0 sampai 3600';
    }
    if (!Number.isInteger(c.max_pwm) || c.max_pwm < 30 || c.max_pwm > 100) {
      return 'max_pwm harus bilangan bulat 30 sampai 100';
    }
    if (!Number.isInteger(c.smoke_on) || c.smoke_on < 100 || c.smoke_on > 1000) {
      return 'smoke_on harus bilangan bulat 100 sampai 1000';
    }
    if (!Number.isInteger(c.smoke_off) || c.smoke_off < 30) {
      return 'smoke_off harus bilangan bulat minimal 30';
    }
    if (c.smoke_on - c.smoke_off < 50) {
      return 'selisih smoke_on dan smoke_off minimal 50';
    }
    return null;
  }

  async function upsertConfig(device, c) {
    await pool.query(
      `INSERT INTO device_config (
         device_id, hum_on, hum_off, post_run_sec, max_pwm, smoke_on, smoke_off, updated_at
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, now())
       ON CONFLICT (device_id) DO UPDATE SET
         hum_on = EXCLUDED.hum_on,
         hum_off = EXCLUDED.hum_off,
         post_run_sec = EXCLUDED.post_run_sec,
         max_pwm = EXCLUDED.max_pwm,
         smoke_on = EXCLUDED.smoke_on,
         smoke_off = EXCLUDED.smoke_off,
         updated_at = now()`,
      [device, c.hum_on, c.hum_off, c.post_run_sec, c.max_pwm, c.smoke_on, c.smoke_off]
    );
  }

  function publishConfig(device, config) {
    if (!allowedSet.has(device) || !mqttClient.connected) return;
    mqttClient.publish(
      `bathfan/${device}/cmd/config`,
      JSON.stringify({
        hum_on: config.hum_on,
        hum_off: config.hum_off,
        post_run_sec: config.post_run_sec,
        max_pwm: config.max_pwm,
        smoke_on: config.smoke_on,
        smoke_off: config.smoke_off,
      }),
      { qos: 1, retain: true }
    );
  }

  async function syncAllConfigs() {
    try {
      const { rows } = await pool.query(
        `SELECT device_id, hum_on, hum_off, post_run_sec, max_pwm, smoke_on, smoke_off
         FROM device_config
         WHERE device_id = ANY($1::text[])`,
        [allowedDevices]
      );
      for (const r of rows) {
        publishConfig(r.device_id, r);
      }
    } catch (e) {
      console.error('Gagal mengirim konfigurasi:', e.message);
    }
  }

  mqttClient.on('connect', syncAllConfigs);
  if (mqttClient.connected) syncAllConfigs();

  app.put('/api/config', async (req, res) => {
    const body = isPlainObject(req.body) ? req.body : {};
    const device = resolveDevice(body.device, res);
    if (!device) return;

    const changes = {};
    for (const k of configKeys) {
      if (body[k] !== undefined) {
        if (typeof body[k] !== 'number' || !Number.isFinite(body[k])) {
          return res.status(400).json({ error: `${k} harus berupa angka` });
        }
        changes[k] = body[k];
      }
    }
    if (Object.keys(changes).length === 0) {
      return res.status(400).json({ error: 'tidak ada yang diubah' });
    }
    try {
      const existing = await readConfigWithoutInsert(device);
      const merged = { ...existing, ...changes };
      const err = checkConfig(merged);
      if (err) return res.status(400).json({ error: err });
      await upsertConfig(device, merged);
      publishConfig(device, merged);
      return res.json({ device, config: merged, defaults: { ...defaultConfig } });
    } catch (e) {
      console.error('Gagal menyimpan pengaturan:', e.message);
      return res.status(500).json({ error: 'gagal menyimpan pengaturan' });
    }
  });

  app.post('/api/config/reset', async (req, res) => {
    const body = isPlainObject(req.body) ? req.body : {};
    const device = resolveDevice(body.device, res);
    if (!device) return;

    const resetCfg = { ...defaultConfig };
    try {
      await upsertConfig(device, resetCfg);
      publishConfig(device, resetCfg);
      return res.json({ device, config: resetCfg, defaults: { ...defaultConfig } });
    } catch (e) {
      console.error('Gagal mereset pengaturan:', e.message);
      return res.status(500).json({ error: 'gagal mereset pengaturan' });
    }
  });

  app.cleanup = () => {
    clearInterval(pruneTimer);
    if (typeof mqttClient.off === 'function') {
      mqttClient.off('connect', syncAllConfigs);
    } else if (typeof mqttClient.removeListener === 'function') {
      mqttClient.removeListener('connect', syncAllConfigs);
    }
  };

  return app;
}

function startApi(mqttClient, { pool = defaultPool, env = process.env, host } = {}) {
  const port = getPort(env);
  const app = createApp(mqttClient, { pool, env });
  const server = app.listen(port, host, (error) => {
    if (error) throw error;
    console.log(`API berjalan di http://localhost:${port}`);
  });
  return server;
}

module.exports = { startApi, createApp };
