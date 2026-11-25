const test = require('node:test');
const assert = require('node:assert/strict');

const {
  DEVICE_RE,
  getAppProfile,
  getAllowedDevices,
  isAllowedDevice,
  getDefaultPostRunSec,
  getDefaultConfig,
  getPort,
  getTrustProxy,
  validateStartupEnv,
} = require('../config');
const { createPoolConfig, init: initDb } = require('../db');
const { createScheduler } = require('../scheduler');
const { handleTelemetryMessage } = require('../index');

const VALID_KEY = 'a'.repeat(24);

test('getDefaultPostRunSec memilih 300 untuk real, 60 untuk bazar, dan mendukung override 0..3600', () => {
  assert.equal(getAppProfile({}), 'real');
  assert.equal(getDefaultPostRunSec({}), 300);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'real' }), 300);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'bazar' }), 60);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'real', DEFAULT_POST_RUN_SEC: '120' }), 120);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'bazar', DEFAULT_POST_RUN_SEC: '0' }), 0);
  assert.equal(getDefaultPostRunSec({ APP_PROFILE: 'real', DEFAULT_POST_RUN_SEC: '3600' }), 3600);
  assert.throws(() => getDefaultPostRunSec({ APP_PROFILE: 'staging' }), /APP_PROFILE/);
  assert.throws(() => getDefaultPostRunSec({ DEFAULT_POST_RUN_SEC: '-1' }), /DEFAULT_POST_RUN_SEC/);
  assert.throws(() => getDefaultPostRunSec({ DEFAULT_POST_RUN_SEC: '3601' }), /DEFAULT_POST_RUN_SEC/);
  assert.throws(() => getDefaultPostRunSec({ DEFAULT_POST_RUN_SEC: '12.5' }), /DEFAULT_POST_RUN_SEC/);
});

test('isAllowedDevice dan validateStartupEnv memvalidasi allowlist, PORT, TRUST_PROXY, dan API_KEY', () => {
  const env = { ALLOWED_DEVICES: 'fan01, fan02, fan01' };
  assert.deepEqual(getAllowedDevices(env), ['fan01', 'fan02']);
  assert.equal(isAllowedDevice('fan01', env), true);
  assert.equal(isAllowedDevice('fan99', env), false);
  assert.equal(isAllowedDevice('../bad', env), false);
  assert.equal(DEVICE_RE.test('fan-01_a'), true);

  assert.throws(() => getAllowedDevices({ ALLOWED_DEVICES: '' }), /ALLOWED_DEVICES/);
  assert.throws(() => getAllowedDevices({ ALLOWED_DEVICES: 'fan01, ../x' }), /ALLOWED_DEVICES/);

  assert.equal(getPort({}), 3000);
  assert.equal(getPort({ PORT: '8080' }), 8080);
  assert.throws(() => getPort({ PORT: '0' }), /PORT/);
  assert.throws(() => getPort({ PORT: '70000' }), /PORT/);

  assert.equal(getTrustProxy({}), false);
  assert.equal(getTrustProxy({ TRUST_PROXY: '0' }), false);
  assert.equal(getTrustProxy({ TRUST_PROXY: 'loopback' }), 'loopback');
  assert.deepEqual(getTrustProxy({ TRUST_PROXY: '10.0.0.1, 10.0.0.2/24' }), ['10.0.0.1', '10.0.0.2/24']);
  assert.throws(() => getTrustProxy({ TRUST_PROXY: 'true' }), /TRUST_PROXY/);
  assert.throws(() => getTrustProxy({ TRUST_PROXY: '1' }), /TRUST_PROXY/);

  assert.throws(() => validateStartupEnv({ API_KEY: 'short' }), /API_KEY/);
  assert.doesNotThrow(() => validateStartupEnv({ API_KEY: VALID_KEY, APP_PROFILE: 'bazar' }));
});

