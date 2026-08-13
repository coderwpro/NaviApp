import Foundation
import Speech
import AVFoundation
import UIKit

/// Plays a story through the robot: narration with changing tone, in-place movements, and
/// pauses where the child answers back.
///
/// Three modes, matching the three things a child does with a story:
///  * listen  — the robot tells it, stopping to ask questions
///  * retell  — the child tells it back, and Pip responds to what they actually said
///  * create  — the robot opens a scene and the two of them build it together
@MainActor
final class StoryTeller: NSObject, ObservableObject {

    enum Phase { case idle, opening, composing, telling, waiting, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var story: Story?
    @Published private(set) var line = ""
    @Published private(set) var prompt: String?
    @Published private(set) var heard = ""
    @Published private(set) var face: FaceMood = .idle
    /// Whose eyes the robot is wearing. Changes with the story being told.
    @Published private(set) var eyes: EyeStyle = .human
    @Published private(set) var beatIndex = 0
    @Published private(set) var problem: String?

    private let recogniser = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var answerContinuation: CheckedContinuation<String, Never>?
    private var runner: Task<Void, Never>?
    private var lastMovementAt = Date.distantPast
    private var listening = false
    /// Fires when the transcript stops changing. `isFinal` can be a second or two behind a
    /// child who has clearly finished speaking.
    private var settleTimer: Timer?

    private unowned let ble: NaviBLE
    private let speech: SpeechEngine
    private let companion = StoryCompanion()
    private let composer = StoryComposer()

    init(ble: NaviBLE, speech: SpeechEngine) {
        self.ble = ble
        self.speech = speech
        super.init()
    }

    // MARK: - Control

    /// Starts a bedtime session: greet with the time, ask what they would like to hear,
    /// then either tell a written story or compose a new one about whatever they said.
    func begin() {
        guard phase == .idle || phase == .finished else { return }
        problem = nil
        beatIndex = 0
        eyes = .human
        phase = .opening
        UIApplication.shared.isIdleTimerDisabled = true
        configureAudioSession()
        speech.prefetch(Self.topicQuestion, emotion: .cheerful)
        speech.prefetch(Self.topicRetry, emotion: .cheerful)
        speech.prefetch(Self.knowThatOne, emotion: .cheerful)
        speech.prefetch(Self.anotherQuestion, emotion: .gentle)
        speech.prefetch(Self.goodnight, emotion: .gentle)

        runner = Task { @MainActor in
            line = Self.bedtimeOpening
            face = .speaking
            await say(line, emotion: .gentle)
            guard phase != .idle, !Task.isCancelled else { return }

            var topic = await askForTopic()
            guard phase != .idle, !Task.isCancelled else { return }

            var round = 0
            var lastTitle = ""
            while !Task.isCancelled, phase != .idle {
                round += 1
                // A second story keeps the child's subject but is written fresh, so
                // "another one like that" never means hearing the same story twice.
                let request = (round == 1 || lastTitle.isEmpty)
                    ? topic
                    : "\(topic) — a brand new story in the same spirit as \(lastTitle), with different characters"

                guard let story = await storyFor(request) else { break }
                guard phase != .idle, !Task.isCancelled else { return }

                self.story = story
                self.eyes = story.eyes
                self.beatIndex = 0
                phase = .telling
                await runListen(story)
                guard !Task.isCancelled, phase != .idle else { return }
                lastTitle = story.title

                switch await nextStep() {
                case .stop:
                    round = -1                     // fall out and say goodnight
                case .sameTheme:
                    break                          // keep `topic`, new story next round
                case .newTopic(let fresh):
                    topic = fresh                  // they asked for something else entirely
                    lastTitle = ""
                }
                if round == -1 { break }
            }

            guard !Task.isCancelled, phase != .idle else { return }
            face = .speaking
            line = Self.goodnight
            perform(.liedown)
            await say(Self.goodnight, emotion: .gentle)
            face = .idle
            phase = .finished
        }
    }

