import Foundation
import Speech
import AVFoundation

/// On-device speech capture plus intent routing.
///
/// Rail 2 lives here: "stop" is matched against the *partial* transcript, synchronously,
/// before any network call and before any model is consulted. Stopping cannot wait for
/// latency, so it never crosses an await.
@MainActor
final class VoiceController: ObservableObject {

    enum Route: String, CaseIterable, Identifiable {
        case both = "keyword, AI fallback"
        case keyword = "keyword only"
        case ai = "AI only"
        var id: String { rawValue }
    }

    @Published private(set) var isListening = false
    @Published private(set) var heard = ""
    @Published private(set) var intent = "—"
    @Published private(set) var intentIsGood = true
    @Published var route: Route = .both
    @Published var model = Secrets.defaultModel
    @Published var motionSeconds: Double = 1.0

    private let recogniser = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// A running multi-step instruction. Always cancellable — a queued list of moves that
    /// could not be interrupted would make the stop word meaningless.
    private var sequence: Task<Void, Never>?

    private unowned let ble: NaviBLE
    private let classifier = IntentClassifier()

    init(ble: NaviBLE) { self.ble = ble }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { setIntent("speech permission denied", good: false); return false }

        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard mic else { setIntent("microphone permission denied", good: false); return false }
        return true
    }

    // MARK: - Capture

    func start() async {
        guard !isListening else { return }
        guard await requestPermissions() else { return }
        guard let recogniser, recogniser.isAvailable else {
            setIntent("recogniser unavailable — needs internet", good: false); return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true
            heard = ""

            task = recogniser.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.heard = text
                        // Rail 2: act on the partial. No await above this line.
                        if Self.isStopPhrase(text) {
                            self.stopSequence()
                            self.ble.stopDriving(reason: "voice: stop")
                            self.setIntent("STOP — matched in code, no model involved", good: false)
                            return
                        }
                        if result.isFinal {
                            self.task = nil
                            let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if final.isEmpty {
                                self.setIntent("nothing heard — speak, then stop the mic", good: false)
                            } else {
                                self.route(final)
                            }
                        }
                    }
                    if error != nil { self.stop() }
                }
            }
        } catch {
            setIntent("mic failed: \(error.localizedDescription)", good: false)
            stop()
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // endAudio() lets the recogniser finish and deliver its final transcript.
        // Do NOT cancel the task here: cancel() throws that transcript away, and the
        // handler then receives an empty final result — which is how "" ended up being
        // sent to the classifier.
        request?.endAudio()
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stopSequence()
        ble.stopDriving(reason: "mic released")
    }

    // MARK: - Intent

    static func isStopPhrase(_ text: String) -> Bool {
        let words = ["stop", "halt", "freeze", "whoa", "stay", "abort", "cancel", "emergency"]
        let lower = text.lowercased()
        return words.contains { lower.contains($0) }
    }

    private static let keywords: [(String, NaviAction)] = [
        ("forward", .forward), ("ahead", .forward), ("walk", .forward), ("go", .forward),
        ("back", .backward), ("reverse", .backward),
        ("left", .turnLeft), ("right", .turnRight),
        ("stand", .stand), ("sit", .sit), ("lie", .lie), ("lay", .lie),
        ("wag", .wagTail), ("tail", .wagTail), ("dance", .dance),
        ("bow", .bow), ("twist", .twist), ("wiggle", .twist), ("raise", .raise), ("lift", .raise),
        // The rest of the firmware skills. Longer phrases first, so "shake hands" is never
        // swallowed by "shake".
        ("shake hands", .shakeHands), ("shake your paw", .shakeHands), ("paw", .shakeHands),
        ("finger heart", .fingerHeart), ("heart", .fingerHeart),
        ("push up", .pushUps), ("press up", .pushUps),
        ("be cute", .beCute), ("cute", .beCute),
        ("impatient", .impatient), ("stretch", .stretch), ("shake", .shake),
        ("spin", .spin), ("crawl", .crawl), ("wave", .wave), ("hello", .wave),
    ]

    private func route(_ text: String) {
        // Belt and braces: never spend an API call on silence, whatever produced it.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setIntent("nothing heard", good: false)
            return
        }
        if Self.isStopPhrase(text) {
            stopSequence()
            ble.stopDriving(reason: "voice: stop")
            setIntent("STOP — matched in code", good: false)
            return
        }

        if route != .ai {
            let lower = text.lowercased()
            if let hit = Self.keywords.first(where: { lower.contains($0.0) }) {
                setIntent("keyword → \(hit.1.rawValue)", good: true)
                perform(VoiceCommand(action: hit.1, effort: .normal, seconds: motionSeconds))
                return
            }
            if route == .keyword { setIntent("no keyword matched — ignored", good: false); return }
        }

        setIntent("…thinking", good: true)
        Task {
            do {
                let (commands, reason) = try await classifier.classify(text, key: Secrets.openAIKey, model: model)
                let usable = commands.filter { $0.action != .unknown }
                guard !usable.isEmpty else {
                    // Show what it heard AND why it declined — "unknown" on its own tells
                    // you nothing about whether the problem is the mic, the words, or the prompt.
                    setIntent("AI → unknown for \"\(text)\" — \(reason)", good: false); return
                }
                let summary = usable.map(\.action.rawValue).joined(separator: " → ")
                setIntent("AI → \(summary) — \(reason)", good: true)
                run(usable)
            } catch {
                setIntent("AI failed: \(error.localizedDescription) — robot not moved", good: false)
            }
        }
    }

    /// Runs a sequence one command at a time. Cancellable, because a queued list of moves
    /// that cannot be interrupted would defeat the point of the stop word.
    private func run(_ commands: [VoiceCommand]) {
        sequence?.cancel()
        sequence = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, command) in commands.enumerated() {
                if Task.isCancelled { return }
                if commands.count > 1 {
                    self.setIntent("running \(index + 1)/\(commands.count): \(command.action.rawValue)", good: true)
                }
                let seconds = self.perform(command)
                // Wait out the move plus a beat, so the next one starts from a stop.
                try? await Task.sleep(nanoseconds: UInt64((seconds + 0.35) * 1_000_000_000))
            }
        }
    }

    /// The model returns a label, a word for effort and a requested duration. The axes and
    /// the byte values are built HERE and clamped by NaviBLE — a model never chooses a byte.
    /// Returns how long the caller should wait before the next command in a sequence.
    @discardableResult
    private func perform(_ command: VoiceCommand) -> Double {
        // The slider is the ceiling; "gentle" may go below it but nothing goes above.
        let speed = min(command.effort.speed, ble.driveSpeed)
        let turn = min(command.effort.speed, ble.turnRate)
        let seconds = min(max(command.seconds, 0.25), NaviProtocol.maxVoiceMotion)

        switch command.action {
        case .forward:   ble.driveForVoice(.init(vx: speed), seconds: seconds)
        case .backward:  ble.driveForVoice(.init(vx: -speed), seconds: seconds)
        case .turnLeft:  ble.driveForVoice(.init(wz: turn), seconds: seconds)
        case .turnRight: ble.driveForVoice(.init(wz: -turn), seconds: seconds)
        case .raise:     ble.driveForVoice(.init(raise: 30), seconds: seconds)
        case .twist:     ble.driveForVoice(.init(twist: 30), seconds: seconds)
        // `bow` exists both as a posture dip and as a firmware skill. Use the skill once a
        // bench test has cleared it, and the posture dip until then — so "bow" always does
        // something, and never something untested.
        case .bow:
            if SkillCatalog.verdict("bow") == .tableSafe { return ble.sendSkill("bow") }
            ble.driveForVoice(.init(bow: 30), seconds: seconds)
        case .stand:       return ble.sendSkill("stand_up")
        case .sit:         return ble.sendSkill("sit_down")
        case .lie:         return ble.sendSkill("lie_down")
        case .wagTail:     return ble.sendSkill("wag_tail")
        case .dance:       return ble.sendSkill("dance")
        case .spin:        return ble.sendSkill("spin")
        case .crawl:       return ble.sendSkill("crawl")
        case .wave:        return ble.sendSkill("wave")
        case .stretch:     return ble.sendSkill("stretch")
        case .shake:       return ble.sendSkill("shake")
        case .shakeHands:  return ble.sendSkill("shake_hands")
        case .fingerHeart: return ble.sendSkill("finger_heart")
        case .pushUps:     return ble.sendSkill("push_ups")
        case .beCute:      return ble.sendSkill("be_cute")
        case .impatient:   return ble.sendSkill("impatient")
        case .stop:      stopSequence(); ble.stopDriving(reason: "voice"); return 0
        case .unknown:   return 0
        }
        return seconds
    }

    /// Cancels any queued sequence. Called by the stop word, by mic release, and by stop().
    private func stopSequence() {
        sequence?.cancel()
        sequence = nil
    }

    private func setIntent(_ text: String, good: Bool) {
        intent = text
        intentIsGood = good
    }
}
