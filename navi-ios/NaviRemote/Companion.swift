import Foundation
import UIKit

/// Free play: a child and the dog just spending time together.
///
/// The other three screens each have a job — a joystick, a lesson, a narration session.
/// This one has none. The child says hello, the dog waves back; they talk, they play, the
/// dog reacts. It is the mode a young child reaches for first.
///
/// The rule the whole screen is built around: **sameness is the bug.** Every reaction is
/// drawn from a large pool with a rolling no-repeat window, the face and the body move
/// together, and greeting the child twice never produces an identical performance.
@MainActor
final class Companion: NSObject, ObservableObject {

    enum Phase { case idle, waking, ready, thinking, playing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var face: FaceMood = .idle
    @Published private(set) var cue: FaceCue?
    @Published private(set) var isTalking = false
    @Published private(set) var line = ""
    @Published private(set) var heard = ""
    @Published private(set) var problem: String?
    /// What it did with the last thing it heard. On screen because "it ignored me" and
    /// "it did not hear me" look identical otherwise.
    @Published private(set) var lastRoute = ""

    private unowned let ble: NaviBLE
    private let speech: SpeechEngine
    private let listener = SpeechListener()
    private let talk = CompanionTalk()
    let ambient: AmbientMotion
    private(set) lazy var runner = RoutineRunner(ble: ble, ambient: ambient)

    private var job: Task<Void, Never>?
    private var game: Game?
    private var cueToken = 0

    // No-repeat pools. These are what stop the dog being boring within a minute.
    private var faces = NoRepeatPicker(FaceMood.allCases.filter(\.isExpressive), window: 5)
    private var greetings = NoRepeatPicker(Script.greetings, window: 3)
    private var acknowledgements = NoRepeatPicker(Script.acknowledgements, window: 4)
    private var praise = NoRepeatPicker(Script.praise, window: 4)

    init(ble: NaviBLE, speech: SpeechEngine) {
        self.ble = ble
        self.speech = speech
        self.ambient = AmbientMotion(ble: ble)
        super.init()
        listener.onPartial = { [weak self] text in self?.hearPartial(text) }
        listener.onSettled = { [weak self] text in self?.hear(text) }
    }

    // MARK: - Session

    func begin() {
        guard phase == .idle else { return }
        phase = .waking
        UIApplication.shared.isIdleTimerDisabled = true
        face = .curious
        ambient.calm = false
        ambient.quiet = false

        job = Task { @MainActor in
            guard await listener.prepare() else {
                problem = listener.problem ?? "Microphone unavailable"
                phase = .idle
                return
            }
            listener.contextualStrings = Script.rehearsedCommands + Script.gameWords
            ambient.start()
            // Prefetch the fixed lines so the opening never waits on the network. The first
            // five seconds of the film are this exact path.
            for line in Script.greetings { speech.prefetch(line, emotion: .cheerful) }
            speech.prefetch(Script.goodbye, emotion: .gentle)

            await greet()
            phase = .ready
            openEars()
        }
    }

