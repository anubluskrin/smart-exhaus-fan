const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const ENDS = ['completed', 'stopped', 'timeout', 'disconnected', 'physical_alarm', 'sensor_fault'];
const isRunId = (value) => typeof value === 'string' && UUID.test(value);

function demoPreset(body) {
  if (![1, 10].includes(body.speed)) return null;
  const { kind, speed, minutes, people, intensity, pattern } = body;
  if (kind === 'shower' && [5, 10, 20].includes(minutes)) return { kind, speed, minutes };
  if (kind === 'smoke' && [1, 2, 3].includes(people) &&
      ['thin', 'medium', 'thick'].includes(intensity) && ['together', 'staggered'].includes(pattern)) {
    return { kind, speed, people, intensity, pattern };
  }
  return null;
}

function parseDemoTelemetry(raw) {
  if (raw === undefined) return { source: 'physical', runId: null, meta: null };
  if (!raw || raw.v !== 1 || !Number.isInteger(raw.generation) ||
      raw.generation < 0 || raw.generation > 0xffffffff) return null;
  const { generation, phase, run_id, end_reason, elapsed_s } = raw;
  const meta = { v: 1, generation, phase };
  if (phase === 'idle') {
    if (run_id !== undefined || end_reason !== undefined) {
      if (!isRunId(run_id) || !ENDS.includes(end_reason)) return null;
      Object.assign(meta, { run_id, end_reason });
    }
    return { source: 'physical', runId: null, meta };
  }
  const preset = demoPreset(raw);
  if (!preset || !isRunId(run_id) || !Number.isInteger(elapsed_s) ||
      elapsed_s < 0 || elapsed_s >= 1800 || end_reason !== undefined ||
      !(preset.kind === 'shower' ? ['shower', 'recovery', 'settling'] : ['smoking', 'settling']).includes(phase)) {
    return null;
  }
  if (raw.config_version !== undefined) {
    if (!Number.isInteger(raw.config_version) || raw.config_version < 0 || raw.config_version > 0xffffffff ||
        !Number.isFinite(raw.hum_on) || raw.hum_on < 45 || raw.hum_on > 85 ||
        !Number.isInteger(raw.smoke_on) || raw.smoke_on < 100 || raw.smoke_on > 1000) return null;
    Object.assign(meta, { config_version: raw.config_version, hum_on: raw.hum_on, smoke_on: raw.smoke_on });
  }
  return { source: 'demo', runId: run_id, meta: { ...meta, ...preset, run_id, elapsed_s } };
}

module.exports = { parseDemoTelemetry, demoPreset, isRunId };
