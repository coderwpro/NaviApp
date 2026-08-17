# NaviApp

An iPhone app that controls a **Navi quadruped robot** directly over Bluetooth Low
Energy — and two things built on top of it for children.

Written during a four-day internship at FF Robotics.

## What's here

| | |
|---|---|
| `navi-ios/` | The iOS app — Swift, SwiftUI, CoreBluetooth. The real project. |
| `navi-web/` | The browser version built first, to verify the protocol before any app existed. |

## The app

**Control** — scan, connect, live telemetry, hold-to-drive, posture, skills, voice
commands, and diagnostics for the parts of the protocol that are still unverified.

**Word Play** — a spoken language tutor. The phone sits on the robot's back and becomes
its face: blinking eyes, and held sideways nothing else. The child picks a language and a
lesson out loud, and a correct answer makes the robot celebrate.

**Stories** — a bedtime storyteller. Ten classic fables, simplified, or a brand-new
two-minute story written on the spot about whatever the child asks for. Tone changes with
the scene, and the robot moves on every sentence.

## Building it

1. Open `navi-ios/NaviRemote.xcodeproj`
2. Copy `NaviRemote/Secrets.swift.example` to `NaviRemote/Secrets.swift` and put your own
   OpenAI key in it — `Secrets.swift` is gitignored, so no key is ever committed
3. Set your team under Signing & Capabilities, and change the bundle identifier
4. **Run on a physical iPhone.** The Simulator has no Bluetooth radio, so
   `CBCentralManager` never leaves `.unsupported` there

Requires iOS 17 or later.

## Notes on the protocol

The robot speaks an undocumented BLE protocol that was reverse-engineered and verified
against real hardware. Two things that shape the whole codebase:

- **Axes are signed bytes.** Anything above 127 is negative, so asking for speed 200
  drives the robot *backwards* — with no error on any channel. Everything is clamped.
- **The robot silently drops frames it does not understand.** No error, no log. "No
  exception was thrown" never means "it worked", so the app reads state back rather than
  trusting a call that did not fail.

The vendor SDK is not included here — it is proprietary.

## Where AI is used, and where it is not

A language model writes words: teaching lines, story text, and intent labels. It never
chooses anything physical — no speed, no axis, no duration, no byte. Every reply is
validated against a fixed list before use, and every call has a written fallback so a
child is never left with silence.
