# Navi Remote — native iOS app

Direct BLE from the iPhone to the robot. **No Mac, no relay, no web page** — CoreBluetooth
talks to the same GATT service the web version used.

Type-checks clean against the iOS 26.5 SDK (Xcode 26.6).

## Files

| | |
|---|---|
| `NaviProtocol.swift` | Frames, limits, parsing. No CoreBluetooth import — pure logic, readable without a robot. |
| `NaviBLE.swift` | Scan, connect, notifications, the 20 Hz drive loop, every safety limit. |
| `VoiceController.swift` | `SFSpeechRecognizer` capture + intent routing. Rail 2 lives here. |
| `IntentClassifier.swift` | OpenAI call. Returns a label from a fixed list, nothing else. |
| `ContentView.swift` | The whole UI, and `@main`. |

## Build it (about 5 minutes)

1. **Xcode → File → New → Project → iOS → App.**
   Product Name `NaviRemote`, Interface **SwiftUI**, Language **Swift**, Storage **None**.

2. **Delete the two files the template generates** — `ContentView.swift` and
   `NaviRemoteApp.swift` (Move to Trash). Mine already contains `@main`; leaving the
   template's copy gives you *"'main' attribute can only apply to one type"*.

3. **Drag all five `.swift` files** from this folder into the project navigator.
   Tick **Copy items if needed** and make sure the app target is checked.

4. **Set the deployment target to iOS 17.0 or later** (target → General → Minimum
   Deployments). `AVAudioApplication.requestRecordPermission` needs it.

5. **Add three permission strings.** Target → **Info** tab → hover a row → `+`:

   | Key | Suggested value |
   |---|---|
   | `NSBluetoothAlwaysUsageDescription` | Connects to the Navi robot over Bluetooth. |
   | `NSMicrophoneUsageDescription` | Listens for spoken movement commands. |
   | `NSSpeechRecognitionUsageDescription` | Turns speech into robot commands. |

   Miss any one and the app dies the instant that feature is touched, with no useful message.

6. **Signing.** Xcode → Settings → Accounts → add your Apple ID. Then target → Signing &
   Capabilities → check *Automatically manage signing* → pick your name as Team. If the
   bundle identifier is rejected, change it to something unique
   (`com.<yourname>.naviremote`).

7. **Plug the iPhone in with a cable**, unlock it, tap **Trust**. Pick it as the run
   destination — *not* a simulator.

   > **The Simulator has no Bluetooth.** `CBCentralManager` sits in `.unsupported` there
   > forever. The app will tell you so, but it can never connect. A physical device is
   > mandatory.

8. **⌘R.** First run only: on the iPhone go to Settings → General → VPN & Device
   Management → your Apple ID → **Trust**. Then launch it again.

With a free Apple ID the build expires after **7 days** — re-run from Xcode to refresh.
A paid Developer Program account ($99/yr) gives a year, and is also the only way to use
TestFlight. You do not need TestFlight to demo this.

## Using it

1. **Scan & connect.** Refuses to connect if it sees more than one Navi — this link has no
   authentication, so two candidates means finding out what else is powered on first.
2. **Watch the battery tick** before anything else.
3. **Tick the safety toggle** — one Navi within 30 m, someone else on the physical remote,
   robot elevated. Driving stays locked until that *and* a status frame has arrived.
4. **Hold** an arrow to move. Release to stop.
5. **Talk** last. Say "go forward" to move, "stop" to stop.

## What's enforced in code, not left to the operator or the model

- Axes clamped to ±127. Above that the byte is negative and the robot reverses silently —
  there is no UI control anywhere that can send 128 or more.
- Posture values below 17 do nothing; the presets start at 30.
- 20 Hz repeat while held, zero frame ×3 on release — the joystick channel never acks, so
  one stop frame is not enough.
- 3 s hold watchdog; voice motion capped at 2 s independently.
- `action_id` is displayed, never gated on.
- The model returns only a label from `NaviAction`, validated on the way back. Speeds,
  durations and axes are built in `VoiceController` and clamped by `NaviBLE`.
- "Stop" is matched against the **partial** transcript, synchronously, before any network
  call. It never crosses an `await`.

## Known, not bugs

- ~30–40% of connection attempts fail. Retry.
- After a skill the firmware can stay in animation mode and ignore the joystick. Drive
  first, skills last.
- `motion_flag` is only trustworthy one way — flipping to busy means accepted; not
  flipping proves nothing.

Protocol source: `William_navi_ble_web_cheatsheet_EN.md` §4, cross-checked against
`ff_sdk 0.1.0a7`. Nothing here was invented.