    func stop() {
        job?.cancel(); job = nil
        game = nil
        speech.stop()
        listener.stopAll()
        runner.stop()
        ambient.stop()
        ble.stopDriving(reason: "companion ended")
        phase = .idle
        face = .idle
        cue = nil
        isTalking = false
        line = ""; heard = ""; lastRoute = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func greet() async {
        let hello = greetings.next() ?? Script.greetings[0]
        // Wave if the bench has cleared `wave`; otherwise a posture greeting, which is
        // honest rather than a button that pretends.
        react(preferring: "wave", fallback: .init(raise: 30, twist: 26), seconds: 0.8)
        flash(.happy)
        await say(hello, emotion: .cheerful, face: .cute)
    }

    // MARK: - Hearing

    /// The stop word, matched on the partial transcript. No network call, no model, and
    /// nothing awaited above this line.
    private func hearPartial(_ text: String) {
        heard = text
        if VoiceController.isStopPhrase(text) {
            runner.stop()
            ble.stopDriving(reason: "companion: stop")
            lastRoute = "STOP — matched in code, no model involved"
        }
    }

    private func hear(_ text: String) {
        guard phase == .ready || phase == .playing else { return }
        heard = text
        listener.mute()
        job?.cancel()
        job = Task { @MainActor in
            await respond(to: text)
            guard !Task.isCancelled else { return }
            openEars()
        }
    }

    private func openEars() {
        guard phase == .ready || phase == .playing else { return }
        face = .listening
        ambient.quiet = true          // still moving, but softly while the mic is open
        listener.listen()
    }

    // MARK: - Responding

    private func respond(to text: String) async {
        let lower = text.lowercased()
        ambient.quiet = false

        if VoiceController.isStopPhrase(lower) { return }

        // A game in progress owns the answer.
        if let running = game {
            await play(running, heard: lower)
            return
        }

        // 1. The rehearsed command list. On-device, no network, no cold start — this is the
        //    path that has to work first take, every take.
        if let action = Script.command(in: lower) {
            lastRoute = "command → \(action.label)"
            let seconds = perform(action)
            flash(faces.next() ?? .happy)
            await say(acknowledgements.next() ?? "Okay!", emotion: .cheerful,
                      face: .happy, after: seconds)
            return
        }

        // 2. A game.
        if let starting = Game.matching(lower) {
            lastRoute = "game → \(starting.name)"
            game = starting
            phase = .playing
            await open(starting)
            return
        }

        // 3. Anything else is conversation.
        lastRoute = "conversation"
        phase = .thinking
        face = .unsure
        let reply = await talk.reply(to: text)
        guard !Task.isCancelled else { phase = .ready; return }
        // The reply carries its own expression and movement, so a spoken answer is never
        // just a speaker talking.
        react(preferring: reply.action, fallback: .init(bow: 22, twist: 20), seconds: 0.7)
        await say(reply.speak, emotion: reply.emotion, face: reply.face)
        phase = .ready
    }

    // MARK: - Games

    /// Short back-and-forth games that need no reading at all.
    enum Game {
        case copyMe(round: Int)
        case guessMyFeeling(answer: FaceMood, round: Int)

        var name: String {
            switch self {
            case .copyMe: "copy me"
            case .guessMyFeeling: "guess my feeling"
            }
        }

        static func matching(_ text: String) -> Game? {
            let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted))
            if words.contains("copy") { return .copyMe(round: 0) }
            if words.contains("feeling") || words.contains("feelings") || words.contains("guess") {
                return .guessMyFeeling(answer: .happy, round: 0)
            }
            if words.contains("game") || words.contains("play") {
                return Bool.random() ? .copyMe(round: 0) : .guessMyFeeling(answer: .happy, round: 0)
            }
            return nil
        }
    }

    private func open(_ game: Game) async {
        switch game {
        case .copyMe:
            await say("Let's play copy me. I will do something, and you do it too. Ready?",
                      emotion: .cheerful, face: .cute)
            await copyMeRound()
        case .guessMyFeeling:
            await say("Let's play guess my feeling. Look at my eyes and tell me how I feel.",
                      emotion: .cheerful, face: .curious)
            await feelingRound(round: 0)
        }
    }

    private func play(_ game: Game, heard text: String) async {
        switch game {
        case .copyMe(let round):
            flash(.happy)
            await say(praise.next() ?? "Nicely done!", emotion: .proud, face: .proud)
            if round >= 2 {
                self.game = nil
                phase = .ready
                await say("That was fun. What shall we do now?", emotion: .cheerful, face: .cute)
            } else {
                self.game = .copyMe(round: round + 1)
                await copyMeRound()
            }

        case .guessMyFeeling(let answer, let round):
            let right = Script.names(for: answer).contains { text.contains($0) }
            if right {
                flash(.happy)
                await say("Yes! I was feeling \(Script.names(for: answer).first ?? "happy").",
                          emotion: .proud, face: .proud)
            } else {
                flash(.unsure)
                await say("Close! I was feeling \(Script.names(for: answer).first ?? "happy").",
                          emotion: .gentle, face: .cute)
            }
            if round >= 2 {
                self.game = nil
                phase = .ready
                await say("You are good at this. What next?", emotion: .cheerful, face: .cute)
            } else {
                await feelingRound(round: round + 1)
            }
        }
    }

    private func copyMeRound() async {
        // Only ever an action that is safe where the robot is actually standing.
        let action = Script.copyable.filter { $0.isAvailable(onFloor: false) }.randomElement() ?? .nod
        let seconds = perform(action)
        await say("Can you \(action.label)?", emotion: .cheerful, face: faces.next() ?? .curious,
                  after: seconds)
    }

    private func feelingRound(round: Int) async {
        // The answer is chosen here and stored, so the check afterwards is against what was
        // actually shown rather than against a guess about it.
        let mood = Script.guessableFeelings.randomElement() ?? .happy
        game = .guessMyFeeling(answer: mood, round: round)
        face = mood
        ambient.punctuate()
        await say("How do I feel now?", emotion: .cheerful, face: mood)
    }

    // MARK: - Robot

    /// Performs a block action and returns how long it occupies the robot.
    @discardableResult
    private func perform(_ action: BlockAction) -> TimeInterval {
        guard ble.motionAllowed else { return 0 }
        ambient.yield(for: action.seconds + 0.3)
        if let skill = action.skill, SkillCatalog.verdict(skill) == .tableSafe {
            return ble.sendSkill(skill)
        }
        if let axes = action.axes {
            ble.driveForVoice(axes, seconds: action.seconds)
            return action.seconds
        }
        // A skill that has not been bench tested does not fire with a phone on the robot's
        // back. Something in place happens instead, so the dog still answers.
        ble.driveForVoice(.init(raise: 24, twist: 22), seconds: 0.7)
        return 0.7
    }

