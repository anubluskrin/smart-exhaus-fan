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