test('createPoolConfig mewajibkan TLS terverifikasi untuk DATABASE_URL cloud dan menolak downgrade', () => {
  for (const bad of [
    'postgres://u:secretpass@db.example.com:5432/bathfan?sslmode=disable',
    'postgres://u:secretpass@db.example.com:5432/bathfan?sslmode=no-verify',
    'postgres://u:secretpass@db.example.com:5432/bathfan?sslmode=prefer',
    'postgres://u:secretpass@db.example.com:5432/bathfan?sslmode=verify-ca',
    'postgres://u:secretpass@db.example.com:5432/bathfan?sslmode=require&uselibpqcompat=true',
    'postgres://u:secretpass@db.example.com:5432/bathfan?ssl=false',
  ]) {
    assert.throws(
      () => createPoolConfig({ DATABASE_URL: bad }),
      (err) => {
        assert.ok(!err.message.includes('secretpass'), 'error tidak boleh membocorkan password');
        return true;
      }
    );
  }

  const ok = createPoolConfig({
    DATABASE_URL: 'postgres://u:secretpass@db.example.com:5432/bathfan?sslmode=verify-full',
  });
  assert.equal(ok.host, 'db.example.com');
  assert.equal(ok.ssl.rejectUnauthorized, true);

  const localCfg = createPoolConfig({ PGHOST: '127.0.0.1', PGDATABASE: 'bathfan' });
  assert.equal(localCfg.ssl, undefined);
});

test('initDb melakukan provisioning allowlist dengan post_run_sec profil dan membuat tabel feedback', async () => {
  const queries = [];
  const mockPool = {
    async query(sql, params = []) {
      queries.push({ sql, params });
      return { rows: [] };
    },
  };

  await initDb(mockPool, { APP_PROFILE: 'bazar', ALLOWED_DEVICES: 'fan02,fan03' });

  const feedbackCreate = queries.find((q) => /CREATE TABLE IF NOT EXISTS feedback/i.test(q.sql));
  assert.ok(feedbackCreate, 'harus membuat tabel feedback');

  const seedQueries = queries.filter((q) => /INSERT INTO device_config/i.test(q.sql));
  assert.equal(seedQueries.length, 2);
  assert.equal(seedQueries[0].params[0], 'fan02');
  assert.equal(seedQueries[0].params[3], 60);
  assert.match(seedQueries[0].sql, /ON CONFLICT \(device_id\) DO NOTHING/i);
  assert.equal(seedQueries[1].params[0], 'fan03');
  assert.equal(seedQueries[1].params[3], 60);
});

test('scheduler hanya memeriksa dan memublikasikan standby untuk perangkat dalam ALLOWED_DEVICES', async () => {
  const executed = [];
  const published = [];
  const mockPool = {
    async query(sql, params) {
      executed.push({ sql, params });
      return {
        rows: [
          {
            device_id: 'fan02',
            start_time: '00:00:00',
            end_time: '23:59:00',
            days: [1, 2, 3, 4, 5, 6, 7],
          },
        ],
      };
    },
  };
  const mockMqtt = {
    connected: true,
    publish(topic, msg, opts) {
      published.push({ topic, msg: JSON.parse(msg), opts });
    },
  };

  const sched = createScheduler(mockMqtt, {
    pool: mockPool,
    env: { ALLOWED_DEVICES: 'fan02' },
    autoStart: false,
  });

  await sched.tick(new Date('2026-11-25T12:00:00+07:00'));

  assert.equal(executed.length, 1);
  assert.match(executed[0].sql, /device_id = ANY\(\$1::text\[\]\)/);
  assert.deepEqual(executed[0].params, [['fan02']]);
  assert.equal(published.length, 1);
  assert.equal(published[0].topic, 'bathfan/fan02/cmd/standby');
  assert.equal(published[0].msg.active, true);
  assert.ok(!published.some((p) => p.topic.includes('fan01')));
});

