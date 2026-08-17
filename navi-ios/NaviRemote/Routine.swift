import Foundation

/// One block in a program a child built.
///
/// The label a child sees IS the action performed — the block called `wave` sends the `wave`
/// skill and nothing else. That is not a nicety: the camera shows the screen and the robot
/// in the same frame, so a block that says one thing and does another is visibly a lie.
enum BlockAction: String, CaseIterable, Identifiable {
    // Every firmware skill, by its own name.
    case stand_up, sit_down, lie_down, wag_tail, dance, spin, crawl, bow
    case wave, stretch, shake, shake_hands, finger_heart, push_ups, be_cute, impatient
    // In-place posture moves, built from the joystick channel rather than a skill.
    case look_left, look_right, nod, stand_tall, wiggle
    // Pacing.
    case wait

    var id: String { rawValue }

    /// The child-facing label. Same words, without the underscores.
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ") }

    /// The firmware skill this block sends, if it is a skill block.
    var skill: String? { SkillCatalog.skill(rawValue) != nil ? rawValue : nil }

    var symbol: String {
        switch self {
        case .stand_up, .stand_tall: "arrow.up.circle"
        case .sit_down: "chair"
        case .lie_down: "bed.double"
        case .wag_tail: "hare"
        case .dance, .be_cute: "music.note"
        case .spin: "arrow.triangle.2.circlepath"
        case .crawl: "figure.walk"
        case .bow, .nod: "arrow.down.circle"
        case .wave, .shake_hands: "hand.wave"
        case .stretch: "arrow.up.and.down"
        case .shake, .wiggle: "waveform"
        case .finger_heart: "heart"
        case .push_ups: "figure.strengthtraining.functional"
        case .impatient: "clock"
        case .look_left: "arrow.left.circle"
        case .look_right: "arrow.right.circle"
        case .wait: "pause.circle"
        }
    }

    /// How long this block occupies the robot.
    var seconds: TimeInterval {
        if let skill { return SkillCatalog.seconds(skill) }
        switch self {
        case .wait: return 1.0
        default:    return 0.9
        }
    }

    /// Posture blocks, expressed as axes. In place — never `vx` / `vy` / `wz`.
    var axes: NaviProtocol.Axes? {
        switch self {
        case .look_left:  .init(twist: 34)
        case .look_right: .init(twist: -34)
        case .nod:        .init(bow: 26)
        case .stand_tall: .init(raise: 30)
        case .wiggle:     .init(raise: 20, twist: 26)
        default: nil
        }
    }

    /// Whether this block is safe to offer given where the robot is standing.
    ///
    /// A skill nobody has bench tested does not appear in the palette while the robot is on
    /// a table with a phone on its back. Filtering here rather than skipping at run time is
    /// deliberate: a program that silently drops a block is a program that does not match
    /// the blocks on screen.
    func isAvailable(onFloor: Bool) -> Bool {
        guard let skill else { return true }             // posture blocks are always in place
        switch SkillCatalog.verdict(skill) {
        case .tableSafe:  return true
        case .floorOnly:  return onFloor
        case .untested:   return onFloor                 // bench it before it goes on a table
        case .noResponse: return false                   // it does nothing; do not offer it
        }
    }
}

struct RoutineBlock: Identifiable, Equatable {
    var id = UUID()
    var action: BlockAction
}

/// Runs a program exactly as written.
///
/// Two rules, both from the filming requirements: the order is the child's order, and
/// running the same program twice produces the same performance. Nothing in here draws from
/// the random pools the companion and the storyteller use — that randomness is for *ambient*
/// behaviour and must never leak into something a child explicitly built.
@MainActor
final class RoutineRunner: ObservableObject {

    /// The child's program. Lives here rather than in the editor's `@State` so closing the
    /// sheet does not throw it away — the film's "change one block and run it again" beat
    /// depends on the program still being there.
    @Published var program: [RoutineBlock] = []
    @Published private(set) var runningIndex: Int?
    @Published private(set) var isRunning = false

    private unowned let ble: NaviBLE
    private var job: Task<Void, Never>?
    /// Told to yield so background wiggles do not play over a program.
    private weak var ambient: AmbientMotion?

    init(ble: NaviBLE, ambient: AmbientMotion? = nil) {
        self.ble = ble
        self.ambient = ambient
    }

    func run(_ blocks: [RoutineBlock]) {
        stop()
        guard !blocks.isEmpty, ble.motionAllowed else { return }
        isRunning = true
        job = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, block) in blocks.enumerated() {
                if Task.isCancelled { break }
                // The gate can close mid-program — e-stop, a dropped link. Stop where it is
                // rather than carrying on with the rest of the list.
                guard self.ble.motionAllowed else { break }
                self.runningIndex = index
                let seconds = self.perform(block.action)
                try? await Task.sleep(nanoseconds: UInt64((seconds + 0.25) * 1_000_000_000))
            }
            self.runningIndex = nil
            self.isRunning = false
        }
    }

    func stop() {
        job?.cancel(); job = nil
        runningIndex = nil
        isRunning = false
        ble.stopDriving(reason: "program stopped")
    }

    @discardableResult
    private func perform(_ action: BlockAction) -> TimeInterval {
        ambient?.yield(for: action.seconds + 0.3)
        if let skill = action.skill {
            let seconds = ble.sendSkill(skill)
            return seconds > 0 ? seconds : action.seconds
        }
        if let axes = action.axes {
            ble.driveForVoice(axes, seconds: action.seconds)
        }
        return action.seconds
    }
}
