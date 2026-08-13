/* Navi BLE web remote — Day 1.
 *
 * Every frame format here comes from the cheat sheet §4 (hardware-verified) and the
 * reference Python in ff_sdk_navi_devkit_20260809.zip (examples/navi/ble_probe.py,
 * ble_smoke.py). Nothing in this file is guessed. If a value disagrees with the robot,
 * suspect the robot is a different build before you suspect this file — and ask David.
 */
'use strict';

/* ── Protocol constants ─────────────────────────────────────────────────────
 * GATT addresses, cheat sheet §4.1 (from vendor/Dogwalk/lib/ble_protocol.dart:26-29).
 * Web Bluetooth requires lowercase UUID strings.
 */
const SERVICE_UUID  = '12345678-1234-5678-1234-56789abc0000';
const CHAR_CMD      = '12345678-1234-5678-1234-56789abc0001'; // text commands, robot replies on EVENT
const CHAR_JOYSTICK = '12345678-1234-5678-1234-56789abc0002'; // 8 raw bytes, no reply, high rate
const CHAR_EVENT    = '12345678-1234-5678-1234-56789abc0003'; // notify: status pushed by the robot

const FRAME_HEADER = 0xAA;
const AXIS_LIMIT   = 127;   // axes are SIGNED bytes. >127 reads as negative. See §4.2.
const POSTURE_MIN  = 17;    // raise/bow/twist do nothing below this.
const TICK_MS      = 50;    // 20 Hz, same rate as ble_smoke.py. The stick is held, not set.
const MAX_HOLD_MS  = 3000;  // watchdog: no single hold drives longer than this.
const ZERO_REPEATS = 3;     // joystick channel never acks, so send the stop more than once.

/* ── Element lookup ─────────────────────────────────────────────────────── */
const $ = (id) => document.getElementById(id);
const els = {};
for (const id of ['dotConn','connState','chipDev','btnEstop','btnRecover','banSecure',
  'banSupport','banEnvOk','btnConnect','btnRetry','btnDisconnect','btnScanAll','banPicked',
  'selfTest','banNoTelemetry','battery','batBar','estopBit','motionState','actionId','temps',
  'charging','frameCount','frameAge','lastError','log','btnClearLog','chkLogStatus',
  'ackSingle','ackRemote','ackElevated','ackNoTelem','banDriveLocked','speed','lastFrame',
  'txCount','banAnim','skillName','btnSkill']) els[id] = $(id);

/* ── Logging ────────────────────────────────────────────────────────────── */
const stamp = () => new Date().toTimeString().slice(0, 8) + '.' +
  String(new Date().getMilliseconds()).padStart(3, '0');

function log(cls, text) {
  const line = document.createElement('div');
  line.innerHTML = `<span class="t">${stamp()}</span> <span class="${cls}">${
    text.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]))}</span>`;
  els.log.appendChild(line);
  while (els.log.childElementCount > 500) els.log.removeChild(els.log.firstChild);
  els.log.scrollTop = els.log.scrollHeight;
}
els.btnClearLog.onclick = () => (els.log.textContent = '');

const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(' ');

/* ── Frame building ─────────────────────────────────────────────────────────
 * byte:  0     1    2    3    4      5     6      7
 *       0xAA  vx   vy   wz  raise  bow  twist  checksum      checksum = sum(1..6) & 0xFF
 * Exactly 8 bytes. An earlier attempt sent 16 and the robot silently discarded every
 * frame for two full test rounds — the joystick channel never reports anything.
 */
function clampAxis(v) {
  v = Math.round(Number(v) || 0);
  return Math.max(-AXIS_LIMIT, Math.min(AXIS_LIMIT, v));
}

