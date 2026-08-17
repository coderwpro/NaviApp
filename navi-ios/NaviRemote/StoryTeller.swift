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
    /// A one-off expression — a wink, a delighted blink — on top of `face`.
    @Published private(set) var cue: FaceCue?
    /// True only while a line is actually playing, so the eyes keep the speaking rhythm
    /// whatever expression the beat is wearing.
    @Published private(set) var isTalking = false
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
    /// Runs for the whole session on its own clock, so the robot is never still for long —
    /// including while a line is playing, while a story is being written, and while it is
    /// waiting for the child to answer.
    private let ambient: AmbientMotion
    /// Faces already used recently, so the same expression never lands twice running.
    private var recentFaces: [FaceMood] = []
    private var cueToken = 0

    init(ble: NaviBLE, speech: SpeechEngine) {
        self.ble = ble
        self.speech = speech
        self.ambient = AmbientMotion(ble: ble)
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
        recentFaces.removeAll()
        ambient.calm = false
        ambient.quiet = false
        ambient.start()
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
            ambient.calm = true
            line = Self.goodnight
            perform(.liedown)
            await say(Self.goodnight, emotion: .gentle, face: .sleepy)
            // The session is over: the robot settles for real here, and only here.
            ambient.stop()
            ble.stopDriving(reason: "story finished")
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
        // Ambient motion must never outlive the session. Killed before the stop frames go
        // out, so nothing can schedule one more gesture behind them.
        ambient.stop()
        ble.stopDriving(reason: "story ended")
        phase = .idle
        face = .idle
        cue = nil
        isTalking = false
        eyes = .human
        beatIndex = 0
        line = ""; prompt = nil; heard = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// What the ambient engine actually played, newest last. Exists so the no-repeat rule
    /// can be checked against a real session instead of taken on trust.
    var movementLog: [String] { ambient.recent }

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
            // The wind-down. The last two beats are the calm ones a child falls asleep to,
            // so they keep moving — a robot that freezes reads as disconnected — but only
            // from the small-amplitude tier and with long gaps between.
            ambient.calm = index >= story.beats.count - 2

            // Face and body land on the same instant. Picked once here and passed into
            // say(), so the expression cannot drift a second behind the movement.
            let beatFace = faceFor(beat.emotion)
            face = beatFace
            if let action = beat.action {
                perform(action)              // a scripted action wins; ambient yields to it
            } else {
                ambient.punctuate()          // otherwise the ambient stream marks the beat
            }
            await say(beat.text, emotion: beat.emotion, face: beatFace)

            if let question = beat.ask {
                if Task.isCancelled { return }
                prompt = question
                await say(question, emotion: .gentle, face: .curious)
                let answer = await listenForAnswer(seconds: 8)
                prompt = nil
                guard !Task.isCancelled else { return }
                if !answer.isEmpty {
                    flash([.happy, .wink, .cute].randomElement()!)
                    ambient.punctuate()
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

    /// A movement the story explicitly asked for. In-place only — the phone is riding on
    /// the robot's back — and the ambient stream is told to yield for its duration so a
    /// posture frame is never laid on top of a running animation.
    private func perform(_ action: StoryAction?) {
        guard let action, ble.motionAllowed else { return }
        lastMovementAt = Date()
        switch action {
        case .nod:     ambient.yield(for: 0.7);  ble.driveForVoice(.init(bow: 25), seconds: 0.5)
        case .bow:     ambient.yield(for: 1.2);  ble.driveForVoice(.init(bow: 45), seconds: 1.0)
        case .wiggle:  ambient.yield(for: 1.2);  ble.driveForVoice(.init(twist: 40), seconds: 1.0)
        case .rearUp:  ambient.yield(for: 1.2);  ble.driveForVoice(.init(raise: 50), seconds: 1.0)
        case .wagTail: ambient.yield(for: ble.sendSkill("wag_tail"))
        case .dance:   ambient.yield(for: ble.sendSkill("dance"))
        case .sit:     ambient.yield(for: ble.sendSkill("sit_down"))
        case .liedown: ambient.yield(for: ble.sendSkill("lie_down"))
        }
    }

    // MARK: - The face

    /// A face for this beat's emotion, never the same one twice running.
    ///
    /// The emotion is already declared by every beat and was already driving the voice.
    /// This is the second output from that same source of truth — before it, ten beats of
    /// a mostly-calm story produced ten identical faces.
    private func faceFor(_ emotion: Emotion) -> FaceMood {
        let options = emotion.faces
        let fresh = options.filter { !recentFaces.contains($0) }
        let choice = (fresh.isEmpty ? options : fresh).randomElement() ?? .speaking
        recentFaces.append(choice)
        if recentFaces.count > 3 { recentFaces.removeFirst(recentFaces.count - 3) }
        return choice
    }

    /// A one-off expression on top of whatever face is resting — a wink when the child
    /// answers, a delighted blink when something lands.
    private func flash(_ mood: FaceMood) {
        cueToken += 1
        cue = FaceCue(mood, token: cueToken)
    }

    // MARK: - Speech out

    private func say(_ text: String, emotion: Emotion, face chosen: FaceMood? = nil) async {
        face = chosen ?? faceFor(emotion)
        isTalking = true
        await speech.speak(text, emotion: emotion)
        isTalking = false
    }

    // MARK: - Speech in

    /// Waits for the child to answer, or gives up after `seconds` of nothing.
    private func listenForAnswer(seconds: Double) async -> String {
        heard = ""
        // Listening has to LOOK like listening, and not like the face it just had while
        // speaking. Wide, attentive, straight at the child.
        face = .listening
        // Still moving — a robot that goes rigid the moment it asks a question reads as
        // crashed — but softly, because servo noise costs recognition accuracy.
        ambient.quiet = true
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
        ambient.quiet = false
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