    /// "It's twenty past eight. Time to go to sleep." Reading the real clock is what makes
    /// it feel like the robot is in the room rather than reciting a script.
    private static let bedtimeOpening =
        "Hello! I'm Pip, your storyteller. Let's have a story before you go to sleep."

    private static let anotherQuestion =
        "Did you like that one? You can ask for another story about anything you want, "
      + "or just say yes for another one like this."
    private static let goodnight =
        "Sweet dreams. Close your eyes now, and sleep well."

    private static let topicQuestion =
        "What would you like your story to be about? You can pick anything at all."
    private static let topicRetry =
        "Anything you like. A dragon? A little lost puppy? A sleepy cloud?"
    private static let knowThatOne = "Oh, I know that one!"

    /// Asks what the story should be about. Two tries, then picks something itself rather
    /// than leaving a child waiting in the dark.
    private func askForTopic() async -> String {
        for attempt in 1...2 {
            guard phase == .opening, !Task.isCancelled else { return "" }
            let question = attempt == 1 ? Self.topicQuestion : Self.topicRetry
            line = question
            prompt = question
            face = .speaking
            await say(question, emotion: .cheerful)
            guard phase == .opening, !Task.isCancelled else { return "" }

            let said = await listenForAnswer(seconds: 8)
            prompt = nil
            if !said.isEmpty { return said }
        }
        return "a sleepy little robot dog and the stars"
    }

    enum NextStep {
        case stop
        case sameTheme
        case newTopic(String)
    }

    /// Asks what happens next. Crucially this is NOT a yes/no question: "I want a princess"
    /// is a new subject, not a vote for another dragon. Anything left over once the filler
    /// is stripped is treated as what they actually asked for.
    private func nextStep() async -> NextStep {
        guard phase != .idle, !Task.isCancelled else { return .stop }
        face = .speaking
        line = Self.anotherQuestion
        prompt = Self.anotherQuestion
        await say(Self.anotherQuestion, emotion: .gentle)
        guard phase != .idle, !Task.isCancelled else { return .stop }

        let said = (await listenForAnswer(seconds: 8)).lowercased()
        prompt = nil
        guard !said.isEmpty else { return .stop }

        // Whole words, not substrings: "another" contains "no", and so do "know", "now"
        // and "nothing". Substring matching turned "another one" into goodnight.
        let words = Set(said.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let noWords: Set<String> = ["no", "nope", "stop", "goodnight", "tired", "enough",
                                    "finished", "nothing", "done"]
        let noPhrases = ["good night", "go to sleep", "that's all", "no thank"]
        if !noWords.isDisjoint(with: words) || noPhrases.contains(where: { said.contains($0) }) {
            return .stop
        }

        // Strip agreement and scaffolding. Whatever survives is the subject.
        let filler: Set<String> = [
            "yes", "yeah", "yep", "ok", "okay", "sure", "please", "another", "more", "again",
            "one", "story", "stories", "tell", "me", "about", "hear", "want", "wanna", "would",
            "like", "can", "you", "i", "a", "an", "the", "to", "now", "next", "with", "of",
            "and", "for", "some", "this", "that", "it", "let's", "do", "have", "new", "different",
        ]
        let leftover = said
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }

        if !leftover.isEmpty { return .newTopic(leftover.joined(separator: " ")) }

        let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "please", "another",
                                     "more", "again", "ok", "okay", "sure"]
        return yesWords.isDisjoint(with: words) ? .stop : .sameTheme
    }