test('handleTelemetryMessage memvalidasi allowlist, ukuran, rentang, dan menerima data lama tanpa MQ-2', async () => {
  const inserted = [];
  const mockPool = {
    async query(sql, params) {
      inserted.push(params);
      return { rows: [] };
    },
  };
  const env = { ALLOWED_DEVICES: 'fan01' };

  const invalidCases = [
    ['bathfan/fan99/telemetry', Buffer.from(JSON.stringify({ hum: 60, temp: 27, pwm: 0, mode: 'auto' }))],
    ['bathfan/fan01/telemetry', Buffer.alloc(5000, 'a')],
    ['bathfan/fan01/telemetry', Buffer.from('not-json')],
    ['bathfan/fan01/telemetry', Buffer.from('[1,2,3]')],
    ['bathfan/fan01/telemetry', Buffer.from(JSON.stringify({ hum: 105, temp: 27, pwm: 0, mode: 'auto' }))],
    ['bathfan/fan01/telemetry', Buffer.from(JSON.stringify({ hum: '60', temp: 27, pwm: 0, mode: 'auto' }))],
    ['bathfan/fan01/telemetry', Buffer.from(JSON.stringify({ hum: 60, temp: 27, pwm: 150, mode: 'auto' }))],
    ['bathfan/fan01/telemetry', Buffer.from(JSON.stringify({ hum: 60, temp: 27, pwm: 40, mode: 'turbo' }))],
  ];

  for (const [topic, payload] of invalidCases) {
    const ok = await handleTelemetryMessage(topic, payload, { pool: mockPool, env });
    assert.equal(ok, false);
  }
  assert.equal(inserted.length, 0);

  // Legacy telemetry tanpa field MQ-2
  const okLegacy = await handleTelemetryMessage(
    'bathfan/fan01/telemetry',
    Buffer.from(JSON.stringify({ hum: 68.5, temp: 28.2, pwm: 55, mode: 'auto', state: 'RUNNING', power: true })),
    { pool: mockPool, env }
  );
  assert.equal(okLegacy, true);
  assert.equal(inserted.length, 1);
  assert.equal(inserted[0][7], null);
  assert.equal(inserted[0][8], false);
  assert.equal(inserted[0][9], false);

  // Modern telemetry dengan delta negatif
  const okModern = await handleTelemetryMessage(
    'bathfan/fan01/telemetry',
    Buffer.from(
      JSON.stringify({
        hum: 58.0,
        temp: 27.0,
        pwm: 0,
        mode: 'auto',
        state: 'IDLE',
        power: true,
        smoke: -14,
        smoke_alert: false,
        smoke_ready: true,
      })
    ),
    { pool: mockPool, env }
  );
  assert.equal(okModern, true);
  assert.equal(inserted.length, 2);
  assert.equal(inserted[1][7], -14);
  assert.equal(inserted[1][8], false);
  assert.equal(inserted[1][9], true);
});

const http = require('node:http');
const { createApp } = require('../api');

async function withTestServer(app, fn) {
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  const baseUrl = `http://127.0.0.1:${addr.port}`;
  try {
    await fn(baseUrl);
  } finally {
    if (typeof app.cleanup === 'function') app.cleanup();
    await new Promise((resolve) => server.close(resolve));
  }
}

test('scheduler mengirim heartbeat hanya untuk perangkat allowlist setelah HEARTBEAT_MS', async () => {
  const published = [];
  const mockPool = {
    async query() {
      return { rows: [] };
    },
  };
  const mockMqtt = {
    connected: true,
    publish(topic, msg) {
      published.push({ topic, msg: JSON.parse(msg) });
    },
  };

  const sched = createScheduler(mockMqtt, {
    pool: mockPool,
    env: { ALLOWED_DEVICES: 'fan02' },
    autoStart: false,
  });

  const t0 = new Date('2026-11-25T12:00:00+07:00');
  await sched.tick(t0);
  await sched.tick(new Date(t0.getTime() + 60000));

  assert.equal(published.length, 2);
  assert.ok(published.every((p) => p.topic === 'bathfan/fan02/cmd/standby'));
});