function buildJoystickFrame({ vx = 0, vy = 0, wz = 0, raise = 0, bow = 0, twist = 0 } = {},
                            { clamp = true } = {}) {
  // clamp:false is reachable only by explicitly selecting a speed above 127. It exists
  // because the operator asked for it, not because any value above 127 is useful: the
  // firmware reads the byte as signed, so those values are reverse commands.
  const conv = clamp ? clampAxis : (v) => Math.round(Number(v) || 0);
  const axes = [vx, vy, wz, raise, bow, twist].map(conv);
  const f = new Uint8Array(8);
  f[0] = FRAME_HEADER;
  let sum = 0;
  for (let i = 0; i < 6; i++) {
    f[i + 1] = axes[i] & 0xff;   // two's complement: -30 -> 0xE2
    sum += f[i + 1];
  }
  f[7] = sum & 0xff;
  return f;
}

/* ── Self-test — runs with no robot, proves the encoder ─────────────────── */
(function selfTest() {
  const cases = [
    ['vx=30 forward (the frame verified on hardware)',
      buildJoystickFrame({ vx: 30 }), 'aa 1e 00 00 00 00 00 1e'],
    ['vx=-30 backward encodes as 0xE2',
      buildJoystickFrame({ vx: -30 }), 'aa e2 00 00 00 00 00 e2'],
    ['vx=200 is clamped to 127, NOT sent as 0xC8 (=-56, backwards)',
      buildJoystickFrame({ vx: 200 }), 'aa 7f 00 00 00 00 00 7f'],
    ['zero frame (the stop)',
      buildJoystickFrame(), 'aa 00 00 00 00 00 00 00'],
    ['checksum wraps at 0xFF',
      buildJoystickFrame({ vx: 100, wz: 100, twist: 100 }), 'aa 64 00 64 00 00 64 2c'],
  ];
  let allPass = true;
  for (const [name, frame, want] of cases) {
    const got = hex(frame);
    const ok = got === want && frame.length === 8;
    if (!ok) allPass = false;
    els.selfTest.insertAdjacentHTML('beforeend',
      `<span class="${ok ? 'pass' : 'fail'}">${ok ? 'PASS' : 'FAIL'}</span><span>${name}<br>` +
      `<span style="color:var(--dim)">${got}${ok ? '' : `  ≠ want ${want}`}</span></span>`);
  }
  log(allPass ? 'good' : 'err', `[self-test] encoder ${allPass ? 'passed' : 'FAILED'} (${cases.length} cases)`);
})();

/* ── Environment checks ─────────────────────────────────────────────────── */
const hasBluetooth = 'bluetooth' in navigator;
els.banSecure.hidden = window.isSecureContext;
els.banSupport.hidden = hasBluetooth;
els.banEnvOk.hidden = !(window.isSecureContext && hasBluetooth);
if (!hasBluetooth || !window.isSecureContext) {
  els.btnConnect.disabled = els.btnScanAll.disabled = true;
}

/* ── Connection state ───────────────────────────────────────────────────── */
let device = null, server = null, cmdChar = null, joyChar = null, evtChar = null;
let connected = false;

function setConnState(state, cls) {
  els.connState.textContent = state;
  els.dotConn.className = 'dot ' + (cls || '');
}

async function connect() {
  els.btnConnect.disabled = true;
  els.btnRetry.hidden = true;
  setConnState('requesting device…', 'busy');
  try {
    // requestDevice must be inside a user gesture; on page load it is silently rejected.
    // Advertised names look like NAVI-AA-EA-044; filters are OR'd, so cover the casings.
    // The service UUID must be in optionalServices or getPrimaryService throws "not allowed" —
    // many devices don't put their service in the advertisement at all.
    device = await navigator.bluetooth.requestDevice({
      filters: [{ namePrefix: 'NAVI' }, { namePrefix: 'Navi' }, { namePrefix: 'navi' }],
      optionalServices: [SERVICE_UUID],
    });
    log('sys', `[picked] ${device.name || '(no name)'}  id=${device.id}`);
    els.chipDev.hidden = false;
    els.chipDev.textContent = device.name || '(unnamed)';
    device.addEventListener('gattserverdisconnected', onDisconnected);

    setConnState('connecting…', 'busy');
    server = await device.gatt.connect();
    const service = await server.getPrimaryService(SERVICE_UUID);
    cmdChar = await service.getCharacteristic(CHAR_CMD);
    joyChar = await service.getCharacteristic(CHAR_JOYSTICK);
    evtChar = await service.getCharacteristic(CHAR_EVENT);

    // Subscribe BEFORE anything else is sent. Telemetry first is the whole point of day 1.
    await evtChar.startNotifications();
    evtChar.addEventListener('characteristicvaluechanged', onNotification);

    connected = true;
    setConnState('connected', 'on');
    els.btnDisconnect.disabled = false;
    log('good', '[connected] subscribed to EVENT — waiting for status frames');
  } catch (err) {
    log('err', `[connect failed] ${err.name}: ${err.message}`);
    setConnState('connect failed', 'off');
    els.btnConnect.disabled = false;
    els.btnRetry.hidden = false;
    // ~30-40% of attempts fail and it is not this code. Retry is the documented answer.
  }
  updateDriveGate();
}

