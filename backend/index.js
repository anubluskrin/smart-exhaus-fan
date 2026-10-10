require('dotenv').config();
const mqtt = require('mqtt');

const client = mqtt.connect(
  `mqtts://${process.env.MQTT_HOST}:${process.env.MQTT_PORT}`,
  {
    username: process.env.MQTT_USER,
    password: process.env.MQTT_PASS,
    clientId: 'backend-bathfan-' + Math.random().toString(16).slice(2, 8),
  }
);

client.on('connect', () => {
  console.log('Backend terhubung ke broker');
  client.subscribe('bathfan/+/telemetry', (err) => {
    if (err) console.error('Gagal berlangganan:', err.message);
    else console.log('Berlangganan: bathfan/+/telemetry');
  });
});

client.on('message', (topic, payload) => {
  console.log(topic, '=>', payload.toString());
});

client.on('error', (err) => {
  console.error('Error MQTT:', err.message);
});