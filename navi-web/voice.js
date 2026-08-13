/* Voice control — keyword matching first, LLM intent parsing as a fallback.
 *
 * The three day-2 safety rails live in THIS file as code, never as prompt text:
 *   1. Voice only starts time-limited motion  → NaviControl.driveFor() caps every request
 *   2. "stop" is matched before the AI sees it → checkStop() runs on interim results
 *   3. The e-stop button is never touched by voice logic
 *
 * A model is asked only to CLASSIFY. It cannot choose a speed, a duration, a skill name,
 * or an axis — every one of those is whitelisted and clamped below after it answers.
 */
'use strict';

const NC = window.NaviControl;
const $v = (id) => document.getElementById(id);

const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
// NOT `els` — app.js already binds that at top level, and two classic scripts share one
// global lexical scope, so a duplicate `const` is a SyntaxError that kills this whole file.
const vEls = {
  mic: $v('btnMic'), state: $v('voiceState'), transcript: $v('transcript'),
  mode: $v('voiceMode'), key: $v('apiKey'), model: $v('apiModel'),
  dur: $v('voiceDuration'), durOut: $v('voiceDurationOut'),
  banner: $v('banVoiceSupport'), intent: $v('lastIntent'),
};

if (!SR) {
  vEls.banner.hidden = false;
  vEls.banner.textContent =
    'This browser has no SpeechRecognition. Voice needs Chrome or Edge — desktop or Android. ' +
    'Recognition also runs in the cloud, so it needs internet (BLE keeps your Wi-Fi free, ' +
    'which is exactly why this project uses Bluetooth rather than the robot hotspot).';
  vEls.mic.disabled = true;
}

/* ── Rail 2: stop is matched in code, before anything async ─────────────────
 * Checked against interim results too, so it fires while the word is still being said
 * rather than after the sentence completes. Nothing here awaits, calls the network,
 * or consults a model — stopping cannot wait for latency.
 */
const STOP_WORDS = /\b(stop|halt|freeze|whoa|stay|abort|cancel|e-?stop|emergency)\b/i;

function checkStop(text) {
  if (!STOP_WORDS.test(text)) return false;
  NC.stopAll('voice: stop');
  setState('STOPPED', 'var(--bad)');
  NC.log('good', `[voice] STOP matched in code: "${text.trim()}" — no model involved`);
  return true;
}

/* ── Route A: keyword matching. Instant, offline, and it demos. ───────────── */
const KEYWORDS = [
  [/\b(forward|forwards|ahead|go|walk|move up)\b/i, () => ({ vx: +NC.speed() })],
  [/\b(back|backward|backwards|reverse|retreat)\b/i, () => ({ vx: -NC.speed() })],
  [/\b(left|turn left|port)\b/i,                     () => ({ wz: +50 })],
  [/\b(right|turn right|starboard)\b/i,              () => ({ wz: -50 })],
  [/\b(bow|bend|down)\b/i,                           () => ({ bow: 30 })],
  [/\b(twist|wiggle|shake)\b/i,                      () => ({ twist: 30 })],
  [/\b(raise|up|taller|lift)\b/i,                    () => ({ raise: 30 })],
];
const SKILL_WORDS = [
  [/\b(stand|stand up|get up)\b/i, 'stand_up'],
  [/\b(sit|sit down)\b/i,          'sit_down'],
  [/\b(lie|lay|lie down|down dog)\b/i, 'lie_down'],
  [/\b(wag|tail)\b/i,              'wag_tail'],
  [/\bdance\b/i,                   'dance'],
];

function matchKeyword(text) {
  for (const [re, name] of SKILL_WORDS) if (re.test(text)) return { kind: 'skill', name };
  for (const [re, build] of KEYWORDS)   if (re.test(text)) return { kind: 'drive', axes: build() };
  return null;
}

/* ── Route B: LLM intent parsing ────────────────────────────────────────────
 * The model returns a label from a fixed list. It never returns a frame, an axis value
 * or a raw byte — those are built here, from the label, with the same clamps the
 * keyboard path uses.
 */
const ACTIONS = ['forward', 'backward', 'turn_left', 'turn_right', 'raise', 'bow', 'twist',
                 'stand', 'sit', 'lie', 'wag_tail', 'dance', 'stop', 'unknown'];

const SYSTEM_PROMPT =
  'You classify a spoken command to a quadruped robot into exactly one action label. ' +
  'You do not control the robot; a separate program applies safety limits to whatever you return. ' +
  'Choose "unknown" whenever the request is unclear, is not a movement command, or asks for ' +
  'anything not in the list — do not substitute something similar. The robot cannot jump, ' +
  'climb, run, fetch, speak, or navigate to places; those are all "unknown".';

