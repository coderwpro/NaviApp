/* phone.js — the iPhone remote. Speaks only to the relay, never to Bluetooth.
 *
 * Safety rails, same three as the desktop page, enforced here in code:
 *   1. Motion is time-limited. Held buttons re-send a short command every 700 ms rather
 *      than sending one open-ended one, so a phone that dies mid-hold stops the robot.
 *   2. "Stop" is matched on this device before any network call or model call.
 *   3. The e-stop button is fixed at the top, never disabled, never covered.
 */
'use strict';

const $ = (id) => document.getElementById(id);
const TOKEN = new URLSearchParams(location.search).get('t');
const SPEED = 30;          // the verified "fairly quick" value; the Mac clamps anyway
const TURN = 50;
const PULSE_MS = 1000;     // duration asked for per pulse
const REPEAT_MS = 700;     // re-send interval while a button is held

if (!TOKEN) {
  $('banGate').hidden = false;
  $('banGate').textContent = 'No token in the URL. Open the exact https://… link the relay printed.';
}

/* ── Transport ─────────────────────────────────────────────────────────── */
async function send(msg) {
  try {
    const r = await fetch(`/cmd?t=${encodeURIComponent(TOKEN)}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(msg),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.ok === false) showGate(j.error || `relay ${r.status}`);
    else hideGate();
    return j;
  } catch (e) { showGate(`relay unreachable: ${e.message}`); }
}
const showGate = (t) => { $('banGate').hidden = false; $('banGate').textContent = t; };
const hideGate = () => { $('banGate').hidden = true; };

/* ── Telemetry ─────────────────────────────────────────────────────────── */
if (TOKEN) {
  const es = new EventSource(`/events?role=remote&t=${encodeURIComponent(TOKEN)}`);
  es.onopen = () => { $('link').textContent = 'linked'; $('link').style.color = 'var(--ok)'; };
  es.onerror = () => { $('link').textContent = 'reconnecting'; $('link').style.color = 'var(--warn)'; };
  es.onmessage = (e) => {
    let m; try { m = JSON.parse(e.data); } catch { return; }
    if (m.type !== 'telemetry') return;
    const s = m.status;
    $('bat').textContent = s ? s.battery : '—';
    $('est').textContent = s ? s.estop : '—';
    $('est').style.color = s && s.estop === '1' ? 'var(--bad)' : 'var(--ok)';
    $('mot').textContent = s ? (s.motionFlag === '1' ? 'idle' : 'busy') : '—';
    $('link').textContent = m.connected ? (m.gateOpen ? 'ready' : 'gate shut') : 'mac: no robot';
    $('link').style.color = m.connected && m.gateOpen ? 'var(--ok)' : 'var(--warn)';
  };
}

/* ── E-stop — first thing wired, never disabled ─────────────────────────── */
$('estop').addEventListener('click', () => { stopAll('estop button'); send({ type: 'estop' }); });
$('recover').addEventListener('click', () => send({ type: 'recover' }));

function stopAll(reason) {
  for (const t of pulses.values()) clearInterval(t);
  pulses.clear();
  document.querySelectorAll('.pad button').forEach((b) => b.classList.remove('on'));
  send({ type: 'stop', reason });
}

/* ── Hold-to-drive: repeated short pulses, not one long command ─────────── */
const AXES = {
  up:   { vx:  SPEED }, down: { vx: -SPEED },
  left: { wz:  TURN },  right: { wz: -TURN },
};
const pulses = new Map();

for (const btn of document.querySelectorAll('.pad button')) {
  const dir = btn.dataset.dir;
  const start = (e) => {
    e.preventDefault();
    if (pulses.has(dir)) return;
    btn.classList.add('on');
    const fire = () => send({ type: 'drive', axes: AXES[dir], ms: PULSE_MS });
    fire();
    pulses.set(dir, setInterval(fire, REPEAT_MS));
  };
  const end = () => {
    if (!pulses.has(dir)) return;
    clearInterval(pulses.get(dir));
    pulses.delete(dir);
    btn.classList.remove('on');
    send({ type: 'stop', reason: 'button released' });
  };
  btn.addEventListener('pointerdown', start);
  btn.addEventListener('pointerup', end);
  btn.addEventListener('pointercancel', end);
  btn.addEventListener('pointerleave', end);
}
for (const b of document.querySelectorAll('[data-skill]')) {
  b.addEventListener('click', () => send({ type: 'skill', name: b.dataset.skill }));
}
// Backgrounding the app must not leave it driving.
document.addEventListener('visibilitychange', () => { if (document.hidden) stopAll('phone backgrounded'); });
window.addEventListener('pagehide', () => stopAll('phone closed'));

/* ── Voice ─────────────────────────────────────────────────────────────── */
const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
const STOP_WORDS = /\b(stop|halt|freeze|whoa|stay|abort|cancel|e-?stop|emergency)\b/i;
const ACTIONS = ['forward', 'backward', 'turn_left', 'turn_right', 'raise', 'bow', 'twist',
                 'stand', 'sit', 'lie', 'wag_tail', 'dance', 'stop', 'unknown'];
const KEYWORDS = [
  [/\b(forward|forwards|ahead|go|walk)\b/i, 'forward'],
  [/\b(back|backward|backwards|reverse)\b/i, 'backward'],
  [/\bleft\b/i, 'turn_left'], [/\bright\b/i, 'turn_right'],
  [/\b(stand|get up)\b/i, 'stand'], [/\bsit\b/i, 'sit'], [/\b(lie|lay)\b/i, 'lie'],
  [/\b(wag|tail)\b/i, 'wag_tail'], [/\bdance\b/i, 'dance'],
  [/\bbow\b/i, 'bow'], [/\b(twist|wiggle)\b/i, 'twist'], [/\b(raise|lift)\b/i, 'raise'],
];

const setIntent = (t, c) => { $('intent').textContent = t; $('intent').style.color = c || 'var(--fg)'; };

if (!SR) {
  $('banVoice').hidden = false;
  $('banVoice').textContent =
    'No SpeechRecognition here. On iOS this needs Safari 14.5+ AND an https page — if you ' +
    'opened an http:// address the microphone is blocked outright.';
  $('mic').disabled = true;
}

function runAction(action) {
  const drive = {
    forward: { vx: SPEED }, backward: { vx: -SPEED },
    turn_left: { wz: TURN }, turn_right: { wz: -TURN },
    raise: { raise: 30 }, bow: { bow: 30 }, twist: { twist: 30 },
  }[action];
  if (drive) return send({ type: 'drive', axes: drive, ms: PULSE_MS });
  const skill = { stand: 'stand_up', sit: 'sit_down', lie: 'lie_down',
                  wag_tail: 'wag_tail', dance: 'dance' }[action];
  if (skill) return send({ type: 'skill', name: skill });
  if (action === 'stop') return stopAll('voice');
}

async function askModel(text) {
  const key = $('key').value.trim();
  if (!key) throw new Error('no API key');
  const r = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model: $('model').value.trim() || 'gpt-4o-mini',
      messages: [
        { role: 'system', content:
          'You classify a spoken command to a quadruped robot into exactly one action label. ' +
          'You do not control the robot; a separate program applies the safety limits. Choose ' +
          '"unknown" for anything unclear or not in the list — never substitute something ' +
          'similar. The robot cannot jump, run, fetch, speak or navigate; those are "unknown".' },
        { role: 'user', content: text },
      ],
      response_format: { type: 'json_schema', json_schema: { name: 'navi_command', strict: true,
        schema: { type: 'object', additionalProperties: false,
          required: ['action', 'reason'],
          properties: { action: { type: 'string', enum: ACTIONS }, reason: { type: 'string' } } } } },
    }),
  });
  if (!r.ok) throw new Error(`${r.status}`);
  return JSON.parse((await r.json()).choices[0].message.content);
}

async function handle(text) {
  if (STOP_WORDS.test(text)) { stopAll('voice: stop'); setIntent('STOP (code, no model)', 'var(--bad)'); return; }
  const mode = $('mode').value;
  if (mode !== 'ai') {
    for (const [re, action] of KEYWORDS) {
      if (re.test(text)) { setIntent(`keyword → ${action}`, 'var(--ok)'); return runAction(action); }
    }
    if (mode === 'keyword') { setIntent('no match — ignored', 'var(--warn)'); return; }
  }
  setIntent('…thinking', 'var(--dim)');
  try {
    const out = await askModel(text);
    if (!ACTIONS.includes(out.action)) { setIntent(`rejected "${out.action}"`, 'var(--bad)'); return; }
    setIntent(`AI → ${out.action} — ${out.reason}`, out.action === 'unknown' ? 'var(--warn)' : 'var(--ok)');
    if (out.action !== 'unknown') runAction(out.action);
  } catch (e) { setIntent(`AI failed: ${e.message} — robot not moved`, 'var(--bad)'); }
}

if (SR) {
  const rec = new SR();
  rec.continuous = false;         // push-to-talk suits a phone and saves battery
  rec.interimResults = true;
  rec.lang = 'en-US';
  let live = false;

  rec.onresult = (e) => {
    let interim = '', final = '';
    for (let i = e.resultIndex; i < e.results.length; i++) {
      const r = e.results[i];
      if (r.isFinal) final += r[0].transcript; else interim += r[0].transcript;
    }
    $('heard').textContent = (final || interim).trim() || '…';
    // rail 2: act on the partial, so "stop" lands before the sentence even ends
    if (interim && STOP_WORDS.test(interim)) { stopAll('voice: stop'); setIntent('STOP (code, no model)', 'var(--bad)'); return; }
    if (final.trim()) handle(final);
  };
  rec.onend = () => { live = false; $('mic').classList.remove('on'); $('mic').textContent = '🎤 hold to talk'; };
  rec.onerror = (e) => setIntent(`mic: ${e.error}`, 'var(--bad)');

  const begin = (e) => {
    e.preventDefault();
    if (live) return;
    live = true;
    $('mic').classList.add('on'); $('mic').textContent = '● listening';
    try { rec.start(); } catch { /* already started */ }
  };
  const finish = () => { if (live) rec.stop(); };
  $('mic').addEventListener('pointerdown', begin);
  $('mic').addEventListener('pointerup', finish);
  $('mic').addEventListener('pointercancel', finish);
}
