import Foundation

/// Wire protocol for the Navi quadruped over BLE.
///
/// Every value here is transcribed from the hardware-verified tables in
/// `William_navi_ble_web_cheatsheet_EN.md` §4 and cross-checked against the compiled
/// constants in `ff_sdk 0.1.0a7` (`internal/oem/navi/ble_protocol`). Nothing is guessed.
/// Pure value types with no CoreBluetooth import, so the frame maths can be unit-tested
/// and read without a robot present.
enum NaviProtocol {

    // MARK: - GATT addresses

    static let serviceUUID  = "12345678-1234-5678-1234-56789ABC0000"
    static let charCommand  = "12345678-1234-5678-1234-56789ABC0001"  // text, robot replies on EVENT
    static let charJoystick = "12345678-1234-5678-1234-56789ABC0002"  // 8 raw bytes, no reply
    static let charEvent    = "12345678-1234-5678-1234-56789ABC0003"  // notify: status pushed

    /// Advertised names look like `NAVI-FA-32-006`. Many units do not put the service UUID
    /// in the advertisement, so scanning filters on the name, not the service.
    static let namePrefix = "NAVI"

    // MARK: - Limits

    /// Axes are SIGNED bytes. 128...255 are negative, so 200 is read as -56 and the robot
    /// reverses with no error on any channel. The clamp is the whole safety story.
    static let axisLimit: Int = 127

    /// raise / bow / twist do nothing at all below this.
    static let postureMinimum: Int = 17

    static let frameHeader: UInt8 = 0xAA
    static let frameLength: Int = 8      // exactly 8. 16 was silently discarded for two test rounds.

    /// The stick is held, not set — frames repeat at 20 Hz while a control is down.
    static let tickInterval: TimeInterval = 0.05

    /// Backstop for a hold whose release never arrives — a lost touch, a crashed view.
    /// Deliberately long: this is NOT meant to limit legitimate driving, only to stop the
    /// robot eventually if the release event is never delivered. Lifting your finger stops
    /// it immediately regardless, and so does leaving the app.
    static let maxHold: TimeInterval = 30.0

    /// Voice-initiated motion is capped harder still. Rail 1: a spoken command may never
    /// start motion with no end condition.
    static let maxVoiceMotion: TimeInterval = 2.0

    // MARK: - Commands

    enum Verb: String {
        case eStop   = "cmd|estop"      // latching
        case recover = "cmd|recover"
        case start   = "cmd|start"
        case stop    = "cmd|stop"
    }

    /// Every `send_skill` name the firmware accepts. `send_skill` is the only JSON command
    /// that exists, and it takes a NAME — a numeric id silently does nothing, with no motion
    /// and no error.
    ///
    /// The list is the allow-list `NaviBLE.sendSkill` enforces; where each name may be USED
    /// is a separate question, answered by `SkillCatalog` and its bench verdicts.
    static var skills: [String] { SkillCatalog.names }

    static func commandData(_ verb: Verb) -> Data {
        Data(verb.rawValue.utf8)
    }

    static func skillData(named name: String) -> Data {
        let payload: [String: Any] = [
            "id": 1,
            "cmd": "send_skill",
            "params": ["skill_name": name],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    // MARK: - Joystick frame

    struct Axes: Equatable {
        var vx = 0      // forward / back
        var vy = 0      // lateral or turn — UNCONFIRMED, see cheat sheet §5.2
        var wz = 0      // turn
        var raise = 0
        var bow = 0
        var twist = 0

        static let zero = Axes()
        var isMoving: Bool { self != .zero }
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, -axisLimit), axisLimit)
    }

    /// byte:  0     1    2    3    4      5     6      7
    ///       0xAA  vx   vy   wz  raise  bow  twist  checksum      checksum = sum(1...6) & 0xFF
    static func joystickFrame(_ axes: Axes) -> Data {
        let values = [axes.vx, axes.vy, axes.wz, axes.raise, axes.bow, axes.twist].map(clamp)
        var frame = [UInt8](repeating: 0, count: frameLength)
        frame[0] = frameHeader
        var sum: Int = 0
        for (index, value) in values.enumerated() {
            let byte = UInt8(bitPattern: Int8(value))   // -30 -> 0xE2
            frame[index + 1] = byte
            sum += Int(byte)
        }
        frame[7] = UInt8(sum & 0xFF)
        return Data(frame)
    }

    static let zeroFrame = joystickFrame(.zero)

    // MARK: - Incoming frames

    struct Status: Equatable {
        var battery: Int
        var eStopLatched: Bool
        /// Inverted relative to its name: the wire sends 1 for idle, 0 for busy.
        var isIdle: Bool
        /// Displayed, never gated on. One healthy unit reports 625.
        var actionID: String
    }

    enum Frame: Equatable {
        case status(Status)
        case temperature([Int])
        case charging(Bool)
        case error(code: String, message: String)
        case unrecognised(String)
    }

    static func parse(_ line: String) -> Frame {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard let kind = parts.first else { return .unrecognised(line) }

        switch kind {
        case "s" where parts.count >= 5:
            return .status(Status(battery: Int(parts[1]) ?? 0,
                                  eStopLatched: parts[2] == "1",
                                  isIdle: parts[3] == "1",
                                  actionID: parts[4]))
        case "t":
            return .temperature(parts.dropFirst().compactMap { Int($0) })
        case "c" where parts.count >= 2:
            return .charging(parts[1] == "1")
        case "e" where parts.count >= 3:
            let decoded = Data(base64Encoded: parts[2]).flatMap { String(data: $0, encoding: .utf8) }
            return .error(code: parts[1], message: decoded ?? parts[2])
        default:
            return .unrecognised(line)
        }
    }
}
