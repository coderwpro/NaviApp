/* host.js — runs in the Mac's Chrome tab, next to app.js.
 *
 * Holds no protocol knowledge of its own. It receives commands from the relay and hands
 * them to NaviControl, which applies exactly the same clamps and time limits the keyboard
 * path uses. A phone therefore cannot ask for anything the Mac's own UI could not ask for.
 */
'use strict';

(() => {
  const NC = window.NaviControl;
  const token = new URLSearchParams(location.search).get('t');

  const chip = document.createElement('span');
  chip.className = 'chip';
  document.querySelector('header .grow').before(chip);
  const setChip = (txt, colour) => { chip.innerHTML = `<i class="dot" style="background:${colour}"></i>bridge: ${txt}`; };

  if (!token) { setChip('off (no token in URL)', 'var(--dim)'); return; }

  /* Whitelist. A command not in this table does nothing — the phone cannot invent one. */
  const HANDLERS = {
    drive: (m) => NC.driveFor(m.axes || {}, m.ms),
    skill: (m) => NC.skill(String(m.name || '')),
    stop:  (m) => NC.stopAll(`phone: ${m.reason || 'stop'}`),
    estop: () => NC.eStop(),
    recover: () => NC.recover(),
  };

  let es = null;
  function connect() {
    es = new EventSource(`/events?role=host&t=${encodeURIComponent(token)}`);
    es.onopen = () => { setChip('connected', 'var(--ok)'); NC.log('good', '[bridge] relay connected — phone can drive'); };
    es.onerror = () => { setChip('reconnecting…', 'var(--warn)'); };
    es.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      const fn = HANDLERS[msg.type];
      if (!fn) { NC.log('err', `[bridge] unknown command "${msg.type}" — ignored`); return; }
      NC.log('rx', `[bridge] ${msg.type}${msg.reason ? ' (' + msg.reason + ')' : ''}`);
      fn(msg);
    };
  }
  connect();

  /* Telemetry upstream, so the phone shows the same battery / e-stop bit the Mac does. */
  setInterval(() => {
    const body = JSON.stringify({ type: 'telemetry', ...NC.getStatus() });
    fetch(`/telemetry?t=${encodeURIComponent(token)}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
    }).catch(() => { /* relay down; the chip already shows it */ });
  }, 500);
})();