test('profil real menolak seluruh request /api anonim dan tetap mengizinkan /health serta kunci valid', async () => {
  const queries = [];
  const mockPool = {
    async query(sql, params = []) {
      queries.push({ sql, params });
      if (/FROM telemetry/i.test(sql) && /LIMIT 1/i.test(sql)) {
        return {
          rows: [
            {
              humidity: 62.1,
              temperature: 27.5,
              fan_pwm: 35,
              mode: 'auto',
              state: 'RUNNING',
              power: true,
              smoke: null,
              smoke_alert: false,
              smoke_ready: false,
              created_at: new Date(),
            },
          ],
        };
      }
      return { rows: [] };
    },
  };
  const mockMqtt = { connected: true, on() {}, publish() {} };

  const app = createApp(mockMqtt, {
    pool: mockPool,
    env: { API_KEY: VALID_KEY, APP_PROFILE: 'real', ALLOWED_DEVICES: 'fan01' },
  });

  await withTestServer(app, async (base) => {
    const health = await fetch(`${base}/health`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { ok: true });

    for (const [method, path] of [
      ['GET', '/api/status'],
      ['GET', '/api/history'],
      ['GET', '/api/schedules'],
      ['GET', '/api/config'],
      ['GET', '/api/admin/verify'],
      ['POST', '/api/feedback'],
      ['POST', '/api/mode'],
    ]) {
      const r = await fetch(`${base}${path}`, { method });
      assert.equal(r.status, 401, `${method} ${path} harus ditolak tanpa kunci pada profil real`);
    }

    const okVerify = await fetch(`${base}/api/admin/verify`, {
      headers: { 'X-API-Key': VALID_KEY },
    });
    assert.equal(okVerify.status, 200);
    assert.deepEqual(await okVerify.json(), { ok: true, role: 'admin' });

    const okStatus = await fetch(`${base}/api/status`, {
      headers: { 'X-API-Key': VALID_KEY },
    });
    assert.equal(okStatus.status, 200);
    const body = await okStatus.json();
    assert.equal(body.latest.smoke, null);
  });
});