    /// A written story if they asked for one, otherwise a new one composed on the spot.
    private func storyFor(_ topic: String) async -> Story? {
        if let known = StoryLibrary.matching(topic) {
            line = known.title
            for beat in known.beats.prefix(3) {
                speech.prefetch(beat.text, emotion: beat.emotion)
            }
            await say(Self.knowThatOne, emotion: .cheerful)
            return known
        }

        phase = .composing
        face = .speaking
        line = "Let me think of a story about \(topic)…"

        // Writing 280 words takes several seconds. Start it FIRST and talk over the wait,
        // rather than speaking and then going silent.
        async let drafting = composer.compose(about: topic)

        await say("Ooh, I like that. Let me think of a good one about \(topic).", emotion: .gentle)
        guard phase == .composing, !Task.isCancelled else { _ = try? await drafting; return nil }
        face = .unsure

        do {
            let made = try await drafting
            guard phase == .composing, !Task.isCancelled else { return nil }
            line = made.title
            // Get the opening beats fetched before the title is even announced.
            for beat in made.beats.prefix(3) {
                speech.prefetch(beat.text, emotion: beat.emotion)
            }
            await say("Here we go. \(made.title).", emotion: .cheerful)
            return made
        } catch {
            // Never leave a child with nothing: fall back to a written story.
            problem = "Could not write a new story — telling a favourite instead."
            let fallback = StoryLibrary.all.randomElement()!
            await say("I could not think of a new one tonight. Here is a favourite instead.",
                      emotion: .gentle)
            return fallback
        }
    }

