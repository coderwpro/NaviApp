import Foundation

/// The fixed vocabulary. A model may only return labels from this list; anything else is
/// rejected before it can reach the robot.
enum NaviAction: String, Codable, CaseIterable {
    case forward, backward
    case turnLeft = "turn_left"
    case turnRight = "turn_right"
    case raise, bow, twist
    case stand, sit, lie
    case wagTail = "wag_tail"
    case dance
    // The rest of the firmware skill set. Every one of these sends a `send_skill` name;
    // whether it is safe where the robot is standing is the operator's call on this screen,
    // and the bench verdict's call on the child-facing screens.
    case spin, crawl, wave, stretch, shake
    case shakeHands = "shake_hands"
    case fingerHeart = "finger_heart"
    case pushUps = "push_ups"
    case beCute = "be_cute"
    case impatient
    case stop, unknown
}

/// How hard to move. A word, not a number — the model never picks a byte.
enum NaviEffort: String, Codable, CaseIterable {
    case gentle, normal, brisk

    /// Mapped to axis values here, and clamped again by NaviBLE on the way out.
    var speed: Int {
        switch self {
        case .gentle: 20
        case .normal: 30
        case .brisk: 100
        }
    }
}

/// One step of a spoken instruction. A sentence can produce several.
struct VoiceCommand: Codable {
    let action: NaviAction
    let effort: NaviEffort
    /// What the model asked for. Clamped before use — never trusted as given.
    let seconds: Double
}

/// Turns a spoken sentence into a short list of actions.
///
/// The model classifies and sequences; it does not control. It cannot return an axis, a
/// byte, or a speed in any unit the robot understands — only a label, a word for effort,
/// and a duration that is clamped afterwards. Every physical limit is applied by NaviBLE.
struct IntentClassifier {

    struct ClassifierError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// No sentence may queue more than this many moves.
    static let maxCommands = 5

    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    private struct Payload: Decodable {
        struct Item: Decodable { let action: String; let effort: String; let seconds: Double }
        let commands: [Item]
        let reason: String
    }

    private static let systemPrompt = """
    You turn a spoken command for a four-legged robot dog into a short list of actions.

    The action labels and what they mean:
    - forward     — move ahead ("go", "walk", "come here")
    - backward    — move back ("back up", "reverse")
    - turn_left   — rotate left
    - turn_right  — rotate right
    - raise       — stand taller, lift the body
    - bow         — dip the front of the body down
    - twist       — twist the body side to side
    - stand       — stand up ("get up")
    - sit         — sit down
    - lie         — lie down ("lay down")
    - wag_tail    — wag its tail
    - dance       — dance
    - spin        — spin on the spot
    - crawl       — crawl along the ground
    - wave        — wave a paw ("say hello", "wave at me")
    - stretch     — stretch out
    - shake       — shake its whole body
    - shake_hands — offer a paw to shake
    - finger_heart— make a heart shape ("make a heart")
    - push_ups    — do push-ups
    - be_cute     — a cute little idle animation
    - impatient   — fidget impatiently
    - stop        — stop moving
    - unknown     — ONLY when nothing above fits

    For each action also give:
    - effort: "gentle", "normal" or "brisk". Use gentle for "a little"/"slowly",
      brisk for "fast"/"quickly". Default to normal.
    - seconds: how long to move, 0.25 to 2. Use 1 unless the person implies otherwise.
      Skill actions (everything from stand down to impatient, plus stop) ignore it — send 1.

    Sequences are allowed: "sit down then wag your tail" is two commands in order.
    Never return more than 5.

    IMPORTANT — distances and step counts are NOT measurable on this robot. Nobody has
    calibrated how far it travels per second. If asked for "5 steps" or "two metres",
    approximate with a duration, and SAY in the reason that it is an uncalibrated guess.

    Pick the closest label whenever intent is reasonably clear, including casual or polite
    phrasing. Speech recognition is imperfect, so tolerate small mis-hearings. Use
    "unknown" only when nothing fits — jumping, running, fetching, speaking and going to a
    named place are all impossible for this robot.

    You do not control the robot. A separate program clamps every speed and duration you
    return, so choose the labels and nothing else.
    """

    func classify(_ text: String, key: String, model: String) async throws -> (commands: [VoiceCommand], reason: String) {
        let key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw ClassifierError(message: "no API key") }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12

        let itemSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["action", "effort", "seconds"],
            "properties": [
                "action": ["type": "string", "enum": NaviAction.allCases.map(\.rawValue)],
                "effort": ["type": "string", "enum": NaviEffort.allCases.map(\.rawValue)],
                "seconds": ["type": "number"],
            ],
        ]
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["commands", "reason"],
            "properties": [
                "commands": ["type": "array", "items": itemSchema],
                "reason": ["type": "string"],
            ],
        ]
        let body: [String: Any] = [
            "model": model.isEmpty ? Secrets.defaultModel : model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "navi_plan", "strict": true, "schema": schema],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClassifierError(message: "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              let raw = content.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: raw) else {
            throw ClassifierError(message: "unreadable reply")
        }

        // Validate every field, even with a strict schema. An unrecognised label is
        // dropped rather than guessed at, and the list is truncated rather than trusted.
        let commands: [VoiceCommand] = payload.commands.prefix(Self.maxCommands).compactMap { item in
            guard let action = NaviAction(rawValue: item.action) else { return nil }
            let effort = NaviEffort(rawValue: item.effort) ?? .normal
            return VoiceCommand(action: action, effort: effort, seconds: item.seconds)
        }
        guard !commands.isEmpty else { throw ClassifierError(message: "no usable command") }
        return (commands, payload.reason)
    }
}
