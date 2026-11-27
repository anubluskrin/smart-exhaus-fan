const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../api');

test('only Admin can queue a validated preset against fresh firmware metadata', async (t) => {
  const key = 'test-key-with-enough-characters';
  const run_id = '00000000-0000-4000-8000-000000000001';
  const now = Date.now();
  const published = [];
  const row = {
    demo_meta: { v: 1, generation: 7, phase: 'idle' },
    created_at: new Date(now), smoke_ready: true, sensor_ok: true,
  };
  const pool = { query: async () => ({ rows: [row] }) };
  const mqtt = { connected: true, on() {}, publish(topic, body, opts, cb) {
    if (!topic.endsWith('/cmd/demo')) return;
    published.push([topic, JSON.parse(body), opts]);
    cb();
  } };
  const app = createApp(mqtt, { pool, nowFn: () => now, env: {
    APP_PROFILE: 'bazar', DEMO_SCENARIOS_ENABLED: 'true', API_KEY: key,
  } });
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  const start = { device: 'fan01', run_id, kind: 'shower', speed: 10, minutes: 10 };
  const post = (body, admin, path = 'start') => fetch(`${base}/api/demo/${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(admin ? { 'X-API-Key': key } : {}) },
    body: JSON.stringify(body),
  });
  assert.equal((await post(start, false)).status, 401);
  assert.equal((await post({ ...start, pwm: 100 }, true)).status, 400);
  assert.equal((await post({ ...start, device: 'fan99' }, true)).status, 403);
  row.created_at = new Date(now - 20000);
  assert.equal((await post(start, true)).status, 503);
  row.created_at = new Date(now);
  assert.equal(published.length, 0);
  const response = await post(start, true);
  assert.equal(response.status, 202);
  assert.deepEqual(await response.json(), { run_id, status: 'pending' });
  const [topic, command, options] = published[0];
  assert.equal(topic, 'bathfan/fan01/cmd/demo');
  assert.equal(command.generation, 7);
  assert.equal(command.expires_at, Math.floor(now / 1000) + 10);
  assert.deepEqual(options, { qos: 1, retain: false });
  for (let i = 1; i < 6; i++) assert.equal((await post(start, true)).status, 202);
  assert.equal((await post(start, true)).status, 429);
  row.demo_meta = { phase: 'shower', generation: 8, run_id };
  assert.equal((await post({ device: 'fan01', run_id }, true, 'stop')).status, 202);
  assert.equal(published.at(-1)[1].op, 'stop');
});

test('feature cannot be enabled on real deployment', () => {
  const env = { API_KEY: 'isolated-test-key-123456789', DEMO_SCENARIOS_ENABLED: 'true' };
  assert.throws(() => createApp({}, { env }), /profil bazar/);
});