function onDisconnected() {
  connected = false;
  cmdChar = joyChar = evtChar = server = null;
  stopDriving('link lost');
  setConnState('disconnected', 'off');
  els.btnConnect.disabled = false;
  els.btnDisconnect.disabled = true;
  els.btnRetry.hidden = false;
  log('err', '[disconnected] link dropped — the page is NOT still controlling the robot');
  updateDriveGate();
}

els.btnConnect.onclick = connect;
els.btnRetry.onclick = connect;
els.btnDisconnect.onclick = () => {
  if (device && device.gatt.connected) device.gatt.disconnect();
};

els.btnScanAll.onclick = async () => {
  try {
    const d = await navigator.bluetooth.requestDevice({
      acceptAllDevices: true, optionalServices: [SERVICE_UUID],
    });
    els.banPicked.hidden = false;
    els.banPicked.innerHTML =
      `Picked <b>${d.name || '(unnamed device)'}</b> — id <code>${d.id}</code>.<br>` +
      `Web Bluetooth works from this page. Not connected: this button only proves the path.`;
    log('good', `[scan-all] picked ${d.name || '(unnamed)'} id=${d.id}`);
  } catch (err) {
    log('sys', `[scan-all] ${err.name}: ${err.message}`);
  }
};

/* ── GATT write scheduler ───────────────────────────────────────────────────
 * A GATT server runs one operation at a time; overlapping writes throw
 * "GATT operation already in progress". At 20 Hz that is guaranteed. So:
 * commands queue FIFO, the joystick keeps only its newest frame (a stale stick
 * position is worthless), and e-stop jumps the whole queue.
 */
const q = { busy: false, cmds: [], joy: null };

function pump() {
  if (q.busy) return;
  q.busy = true;
  (async () => {
    try {
      while (q.cmds.length || q.joy) {
        if (q.cmds.length) {
          const job = q.cmds.shift();
          try {
            await cmdChar.writeValue(new TextEncoder().encode(job.text));
            log('tx', `[cmd] ${job.text}`);
          } catch (err) {
            log('err', `[cmd failed] ${job.text} — ${err.name}: ${err.message}`);
          }
        } else {
          const frame = q.joy; q.joy = null;
          try {
            // writeWithoutResponse: no ack, which is what a 20 Hz stick needs.
            if (joyChar.writeValueWithoutResponse) await joyChar.writeValueWithoutResponse(frame);
            else await joyChar.writeValue(frame);
            txCount++;
            els.txCount.textContent = txCount;
            els.lastFrame.textContent = hex(frame);
          } catch (err) {
            log('err', `[joystick failed] ${err.name}: ${err.message}`);
          }
        }
      }
    } finally { q.busy = false; }
  })();
}

function sendCommand(text, { urgent = false } = {}) {
  if (!connected || !cmdChar) { log('err', `[cmd dropped — no link] ${text}`); return; }
  if (urgent) { q.joy = null; q.cmds.unshift({ text }); } else { q.cmds.push({ text }); }
  pump();
}