async function askModel(text) {
  const key = vEls.key.value.trim();
  if (!key) throw new Error('No API key entered');
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model: vEls.model.value.trim() || 'gpt-4o-mini',
      messages: [{ role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: text }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'navi_command',
          strict: true,
          schema: {
            type: 'object',
            properties: {
              action: { type: 'string', enum: ACTIONS },
              confidence: { type: 'number' },
              reason: { type: 'string' },
            },
            required: ['action', 'confidence', 'reason'],
            additionalProperties: false,
          },
        },
      },
    }),
  });
  if (!res.ok) throw new Error(`${res.status} ${(await res.text()).slice(0, 160)}`);
  const data = await res.json();
  return JSON.parse(data.choices[0].message.content);
}

/* ── Execution — every path funnels through here ─────────────────────────── */
function runAction(action) {
  const dur = Number(vEls.dur.value);
  const s = NC.speed();
  const drive = {
    forward:    { vx:  s }, backward:  { vx: -s },
    turn_left:  { wz:  50 }, turn_right: { wz: -50 },
    raise:      { raise: 30 }, bow: { bow: 30 }, twist: { twist: 30 },
  }[action];
  if (drive) return NC.driveFor(drive, dur);

  const skill = { stand: 'stand_up', sit: 'sit_down', lie: 'lie_down',
                  wag_tail: 'wag_tail', dance: 'dance' }[action];
  if (skill) { NC.skill(skill); return true; }

  if (action === 'stop') { NC.stopAll('voice: stop'); return true; }
  NC.log('err', `[voice] "${action}" is not an action this robot has — ignored`);
  return false;
}

async function handleFinal(text) {
  if (checkStop(text)) return;                       // rail 2, already handled
  showIntent('…thinking', 'var(--dim)');

  const mode = vEls.mode.value;
  if (mode !== 'ai') {
    const kw = matchKeyword(text);
    if (kw) {
      showIntent(`keyword → ${kw.kind === 'skill' ? kw.name : JSON.stringify(kw.axes)}`, 'var(--ok)');
      if (kw.kind === 'skill') NC.skill(kw.name); else NC.driveFor(kw.axes, Number(vEls.dur.value));
      return;
    }
    if (mode === 'keyword') { showIntent('no keyword matched — ignored', 'var(--warn)'); return; }
  }

  try {
    const out = await askModel(text);
    if (!ACTIONS.includes(out.action)) {             // never trust the label blindly
      showIntent(`model returned unknown label "${out.action}" — rejected`, 'var(--bad)');
      return;
    }
    showIntent(`AI → ${out.action} (${(out.confidence ?? 0).toFixed(2)}) — ${out.reason}`,
               out.action === 'unknown' ? 'var(--warn)' : 'var(--ok)');
    if (out.action !== 'unknown') runAction(out.action);
  } catch (err) {
    showIntent(`AI failed: ${err.message}`, 'var(--bad)');
    NC.log('err', `[voice] model call failed — robot not moved. ${err.message}`);
  }
}

/* ── Speech recognition wiring ──────────────────────────────────────────── */
let rec = null, listening = false;

function setState(txt, color) { vEls.state.textContent = txt; vEls.state.style.color = color || 'var(--dim)'; }
function showIntent(txt, color) { vEls.intent.textContent = txt; vEls.intent.style.color = color || 'var(--fg)'; }

function startListening() {
  rec = new SR();
  rec.continuous = true;
  rec.interimResults = true;
  rec.lang = 'en-US';

  rec.onstart = () => { listening = true; vEls.mic.classList.add('held'); setState('listening', 'var(--ok)'); };
  rec.onerror = (e) => { setState(`error: ${e.error}`, 'var(--bad)'); NC.log('err', `[voice] ${e.error}`); };
  rec.onend = () => {
    vEls.mic.classList.remove('held');
    if (listening) { try { rec.start(); } catch { /* restarts race; ignore */ } }  // keep the mic alive
    else setState('idle');
  };

  rec.onresult = (e) => {
    let interim = '', final = '';
    for (let i = e.resultIndex; i < e.results.length; i++) {
      const r = e.results[i];
      if (r.isFinal) final += r[0].transcript; else interim += r[0].transcript;
    }
    vEls.transcript.textContent = (final || interim).trim() || '…';
    if (interim && checkStop(interim)) return;   // rail 2: fire on the partial, don't wait
    if (final.trim()) handleFinal(final);
  };

  try { rec.start(); } catch (err) { setState(`could not start: ${err.message}`, 'var(--bad)'); }
}

function stopListening() {
  listening = false;
  if (rec) rec.stop();
  vEls.mic.classList.remove('held');
  setState('idle');
  NC.stopAll('mic off');
}

vEls.mic.addEventListener('click', () => (listening ? stopListening() : startListening()));
vEls.dur.addEventListener('input', () => { vEls.durOut.textContent = vEls.dur.value + ' ms'; });
vEls.durOut.textContent = vEls.dur.value + ' ms';
showIntent('—');
setState('idle');
