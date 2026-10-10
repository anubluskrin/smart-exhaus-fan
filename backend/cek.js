const db = require('./db');

const total = db.prepare('SELECT COUNT(*) AS jumlah FROM telemetry').get();
console.log('Jumlah baris di database:', total.jumlah);

const terakhir = db
  .prepare('SELECT * FROM telemetry ORDER BY id DESC LIMIT 5')
  .all();
console.log('5 baris terakhir:');
console.table(terakhir);