function sendJoystick(frame) {
  if (!connected || !joyChar) return;
  q.joy = frame;      // latest wins
  pump();
}

let txCount = 0;

/* ── E-stop / recover — reachable in every state, never disabled ─────────── */
els.btnEstop.onclick = () => {
  stopDriving('e-stop pressed');
  sendCommand('cmd|estop', { urgent: true });
  log('tx', '[E-STOP] cmd|estop — latching. Watch the e-stop bit flip 0 → 1.');
};
els.btnRecover.onclick = () => {
  sendCommand('cmd|recover');
  log('tx', '[recover] cmd|recover — releases the latch. Bit should go 1 → 0.');
};

/* ── Incoming frames ────────────────────────────────────────────────────── */
let statusCount = 0, lastStatusAt = 0;
let lastStatus = null;   // most recent parsed status frame, mirrored to the phone by host.js

function onNotification(event) {
  const bytes = new Uint8Array(event.target.value.buffer);
  const text = new TextDecoder().decode(bytes);
  // Frames are bare UTF-8 on the wire. Occasionally more than one arrives together.
  for (const part of text.split(/[\r\n]+/)) {
    const line = part.trim();
    if (line) handleFrame(line, bytes);
  }
}

function handleFrame(line, rawBytes) {
  const p = line.split('|');
  switch (p[0]) {
    case 's': {                                   // s|<battery>|<estop>|<motion_flag>|<action_id>
      statusCount++;
      lastStatusAt = performance.now();
      els.frameCount.textContent = statusCount;
      els.banNoTelemetry.hidden = true;

      const battery = Number(p[1]);
      els.battery.textContent = Number.isFinite(battery) ? battery : '?';
      els.batBar.style.width = Math.max(0, Math.min(100, battery)) + '%';
      els.batBar.style.background = battery < 30 ? 'var(--bad)' : battery < 50 ? 'var(--warn)' : 'var(--ok)';

      const estop = p[2];
      els.estopBit.textContent = estop;
      els.estopBit.style.color = estop === '1' ? 'var(--bad)' : 'var(--ok)';

      // motion_flag is inverted relative to its name: 1 = idle, 0 = busy.
      const mf = p[3];
      els.motionState.textContent = mf === '1' ? 'idle' : mf === '0' ? 'busy' : mf;
      els.motionState.style.color = mf === '0' ? 'var(--warn)' : 'var(--fg)';

      // action_id is shown, never gated on. 4 is idle here; another healthy unit reports 625.
      els.actionId.textContent = p[4];
      lastStatus = { battery, estop, motionFlag: mf, actionId: p[4], at: Date.now() };

      if (els.chkLogStatus.checked) log('rx', `${line}   [${hex(rawBytes)}]`);
      updateDriveGate();
      break;
    }
    case 't':
      els.temps.textContent = p.slice(1).join(' / ') + ' °C';
      log('rx', line);
      break;
    case 'c':
      els.charging.textContent = p[1] === '1' ? 'yes' : p[1] === '0' ? 'no' : p[1];
      log('rx', line);
      break;
    case 'e': {
      let msg = p[2] || '';
      try { msg = atob(msg); } catch { /* not base64 — show it raw */ }
      els.lastError.textContent = `${p[1]}: ${msg}`;
      log('err', `[robot error] code=${p[1]} ${msg}`);
      break;
    }
    default:
      log('rx', `[unrecognised] ${line}   [${hex(rawBytes)}]`);
  }
}

setInterval(() => {
  els.frameAge.textContent = lastStatusAt
    ? ((performance.now() - lastStatusAt) / 1000).toFixed(1) + ' s ago' : '—';
}, 200);

