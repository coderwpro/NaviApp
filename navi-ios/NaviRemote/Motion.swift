import Foundation

// MARK: - Firmware skills

/// What a bench test found when the skill was actually run on the robot.
///
/// Nothing here is inferred from a name. `spin` sounds harmless and may well walk the robot
/// off a table; `be_cute` sounds harmless and nobody has ever seen it. Until somebody runs it
/// with the robot on a table and watches, the honest answer is `untested`.
enum SkillVerdict: String, CaseIterable, Identifiable {
    case untested       // never run on this hardware
    case tableSafe      // stays in place, small footprint — safe with the phone on its back
    case floorOnly      // translates or needs floor space
    case noResponse     // the firmware accepted the name but nothing moved

    var id: String { rawValue }

    var label: String {
        switch self {
        case .untested:   "untested"
        case .tableSafe:  "table-safe"
        case .floorOnly:  "floor only"
        case .noResponse: "no response"
        }
    }
}

struct RobotSkill: Identifiable {
    let name: String
    /// Roughly how long the animation runs. The joystick channel is ignored while a skill
    /// plays, so the scheduler has to wait this out rather than write over it.
    let seconds: TimeInterval
    /// What we believe before anyone tests it. Only the five already seen on hardware are
    /// anything other than `.untested`.
    let expected: SkillVerdict
    /// May join the storytelling ambient pool *once it tests table-safe*. False for the ones
    /// that are the wrong register for background movement even if they are safe.
    let ambientCandidate: Bool
    let note: String

    var id: String { name }
}

/// The complete `send_skill` vocabulary, and where each entry is allowed to be used.
///
/// `NaviBLE.sendSkill` refuses anything outside this list, so this list is the gate. All
/// sixteen firmware names are present; what varies is the verdict, and a verdict only
/// changes when somebody runs the skill on the bench and records what happened.
enum SkillCatalog {

    static let all: [RobotSkill] = [
        RobotSkill(name: "stand_up", seconds: 1.6, expected: .tableSafe, ambientCandidate: false,
                   note: "Confirmed on hardware. A whole-posture change — a scripted move, not background movement."),
        RobotSkill(name: "sit_down", seconds: 1.6, expected: .tableSafe, ambientCandidate: false,
                   note: "Confirmed on hardware. Scripted only."),
        RobotSkill(name: "lie_down", seconds: 1.8, expected: .tableSafe, ambientCandidate: false,
                   note: "Confirmed on hardware. Used to end a story."),
        RobotSkill(name: "wag_tail", seconds: 1.4, expected: .tableSafe, ambientCandidate: true,
                   note: "Confirmed on hardware and confirmed in place. The only skill in the ambient pool by default."),
        RobotSkill(name: "dance", seconds: 3.0, expected: .untested, ambientCandidate: true,
                   note: "Confirmed to run, but nobody has checked whether it stays in place."),
        RobotSkill(name: "spin", seconds: 2.5, expected: .untested, ambientCandidate: false,
                   note: "Almost certainly rotates on the spot at best. Bench first."),
        RobotSkill(name: "crawl", seconds: 3.0, expected: .untested, ambientCandidate: false,
                   note: "Locomotion by name. Expect floor-only."),
        RobotSkill(name: "bow", seconds: 1.6, expected: .untested, ambientCandidate: true,
                   note: "Plausibly in place. Would be a good storytelling gesture."),
        RobotSkill(name: "wave", seconds: 2.0, expected: .untested, ambientCandidate: true,
                   note: "The Companion tab's headline gesture. Needs a bench check before filming."),
        RobotSkill(name: "stretch", seconds: 2.6, expected: .untested, ambientCandidate: false,
                   note: "May extend well past the robot's footprint. Bench first."),
        RobotSkill(name: "shake", seconds: 1.8, expected: .untested, ambientCandidate: true,
                   note: "Whole-body shake — check it does not walk itself sideways."),
        RobotSkill(name: "shake_hands", seconds: 2.2, expected: .untested, ambientCandidate: true,
                   note: "Lifts a front leg. Check the centre of mass with a phone on the back."),
        RobotSkill(name: "finger_heart", seconds: 2.2, expected: .untested, ambientCandidate: true,
                   note: "Expressive, likely in place."),
        RobotSkill(name: "push_ups", seconds: 3.2, expected: .untested, ambientCandidate: false,
                   note: "Large vertical travel. Bench with nothing on the back first."),
        RobotSkill(name: "be_cute", seconds: 2.4, expected: .untested, ambientCandidate: true,
                   note: "Idle-style animation — exactly what a storyteller wants, if it is in place."),
        RobotSkill(name: "impatient", seconds: 2.0, expected: .untested, ambientCandidate: true,
                   note: "Idle-style animation. Same check as be_cute."),
    ]

