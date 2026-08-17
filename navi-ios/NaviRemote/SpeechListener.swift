import Foundation
import Speech
import AVFoundation

/// A microphone that stays up.
///
/// The expensive, disruptive calls — `setCategory`, `setActive`, `engine.start()`,
/// `installTap` — happen once. Clearing the transcript is a new request; stopping the phone
/// from transcribing its own voice is a gate. That was the difference between a screen that
/// felt laggy and cut itself off mid-sentence and one that does not.
///
/// It also restarts itself. iOS ends a recognition task after a stretch of silence and after
/// about a minute of audio; for a companion that is meant to be listening the whole time,
/// that has to be invisible.
@MainActor
final class SpeechListener: NSObject, ObservableObject {

    @Published private(set) var heard = ""
    @Published private(set) var isOpen = false
    @Published private(set) var problem: String?

    /// Fires when the transcript has stopped changing. `isFinal` can be a second or two
    /// behind a child who has obviously finished talking.
    var onSettled: ((String) -> Void)?
    /// Fires on every partial. Used for the stop word, which cannot wait for anything.
    var onPartial: ((String) -> Void)?

    /// What the speaker is most likely about to say. The single biggest accuracy win
    /// available, and the reason a rehearsed command list is worth having.
    var contextualStrings: [String] = []
    var settleDelay: TimeInterval = 0.65

    private let sink = AudioSink()
    private let engine = AVAudioEngine()
    private var recogniser: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var settleTimer: Timer?
    private var audioReady = false
    /// Stops a callback from a window that has already been replaced reopening the gate.
    private var generation = 0

    // MARK: - Lifecycle

    func prepare(locale: String = "en-US") async -> Bool {
        guard await permissions() else { return false }
        recogniser = SFSpeechRecognizer(locale: Locale(identifier: locale))
        guard let recogniser, recogniser.isAvailable else {
            problem = "Speech recognition unavailable"
            return false
        }
        configureSession()
        startAudio()
        return audioReady
    }

    /// Open a fresh window: a brand-new request, so the transcript starts empty. No audio
    /// teardown — that is what used to swallow the first word of every answer.
    func listen() {
        guard audioReady, let recogniser, recogniser.isAvailable else { return }
        generation += 1
        let mine = generation
        task?.cancel()
        request?.endAudio()

        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.shouldReportPartialResults = true
        fresh.contextualStrings = contextualStrings
        fresh.taskHint = .search
        request = fresh
        heard = ""
        settleTimer?.invalidate(); settleTimer = nil
        sink.attach(fresh)
        sink.setOpen(true)
        isOpen = true

        task = recogniser.recognitionTask(with: fresh) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    self.onPartial?(self.heard)
                    if result.isFinal {
                        let text = self.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { self.onSettled?(text) }
                        // iOS ends the task after silence. Roll straight into a new one —
                        // cheap, because the engine never stopped.
                        if self.isOpen { self.listen() }
                    } else {
                        self.armSettle()
                    }
                } else if error != nil, self.isOpen {
                    self.listen()
                }
            }
        }
    }

    /// Shut the gate — while the robot is talking, so it never transcribes its own voice —
    /// and stop any stale callback from reopening it.
    func mute() {
        generation += 1
        isOpen = false
        settleTimer?.invalidate(); settleTimer = nil
        sink.setOpen(false)
    }

    func stopAll() {
        mute()
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

    // MARK: - Internals

    private func armSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                let text = self.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                self.onSettled?(text)
            }
        }
    }

    private func permissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { problem = "Speech permission denied"; return false }
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard mic else { problem = "Microphone permission denied"; return false }
        return true
    }

    /// `.playAndRecord` with `.defaultToSpeaker`, not `.record`: this has to talk and listen
    /// at the same time. `.measurement` is avoided deliberately — it disables output
    /// processing and makes the speaker far too quiet across a room.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Not every device accepts `.voicePrompt`, and a category that fails to apply
            // leaves the input node at a zero sample rate — installTap then raises an
            // Objective-C exception no Swift `catch` can see, and the app simply dies.
            do {
                try session.setCategory(.playAndRecord, mode: .voicePrompt,
                                        options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            } catch {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try? session.overrideOutputAudioPort(.speaker)
        } catch {
            problem = "Audio session failed: \(error.localizedDescription)"
        }
    }

    private func startAudio() {
        guard !audioReady else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "Microphone unavailable — audio route not ready"
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [sink] buffer, _ in
            sink.append(buffer)          // audio thread; the sink is the gate
        }
        engine.prepare()
        do {
            try engine.start()
            audioReady = true
        } catch {
            problem = "Microphone failed: \(error.localizedDescription)"
        }
    }
}