/* ── Drive gate ─────────────────────────────────────────────────────────── */
function safetyAcked() {
  return els.ackSingle.checked && els.ackRemote.checked && els.ackElevated.checked;
}
function haveTelemetry() {
  return statusCount > 0 || els.ackNoTelem.checked;
}
function canDrive() {
  return connected && safetyAcked() && haveTelemetry();
}
function updateDriveGate() {
  const ok = canDrive();
  els.banDriveLocked.hidden = ok;
  if (!ok) {
    const why = !connected ? 'not connected'
      : !safetyAcked() ? 'safety boxes not ticked'
      : 'no status frame received yet — you would be driving blind';
    els.banDriveLocked.textContent = `Driving locked — ${why}.`;
    stopDriving('gate closed');
  }
  for (const b of document.querySelectorAll('[data-drive],[data-posture],[data-vy],#btnRaw')) b.disabled = !ok;
  for (const b of document.querySelectorAll('[data-skill],[data-cmd]')) b.disabled = !connected;
  els.btnSkill.disabled = !connected;
}
for (const id of ['ackSingle', 'ackRemote', 'ackElevated', 'ackNoTelem']) {
  els[id].addEventListener('change', updateDriveGate);
}

/* ── Drive loop — the stick is held, so frames repeat at 20 Hz ──────────── */
const axes = { vx: 0, vy: 0, wz: 0, raise: 0, bow: 0, twist: 0 };
let driveTimer = null, holdStartedAt = 0;

/* Set only by the raw-byte tester, cleared by stopDriving(). When set it replaces the
 * built frame entirely, so the unclamped path cannot leak into normal driving. */
let rawFrame = null;

/* Declared here, not down in the keyboard section: stopDriving() clears it, and
 * stopDriving() runs during startup (updateDriveGate / onSpeedChange). A `const` below
 * its first use is a temporal-dead-zone ReferenceError that kills the whole script. */
const held = new Set();

const anyAxis = () => Object.values(axes).some((v) => v !== 0);

function pushAxes() {
  if (!canDrive()) { zeroAxes(); return; }
  if (anyAxis() || rawFrame) {
    if (!driveTimer) {
      holdStartedAt = performance.now();
      driveTimer = setInterval(tick, TICK_MS);
      tick();
    }
  } else if (driveTimer) {
    stopDriving('released');
  }
}

function tick() {
  if (!canDrive()) { stopDriving('gate closed mid-drive'); return; }
  if (performance.now() - holdStartedAt > MAX_HOLD_MS) {
    log('sys', `[watchdog] ${MAX_HOLD_MS} ms hold limit reached — zeroing`);
    zeroAxes();
    stopDriving('watchdog');
    return;
  }
  sendJoystick(rawFrame || buildJoystickFrame(axes, { clamp: !speedIsUnclamped() }));
}

function stopDriving(reason) {
  if (driveTimer) { clearInterval(driveTimer); driveTimer = null; }
  rawFrame = null;
  for (const k of Object.keys(axes)) axes[k] = 0;
  document.querySelectorAll('.held').forEach((b) => b.classList.remove('held'));
  held.clear();
  if (connected && joyChar) {
    // The joystick channel never acks. Send the stop more than once.
    for (let i = 0; i < ZERO_REPEATS; i++) setTimeout(() => sendJoystick(buildJoystickFrame()), i * TICK_MS);
    if (reason) log('tx', `[stop: ${reason}] zero frame ×${ZERO_REPEATS}`);
  }
}
function zeroAxes() { for (const k of Object.keys(axes)) axes[k] = 0; }

// Selected speed is NOT clamped here — the >127 options are deliberate, and clamping
// them silently would make the dropdown label a lie. The clamp is applied in the frame
// builder for every value at or below 127, i.e. every value that means what it says.
const speed = () => Math.round(Number(els.speed.value) || 0);
const speedIsUnclamped = () => speed() > AXIS_LIMIT;
const TURN_RATE = 50;   // "50 fast" per §4.2; wz sign convention is not documented.

function onSpeedChange() {
  const over = speedIsUnclamped();
  $('banOverClamp').hidden = !over;
  if (over) {
    const v = speed() & 0xff;
    $('overClampSigned').textContent = String(v > 127 ? v - 256 : v);
    log('err', `[speed ${speed()}] clamp OFF — forward key now sends ${v > 127 ? v - 256 : v}. ` +
               'The robot will drive the opposite way to the key you press.');
  }
  stopDriving('speed changed');
}
els.speed.addEventListener('change', onSpeedChange);
onSpeedChange();