    /// Prefer a named skill if the bench has cleared it, otherwise a posture move.
    private func react(preferring skill: String?, fallback: NaviProtocol.Axes, seconds: TimeInterval) {
        guard ble.motionAllowed else { return }
        if let skill, SkillCatalog.verdict(skill) == .tableSafe {
            ambient.yield(for: ble.sendSkill(skill))
            return
        }
        ambient.yield(for: seconds + 0.2)
        ble.driveForVoice(fallback, seconds: seconds)
    }

    private func flash(_ mood: FaceMood) {
        cueToken += 1
        cue = FaceCue(mood, token: cueToken)
    }

    private func say(_ text: String, emotion: Emotion, face chosen: FaceMood,
                     after delay: TimeInterval = 0) async {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(min(delay, 2.0) * 1_000_000_000)) }
        guard !Task.isCancelled else { return }
        line = text
        face = chosen
        isTalking = true
        await speech.speak(text, emotion: emotion)
        isTalking = false
    }
}

// MARK: - The rehearsed script

/// The fixed English command list, agreed in advance and rehearsed by the child.
///
/// Matching happens here, on the device, before anything is sent anywhere. That is what
/// makes the opening command of the film repeatable: no network, no model, no cold start —
/// and no dependency on a service being up on the shooting day.
enum Script {

    /// Command phrases mapped to blocks. Order matters: longer phrases are checked first so
    /// "stand tall" never matches as "stand".
    static let commands: [(phrase: String, action: BlockAction)] = [
        ("stand tall", .stand_tall), ("stand up", .stand_up), ("stand", .stand_up),
        ("sit down", .sit_down), ("sit", .sit_down),
        ("lie down", .lie_down), ("lay down", .lie_down), ("lie", .lie_down),
        ("wag your tail", .wag_tail), ("wag", .wag_tail),
        ("shake hands", .shake_hands), ("shake my hand", .shake_hands), ("shake", .shake),
        ("finger heart", .finger_heart), ("make a heart", .finger_heart),
        ("push ups", .push_ups), ("push up", .push_ups),
        ("be cute", .be_cute), ("look cute", .be_cute),
        ("dance", .dance), ("spin", .spin), ("crawl", .crawl), ("stretch", .stretch),
        ("wave", .wave), ("say hello", .wave), ("bow", .bow),
        ("look left", .look_left), ("look right", .look_right),
        ("nod", .nod), ("wiggle", .wiggle),
    ]

    static func command(in text: String) -> BlockAction? {
        commands.first { text.contains($0.phrase) }?.action
    }

    /// Fed to the recogniser as hints — the single biggest accuracy win for a child speaker
    /// at filming distance.
    static var rehearsedCommands: [String] { commands.map(\.phrase) }

    static let gameWords = ["play a game", "copy me", "guess my feeling",
                            "happy", "sad", "sleepy", "surprised", "serious", "curious"]

    /// Actions a child can copy without a screen. Kept small and legible on camera.
    static let copyable: [BlockAction] = [.nod, .look_left, .look_right, .stand_tall,
                                          .wiggle, .wag_tail, .bow, .wave]

    static let guessableFeelings: [FaceMood] = [.happy, .sad, .sleepy, .surprised, .curious, .serious]

    /// Words a child might use for a feeling. Generous on purpose — this is a game, and
    /// "tired" for sleepy is a correct answer from a five-year-old.
    static func names(for mood: FaceMood) -> [String] {
        switch mood {
        case .happy:     ["happy", "glad", "excited", "smiling"]
        case .sad:       ["sad", "upset", "unhappy"]
        case .sleepy:    ["sleepy", "tired", "sleeping"]
        case .surprised: ["surprised", "shocked", "wow"]
        case .curious:   ["curious", "wondering", "confused"]
        case .serious:   ["serious", "cross", "angry", "grumpy"]
        default:         ["happy"]
        }
    }

    static let greetings = [
        "Hi! I'm Navi. I'm so happy to see you.",
        "Hello there! Shall we play?",
        "Hey! You're back. I was waiting for you.",
        "Hi! Tell me to do something, or just talk to me.",
    ]

    static let acknowledgements = [
        "Okay!", "On it!", "Here I go!", "Watch this!", "Sure thing!", "Like this?",
    ]

    static let praise = [
        "Nicely done!", "You did it!", "That was great!", "You're good at this!",
        "Brilliant!", "Look at you go!",
    ]

    static let goodbye = "Bye for now. Come back soon."
}

extension FaceMood {
    /// Faces worth flashing as a reaction. Excludes the plumbing states.
    var isExpressive: Bool {
        switch self {
        case .idle, .neutral, .listening, .speaking, .blink: false
        default: true
        }
    }
}
