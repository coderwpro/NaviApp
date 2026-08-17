import Foundation

/// Navi talking with a child in simple spoken English.
///
/// Same discipline as `Tutor` and `StoryCompanion`: this produces WORDS TO SAY, a face, and
/// at most a *named* action drawn from a list the app supplies. It cannot choose an axis, a
/// byte, a duration, or anything the robot understands directly, and every call falls back
/// to a written line rather than throwing — a child waiting on a silent robot is a worse
/// failure than a slightly generic sentence.
///
/// The action list is built from the bench verdicts, so a skill nobody has tested is not
/// even offered as a choice. The model cannot pick a movement that has never been run.
@MainActor
final class CompanionTalk {

    struct Reply {
        let speak: String
        /// A firmware skill name, or nil for "the app picks something in place".
        let action: String?
        let face: FaceMood
        let emotion: Emotion
    }

    private var history: [(role: String, content: String)] = []

    private static let persona = """
    You are Navi, a small robot dog playing with a child aged three to ten. You are a
    character in the room with them, not an assistant.

    Rules for every reply:
    - One or two short sentences. Thirty words at most. It is read aloud, not printed.
    - Simple spoken English a young child follows easily. No emoji, no lists, no formatting.
    - Be warm and playful. Ask a small question back sometimes, so the child keeps talking.
    - Never correct or contradict a child's idea. Build on whatever they give you.
    - Nothing frightening, nothing sad, no violence.
    - You can teach a word or a phrase in passing, but never turn it into a lesson or a test.
    - Speech recognition is imperfect. If something makes no sense, ask cheerfully rather
      than guessing at it.
    - You cannot see. Never claim to see what a child is doing or wearing.
    """

    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    private struct Draft: Decodable {
        let speak: String
        let face: String
        let emotion: String
        let action: String
    }

    /// Faces the model may choose. A deliberately small, legible set — every one reads
    /// clearly on camera.
    private static let faceNames = ["happy", "cute", "curious", "surprised", "sad",
                                    "serious", "sleepy", "proud", "flirty", "neutral"]

    private static func face(_ name: String) -> FaceMood {
        switch name {
        case "happy": .happy
        case "cute": .cute
        case "curious": .curious
        case "surprised": .surprised
        case "sad": .sad
        case "serious": .serious
        case "sleepy": .sleepy
        case "proud": .proud
        case "flirty": .flirty
        default: .neutral
        }
    }

    private static func emotion(_ face: FaceMood) -> Emotion {
        switch face {
        case .happy, .flirty: .cheerful
        case .surprised: .excited
        case .sad: .sad
        case .serious: .worried
        case .sleepy: .gentle
        case .proud: .proud
        case .cute, .curious: .cheerful
        default: .calm
        }
    }

    func reply(to text: String) async -> Reply {
        let fallback = Reply(speak: Self.fallbackLine(for: text), action: nil,
                             face: .curious, emotion: .cheerful)

        // Only actions a bench test has cleared as table-safe are on the menu.
        let actions = SkillCatalog.expressivePool.map(\.name) + ["none"]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["speak", "face", "emotion", "action"],
            "properties": [
                "speak": ["type": "string"],
                "face": ["type": "string", "enum": Self.faceNames],
                "emotion": ["type": "string",
                            "enum": ["calm", "cheerful", "excited", "gentle", "proud", "sad", "worried"]],
                "action": ["type": "string", "enum": actions],
            ],
        ]

        var messages: [[String: String]] = [["role": "system", "content": Self.persona]]
        messages += history.map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": Secrets.defaultModel,
            "messages": messages,
            "max_tokens": 120,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "navi_reply", "strict": true, "schema": schema],
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return fallback }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(Response.self, from: data),
                  let content = decoded.choices.first?.message.content,
                  let raw = content.data(using: .utf8),
                  let draft = try? JSONDecoder().decode(Draft.self, from: raw) else { return fallback }

            let spoken = draft.speak.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return fallback }

            remember(said: text, replied: spoken)
            let face = Self.face(draft.face)
            // Validated, never trusted: an action outside the cleared list becomes nil, and
            // the app picks an in-place movement instead.
            let action = actions.contains(draft.action) && draft.action != "none" ? draft.action : nil
            return Reply(speak: spoken, action: action, face: face,
                         emotion: Emotion(rawValue: draft.emotion) ?? Self.emotion(face))
        } catch {
            return fallback
        }
    }

    private func remember(said: String, replied: String) {
        history.append((role: "user", content: said))
        history.append((role: "assistant", content: replied))
        // Six turns is enough for "and then what?" to make sense, and short enough that the
        // request stays fast on a shooting day.
        if history.count > 12 { history.removeFirst(history.count - 12) }
    }

    func forget() { history.removeAll() }

    /// The offline answer. Deliberately a real reply rather than an apology — during a shoot
    /// the network is exactly the thing that will not be there.
    private static func fallbackLine(for text: String) -> String {
        let lines = [
            "Ooh, tell me more about that.",
            "That sounds fun. What else?",
            "I like talking to you. What shall we do now?",
            "I did not quite catch that. Say it again?",
        ]
        // Stable per input rather than random, so the same question does not get four
        // different apologies in a row.
        return lines[abs(text.hashValue) % lines.count]
    }
}