    static let names: [String] = all.map(\.name)

    static func skill(_ name: String) -> RobotSkill? {
        all.first { $0.name == name }
    }

    static func seconds(_ name: String) -> TimeInterval {
        skill(name)?.seconds ?? 1.5
    }

    // MARK: Bench verdicts

    private static let defaultsKey = "navi.skillVerdicts"

    /// What the bench found, falling back to what we believed before it ran.
    static func verdict(_ name: String) -> SkillVerdict {
        if let stored = stored[name], let verdict = SkillVerdict(rawValue: stored) { return verdict }
        return skill(name)?.expected ?? .untested
    }

    static func record(_ verdict: SkillVerdict, for name: String) {
        var table = stored
        table[name] = verdict.rawValue
        UserDefaults.standard.set(table, forKey: defaultsKey)
    }

    static func clearVerdicts() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static var stored: [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// Where the robot is standing. A property of the physical situation, not of a screen,
    /// so the block palette and the companion's command list agree about it rather than
    /// each keeping their own idea.
    ///
    /// Off — on a table with the phone on its back — means no walking, no turning, and no
    /// skill that has not been bench tested.
    static var onFloor: Bool {
        get { UserDefaults.standard.bool(forKey: "navi.onFloor") }
        set { UserDefaults.standard.set(newValue, forKey: "navi.onFloor") }
    }

    /// Skills the ambient engine may use: candidates that have actually tested table-safe.
    /// Before anyone benches anything this is just `wag_tail`, which is the honest answer.
    static var ambientPool: [RobotSkill] {
        all.filter { $0.ambientCandidate && verdict($0.name) == .tableSafe }
    }

    /// Skills the Companion may use as a reaction: anything that stays in place, plus the
    /// posture changes. Floor-only and untested names never fire with a phone on the back.
    static var expressivePool: [RobotSkill] {
        all.filter { verdict($0.name) == .tableSafe }
    }

    /// A plain-text record of the bench, for pasting into the issue.
    static var report: String {
        all.map { "\($0.name.padding(toLength: 14, withPad: " ", startingAt: 0))  \(verdict($0.name).label)" }
            .joined(separator: "\n")
    }
}

// MARK: - Posture gestures

/// One held posture. `raise` / `bow` / `twist` only — never `vx` / `vy` / `wz`, because the
/// phone is riding on the robot's back and the robot is on a table.
struct GestureStep {
    let axes: NaviProtocol.Axes
    let seconds: TimeInterval
}

struct Gesture: Identifiable {
    let id: String
    let name: String
    /// 0.6 / 0.8 / 1.0 of the proven amplitude. The soft pool is the 0.6 tier.
    let amplitude: Double
    let steps: [GestureStep]

    var seconds: TimeInterval { steps.reduce(0) { $0 + $1.seconds } }
}

/// The parameterised posture space that replaced ten hard-coded tuples.
///
/// A shape (what the body does), an amplitude (how far) and a tempo (how fast) multiply out
/// to ninety visibly different gestures without a single new protocol call. The ceilings are
/// the amplitudes already proven on this hardware — raise 30, bow 26, twist 34. Anything
/// larger needs a bench check, so nothing here exceeds them.
enum GesturePool {

    private static let raiseMax = 30
    private static let bowMax   = 26
    private static let twistMax = 34

