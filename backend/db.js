require('dotenv').config();
const fs = require('node:fs');
const { Pool } = require('pg');
const { getAllowedDevices, getDefaultConfig } = require('./config');

const DOWNGRADED_SSL_MODES = new Set(['disable', 'allow', 'prefer', 'no-verify', 'verify-ca']);

function isLocalHost(hostname) {
  const h = String(hostname || '').toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}

function readCaCert(env) {
  if (env.DATABASE_CA_CERT && String(env.DATABASE_CA_CERT).trim() !== '') {
    return String(env.DATABASE_CA_CERT).replace(/\\n/g, '\n');
  }
  const filePath = env.DATABASE_CA_FILE || env.PGSSLROOTCERT;
  if (filePath && String(filePath).trim() !== '') {
    return fs.readFileSync(String(filePath).trim(), 'utf8');
  }
  return null;
}

function createPoolConfig(env = process.env) {
  const ca = readCaCert(env);
  const rawUrl = env.DATABASE_URL;

  if (rawUrl && String(rawUrl).trim() !== '') {
    let parsed;
    try {
      parsed = new URL(String(rawUrl).trim());
    } catch (_) {
      throw new Error('DATABASE_URL tidak valid');
    }

    if (parsed.protocol !== 'postgres:' && parsed.protocol !== 'postgresql:') {
      throw new Error('DATABASE_URL harus menggunakan skema postgres:// atau postgresql://');
    }

    const host = parsed.hostname.replace(/^\[(.+)\]$/, '$1');
    if (!host) {
      throw new Error('DATABASE_URL harus menyertakan host');
    }

    const local = isLocalHost(host);
    const sslMode = (parsed.searchParams.get('sslmode') || '').toLowerCase();
    const sslParam = (parsed.searchParams.get('ssl') || '').toLowerCase();
    const compatParam = parsed.searchParams.get('uselibpqcompat');

    if (!local) {
      if (compatParam !== null) {
        throw new Error('DATABASE_URL cloud menolak uselibpqcompat');
      }
      if (sslParam === 'false' || sslParam === '0') {
        throw new Error('DATABASE_URL cloud tidak boleh menonaktifkan SSL');
      }
      if (sslMode && DOWNGRADED_SSL_MODES.has(sslMode)) {
        throw new Error(`DATABASE_URL cloud menolak sslmode=${sslMode}; gunakan verify-full`);
      }
    }

    const config = {
      host,
      port: parsed.port ? Number(parsed.port) : 5432,
      database: parsed.pathname ? decodeURIComponent(parsed.pathname.slice(1)) : undefined,
      user: parsed.username ? decodeURIComponent(parsed.username) : undefined,
      password: parsed.password ? decodeURIComponent(parsed.password) : undefined,
    };

    if (!local || (sslMode && sslMode !== 'disable') || ca) {
      config.ssl = {
        rejectUnauthorized: true,
        ...(ca ? { ca } : {}),
      };
    }

    return config;
  }

  // Fallback konfigurasi PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD standar dari .env
  const localConfig = {};
  if (ca) {
    localConfig.ssl = { rejectUnauthorized: true, ca };
  }
  return localConfig;
}

const pool = new Pool(createPoolConfig(process.env));

async function init(targetPool = pool, env = process.env) {
  await targetPool.query(`
    CREATE TABLE IF NOT EXISTS telemetry (
      id BIGSERIAL PRIMARY KEY,
      device_id TEXT NOT NULL,
      humidity DOUBLE PRECISION,
      temperature DOUBLE PRECISION,
      fan_pwm INTEGER,
      mode TEXT,
      state TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  await targetPool.query(`
    CREATE INDEX IF NOT EXISTS idx_telemetry_device_time
      ON telemetry (device_id, created_at)
  `);

  await targetPool.query(
    'ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS power BOOLEAN'
  );
  await targetPool.query(
    'ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS smoke INTEGER'
  );
  await targetPool.query(
    'ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS smoke_alert BOOLEAN'
  );
  await targetPool.query(
    'ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS smoke_ready BOOLEAN'
  );

  await targetPool.query(`
    CREATE TABLE IF NOT EXISTS schedules (
      id BIGSERIAL PRIMARY KEY,
      device_id TEXT NOT NULL,
      name TEXT NOT NULL,
      start_time TIME NOT NULL,
      end_time TIME NOT NULL,
      days INTEGER[] NOT NULL,
      enabled BOOLEAN NOT NULL DEFAULT true,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      CHECK (start_time <> end_time),
      CHECK (cardinality(days) > 0)
    )
  `);

  await targetPool.query(`
    CREATE TABLE IF NOT EXISTS device_config (
      device_id TEXT PRIMARY KEY,
      hum_on DOUBLE PRECISION NOT NULL DEFAULT 70,
      hum_off DOUBLE PRECISION NOT NULL DEFAULT 60,
      post_run_sec INTEGER NOT NULL DEFAULT 300,
      max_pwm INTEGER NOT NULL DEFAULT 100,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      CHECK (hum_off >= 40 AND hum_on <= 85 AND hum_on - hum_off >= 5),
      CHECK (post_run_sec BETWEEN 0 AND 3600),
      CHECK (max_pwm BETWEEN 30 AND 100)
    )
  `);
  await targetPool.query(
    'ALTER TABLE device_config ADD COLUMN IF NOT EXISTS smoke_on INTEGER NOT NULL DEFAULT 250'
  );
  await targetPool.query(
    'ALTER TABLE device_config ADD COLUMN IF NOT EXISTS smoke_off INTEGER NOT NULL DEFAULT 100'
  );

  const def = getDefaultConfig(env);
  for (const deviceId of getAllowedDevices(env)) {
    await targetPool.query(
      `INSERT INTO device_config (device_id, hum_on, hum_off, post_run_sec, max_pwm, smoke_on, smoke_off)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (device_id) DO NOTHING`,
      [
        deviceId,
        def.hum_on,
        def.hum_off,
        def.post_run_sec,
        def.max_pwm,
        def.smoke_on,
        def.smoke_off,
      ]
    );
  }

  await targetPool.query(`
    CREATE TABLE IF NOT EXISTS feedback (
      id BIGSERIAL PRIMARY KEY,
      device_id TEXT NOT NULL,
      name TEXT,
      rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
      comment TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);
  await targetPool.query(`
    CREATE INDEX IF NOT EXISTS idx_feedback_created_at
      ON feedback (created_at)
  `);
}

async function cleanupOldFeedback(targetPool = pool, retentionDays = 30) {
  const days = Math.max(1, Math.min(365, Math.trunc(retentionDays)));
  await targetPool.query(
    `DELETE FROM feedback WHERE created_at < now() - ($1::int * INTERVAL '1 day')`,
    [days]
  );
}

module.exports = { pool, init, createPoolConfig, cleanupOldFeedback };

if (require.main === module) {
  (async () => {
    try {
      await init();
      const r = await pool.query(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
      );
      console.log('Database siap. Tabel:', r.rows.map((x) => x.table_name).join(', '));
    } catch (e) {
      console.error('Gagal:', e.message);
    } finally {
      await pool.end();
    }
  })();
}
