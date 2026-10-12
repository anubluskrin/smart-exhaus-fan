const { pool } = require('./db');

(async () => {
  try {
    const total = await pool.query(
      'SELECT COUNT(*)::int AS jumlah FROM telemetry'
    );
    console.log('Jumlah baris di database:', total.rows[0].jumlah);

    const terakhir = await pool.query(`
      SELECT id, device_id, humidity, temperature, fan_pwm, mode, state, created_at
      FROM telemetry
      ORDER BY id DESC
      LIMIT 5
    `);
    console.log('5 baris terakhir:');
    console.table(terakhir.rows);
  } catch (e) {
    console.error('Gagal:', e.message);
  } finally {
    await pool.end();
  }
})();