    /// Fractions of each axis maximum, one triple per step: (raise, bow, twist).
    private static let shapes: [(name: String, steps: [(Double, Double, Double)])] = [
        ("look left",      [(0, 0, 1.0)]),
        ("look right",     [(0, 0, -1.0)]),
        ("nod",            [(0, 1.0, 0)]),
        ("stretch up",     [(1.0, 0, 0)]),
        ("lean left",      [(0.7, 0, 0.8)]),
        ("lean right",     [(0.7, 0, -0.8)]),
        ("dip left",       [(0, 0.7, 0.7)]),
        ("dip right",      [(0, 0.7, -0.7)]),
        ("sway",           [(0.75, 0.5, 0)]),
        ("head tilt",      [(0.5, 0.4, 0.9)]),
        ("peek",           [(0.4, 0, -0.9)]),
        ("look about",     [(0, 0, 0.9), (0, 0, -0.9)]),
        ("double nod",     [(0, 0.9, 0), (0, 0.6, 0)]),
        ("rise and dip",   [(1.0, 0, 0), (0, 0.8, 0)]),
        ("shimmy",         [(0, 0, 0.6), (0, 0, -0.6), (0, 0, 0.5)]),
        ("settle",         [(0.6, 0, 0.5), (0, 0.5, -0.4)]),
    ]

    private static let amplitudes: [(name: String, scale: Double)] = [
        ("small", 0.6), ("wide", 0.8), ("full", 1.0),
    ]

    private static let tempos: [(name: String, seconds: TimeInterval)] = [
        ("quick", 0.35), ("easy", 0.65), ("slow", 0.95),
    ]

    /// Every gesture the robot has. Built once.
    static let all: [Gesture] = {
        var built: [Gesture] = []
        for shape in shapes {
            for amplitude in amplitudes {
                for tempo in tempos {
                    let steps = shape.steps.map { triple in
                        GestureStep(
                            axes: .init(raise: posture(triple.0 * amplitude.scale, max: raiseMax),
                                        bow:   posture(triple.1 * amplitude.scale, max: bowMax),
                                        twist: posture(triple.2 * amplitude.scale, max: twistMax)),
                            seconds: tempo.seconds)
                    }
                    built.append(Gesture(id: "\(shape.name)-\(amplitude.name)-\(tempo.name)",
                                         name: "\(shape.name) · \(amplitude.name) · \(tempo.name)",
                                         amplitude: amplitude.scale,
                                         steps: steps))
                }
            }
        }
        return built
    }()

    /// The quiet tier: small amplitude only. Used for the wind-down and while the
    /// microphone is open.
    static let soft: [Gesture] = all.filter { $0.amplitude <= 0.61 }

    /// A fraction of an axis maximum, honouring the floor below which the robot does
    /// nothing at all. 0.6 × 0.6 × 34 is 12, and 12 is a gesture that never happens.
    private static func posture(_ fraction: Double, max limit: Int) -> Int {
        guard abs(fraction) > 0.001 else { return 0 }
        let magnitude = min(Swift.max(Int((abs(fraction) * Double(limit)).rounded()),
                                      NaviProtocol.postureMinimum), limit)
        return fraction < 0 ? -magnitude : magnitude
    }
}

// MARK: - No-repeat picking

/// Random draw that will not repeat anything inside a rolling window.
///
/// A plain `randomElement()` produces runs, and a "not the same as last time" check still
/// allows A, B, A, B forever — which is exactly what made the old ten-move pool look
/// mechanical within one story.
struct NoRepeatPicker<Element> {
    private let items: [Element]
    private let window: Int
    private var recent: [Int] = []

    init(_ items: [Element], window: Int = 5) {
        self.items = items
        // A window as large as the pool would exclude everything.
        self.window = min(window, max(items.count - 1, 0))
    }

    var isEmpty: Bool { items.isEmpty }