    func stop() {
        runner?.cancel(); runner = nil
        speech.stop()
        answerContinuation?.resume(returning: "")
        answerContinuation = nil
        stopListening()
        ble.stopDriving(reason: "story ended")
        phase = .idle
        face = .idle
        eyes = .human
        beatIndex = 0
        line = ""; prompt = nil; heard = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Modes

    private func runListen(_ story: Story) async {
        for (index, beat) in story.beats.enumerated() {
            if Task.isCancelled { return }
            beatIndex = index
            line = beat.text
            // Fetch the next beat while this one is still being spoken, so the story does
            // not pause for the network between sentences.
            for ahead in 1...2 where index + ahead < story.beats.count {
                let upcoming = story.beats[index + ahead]
                speech.prefetch(upcoming.text, emotion: upcoming.emotion)
                if let question = upcoming.ask {
                    speech.prefetch(question, emotion: .gentle)
                }
            }
            // Scripted action if the story asked for one, otherwise something of its own —
            // either way the robot moves on every beat.
            if beat.action != nil {
                perform(beat.action)
            } else {
                moveForBeat(index, of: story.beats.count)
            }
            await say(beat.text, emotion: beat.emotion)

            if let question = beat.ask {
                if Task.isCancelled { return }
                prompt = question
                await say(question, emotion: .gentle)
                let answer = await listenForAnswer(seconds: 8)
                prompt = nil
                guard !Task.isCancelled else { return }
                if !answer.isEmpty {
                    let reply = await companion.reply(
                        .answeredQuestion(story: story.title, question: question, said: answer))
                    line = reply
                    await say(reply, emotion: .cheerful)
                }
            }
        }
        let ending = await companion.reply(.finishedStory(story: story.title, theme: story.theme))
        guard !Task.isCancelled else { return }
        line = ending
        perform(.wagTail)
        await say(ending, emotion: .gentle)
    }

    // MARK: - Robot

    /// Little unscripted movements between beats: a shift of weight, a small twist, a
    /// dip of the head. Amplitudes are deliberately half those of the scripted actions —
    /// this should read as a creature listening to itself talk, not as choreography.
    /// Movement for a beat that has no scripted action. Combinations, not single axes —
    /// a twist with a little lift reads as a whole body shifting rather than one joint
    /// moving. All in-place: the phone is riding on the robot's back.
    private static let ambientMoves: [(NaviProtocol.Axes, TimeInterval)] = [
        (.init(twist:  34),            0.8),   // look left
        (.init(twist: -34),            0.8),   // look right
        (.init(raise: 20, twist:  26), 0.8),   // lean and lift
        (.init(raise: 20, twist: -26), 0.8),
        (.init(bow:     26),           0.6),   // dip
        (.init(bow:     18),           0.4),   // small nod
        (.init(raise:   30),           0.7),   // stretch up
        (.init(raise: 22, bow: 14),    0.6),   // sway
        (.init(bow: 18, twist:  20),   0.6),   // head tilt
        (.init(bow: 18, twist: -20),   0.6),
    ]
    private var lastAmbientIndex = -1

    /// One movement per beat, so the robot is doing something through the whole story.
    private func moveForBeat(_ index: Int, of total: Int) {
        guard ble.canDrive else { return }
        // The last two beats stay still — those are the calm ones to fall asleep to.
        guard index < total - 2 else { return }
        var pick = Int.random(in: 0..<Self.ambientMoves.count)
        if pick == lastAmbientIndex { pick = (pick + 1) % Self.ambientMoves.count }
        lastAmbientIndex = pick
        let (axes, seconds) = Self.ambientMoves[pick]
        lastMovementAt = Date()
        ble.driveForVoice(axes, seconds: seconds)
    }

    /// In-place only — the phone is riding on the robot's back.
    private func perform(_ action: StoryAction?) {
        guard let action, ble.canDrive else { return }
        lastMovementAt = Date()
        switch action {
        case .nod:     ble.driveForVoice(.init(bow: 25), seconds: 0.5)
        case .bow:     ble.driveForVoice(.init(bow: 45), seconds: 1.0)
        case .wiggle:  ble.driveForVoice(.init(twist: 40), seconds: 1.0)
        case .rearUp:  ble.driveForVoice(.init(raise: 50), seconds: 1.0)
        case .wagTail: ble.sendSkill("wag_tail")
        case .dance:   ble.sendSkill("dance")
        case .sit:     ble.sendSkill("sit_down")
        case .liedown: ble.sendSkill("lie_down")
        }
    }

    // MARK: - Speech out

    private func say(_ text: String, emotion: Emotion) async {
        face = emotion.face
        await speech.speak(text, emotion: emotion)
    }

    // MARK: - Speech in

    /// Waits for the child to answer, or gives up after `seconds` of nothing.
    private func listenForAnswer(seconds: Double) async -> String {
        heard = ""
        face = .listening
        phase = .waiting
        startListening()
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            answerContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                // Timeout: whatever was heard by now is the answer, even if partial.
                if let waiting = answerContinuation {
                    answerContinuation = nil
                    waiting.resume(returning: heard)
                }
            }
        }
        stopListening()
        phase = .telling
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .voicePrompt is tuned for spoken output while a mic is live and is
            // noticeably louder, but not every device accepts it. Falling back to .default
            // matters: a category that fails to apply leaves the input node with a zero
            // sample rate, and installTap then raises an Objective-C exception that no
            // Swift `catch` can see — the app just dies.
            do {
                try session.setCategory(.playAndRecord, mode: .voicePrompt,
                                        options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            } catch {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            // Belt and braces: .playAndRecord can still route to the earpiece, which is
            // far too quiet for a robot across a room.
            try? session.overrideOutputAudioPort(.speaker)
        } catch {
            problem = "Audio session failed: \(error.localizedDescription)"
        }
    }

    private func startListening() {
        guard !listening, let recogniser, recogniser.isAvailable else { return }
        listening = true
        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            // Session is configured once in begin(); reconfiguring here would interrupt
            // the narration mid-word.
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // installTap raises an ObjC exception on an invalid format, which cannot be
            // caught in Swift and takes the whole app down. Check it instead.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                problem = "Microphone unavailable — audio route not ready"
                listening = false
                return
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            task = recogniser.recognitionTask(with: request) { [weak self] result, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.heard = result.bestTranscription.formattedString
                        if result.isFinal, let waiting = self.answerContinuation {
                            self.answerContinuation = nil
                            waiting.resume(returning: self.heard)
                        } else if !result.isFinal {
                            self.armSettle()
                        }
                    }
                }
            }
        } catch {
            problem = "Microphone failed: \(error.localizedDescription)"
            listening = false
        }
    }

    /// Treats a settled transcript as finished, instead of waiting for the recogniser.
    private func armSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let waiting = self.answerContinuation else { return }
                let text = self.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                self.answerContinuation = nil
                waiting.resume(returning: text)
            }
        }
    }

    private func stopListening() {
        settleTimer?.invalidate(); settleTimer = nil
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        request?.endAudio()
        request = nil
        task = nil
    }
}

