const Database = require('better-sqlite3');
const path = require('path');

const db = new Database(path.join(__dirname, 'bathfan.db'));

db.exec(`
  CREATE TABLE IF NOT EXISTS telemetry (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    humidity REAL,
    temperature REAL,
    fan_pwm INTEGER,
    mode TEXT,
    state TEXT,
    created_at TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_telemetry_device_time
    ON telemetry (device_id, created_at);
`);

module.exports = db;

if (require.main === module) {
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
    .all();
  console.log('Database siap. Tabel:', tables.map((t) => t.name).join(', '));
}