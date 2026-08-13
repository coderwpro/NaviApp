# Navi BLE web remote — Day 1

Two files, no backend, no build step: `index.html` + `app.js`.

## Run

```bash
cd navi-web
python3 -m http.server 8000
```

Open **http://localhost:8000** in **Chrome or Edge**. Not `file://` — Web Bluetooth needs a
secure context, and the page tells you so in section 1 if you get it wrong.

## Order of work (don't shuffle this)

1. **No robot needed** — "List every BLE device nearby" opens Chrome's own chooser. Devices
   appear ⇒ your Web Bluetooth path works. Section 3 also runs the frame-encoder self-test
   against the frames the cheat sheet verified on hardware.
2. **Connect** → watch section 4. Battery should start ticking at ~5 Hz.
3. **E-stop** → the e-stop bit flips 0 → 1. **recover** → 1 → 0. That is your proof that
   commands land.
4. **Only then drive.** Tick the three safety boxes, then hold the arrow keys.

Driving stays locked until you are connected, the safety boxes are ticked, *and* a status
frame has arrived. If a unit genuinely never sends status, there's an explicit override
checkbox — but tick it knowing you're driving blind.

## Controls

| | |
|---|---|
| Arrow keys / on-screen pad | drive (held, not toggled — release sends the zero frame) |
| `Space` | e-stop — jumps ahead of every queued write |
| `Esc` | zero all axes |

## What's enforced in code rather than trusted to the operator

- Every axis clamped to ±127. Signed bytes: 200 would be read as −56 and the robot walks
  backwards with no error anywhere. There is no 0–255 slider in this UI on purpose.
- Posture bytes floored at 17 — below that they do nothing at all.
- 20 Hz repeat while held (matches `ble_smoke.py`), zero frame ×3 on release — the joystick
  channel never acks, so a single stop frame is not good enough.
- 3 s hold watchdog; `blur` / tab-hide / page-close all zero the axes. Alt-tabbing mid-hold
  can't leave the robot driving.
- One GATT write in flight at a time. Commands queue FIFO, the joystick keeps only its
  newest frame, e-stop clears the pending joystick and jumps the queue.
- `action_id` is displayed, never gated on — a healthy unit reports `625`.

## Known, not bugs here

- 30–40% of connection attempts fail; sessions drop mid-run. Use Retry.
- After a skill, the firmware can stay in animation mode and silently ignore the joystick.
  Drive first, skills last. The page shows a banner once a skill has been sent.
- `motion_flag` not flipping proves nothing — it's only trustworthy in the "flipped ⇒
  accepted" direction.

Protocol source of truth: `../william_navi_task_and_schedule_en/William_navi_ble_web_cheatsheet_EN.md` §4.
Nothing here was invented.
