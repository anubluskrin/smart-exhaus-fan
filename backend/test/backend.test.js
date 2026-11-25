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
