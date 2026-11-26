const { randomBytes } = require('node:crypto');
const test = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const { init } = require('../db');
const { handleTelemetryMessage } = require('../index');
const { createApp } = require('../api');

const url = process.env.BATHFAN_TEST_DATABASE_URL;
test('PostgreSQL buckets and concurrent history isolate physical and two demo runs',
  { skip: !url && 'set BATHFAN_TEST_DATABASE_URL to an expendable test database' }, async (t) => {
    const schema = 'demo_test_' + randomBytes(8).toString('hex');
    const admin = new Pool({ connectionString: url });
    const pool = new Pool({ connectionString: url, options: `-c search_path=${schema}` });
    await admin.query(`CREATE SCHEMA ${schema}`);
    t.after(async () => {
      await pool.end();
      await admin.query(`DROP SCHEMA ${schema} CASCADE`);
      await admin.end();
    });
    const env = { APP_PROFILE: 'bazar', DEMO_SCENARIOS_ENABLED: 'true',
      API_KEY: 'isolated-test-key-123456789' };
    await init(pool, env);
    const ids = ['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002'];
    const ingest = (hum, demo) => handleTelemetryMessage('bathfan/fan01/telemetry',
      JSON.stringify({ hum, temp: 26, demo }), { pool, env });
    assert.equal(await ingest(55), true);
    for (const [i, id] of ids.entries()) {
      assert.equal(await ingest(i === 0 ? 85 : 65, {
        v: 1, generation: i + 1, run_id: id, kind: 'shower',
        phase: 'shower', minutes: 10, speed: 10, elapsed_s: 8,
      }), true);
    }
    await pool.query('UPDATE telemetry SET created_at = date_trunc(\'minute\', now())');
    const app = createApp({ on() {}, connected: false }, { pool, env });
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    try {
      const base = `http://127.0.0.1:${server.address().port}/api`;
      const paths = ['', ...ids.map((id) => `?source=demo&run_id=${id}`), ''];
      const history = await Promise.all(paths.map(async (path) => {
        const response = await fetch(`${base}/history${path}`);
        assert.equal(response.status, 200);
        return (await response.json()).points.map((point) => point.humidity);
      }));
      assert.deepEqual(history, [[55], [85], [65], [55]]);
      const status = await (await fetch(`${base}/status`)).json();
      assert.equal(status.latest.source, 'demo');
      assert.equal(status.latest.demo.run_id, ids[1]);
      assert.equal(Object.hasOwn(status.latest.demo, 'generation'), false);
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });
