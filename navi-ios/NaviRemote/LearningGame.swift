import Foundation
import Speech
import AVFoundation
import UIKit

/// The word game that runs while the phone sits on the robot's back.
///
/// It is written as a CONVERSATION, not a quiz. Pip greets the child in the language they
/// picked, chats between words, reacts to what they say, and helps when they are stuck.
/// A bare word followed by silence is a flashcard; this is meant to feel like someone is
/// in the room.
///
/// Two constraints throughout:
///  * The phone is the robot's face, so the child talks hands-free — the recogniser listens
///    continuously rather than waiting for a button.
///  * The phone is ON the robot. Every reward is IN-PLACE. Nothing walks, because walking
///    would carry the robot out from under the phone.
@MainActor
final class LearningGame: NSObject, ObservableObject {

    enum Phase { case setup, choosingLanguage, choosing, playing }
    typealias Mood = FaceMood

    /// What the child asked to do. Chosen out loud, not from a menu on screen — the phone
    /// is on the robot's back and out of reach.
    enum Lesson: String {
        case words      // hear a word in the new language, say what it means
        case speaking   // hear a word, say it back in the new language
        case phrases    // everyday phrases, said back in the new language

        var invitation: String {
            switch self {
            case .words: "Lovely. I will say a word, and you tell me what it means."
            case .speaking: "Great choice. I will say a word, and you say it back to me."
            case .phrases: "Wonderful. I will teach you things people really say."
            }
        }
        /// Speaking and phrases are answered in the language being learned, so the
        /// recogniser has to listen in that language rather than English.
        var answeredInTargetLanguage: Bool { self != .words }
    }

    @Published private(set) var phase: Phase = .setup
    @Published private(set) var current: WordPair?
    @Published private(set) var heard = ""
    @Published private(set) var mood: Mood = .idle
    /// A one-off expression on top of `mood` — a wink for a right answer, a curious look
    /// for a wrong one. Drawn from a no-repeat pool so the same reward face never lands twice.
    @Published private(set) var cue: FaceCue?
    @Published private(set) var correct = 0
    @Published private(set) var asked = 0
    @Published private(set) var banner: String?
    /// What the teacher just said, shown in portrait for an adult following along.
    @Published private(set) var tutorLine: String?
    @Published private(set) var micProblem: String?
    @Published private(set) var lesson: Lesson = .words
    @Published var deck: WordDeck = .spanish
    @Published var rewardsEnabled = true

    private var cueToken = 0
    private var delighted = NoRepeatPicker<FaceMood>([.happy, .wink, .winkLeft, .proud, .cute, .flirty], window: 3)
    private var puzzled = NoRepeatPicker<FaceMood>([.curious, .unsure, .surprised, .serious], window: 2)

    /// Plays a one-off expression, then the face falls back to whatever it was resting on.
    private func flash(_ mood: FaceMood) {
        cueToken += 1
        cue = FaceCue(mood, token: cueToken)
    }

    /// In-place only. A reward that walks the robot would tip the phone off its back.
    private static let rewards: [(label: String, run: (NaviBLE) -> Void)] = [
        ("dance",    { $0.sendSkill("dance") }),
        ("tail wag", { $0.sendSkill("wag_tail") }),
        ("wiggle",   { $0.driveForVoice(.init(twist: 40), seconds: 1.2) }),
        ("bow",      { $0.driveForVoice(.init(bow: 40), seconds: 1.0) }),
        ("stretch",  { $0.driveForVoice(.init(raise: 40), seconds: 1.0) }),
    ]

    /// Conversational lead-ins, so a word never arrives out of nowhere.
    private static let leadIns = [
        "Here is the next one.", "Ooh, I like this word.", "Ready? Listen carefully.",
        "Let's try another.", "How about this one?", "This one is fun to say.",
        "Here comes a good one.", "Now then. Listen.",
    ]
    private var lastLeadIn = -1

