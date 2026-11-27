const test = require('node:test');
const assert = require('node:assert/strict');
const { parseDemoTelemetry } = require('../demo_telemetry');
const { handleTelemetryMessage } = require('../index');

const id = '00000000-0000-4000-8000-000000000001';
test('run source follows phase, not presence of an ID', () => {
  assert.equal(parseDemoTelemetry(undefined).source, 'physical');
  const idle = parseDemoTelemetry({ v: 1, generation: 1, phase: 'idle', run_id: id, end_reason: 'sensor_fault' });
  assert.equal(idle.source, 'physical');
  assert.equal(idle.runId, null);
  assert.equal(parseDemoTelemetry({ ...idle.meta, kind: 'shower', elapsed_s: 12 }), null);
  const finished = parseDemoTelemetry({ ...idle.meta, end_reason: 'completed', final_idle: true });
  assert.equal(finished.source, 'physical');
  assert.equal(finished.meta.final_idle, true);
  const active = parseDemoTelemetry({ v: 1, generation: 2, phase: 'smoking', run_id: id,
    kind: 'smoke', people: 2, intensity: 'medium', pattern: 'staggered', speed: 10, elapsed_s: 3 });
  assert.equal(active.source, 'demo');
  assert.equal(active.runId, id);
  assert.equal(parseDemoTelemetry({ ...active.meta, v: 2 }), null);
  assert.equal(parseDemoTelemetry({ ...active.meta, phase: 'shower' }), null);
});

test('contradictory idle metadata never reaches telemetry insert', async () => {
  let writes = 0;
  const pool = { query: async () => { writes++; } };
  assert.equal(await handleTelemetryMessage('bathfan/fan01/telemetry', JSON.stringify({
    hum: 85, temp: 26, demo: { v: 1, generation: 1, phase: 'idle', kind: 'shower', elapsed_s: 3 },
  }), { pool, env: {} }), false);
  assert.equal(writes, 0);
});
