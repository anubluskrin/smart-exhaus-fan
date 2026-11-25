const net = require('node:net');

const DEVICE_RE = /^[A-Za-z0-9_-]{1,32}$/;
const VALID_PROFILES = new Set(['real', 'bazar']);
const BUILTIN_TRUST_PROXIES = new Set(['loopback', 'linklocal', 'uniquelocal']);

function getAppProfile(env = process.env) {
  const raw = env.APP_PROFILE;
  if (raw === undefined || String(raw).trim() === '') return 'real';
  const profile = String(raw).trim().toLowerCase();
  if (!VALID_PROFILES.has(profile)) {
    throw new Error(`APP_PROFILE tidak valid: "${raw}" (harus "real" atau "bazar")`);
  }
  return profile;
}

function getDefaultPostRunSec(env = process.env) {
  const profile = getAppProfile(env);
  const raw = env.DEFAULT_POST_RUN_SEC;
  if (raw !== undefined && String(raw).trim() !== '') {
    const s = String(raw).trim();
    if (!/^\d+$/.test(s)) {
      throw new Error(`DEFAULT_POST_RUN_SEC tidak valid: "${raw}" (harus bilangan bulat 0..3600)`);
    }
    const n = Number(s);
    if (!Number.isInteger(n) || n < 0 || n > 3600) {
      throw new Error(`DEFAULT_POST_RUN_SEC di luar rentang 0..3600: ${n}`);
    }
    return n;
  }
  return profile === 'bazar' ? 60 : 300;
}

function getAllowedDevices(env = process.env) {
  if (env.ALLOWED_DEVICES === undefined) {
    return ['fan01'];
  }
  const raw = String(env.ALLOWED_DEVICES);
  const parts = raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);

  if (parts.length === 0) {
    throw new Error('ALLOWED_DEVICES tidak boleh kosong jika didefinisikan');
  }

  const out = [];
  const seen = new Set();
  for (const id of parts) {
    if (!DEVICE_RE.test(id)) {
      throw new Error(`ALLOWED_DEVICES memuat ID perangkat tidak valid: "${id}"`);
    }
    if (!seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

function isAllowedDevice(device, env = process.env) {
  if (typeof device !== 'string' || !DEVICE_RE.test(device)) return false;
  return getAllowedDevices(env).includes(device);
}

function getDefaultConfig(env = process.env) {
  return {
    hum_on: 70,
    hum_off: 60,
    post_run_sec: getDefaultPostRunSec(env),
    max_pwm: 100,
    smoke_on: 250,
    smoke_off: 100,
  };
}

function getPort(env = process.env) {
  const raw = env.PORT;
  if (raw === undefined || String(raw).trim() === '') return 3000;
  const s = String(raw).trim();
  if (!/^\d+$/.test(s)) {
    throw new Error(`PORT tidak valid: "${raw}"`);
  }
  const port = Number(s);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`PORT harus antara 1 dan 65535: ${port}`);
  }
  return port;
}

function isValidIpOrCidr(entry) {
  const parts = entry.split('/');
  if (parts.length > 2) return false;
  const ipVer = net.isIP(parts[0]);
  if (ipVer === 0) return false;
  if (parts.length === 1) return true;
  if (!/^\d+$/.test(parts[1])) return false;
  const prefix = Number(parts[1]);
  return ipVer === 4 ? prefix >= 0 && prefix <= 32 : prefix >= 0 && prefix <= 128;
}

function getTrustProxy(env = process.env) {
  const raw = env.TRUST_PROXY;
  if (raw === undefined) return false;
  const s = String(raw).trim();
  if (s === '' || s === '0' || s.toLowerCase() === 'false') return false;

  const lower = s.toLowerCase();
  if (lower === 'true' || lower === '*' || /^\d+$/.test(s)) {
    throw new Error(
      `TRUST_PROXY "${raw}" terlalu permisif atau tidak didukung; tentukan IP/CIDR ingress atau "loopback"`
    );
  }
  if (BUILTIN_TRUST_PROXIES.has(lower)) return lower;

  const entries = s
    .split(',')
    .map((x) => x.trim())
    .filter((x) => x.length > 0);

  if (entries.length === 0 || entries.some((x) => !isValidIpOrCidr(x))) {
    throw new Error(`TRUST_PROXY memuat alamat/CIDR tidak valid: "${raw}"`);
  }
  return entries.length === 1 ? entries[0] : entries;
}

function validateStartupEnv(env = process.env) {
  const apiKey = typeof env.API_KEY === 'string' ? env.API_KEY : '';
  if (apiKey.length < 24) {
    throw new Error('API_KEY di .env belum diisi atau kurang dari 24 karakter');
  }
  return {
    profile: getAppProfile(env),
    postRunSec: getDefaultPostRunSec(env),
    allowedDevices: getAllowedDevices(env),
    port: getPort(env),
    trustProxy: getTrustProxy(env),
  };
}

module.exports = {
  DEVICE_RE,
  getAppProfile,
  getAllowedDevices,
  isAllowedDevice,
  getDefaultPostRunSec,
  getDefaultConfig,
  getPort,
  getTrustProxy,
  validateStartupEnv,
};
