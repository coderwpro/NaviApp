import Foundation

/// Writes a brand-new bedtime story about whatever the child asked for.
///
/// Returns the same `Story` shape the ten written ones use, so everything downstream —
/// narration, emotion, in-place actions, the eyes — works identically whether a story came
/// from the library or from the model.
///
/// The model chooses words, tone and pacing. It does NOT choose what the robot does with
/// its body: action names are validated against a fixed list here, and anything unknown is
/// dropped rather than guessed at.
struct StoryComposer {

    struct ComposerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    private struct Draft: Decodable {
        struct Beat: Decodable {
            let text: String
            let emotion: String
            let action: String
            let ask: String
        }
        let title: String
        let beats: [Beat]
    }

    private static let brief = """
    You write bedtime stories for a robot dog to read aloud to a child aged three to ten.

    Length: 10 to 13 beats, each one or two sentences. The whole story must take about two
    minutes to read aloud — roughly 250 to 300 words in total. Do not exceed that.

    Style:
    - Simple spoken English a young child follows easily. Short sentences.
    - Gentle throughout. Nothing frightening, nothing sad at the end, no peril that is not
      resolved warmly within a beat or two. It is bedtime.
    - Give it a clear beginning, a small problem, and a kind resolution.
    - Sound like someone telling it, not like something written down.

    For each beat also give:
    - emotion: one of calm, cheerful, excited, worried, sad, sly, scared, proud, gentle.
      Use worried, sly and scared sparingly and never in the last two beats.
    - action: what the robot dog does, one of nod, wiggle, bow, rearUp, wagTail, dance,
      sit, liedown, or none. Use none for most beats — a robot moving constantly is
      distracting. Two or three movements in the whole story is plenty.
    - ask: a short question for the child, or an empty string. Use at most two questions in
      the whole story, and never in the last beat.

    End on a calm, warm beat suitable for falling asleep to.
    """

    func compose(about topic: String) async throws -> Story {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45

        let beatSchema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["text", "emotion", "action", "ask"],
            "properties": [
                "text": ["type": "string"],
                "emotion": ["type": "string",
                            "enum": ["calm", "cheerful", "excited", "worried", "sad", "sly", "scared", "proud", "gentle"]],
                "action": ["type": "string",
                           "enum": ["nod", "wiggle", "bow", "rearUp", "wagTail", "dance", "sit", "liedown", "none"]],
                "ask": ["type": "string"],
            ],
        ]
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["title", "beats"],
            "properties": [
                "title": ["type": "string"],
                "beats": ["type": "array", "items": beatSchema],
            ],
        ]
        let body: [String: Any] = [
            "model": Secrets.defaultModel,
            "messages": [
                ["role": "system", "content": Self.brief],
                ["role": "user", "content": "Write a bedtime story about: \(topic)"],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "bedtime_story", "strict": true, "schema": schema],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ComposerError(message: "the story service did not answer")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let content = decoded.choices.first?.message.content,
              let raw = content.data(using: .utf8),
              let draft = try? JSONDecoder().decode(Draft.self, from: raw),
              !draft.beats.isEmpty else {
            throw ComposerError(message: "the story came back unreadable")
        }

        let beats: [StoryBeat] = draft.beats.compactMap { beat in
            let text = beat.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Validated, never trusted: an unrecognised emotion becomes calm, and an
            // unrecognised action becomes no movement at all.
            let emotion = Emotion(rawValue: beat.emotion) ?? .calm
            let action = StoryAction(rawValue: beat.action)
            let ask = beat.ask.trimmingCharacters(in: .whitespacesAndNewlines)
            return StoryBeat(text, emotion, action: action, ask: ask.isEmpty ? nil : ask)
        }
        guard !beats.isEmpty else { throw ComposerError(message: "the story came back empty") }

        return Story(id: "made-\(UUID().uuidString.prefix(6))",
                     title: draft.title.isEmpty ? topic.capitalized : draft.title,
                     emoji: "✨",
                     ages: "3–10",
                     theme: topic,
                     eyes: Self.eyes(for: topic + " " + draft.title),
                     beats: beats)
    }

    /// A face to wear for a made-up story, guessed from what it is about. Falls back to
    /// the storyteller's own eyes rather than picking something arbitrary.
    private static func eyes(for text: String) -> EyeStyle {
        let t = text.lowercased()
        if t.contains("fox") { return .fox }
        if t.contains("wolf") { return .wolf }
        if t.contains("lion") || t.contains("tiger") || t.contains("cat") { return .lion }
        if t.contains("bear") { return .bear }
        if t.contains("pig") { return .pig }
        if t.contains("turtle") || t.contains("tortoise") || t.contains("frog") { return .tortoise }
        if t.contains("bug") || t.contains("ant") || t.contains("bee") || t.contains("insect") { return .insect }
        if t.contains("fairy") || t.contains("elf") || t.contains("magic") || t.contains("dragon") { return .elf }
        if t.contains("horse") || t.contains("donkey") || t.contains("pony") { return .donkey }
        return .human
    }
}