/* ── Keyboard ───────────────────────────────────────────────────────────── */
const KEY_AXIS = {
  ArrowUp:    () => ({ vx:  speed() }),
  ArrowDown:  () => ({ vx: -speed() }),
  ArrowLeft:  () => ({ wz:  TURN_RATE }),
  ArrowRight: () => ({ wz: -TURN_RATE }),
};

window.addEventListener('keydown', (e) => {
  if (e.code === 'Space') { e.preventDefault(); if (!e.repeat) els.btnEstop.click(); return; }
  if (e.key === 'Escape') { e.preventDefault(); stopDriving('escape'); return; }
  if (!KEY_AXIS[e.key]) return;
  e.preventDefault();
  if (e.repeat) return;
  held.add(e.key);
  applyHeld();
});
window.addEventListener('keyup', (e) => {
  if (!KEY_AXIS[e.key]) return;
  e.preventDefault();
  held.delete(e.key);
  applyHeld();
});
// Alt-tab while holding a key means keyup never fires. That would be a runaway.
window.addEventListener('blur', () => stopDriving('window lost focus'));
document.addEventListener('visibilitychange', () => { if (document.hidden) stopDriving('tab hidden'); });
window.addEventListener('pagehide', () => stopDriving('page closing'));

function applyHeld() {
  zeroAxes();
  for (const k of held) Object.assign(axes, KEY_AXIS[k]());
  for (const b of document.querySelectorAll('[data-drive]')) {
    const key = { up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight' }[b.dataset.drive];
    b.classList.toggle('held', held.has(key));
  }
  pushAxes();
}

/* ── On-screen momentary buttons ────────────────────────────────────────── */
function momentary(el, onPress) {
  const press = (e) => {
    e.preventDefault();
    if (el.disabled) return;
    el.classList.add('held');
    onPress();
    pushAxes();
  };
  const release = () => {
    if (!el.classList.contains('held')) return;
    el.classList.remove('held');
    stopDriving('button released');
  };
  el.addEventListener('pointerdown', press);
  el.addEventListener('pointerup', release);
  el.addEventListener('pointerleave', release);
  el.addEventListener('pointercancel', release);
}

for (const b of document.querySelectorAll('[data-drive]')) {
  const dir = b.dataset.drive;
  momentary(b, () => {
    zeroAxes();
    Object.assign(axes, {
      up: { vx: speed() }, down: { vx: -speed() },
      left: { wz: TURN_RATE }, right: { wz: -TURN_RATE },
    }[dir]);
  });
}
for (const b of document.querySelectorAll('[data-posture]')) {
  momentary(b, () => {
    zeroAxes();
    // Below 17 these do nothing at all, so a value that low is a bug, not a small movement.
    axes[b.dataset.posture] = Math.max(POSTURE_MIN, clampAxis(Number(b.dataset.val)));
  });
}
for (const b of document.querySelectorAll('[data-vy]')) {
  momentary(b, () => {
    zeroAxes();                       // everything else zero — that is what makes this a clean test
    axes.vy = clampAxis(Number(b.dataset.vy));
    log('sys', '[vy probe] vy alone. Lateral shift or a turn? Watch the robot, then write it down.');
  });
}

/* ── Raw byte tester — the one control that does NOT clamp ─────────────────
 * Builds the frame from the byte exactly as typed so the signed-byte behaviour can be
 * observed rather than taken on trust. Everything else in this file clamps to ±127.
 */
function buildRawFrame(axisIndex, rawByte) {
  const f = new Uint8Array(8);
  f[0] = FRAME_HEADER;
  f[1 + axisIndex] = rawByte & 0xff;
  let sum = 0;
  for (let i = 1; i <= 6; i++) sum += f[i];
  f[7] = sum & 0xff;
  return f;
}

const rawAxisEl = $('rawAxis'), rawValueEl = $('rawValue'), btnRaw = $('btnRaw');

function rawByte() {
  const n = parseInt(rawValueEl.value, 10);
  return Number.isFinite(n) ? n & 0xff : 0;
}

function showRawInterpretation() {
  const b = rawByte();
  const signed = b > 127 ? b - 256 : b;
  $('rawHex').textContent = `0x${b.toString(16).padStart(2, '0').toUpperCase()} (${b} unsigned)`;
  const el = $('rawSigned');
  el.textContent = signed < 0 ? `${signed}  ← reverse` : `${signed}`;
  el.style.color = signed < 0 ? 'var(--bad)' : 'var(--fg)';
}
rawValueEl.addEventListener('input', showRawInterpretation);
showRawInterpretation();

momentary(btnRaw, () => {
  zeroAxes();
  const b = rawByte();
  rawFrame = buildRawFrame(Number(rawAxisEl.value), b);
  const signed = b > 127 ? b - 256 : b;
  log('sys', `[raw] ${rawAxisEl.selectedOptions[0].text}=${b} → wire ${hex(rawFrame)} → robot reads ${signed}`);
});

/* ── Skills and raw commands ────────────────────────────────────────────── */
function sendSkill(name) {
  if (!name) return;
  // send_skill is the only JSON command. By name — a numeric id silently does nothing.
  sendCommand(JSON.stringify({ id: 1, cmd: 'send_skill', params: { skill_name: name } }));
  els.banAnim.hidden = false;
  log('sys', '[skill sent] joystick may now be ignored until the animation ends — trap #2');
}
for (const b of document.querySelectorAll('[data-skill]')) b.onclick = () => sendSkill(b.dataset.skill);
els.btnSkill.onclick = () => sendSkill(els.skillName.value.trim());
for (const b of document.querySelectorAll('[data-cmd]')) b.onclick = () => sendCommand(b.dataset.cmd);

/* ── Public control surface for voice.js ────────────────────────────────────
 * Everything voice can do goes through here, so the limits live in ONE place and a
 * caller (including an AI) cannot reach past them. Rail 1 of the day-2 safety rules:
 * voice may only start TIME-LIMITED motion, enforced in code, not in a prompt.
 */
const VOICE_MAX_MS = 2000;   // hard ceiling on any voice-initiated motion
let voiceTimer = null;

function driveFor(desired, ms) {
  if (!canDrive()) { log('err', '[voice] refused — drive gate is closed'); return false; }
  clearTimeout(voiceTimer);
  zeroAxes();
  for (const [k, v] of Object.entries(desired)) {
    if (k in axes) axes[k] = clampAxis(v);   // clamped regardless of what the caller asked
  }
  const dur = Math.max(250, Math.min(VOICE_MAX_MS, Math.round(Number(ms) || 0)));
  pushAxes();
  voiceTimer = setTimeout(() => stopDriving('voice time limit'), dur);
  log('tx', `[voice] ${JSON.stringify(axes)} for ${dur}ms`);
  return true;
}

window.NaviControl = {
  AXIS_LIMIT,
  VOICE_MAX_MS,
  log,
  isConnected: () => connected,
  canDrive: () => canDrive(),
  getStatus: () => ({ connected, gateOpen: canDrive(), status: lastStatus, frames: statusCount }),
  recover: () => sendCommand('cmd|recover'),
  speed: () => Math.min(AXIS_LIMIT, Math.abs(speed())),   // voice never uses the >127 options
  driveFor,
  skill: (name) => sendSkill(name),
  stopAll: (reason) => { clearTimeout(voiceTimer); stopDriving(reason || 'voice stop'); },
  eStop: () => els.btnEstop.click(),
};

/* ── Boot ───────────────────────────────────────────────────────────────── */
updateDriveGate();
log('sys', '[ready] Order for today: connect → watch battery tick → e-stop bit flips → then drive.');
