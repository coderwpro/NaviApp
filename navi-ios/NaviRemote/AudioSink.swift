import Foundation
import AVFoundation
import Speech

/// The bridge between the audio thread and the recogniser.
///
/// The microphone tap is installed ONCE and left alone. Everything that used to require
/// tearing the engine down — clearing the transcript, stopping the phone from hearing
/// itself — is done here instead, by swapping the request or closing a gate.
///
/// Why it matters: `setCategory` / `setActive` / `engine.start()` are expensive and
/// disruptive. Calling them between every question interrupts playback mid-word, drops the
/// first moment of every answer, and makes the whole screen feel laggy.
///
/// `@unchecked Sendable` with a lock: `append` is called on the real-time audio thread and
/// cannot touch main-actor state.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var open = false

    /// Point the microphone at a new request — this is how the transcript is cleared,
    /// with no audio teardown at all.
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); self.request = request; lock.unlock()
    }

    /// Closed while the phone is speaking, so it never transcribes its own voice.
    func setOpen(_ open: Bool) {
        lock.lock(); self.open = open; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let target = open ? request : nil
        lock.unlock()
        target?.append(buffer)
    }
}