    /// Every line Pip says that is known in advance. Fetched at session start so none of
    /// them ever costs a network round trip mid-conversation.
    private static let languageQuestion =
        "Which language would you like to learn? Spanish, French, or Mandarin?"
    private static let languageRetry = "You can say Spanish, French, or Mandarin."
    private static let lessonQuestion =
        "What would you like to do today? We can learn new words, practise saying them out loud, or learn things people really say."
    private static let lessonRetry = "Would you like words, speaking, or phrases?"
    private static let sayItBack = "Now you say it."
    private static let listenAgain = "Listen again."
    private static let openingHello = "Hello! I am Pip. I can teach you a new language today."

    /// Said the instant an answer lands, while the model is still being asked for the
    /// real reply. Short, cached, and never a network call — this is what removes the
    /// dead air between answering and hearing anything back.
    private static let acksCorrect = ["Yes!", "That's it!", "Well done!", "Perfect!"]
    private static let acksWrong   = ["Hmm.", "Not quite.", "Ooh, close."]
    private static let acksHelp    = ["Let me help.", "Here's a clue."]

    private func instantAck(for moment: Tutor.Moment) -> (String, Emotion) {
        switch moment {
        case .correct: (Self.acksCorrect.randomElement()!, .excited)
        case .wrong:   (Self.acksWrong.randomElement()!, .gentle)
        case .hint:    (Self.acksHelp.randomElement()!, .gentle)
        case .reveal:  ("Let me tell you.", .gentle)
        default:       ("", .calm)
        }
    }

    private func warmVoiceCache() {
        for line in Self.leadIns { speech.prefetch(line, emotion: .cheerful) }
        speech.prefetch(Self.languageQuestion, emotion: .cheerful)
        speech.prefetch(Self.lessonQuestion, emotion: .cheerful)
        speech.prefetch(Self.sayItBack, emotion: .gentle)
        speech.prefetch(Self.listenAgain, emotion: .gentle)
        for ack in Self.acksCorrect { speech.prefetch(ack, emotion: .excited) }
        for ack in Self.acksWrong { speech.prefetch(ack, emotion: .gentle) }
        for ack in Self.acksHelp { speech.prefetch(ack, emotion: .gentle) }
        speech.prefetch("Let me tell you.", emotion: .gentle)
        for deck in WordDeck.all {
            speech.prefetch(deck.greeting, emotion: .cheerful, language: deck.locale)
            speech.prefetch("\(deck.name) it is.", emotion: .cheerful)
        }
    }

    /// One recogniser per language. `SFSpeechRecognizer`'s locale is fixed at init, and
    /// asking an English recogniser to hear "gracias" gets you "grassy ass".
    private var recognisers: [String: SFSpeechRecognizer] = [:]
    private var listeningLocale = "en-US"

    private func recogniser(for locale: String) -> SFSpeechRecognizer? {
        if let cached = recognisers[locale] { return cached }
        let made = SFSpeechRecognizer(locale: Locale(identifier: locale))
        recognisers[locale] = made
        return made
    }
    private let engine = AVAudioEngine()
    private let sink = AudioSink()
    private var audioReady = false
    /// Bumped for every answer window. A cancelled recognition task still delivers one
    /// last callback; without this it reopens the window and cancels the task that just
    /// replaced it, and the microphone ends up permanently dead.
    private var windowGeneration = 0
    /// Fires when the transcript has stopped changing. `isFinal` from the recogniser can
    /// be a second or two behind a child who has clearly finished speaking.
    private var settleTimer: Timer?
    private static let settleDelay: TimeInterval = 0.7
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var remaining: [WordPair] = []
    private var accepting = false
    private let tutor = Tutor()
    /// Attempts allowed on one card before the answer is simply given. Wrong guesses and
    /// "I don't know" both count, so a child cannot be stuck on one word.
    private static let maxTries = 2
    private var tries = 0
    private var streak = 0
    private var busyTeaching = false
    private var runner: Task<Void, Never>?

    private unowned let ble: NaviBLE
    private let speech: SpeechEngine

