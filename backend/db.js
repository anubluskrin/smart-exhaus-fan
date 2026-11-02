require('dotenv').config();
const { Pool } = require('pg');

// Pool membaca PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD dari .env
const pool = new Pool();

async function init() {
  await pool.query(`
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
  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_telemetry_device_time
      ON telemetry (device_id, created_at)
  `);

    await pool.query(
    'ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS power BOOLEAN'
  );

    await pool.query(`
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

    await pool.query(`
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
  await pool.query(
    "INSERT INTO device_config (device_id) VALUES ('fan01') ON CONFLICT DO NOTHING"
  );
}

module.exports = { pool, init };

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