test('profil bazar mengizinkan Guest baca & feedback, menolak mutasi Guest, menjaga smoke null, dan GET config bebas INSERT', async () => {
  const queries = [];
  const published = [];
  const mockPool = {
    async query(sql, params = []) {
      queries.push({ sql, params });
      if (/FROM telemetry/i.test(sql) && /LIMIT 1/i.test(sql)) {
        return {
          rows: [
            {
              humidity: 55.0,
              temperature: 26.0,
              fan_pwm: 0,
              mode: 'auto',
              state: 'IDLE',
              power: true,
              smoke: null,
              smoke_alert: false,
              smoke_ready: false,
              created_at: new Date(),
            },
          ],
        };
      }
      if (/FROM device_config/i.test(sql) && /SELECT/i.test(sql)) {
        return { rows: [] };
      }
      if (/FROM schedules/i.test(sql)) {
        return { rows: [] };
      }
      return { rows: [] };
    },
  };
  const mockMqtt = {
    connected: true,
    on() {},
    publish(topic, payload, opts, cb) {
      published.push({ topic, payload });
      if (cb) cb(null);
    },
  };

  const app = createApp(mockMqtt, {
    pool: mockPool,
    env: { API_KEY: VALID_KEY, APP_PROFILE: 'bazar', ALLOWED_DEVICES: 'fan01' },
  });

  await withTestServer(app, async (base) => {
    const statusRes = await fetch(`${base}/api/status`);
    assert.equal(statusRes.status, 200);
    const statusJson = await statusRes.json();
    assert.equal(statusJson.latest.smoke, null);

    const cfgRes = await fetch(`${base}/api/config`);
    assert.equal(cfgRes.status, 200);
    const cfgJson = await cfgRes.json();
    assert.equal(cfgJson.config.post_run_sec, 60);
    assert.equal(cfgJson.defaults.post_run_sec, 60);
    assert.ok(!queries.some((q) => /INSERT INTO device_config/i.test(q.sql)), 'GET /api/config dilarang INSERT');

    assert.equal((await fetch(`${base}/api/schedules`)).status, 200);

    // Metode salah dan pembacaan feedback ditolak untuk Guest
    assert.equal((await fetch(`${base}/api/status`, { method: 'POST' })).status, 401);
    assert.equal((await fetch(`${base}/api/feedback`, { method: 'GET' })).status, 401);
    assert.equal(
      (await fetch(`${base}/api/feedback`, { headers: { 'X-API-Key': VALID_KEY } })).status,
      404
    );

    const beforeMutations = queries.length;
    for (const [method, path, payload] of [
      ['POST', '/api/mode', { mode: 'manual' }],
      ['POST', '/api/speed', { pwm: 80 }],
      ['POST', '/api/power', { on: false }],
      ['POST', '/api/schedules', { name: 'Malam', start_time: '22:00', end_time: '05:00', days: [1] }],
      ['PUT', '/api/schedules/1', { enabled: false }],
      ['DELETE', '/api/schedules/1', null],
      ['PUT', '/api/config', { max_pwm: 80 }],
      ['POST', '/api/config/reset', {}],
    ]) {
      const res = await fetch(`${base}${path}`, {
        method,
        headers: payload ? { 'Content-Type': 'application/json' } : {},
        body: payload ? JSON.stringify(payload) : undefined,
      });
      assert.equal(res.status, 401, `Guest ${method} ${path} harus ditolak 401`);
    }
    assert.equal(queries.length, beforeMutations, 'mutasi Guest tidak boleh menyentuh DB');
    assert.equal(published.length, 0, 'mutasi Guest tidak boleh memublikasikan MQTT');
  });
});

test('allowlist membatasi PUT/DELETE schedule dan syncAllConfigs hanya ke perangkat yang diizinkan', async () => {
  const queries = [];
  const published = [];
  const mockPool = {
    async query(sql, params = []) {
      queries.push({ sql, params });
      if (/SELECT device_id, hum_on/i.test(sql)) {
        return {
          rows: [
            { device_id: 'fan02', hum_on: 70, hum_off: 60, post_run_sec: 60, max_pwm: 100, smoke_on: 250, smoke_off: 100 },
          ],
        };
      }
      if (/UPDATE schedules/i.test(sql) || /DELETE FROM schedules/i.test(sql)) {
        // Simulasikan baris id=7 milik fan01 (bukan fan02), sehingga filter allowlist menghasilkan 0 baris
        return { rows: [], rowCount: 0 };
      }
      return { rows: [], rowCount: 0 };
    },
  };
  const mockMqtt = {
    connected: true,
    on() {},
    publish(topic, payload) {
      published.push({ topic, payload: JSON.parse(payload) });
    },
  };

  const app = createApp(mockMqtt, {
    pool: mockPool,
    env: { API_KEY: VALID_KEY, APP_PROFILE: 'bazar', ALLOWED_DEVICES: 'fan02' },
  });

  await withTestServer(app, async (base) => {
    const putRes = await fetch(`${base}/api/schedules/7`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': VALID_KEY },
      body: JSON.stringify({ enabled: false }),
    });
    assert.equal(putRes.status, 404);

    const delRes = await fetch(`${base}/api/schedules/7`, {
      method: 'DELETE',
      headers: { 'X-API-Key': VALID_KEY },
    });
    assert.equal(delRes.status, 404);

    const updateQ = queries.find((q) => /UPDATE schedules/i.test(q.sql));
    const deleteQ = queries.find((q) => /DELETE FROM schedules/i.test(q.sql));
    assert.match(updateQ.sql, /device_id = ANY\(\$\d+::text\[\]\)/);
    assert.deepEqual(updateQ.params.at(-1), ['fan02']);
    assert.match(deleteQ.sql, /device_id = ANY\(\$2::text\[\]\)/);
    assert.deepEqual(deleteQ.params[1], ['fan02']);

    const syncQ = queries.find((q) => /SELECT device_id, hum_on/i.test(q.sql));
    assert.match(syncQ.sql, /WHERE device_id = ANY\(\$1::text\[\]\)/);
    assert.equal(published.length, 1);
    assert.equal(published[0].topic, 'bathfan/fan02/cmd/config');
  });
});