    init(ble: NaviBLE, speech: SpeechEngine) {
        self.ble = ble
        self.speech = speech
        super.init()
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .setup else { return }
        guard await requestPermissions() else { return }
        correct = 0; asked = 0; micProblem = nil; streak = 0
        remaining = []
        phase = .choosingLanguage
        // The phone is acting as a face — it must not sleep mid-game.
        UIApplication.shared.isIdleTimerDisabled = true
        startAudio()
        warmVoiceCache()

        runner = Task { @MainActor in
            // English first — the child has not chosen a language yet, so greeting them in
            // one they may not know is meaningless.
            closeAnswerWindow()
            mood = .speaking
            let hello = Self.openingHello
            tutorLine = hello
            await speech.speak(hello, emotion: .cheerful)
            guard phase != .setup, !Task.isCancelled else { return }

            await chooseLanguage()
            guard phase != .setup, !Task.isCancelled else { return }

            // NOW the greeting in the chosen language means something.
            closeAnswerWindow()
            mood = .speaking
            await speech.speak(deck.greeting, emotion: .cheerful, language: deck.locale)
            guard phase != .setup, !Task.isCancelled else { return }

            await chooseLesson()
            guard phase != .setup, !Task.isCancelled else { return }
            await askNext()
        }
    }

    func stop() {
        runner?.cancel(); runner = nil
        accepting = false
        speech.stop()
        stopAudio()
        ble.stopDriving(reason: "game ended")
        phase = .setup
        mood = .idle
        current = nil
        banner = nil
        tutorLine = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func skip() {
        guard phase == .playing else { return }
        runner?.cancel()
        runner = Task { @MainActor in await askNext() }
    }

    /// Tap anywhere to hear the word again — the only affordance that survives in the
    /// eyes-only landscape layout.
    func repeatQuestion() {
        guard phase == .playing, let card = current else { return }
        runner?.cancel()
        runner = Task { @MainActor in
            accepting = false
            closeAnswerWindow()
            mood = .speaking
            await speech.speak(Self.listenAgain, emotion: .gentle)
            await speech.speak(card.speechText, emotion: .gentle, language: deck.locale)
            guard phase == .playing, !Task.isCancelled else { return }
            await beginFreshAnswer()
            guard phase == .playing, !Task.isCancelled else { return }
            mood = .listening
        }
    }

    // MARK: - Choosing a language, out loud

    /// Asks which language to learn. Two attempts, then picks one rather than leaving a
    /// child stuck in a question loop.
    private func chooseLanguage() async {
        for attempt in 1...2 {
            guard phase == .choosingLanguage, !Task.isCancelled else { return }
            closeAnswerWindow()
            mood = .speaking
            let question = attempt == 1
                ? Self.languageQuestion : Self.languageRetry
            tutorLine = question
            mood = .curious
            await speech.speak(question, emotion: .cheerful)
            guard phase == .choosingLanguage, !Task.isCancelled else { return }

            mood = .listening
            let said = await listen(seconds: 7, locale: "en-US")
            guard phase == .choosingLanguage, !Task.isCancelled else { return }
            if said.isEmpty { continue }

            if let picked = WordDeck.matching(said) {
                deck = picked
                phase = .choosing
                closeAnswerWindow()
                mood = .speaking
                let confirm = "\(picked.name) it is."
                tutorLine = confirm
                await speech.speak(confirm, emotion: .cheerful)
                return
            }
        }
        deck = .spanish
        phase = .choosing
        await speech.speak("Let us try Spanish.", emotion: .cheerful)
    }

    // MARK: - Choosing a lesson, out loud

    /// Asks what the child would like to do and waits for a spoken answer. Asks twice; if
    /// it still cannot tell, it picks words rather than leaving a child in a loop.
    private func chooseLesson() async {
        for attempt in 1...2 {
            guard phase == .choosing, !Task.isCancelled else { return }
            closeAnswerWindow()
            mood = .speaking
            let question = attempt == 1
                ? Self.lessonQuestion : Self.lessonRetry
            tutorLine = question
            mood = .curious
            await speech.speak(question, emotion: .cheerful)
            guard phase == .choosing, !Task.isCancelled else { return }

            mood = .listening
            let said = await listen(seconds: 7, locale: "en-US")
            guard phase == .choosing, !Task.isCancelled else { return }
            if said.isEmpty { continue }

            // Keywords first — instant and offline. The model only sees what they miss.
            var picked = Tutor.lessonKeyword(in: said)
            if picked == nil { picked = await tutor.lessonChoice(said: said) }
            guard phase == .choosing, !Task.isCancelled else { return }

            if let picked, let chosen = Lesson(rawValue: picked) {
                lesson = chosen
                remaining = (chosen == .phrases ? deck.phrases : deck.cards).shuffled()
                phase = .playing
                closeAnswerWindow()
                mood = .speaking
                tutorLine = chosen.invitation
                await speech.speak(chosen.invitation, emotion: .cheerful)
                return
            }
        }
        // Fell through twice: start somewhere rather than keep asking.
        lesson = .words
        remaining = deck.cards.shuffled()
        phase = .playing
        await speech.speak("Let us start with some words.", emotion: .cheerful)
    }

    /// One-shot listen used by the menu. The continuous game loop is separate.
    private func listen(seconds: Double, locale: String) async -> String {
        listeningLocale = locale
        openAnswerWindow()                // Pip's own question is not in this transcript
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        closeAnswerWindow()
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Asking

    private func nextLeadIn() -> String {
        var index = Int.random(in: 0..<Self.leadIns.count)
        if index == lastLeadIn { index = (index + 1) % Self.leadIns.count }
        lastLeadIn = index
        return Self.leadIns[index]
    }

    private func askNext() async {
        if remaining.isEmpty {
            remaining = (lesson == .phrases ? deck.phrases : deck.cards).shuffled()
        }
        let card = remaining.removeFirst()
        current = card
        asked += 1
        heard = ""
        tries = 0
        accepting = false
        banner = nil
        closeAnswerWindow()
        mood = .speaking

        await speech.speak(nextLeadIn(), emotion: .cheerful)
        guard phase == .playing, !Task.isCancelled else { return }
        await speech.speak(card.speechText, emotion: .gentle, language: deck.locale)
        guard phase == .playing, !Task.isCancelled else { return }

        // In the two speaking lessons the child answers in the new language, so ask for it
        // and switch the recogniser over.
        if lesson.answeredInTargetLanguage {
            await speech.speak(Self.sayItBack, emotion: .gentle)
            guard phase == .playing, !Task.isCancelled else { return }
        }
        // Speaking lessons are answered in the new language, so the recogniser has to
        // listen in it. Just a different recogniser on the next window — no audio restart.
        listeningLocale = lesson.answeredInTargetLanguage ? deck.locale : "en-US"

        // Fetch the next word's audio while the child is thinking, so it arrives instantly.
        if let upcoming = remaining.first {
            speech.prefetch(upcoming.speechText, emotion: .gentle, language: deck.locale)
        }

        tutorLine = nil
        openAnswerWindow()
        mood = .listening
    }

    // MARK: - Answer checking

    /// A child asking for help, in the many ways they actually say it.
    private func isAskingForHelp(_ said: String) -> Bool {
        let cleaned = said.lowercased()
        let phrases = ["i don't know", "i dont know", "dunno", "don't know", "dont know",
                       "no idea", "not sure", "i give up", "help me", "help", "hint",
                       "tell me", "what is it", "i forgot", "skip"]
        return phrases.contains { cleaned.contains($0) }
    }

    /// Lenient on purpose: a child saying "it's a dog" should count. Homophones are
    /// accepted too — "sun" and "son" are acoustically identical.
    private func isCorrect(_ said: String, for card: WordPair) -> Bool {
        // Speaking lessons are marked against the foreign word, not its meaning — and
        // against every reasonable way of saying it.
        if lesson.answeredInTargetLanguage {
            let flattened = said
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
                .lowercased()
            let spoken = flattened
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            for form in card.spokenForms {
                if flattened.contains(form) { return true }
                if spoken.contains(where: { Homophones.isNearMiss($0, form) }) { return true }
            }
            return false
        }
        let words = said.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        for answer in card.answers {
            let accepted = Homophones.accepted(for: answer)
            if words.contains(where: { accepted.contains($0) }) { return true }
            if words.contains(where: { Homophones.isNearMiss($0, answer.lowercased()) }) { return true }
        }
        return false
    }

    /// `isFinal` matters: a correct answer fires on a partial so the celebration lands
    /// while the child is still speaking, but "wrong" and "I don't know" only count once
    /// they have actually finished the sentence.
    private func handle(_ said: String, isFinal: Bool) {
        guard accepting, !busyTeaching, let card = current else { return }

        if isCorrect(said, for: card) {
            accepting = false
            correct += 1
            streak += 1
            mood = .happy
            flash(delighted.next() ?? .happy)
            let reward = fireReward()
            banner = "\(card.word) = \(card.answer)\(reward.map { " — " + $0 } ?? "")"
            teach(.correct(word: card.word, answer: card.answer), thenAdvance: true)
            return
        }

        guard isFinal, !said.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        if isAskingForHelp(said) {
            accepting = false
            tries += 1
            mood = .unsure
            flash(puzzled.next() ?? .curious)
            let done = tries >= Self.maxTries
            teach(done ? .reveal(word: card.word, answer: card.answer)
                       : .hint(word: card.word, answer: card.answer),
                  thenAdvance: done)
            return
        }

        accepting = false
        streak = 0
        tries += 1
        mood = .unsure
        flash(puzzled.next() ?? .curious)
        let done = tries >= Self.maxTries
        teach(done ? .reveal(word: card.word, answer: card.answer)
                   : .wrong(word: card.word, answer: card.answer, heard: said),
              thenAdvance: done)
    }

    /// Picks and runs a celebration. Returns its name, or nil if the robot cannot move.
    private func fireReward() -> String? {
        guard rewardsEnabled, ble.canDrive else { return nil }
        let reward = Self.rewards.randomElement()!
        reward.run(ble)
        return reward.label
    }

    /// Asks the tutor for a line, speaks it, then either moves on or re-opens the same
    /// card for another try. The model never decides which of those happens.
    private func teach(_ moment: Tutor.Moment, thenAdvance: Bool) {
        busyTeaching = true
        runner?.cancel()
        runner = Task { @MainActor in
            // Start the model call and the acknowledgement together. By the time "Yes!"
            // has finished playing, the real reply has usually arrived — so the pause
            // between answering and hearing something back disappears.
            async let pending = tutor.line(for: moment, language: deck.name)

            closeAnswerWindow()
            mood = .speaking
            let (ack, ackEmotion) = instantAck(for: moment)
            if !ack.isEmpty { await speech.speak(ack, emotion: ackEmotion) }
            guard phase == .playing, !Task.isCancelled else { _ = await pending; return }

            let line = await pending
            guard phase == .playing, !Task.isCancelled else { return }
            tutorLine = line
            await speech.speak(line, emotion: thenAdvance ? .proud : .gentle)

            if streak >= 3, thenAdvance {
                let cheer = await tutor.line(for: .encourage(streak: streak), language: deck.name)
                guard phase == .playing, !Task.isCancelled else { return }
                tutorLine = cheer
                await speech.speak(cheer, emotion: .excited)
            }

            guard phase == .playing, !Task.isCancelled else { return }
            busyTeaching = false
            if thenAdvance {
                await askNext()
            } else {
                // Same word, another go. Say it again so they hear it fresh.
                await speech.speak(current?.speechText ?? "", emotion: .gentle, language: deck.locale)
                guard phase == .playing, !Task.isCancelled else { return }
                await beginFreshAnswer()
                guard phase == .playing, !Task.isCancelled else { return }
                mood = .listening
            }
        }
    }

    /// Starts a clean answer window. The gate was shut while Pip spoke, so nothing the
    /// phone said is in the transcript.
    private func beginFreshAnswer() async {
        accepting = false
        openAnswerWindow()
    }

    // MARK: - Audio

    private func requestPermissions() async -> Bool {
        let speechAuth = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechAuth == .authorized else { micProblem = "Speech permission denied"; return false }
        let mic = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else { micProblem = "Microphone permission denied"; return false }
        return true
    }

    /// `.playAndRecord` with `.defaultToSpeaker`, NOT `.record`: the game has to talk and
    /// listen at the same time. `.measurement` mode is also avoided deliberately — it
    /// disables output processing and makes the speaker far too quiet across a room.
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
            micProblem = "Audio session failed: \(error.localizedDescription)"
        }
    }

