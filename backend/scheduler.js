const { pool } = require('./db');

const TICK_MS = 30000;
const HEARTBEAT_MS = 55000;
const TZ = 'Asia/Jakarta';

const WEEKDAYS = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
const fmt = new Intl.DateTimeFormat('en-US', {
  timeZone: TZ,
  weekday: 'short',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

function nowInJakarta(date = new Date()) {
  const parts = {};
  for (const p of fmt.formatToParts(date)) parts[p.type] = p.value;
  return {
    dow: WEEKDAYS[parts.weekday],
    minutes: (Number(parts.hour) % 24) * 60 + Number(parts.minute),
  };
}

function toMinutes(t) {
  const [h, m] = t.split(':').map(Number);
  return h * 60 + m;
}

function isActive(s, now) {
  const start = toMinutes(s.start_time);
  const end = toMinutes(s.end_time);
  const yesterday = now.dow === 1 ? 7 : now.dow - 1;
  if (start < end) {
    return s.days.includes(now.dow) && now.minutes >= start && now.minutes < end;
  }
  // melewati tengah malam
  return (
    (s.days.includes(now.dow) && now.minutes >= start) ||
    (s.days.includes(yesterday) && now.minutes < end)
  );
}

function startScheduler(client) {
  const last = new Map(); // device -> { active, at }

  async function tick() {
    if (!client.connected) return;
    try {
      const { rows } = await pool.query(`
        SELECT device_id, start_time::text AS start_time,
               end_time::text AS end_time, days
        FROM schedules
        WHERE enabled = true
      `);
      const byDevice = new Map([['fan01', []]]);
      for (const d of last.keys()) {
        if (!byDevice.has(d)) byDevice.set(d, []);
      }
      for (const r of rows) {
        if (!byDevice.has(r.device_id)) byDevice.set(r.device_id, []);
        byDevice.get(r.device_id).push(r);
      }

      const now = nowInJakarta();
      const t = Date.now();
      for (const [device, list] of byDevice) {
        const active = list.some((s) => isActive(s, now));
        const prev = last.get(device);
        const changed = !prev || prev.active !== active;
        if (changed || t - prev.at >= HEARTBEAT_MS) {
          client.publish(
            `bathfan/${device}/cmd/standby`,
            JSON.stringify({ active }),
            { qos: 1 }
          );
          if (changed) {
            console.log(`Standby [${device}] ${active ? 'AKTIF' : 'tidak aktif'}`);
          }
          last.set(device, { active, at: t });
        }
      }
    } catch (e) {
      console.error('Gagal memeriksa jadwal:', e.message);
    }
  }

  tick();
  setInterval(tick, TICK_MS);
}

module.exports = { startScheduler };