test('GET /api/history berbagi satu query saat serentak, memfilter warm-up di agregat asap, dan tidak meng-cache input invalid', async () => {
  let historyCalls = 0;
  let capturedSql = '';
  const mockPool = {
    async query(sql) {
      if (/FROM telemetry/i.test(sql) && /GROUP BY 1/i.test(sql)) {
        historyCalls += 1;
        capturedSql = sql;
        await new Promise((r) => setTimeout(r, 40));
        return {
          rows: [
            {
              t: '2026-11-25T12:00:00.000Z',
              humidity: 65.2,
              temperature: 28.0,
              fan_pwm: 45,
              smoke: null,
              smoke_alert: false,
            },
          ],
        };
      }
      return { rows: [] };
    },
  };
  const mockMqtt = { connected: true, on() {}, publish() {} };

  const app = createApp(mockMqtt, {
    pool: mockPool,
    env: { API_KEY: VALID_KEY, APP_PROFILE: 'bazar', ALLOWED_DEVICES: 'fan01' },
  });

  await withTestServer(app, async (base) => {
    const [r1, r2] = await Promise.all([
      fetch(`${base}/api/history?range=1h`),
      fetch(`${base}/api/history?range=1h`),
    ]);
    assert.equal(r1.status, 200);
    assert.equal(r2.status, 200);
    assert.equal(historyCalls, 1, 'request serentak harus berbagi satu query');
    assert.match(capturedSql, /FILTER\s*\(\s*WHERE\s+smoke_ready\s+IS\s+TRUE\s*\)/i);
    assert.match(capturedSql, /BOOL_OR\s*\(/i);

    const j1 = await r1.json();
    assert.equal(j1.points[0].smoke, null);
    assert.equal(j1.points[0].humidity, 65.2);

    // Cache hit dalam <5s
    const r3 = await fetch(`${base}/api/history?range=1h`);
    assert.equal(r3.status, 200);
    assert.equal(historyCalls, 1);

    // Invalid range & device ditolak tanpa menambah query atau cache
    assert.equal((await fetch(`${base}/api/history?range=99d`)).status, 400);
    assert.equal((await fetch(`${base}/api/history?device=fan99`)).status, 403);
    assert.equal(historyCalls, 1);
  });
});

test('rate limiter auth, baca publik, feedback, dan trust proxy bekerja sesuai batas', async () => {
  let fakeNow = 1_700_000_000_000;
  const feedbackRows = [];
  const mockPool = {
    async query(sql, params = []) {
      if (/INSERT INTO feedback/i.test(sql)) {
        feedbackRows.push(params);
        return { rows: [{ id: feedbackRows.length, created_at: new Date(fakeNow) }] };
      }
      return { rows: [] };
    },
  };
  const mockMqtt = { connected: true, on() {}, publish() {} };

  const app = createApp(mockMqtt, {
    pool: mockPool,
    env: {
      API_KEY: VALID_KEY,
      APP_PROFILE: 'bazar',
      ALLOWED_DEVICES: 'fan01',
      PUBLIC_READ_LIMIT_PER_MIN: '3',
      FEEDBACK_HOURLY_LIMIT: '6',
    },
    nowFn: () => fakeNow,
  });

  await withTestServer(app, async (base) => {
    // 1. Guest valid reads tidak mengonsumsi kuota auth gagal, tetapi tunduk pada publicReadLimiter (limit 3)
    for (let i = 0; i < 3; i++) {
      assert.equal(
        (await fetch(`${base}/api/status`, { headers: { 'X-Forwarded-For': `1.2.3.${i}` } })).status,
        200
      );
    }
    const pub429 = await fetch(`${base}/api/status`, {
      headers: { 'X-Forwarded-For': '9.9.9.9' }, // harus diabaikan karena trust proxy mati!
    });
    assert.equal(pub429.status, 429);
    assert.ok(Number(pub429.headers.get('retry-after')) >= 1);

    // 2. 10 kegagalan auth across /api/admin/verify dan /api/mode -> ke-11 returns 429
    for (let i = 0; i < 10; i++) {
      const target = i % 2 === 0 ? '/api/admin/verify' : '/api/mode';
      const method = i % 2 === 0 ? 'GET' : 'POST';
      const r = await fetch(`${base}${target}`, {
        method,
        headers: { 'X-API-Key': 'wrong-key' },
      });
      assert.equal(r.status, 401);
    }
    const auth429 = await fetch(`${base}/api/admin/verify`, {
      headers: { 'X-API-Key': VALID_KEY }, // bahkan kunci benar tetap diblokir saat 429
    });
    assert.equal(auth429.status, 429);
    assert.ok(Number(auth429.headers.get('retry-after')) >= 1);

    // Setelah jendela 60 detik lewat, pulih
    fakeNow += 61000;
    const recovered = await fetch(`${base}/api/admin/verify`, {
      headers: { 'X-API-Key': VALID_KEY },
    });
    assert.equal(recovered.status, 200);

    // 3. Feedback validasi & kuota 5/10menit/IP
    assert.equal(
      (
        await fetch(`${base}/api/feedback`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ rating: 6, comment: 'ok' }),
        })
      ).status,
      400
    );
    assert.equal(
      (
        await fetch(`${base}/api/feedback`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ rating: 5, comment: '   ' }),
        })
      ).status,
      400
    );

    for (let i = 0; i < 5; i++) {
      const fbRes = await fetch(`${base}/api/feedback`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: 'Budi', rating: 5, comment: `Keren ${i}` }),
      });
      assert.equal(fbRes.status, 201);
      const fbJson = await fbRes.json();
      assert.equal(fbJson.ok, true);
      assert.equal(fbJson.name, undefined, 'respons tidak boleh menggemakan nama');
      assert.equal(fbJson.comment, undefined, 'respons tidak boleh menggemakan komentar');
    }

    const fb429 = await fetch(`${base}/api/feedback`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rating: 4, comment: 'keenam' }),
    });
    assert.equal(fb429.status, 429);
    assert.ok(Number(fb429.headers.get('retry-after')) >= 1);
  });
});

test('POST /api/feedback menolak payload > 16 KiB dan history cache pulih sesudah query gagal', async () => {
  let shouldFail = true;
  let calls = 0;
  const mockPool = {
    async query(sql) {
      if (/FROM telemetry/i.test(sql) && /GROUP BY 1/i.test(sql)) {
        calls += 1;
        if (shouldFail) throw new Error('db timeout');
        return { rows: [] };
      }
      return { rows: [] };
    },
  };
  const mockMqtt = { connected: true, on() {}, publish() {} };
  const app = createApp(mockMqtt, {
    pool: mockPool,
    env: { API_KEY: VALID_KEY, APP_PROFILE: 'bazar', ALLOWED_DEVICES: 'fan01' },
  });

  await withTestServer(app, async (base) => {
    const big = await fetch(`${base}/api/feedback`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rating: 5, comment: 'x'.repeat(20000) }),
    });
    assert.equal(big.status, 413);

    assert.equal((await fetch(`${base}/api/history?range=24h`)).status, 500);
    shouldFail = false;
    assert.equal((await fetch(`${base}/api/history?range=24h`)).status, 200);
    assert.equal(calls, 2);
  });
});