    /// Brings the microphone up ONCE. Never called again for the life of a session.
    private func startAudio() {
        guard !audioReady else { return }
        configureAudioSession()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // installTap raises an ObjC exception on an invalid format, which cannot be caught
        // in Swift and takes the whole app down. Check it instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            micProblem = "Microphone unavailable — audio route not ready"
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [sink] buffer, _ in
            sink.append(buffer)          // runs on the audio thread; the sink is the gate
        }
        engine.prepare()
        do {
            try engine.start()
            audioReady = true
        } catch {
            micProblem = "Microphone failed: \(error.localizedDescription)"
        }
    }

    private func stopAudio() {
        sink.setOpen(false)
        sink.attach(nil)
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if audioReady {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            audioReady = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Opens a fresh answer window: a brand-new request, so the transcript starts empty,
    /// and the gate opened so the child's voice reaches it. No audio teardown involved —
    /// that is what made this laggy and cut Pip off mid-sentence.
    private func openAnswerWindow() {
        guard audioReady else { micProblem = "Microphone not running"; return }
        // Not every phone has every language pack. Rather than going deaf, fall back to
        // English and lean on the lenient matching — an English recogniser hearing 书 as
        // "shoe" still gets marked correct.
        var recogniser = recogniser(for: listeningLocale)
        if recogniser == nil || recogniser?.isAvailable == false {
            recogniser = self.recogniser(for: "en-US")
            if listeningLocale != "en-US" {
                micProblem = "\(listeningLocale) speech pack not installed — listening in English"
            }
        }
        guard let recogniser, recogniser.isAvailable else {
            micProblem = "Speech recognition unavailable"
            return
        }
        windowGeneration += 1
        let generation = windowGeneration
        task?.cancel()
        request?.endAudio()

        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.shouldReportPartialResults = true
        // Answers here are one or two words from a known set. Telling the recogniser what
        // to expect is the single biggest accuracy win available — without it "gato" comes
        // back as "gotta" and "phrases" as "phases".
        fresh.contextualStrings = expectedAnswers
        fresh.taskHint = .search
        request = fresh
        heard = ""
        settleTimer?.invalidate(); settleTimer = nil
        sink.attach(fresh)
        sink.setOpen(true)
        // The window IS the accepting state. Setting this afterwards left a gap where an
        // early finalise found `accepting == false` and never reopened.
        accepting = true

        task = recogniser.recognitionTask(with: fresh) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.phase != .setup else { return }
                // Ignore anything from a window that has already been replaced.
                guard self.windowGeneration == generation else { return }

                if let result {
                    self.heard = result.bestTranscription.formattedString
                    if self.phase == .playing {
                        self.handle(self.heard, isFinal: result.isFinal)
                        // Treat a settled transcript as finished, rather than waiting for
                        // the recogniser to decide the silence has gone on long enough.
                        if !result.isFinal { self.armSettleTimer() }
                    }
                    // iOS ends a task after a stretch of silence. Roll straight into a new
                    // one — cheap now, because the engine never stops.
                    if result.isFinal, self.accepting { self.openAnswerWindow() }
                } else if error != nil, self.accepting {
                    self.openAnswerWindow()
                }
            }
        }
    }

    /// What the child is most likely about to say, fed to the recogniser as a hint.
    private var expectedAnswers: [String] {
        switch phase {
        case .choosingLanguage:
            return ["Spanish", "French", "Mandarin", "Chinese"]
        case .choosing:
            return ["words", "speaking", "phrases", "talking", "sentences"]
        default:
            guard let card = current else { return [] }
            if lesson.answeredInTargetLanguage { return [card.word] + card.spokenForms }
            var hints = card.answers
            for answer in card.answers { hints += Homophones.accepted(for: answer) }
            return hints + ["I don't know", "help"]
        }
    }

    /// Restarts the "they have stopped talking" countdown on every new partial result.
    private func armSettleTimer() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.accepting, self.phase == .playing else { return }
                let text = self.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                self.handle(text, isFinal: true)
            }
        }
    }

    /// Shuts the gate so the recogniser cannot hear the phone's own voice, and stops any
    /// stale callback from reopening it.
    private func closeAnswerWindow() {
        windowGeneration += 1
        accepting = false
        settleTimer?.invalidate(); settleTimer = nil
        sink.setOpen(false)
    }

}
