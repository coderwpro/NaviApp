import Foundation
import AVFoundation

/// Everything the robot says, in one place.
///
/// Two voices, in order of preference:
///  1. OpenAI text-to-speech — genuinely human, and it accepts a plain-English instruction
///     about HOW to say the line, which is what makes a sly wolf sound sly.
///  2. The best on-device voice available — used when the network is slow, absent, or the
///     natural voice is switched off. iOS defaults to the *compact* voice, which is the
///     robotic one everybody recognises; this deliberately hunts for premium or enhanced.
///
/// A story cannot stall on a network call, so every line falls back rather than throwing,
/// and the next line is fetched while the current one is still playing.
@MainActor
final class SpeechEngine: NSObject, ObservableObject {

    @Published var useNaturalVoice = true
    /// True while a line is actually playing. The eyes use it for the speaking rhythm, so
    /// a delighted or sly face still moves while it talks instead of having to BE `.speaking`.
    @Published private(set) var isSpeaking = false
    @Published private(set) var lastFallbackReason: String?

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private var synthContinuation: CheckedContinuation<Void, Never>?

    /// Audio already fetched, keyed by what was asked for. Small — a story is ~10 lines.
    private var cache: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Speaking

    func speak(_ text: String, emotion: Emotion, language: String = "en-US") async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSpeaking = true
        defer { isSpeaking = false }

        if useNaturalVoice, let data = await audio(for: text, emotion: emotion, language: language) {
            await play(data)
            if emotion.tail > 0 {
                try? await Task.sleep(nanoseconds: UInt64(emotion.tail * 1_000_000_000))
            }
            return
        }
        await speakOnDevice(text, emotion: emotion, language: language)
    }

    /// Start fetching a line now so it is ready the moment it is needed.
    func prefetch(_ text: String, emotion: Emotion, language: String = "en-US") {
        guard useNaturalVoice, !text.isEmpty else { return }
        let key = Self.key(text, emotion, language)
        guard cache[key] == nil, inFlight[key] == nil else { return }
        inFlight[key] = Task { await Self.fetch(text, emotion, language) }
    }

    func stop() {
        isSpeaking = false
        player?.stop()
        player = nil
        playbackContinuation?.resume(); playbackContinuation = nil
        synth.stopSpeaking(at: .immediate)
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
    }

    func clearCache() {
        cache.removeAll()
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Natural voice

    private func audio(for text: String, emotion: Emotion, language: String) async -> Data? {
        let key = Self.key(text, emotion, language)
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] {
            let data = await running.value
            inFlight[key] = nil
            if let data { cache[key] = data }
            return data
        }
        let data = await Self.fetch(text, emotion, language)
        if let data {
            cache[key] = data
        } else {
            lastFallbackReason = "natural voice unavailable — using the on-device voice"
        }
        return data
    }

    private static func key(_ text: String, _ emotion: Emotion, _ language: String) -> String {
        "\(language)|\(emotion.rawValue)|\(text)"
    }

    private static func fetch(_ text: String, _ emotion: Emotion, _ language: String) async -> Data? {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12

        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            // "fable" is the warm storyteller of the set — right for a robot reading to a child.
            "voice": "fable",
            "input": text,
            "instructions": emotion.deliveryInstruction(language: language),
            "response_format": "mp3",
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func play(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackContinuation?.resume()
            playbackContinuation = continuation
            do {
                let audioPlayer = try AVAudioPlayer(data: data)
                audioPlayer.delegate = self
                audioPlayer.volume = 1.0
                audioPlayer.prepareToPlay()
                player = audioPlayer
                audioPlayer.play()
            } catch {
                playbackContinuation = nil
                continuation.resume()
            }
        }
    }

    // MARK: - On-device fallback

    /// iOS hands out the compact voice by default. Premium and enhanced voices sound far
    /// better but only exist if the user has downloaded them
    /// (Settings → Accessibility → Spoken Content → Voices).
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    private func speakOnDevice(_ text: String, emotion: Emotion, language: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            synthContinuation?.resume()
            synthContinuation = continuation
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.bestVoice(for: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * emotion.rate
            utterance.pitchMultiplier = emotion.pitch
            utterance.postUtteranceDelay = emotion.tail
            utterance.volume = 1.0
            synth.speak(utterance)
        }
    }
}

// MARK: - Completion

extension SpeechEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            playbackContinuation?.resume(); playbackContinuation = nil
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            playbackContinuation?.resume(); playbackContinuation = nil
        }
    }
}

extension SpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in synthContinuation?.resume(); synthContinuation = nil }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in synthContinuation?.resume(); synthContinuation = nil }
    }
}

// MARK: - Emotion as a spoken instruction

extension Emotion {
    /// Plain English telling the model HOW to deliver the line. This is the part that makes
    /// a natural voice worth the round trip — pitch and rate numbers cannot do it.
    func deliveryInstruction(language: String) -> String {
        let base: String
        switch self {
        case .calm:     base = "Warm and steady, like a parent reading at bedtime."
        case .gentle:   base = "Very soft and tender, slowing down at the end."
        case .cheerful: base = "Bright and smiling, with a light bounce."
        case .excited:  base = "Fast and thrilled, eyes wide, barely able to wait."
        case .worried:  base = "Hushed and uneasy, as if something is about to go wrong."
        case .sad:      base = "Slow and heavy-hearted, but kind."
        case .sly:      base = "Low, sneaky and mischievous, almost a whisper."
        case .scared:   base = "Urgent and breathless, high and quick."
        case .proud:    base = "Full of warmth and quiet pride, unhurried."
        }
        let audience = "You are a friendly robot dog telling a story to a young child. "
        let tongue = language.hasPrefix("en") ? "" :
            " Pronounce this correctly as \(Locale.current.localizedString(forIdentifier: language) ?? language)."
        return audience + base + tongue
    }
}
