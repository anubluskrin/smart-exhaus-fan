const { demoPreset, isRunId } = require('./demo_telemetry');

function registerDemoRoutes(app, { pool, mqttClient, enabled, nowFn, resolveDevice, limiter }) {
  if (!enabled) return;
  for (const op of ['start', 'stop']) {
    app.post(`/api/demo/${op}`, async (req, res) => {
      const body = req.body;
      const preset = op === 'start' && body ? demoPreset(body) : null;
      const fields = ['device', 'run_id', ...Object.keys(preset ?? {})];
      if (!body || Array.isArray(body) || typeof body !== 'object' ||
          Object.keys(body).length !== fields.length || !fields.every((key) => Object.hasOwn(body, key)) ||
          typeof body.device !== 'string' || !body.device || !isRunId(body.run_id) ||
          (op === 'start' && !preset)) return res.status(400).json({ error: 'skenario tidak valid' });
      const device = resolveDevice(body.device, res);
      if (!device) return;
      if (!mqttClient.connected) return res.status(503).json({ error: 'broker belum terhubung' });
      try {
        const { rows: [row] } = await pool.query(
          `SELECT demo_meta, created_at, sensor_ok, smoke_ready, smoke_alert
             FROM telemetry WHERE device_id = $1 ORDER BY id DESC LIMIT 1`, [device]);
        const now = nowFn();
        if (!row || now - new Date(row.created_at).getTime() >= 20000) {
          return res.status(503).json({ error: 'perangkat offline' });
        }
        const info = row.demo_meta;
        if (!info || !Number.isInteger(info.generation)) {
          return res.status(409).json({ error: 'firmware demo tidak tersedia' });
        }
        if (op === 'start') {
          if (info.phase !== 'idle' || info.run_id === body.run_id ||
              row.sensor_ok !== true || row.smoke_ready !== true || row.smoke_alert === true) {
            return res.status(409).json({ error: 'perangkat belum siap menjalankan skenario' });
          }
          const retry = limiter.retryAfterSec(device);
          if (retry > 0) {
            return res.set('Retry-After', String(retry)).status(429).json({ error: 'terlalu banyak percobaan skenario' });
          }
          limiter.record(device);
        } else if (info.phase === 'idle' || info.run_id !== body.run_id) {
          return res.status(409).json({ error: 'skenario ini tidak aktif' });
        }
        if (!mqttClient.connected) return res.status(503).json({ error: 'broker belum terhubung' });
        const payload = { op, run_id: body.run_id, generation: info.generation,
          expires_at: Math.floor(now / 1000) + 10, ...preset };
        mqttClient.publish(`bathfan/${device}/cmd/demo`, JSON.stringify(payload),
          { qos: 1, retain: false }, (error) => {
            if (error) return res.status(503).json({ error: 'perintah demo belum diterima broker' });
            return res.status(202).json({ run_id: body.run_id, status: 'pending' });
          });
      } catch (_) {
        return res.status(503).json({ error: 'status perangkat tidak tersedia' });
      }
    });
  }
}

module.exports = { registerDemoRoutes };