    mutating func next() -> Element? {
        guard !items.isEmpty else { return nil }
        let allowed = items.indices.filter { !recent.contains($0) }
        guard let pick = (allowed.isEmpty ? Array(items.indices) : allowed).randomElement() else { return nil }
        recent.append(pick)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        return items[pick]
    }
}

// MARK: - Ambient motion

/// Keeps the robot moving for as long as a session is open.
///
/// The old behaviour was one movement per story beat and stillness in between — during
/// speech, while waiting for an answer, while a story was being written. A still robot reads
/// as a disconnected robot. This runs on its own clock instead: gesture, varied gap, gesture,
/// independent of what the narration is doing.
///
/// Everything it sends is in place. `vx` / `vy` / `wz` are never touched, so it cannot walk
/// the robot off a table however long it runs.
@MainActor
final class AmbientMotion {

    /// Wind-down: the calm beats a child falls asleep to. Still moving, but only from the
    /// small-amplitude tier and with long gaps.
    var calm = false
    /// The microphone is open. Keep moving so the robot does not look switched off, but
    /// softly — servo noise while a child is answering costs recognition accuracy.
    var quiet = false

    /// Rolling record of what was played, newest last. Exists so the no-repeat rule can be
    /// checked against a real session rather than asserted.
    private(set) var recent: [String] = []

    private unowned let ble: NaviBLE
    private var loop: Task<Void, Never>?
    private var full = NoRepeatPicker(GesturePool.all)
    private var soft = NoRepeatPicker(GesturePool.soft)
    private var skills = NoRepeatPicker(SkillCatalog.ambientPool, window: 2)
    /// Nothing is written while a scripted action or a skill animation owns the body.
    private var busyUntil = Date.distantPast
    /// `punctuate()` runs off the loop's clock, so without this the two can start a gesture
    /// in the same instant and interleave posture frames.
    private var isPlaying = false

    init(ble: NaviBLE) { self.ble = ble }

    var isRunning: Bool { loop != nil }

    func start() {
        guard loop == nil else { return }
        skills = NoRepeatPicker(SkillCatalog.ambientPool, window: 2)   // bench verdicts may have changed
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.busyUntil.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                // The gate can close under us — e-stop, a dropped link, a tab switch. Stop
                // writing immediately and keep checking, rather than dying.
                guard self.ble.motionAllowed else {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                await self.playOne()
                let gap = self.calm ? Double.random(in: 1.4...2.6)
                        : self.quiet ? Double.random(in: 0.9...1.8)
                        : Double.random(in: 0.35...1.2)
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        busyUntil = .distantPast
    }

    /// A scripted action owns the body for this long. The ambient stream yields rather than
    /// writing a posture frame on top of a running animation.
    func yield(for seconds: TimeInterval) {
        busyUntil = max(busyUntil, Date().addingTimeInterval(seconds))
    }

    /// Move *now*, so a movement lands on the same instant as a new beat and a new
    /// expression. Does nothing if something already owns the body.
    func punctuate() {
        guard loop != nil, !isPlaying, busyUntil < Date(), ble.motionAllowed else { return }
        Task { @MainActor in await playOne() }
    }

    private func playOne() async {
        guard !isPlaying else { return }
        isPlaying = true
        defer { isPlaying = false }

        // Occasionally a real skill instead of a posture gesture — but only ones a bench
        // test has actually cleared as table-safe.
        if !skills.isEmpty, Int.random(in: 0..<7) == 0, !calm, !quiet,
           let skill = skills.next() {
            let seconds = ble.sendSkill(skill.name)
            note(skill.name)
            busyUntil = Date().addingTimeInterval(seconds)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return
        }

        let gesture = (calm || quiet) ? soft.next() : full.next()
        guard let gesture else { return }
        busyUntil = Date().addingTimeInterval(gesture.seconds + 0.1)
        note(gesture.name)
        for step in gesture.steps {
            guard ble.motionAllowed, !Task.isCancelled else { return }
            ble.driveForVoice(step.axes, seconds: step.seconds)
            try? await Task.sleep(nanoseconds: UInt64((step.seconds + 0.05) * 1_000_000_000))
        }
    }

    private func note(_ name: String) {
        recent.append(name)
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
    }
}
