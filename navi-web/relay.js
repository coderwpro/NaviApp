#!/usr/bin/env node
/* Navi bridge relay — zero dependencies, Node built-ins only.
 *
 *   iPhone (https, LAN)  ──POST /cmd──▶  relay  ──SSE──▶  Mac Chrome (holds the BLE link)
 *   iPhone  ◀──SSE──  relay  ◀──POST /telemetry──  Mac Chrome
 *
 * The relay never touches Bluetooth. The Mac's Chrome tab keeps the GATT connection that
 * is already proven against hardware; this just carries messages to it. That is deliberate:
 * a native BLE library in Node would be a second, unproven path to the robot.
 *
 * Two listeners on purpose:
 *   http  on 8000 → the Mac opens http://localhost:8000  (localhost IS a secure context,
 *                   so Web Bluetooth works with no certificate warnings)
 *   https on 8443 → the phone opens https://<lan-ip>:8443 (iOS blocks the microphone on
 *                   plain http, so the phone half has to be TLS even on a LAN)
 */
'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const ROOT = __dirname;
const HTTP_PORT = 8000;
const HTTPS_PORT = 8443;

/* A shared token, regenerated every start. Without it, anything else on the Wi-Fi could
 * POST a drive command to a robot that has no authentication of its own. */
const TOKEN = crypto.randomBytes(4).toString('hex');

const hosts = new Set();    // the Mac tab(s) holding the BLE link
const remotes = new Set();  // the phone(s)

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
               '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml',
               '.ico': 'image/x-icon', '.md': 'text/plain; charset=utf-8' };

function lanIp() {
  for (const list of Object.values(os.networkInterfaces())) {
    for (const i of list || []) if (i.family === 'IPv4' && !i.internal) return i.address;
  }
  return '127.0.0.1';
}

function sse(res, set, label) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.write(': connected\n\n');
  set.add(res);
  console.log(`  + ${label} connected (${set.size} total)`);
  const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch { /* closed */ } }, 15000);
  res.on('close', () => {
    clearInterval(ping);
    set.delete(res);
    console.log(`  - ${label} left (${set.size} total)`);
    // A phone that vanishes mid-command must not leave the robot driving. Motion started
    // from the phone is already time-limited on the Mac side, but say so explicitly.
    if (set === remotes && remotes.size === 0) broadcast(hosts, { type: 'stop', reason: 'phone disconnected' });
  });
}

function broadcast(set, obj) {
  const line = `data: ${JSON.stringify(obj)}\n\n`;
  for (const res of set) { try { res.write(line); } catch { set.delete(res); } }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (c) => {
      raw += c;
      if (raw.length > 1e5) { reject(new Error('body too large')); req.destroy(); }
    });
    req.on('end', () => { try { resolve(JSON.parse(raw || '{}')); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const p = url.pathname;

  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  // ── API ────────────────────────────────────────────────────────────────
  if (p === '/events' || p === '/cmd' || p === '/telemetry') {
    const token = url.searchParams.get('t') || req.headers['x-token'];
    if (token !== TOKEN) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      return res.end('bad or missing token');
    }
    if (p === '/events') {
      const role = url.searchParams.get('role');
      if (role === 'host') return sse(res, hosts, 'HOST (Mac/BLE)');
      if (role === 'remote') return sse(res, remotes, 'REMOTE (phone)');
      res.writeHead(400); return res.end('role must be host or remote');
    }
    let body;
    try { body = await readBody(req); }
    catch { res.writeHead(400); return res.end('bad json'); }

    if (p === '/cmd') {
      if (hosts.size === 0) {
        res.writeHead(503, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ ok: false, error: 'no host connected — open the Mac page' }));
      }
      broadcast(hosts, body);
      console.log(`  → cmd ${JSON.stringify(body).slice(0, 120)}`);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ ok: true, hosts: hosts.size }));
    }
    broadcast(remotes, body);                      // /telemetry
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ok: true }));
  }

  // ── Static ─────────────────────────────────────────────────────────────
  let rel = p === '/' ? '/index.html' : p;
  const file = path.join(ROOT, path.normalize(rel).replace(/^(\.\.[/\\])+/, ''));
  if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end('nope'); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, { 'Content-Type': 'text/plain' }); return res.end('not found'); }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}

// ── Boot ─────────────────────────────────────────────────────────────────
http.createServer(handle).listen(HTTP_PORT);

let tls = null;
try {
  tls = { key: fs.readFileSync(path.join(ROOT, 'certs/key.pem')),
          cert: fs.readFileSync(path.join(ROOT, 'certs/cert.pem')) };
  https.createServer(tls, handle).listen(HTTPS_PORT);
} catch {
  console.log('\n!! No certs/ found — HTTPS disabled, so the phone CANNOT use the microphone.');
  console.log('   Regenerate with the openssl command in README.md\n');
}

const ip = lanIp();
console.log('\n  Navi bridge relay');
console.log('  ─────────────────────────────────────────────────────────────');
console.log(`  Mac  (holds the BLE link):  http://localhost:${HTTP_PORT}/?t=${TOKEN}`);
if (tls) console.log(`  Phone (the remote):         https://${ip}:${HTTPS_PORT}/phone.html?t=${TOKEN}`);
console.log('  ─────────────────────────────────────────────────────────────');
console.log(`  token ${TOKEN} — regenerated every restart, so re-open both links after one`);
console.log('  Safari will warn about the certificate. Tap Show Details → visit — it is');
console.log('  your own machine, and without TLS iOS refuses the microphone entirely.\n');
