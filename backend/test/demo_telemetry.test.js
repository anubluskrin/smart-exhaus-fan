const test = require('node:test');
const assert = require('node:assert/strict');
const { parseDemoTelemetry } = require('../demo_telemetry');

const id = '00000000-0000-4000-8000-000000000001';
test('run source follows phase, not presence of an ID', () => {
  assert.equal(parseDemoTelemetry(undefined).source, 'physical');
  const idle = parseDemoTelemetry({ v: 1, generation: 1, phase: 'idle', run_id: id, end_reason: 'sensor_fault' });
  assert.equal(idle.source, 'physical');
  assert.equal(idle.runId, null);
  const active = parseDemoTelemetry({ v: 1, generation: 2, phase: 'smoking', run_id: id,
    kind: 'smoke', people: 2, intensity: 'medium', pattern: 'staggered', speed: 10, elapsed_s: 3 });
  assert.equal(active.source, 'demo');
  assert.equal(active.runId, id);
  assert.equal(parseDemoTelemetry({ ...active.meta, v: 2 }), null);
  assert.equal(parseDemoTelemetry({ ...active.meta, phase: 'shower' }), null);
});
