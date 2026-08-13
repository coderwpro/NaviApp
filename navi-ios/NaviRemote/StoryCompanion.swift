import Foundation

/// Pip's storytelling voice — the part of the story session that has to respond to what a
/// child actually said, rather than read from a script.
///
/// Same discipline as `Tutor`: this only ever produces WORDS TO SAY. It cannot move the
/// robot, choose an action, decide whether a retelling was right, or end a session. Every
/// call falls back to a written line rather than throwing, because a child waiting on a
/// silent robot is a worse failure than a slightly generic sentence.
struct StoryCompanion {

    enum Moment {
        /// The child answered one of the story's own questions.
        case answeredQuestion(story: String, question: String, said: String)
        /// A story just ended.
        case finishedStory(story: String, theme: String)
        /// The child is retelling; `soFar` is everything they have said.
        case retellingProgress(story: String, soFar: String, round: Int)
        /// Opening line for a brand-new made-up story.
        case startCreating(inspiredBy: String, theme: String)
        /// The child added an idea; carry it forward.
        case continueCreating(soFar: String, childSaid: String, isLast: Bool)
    }

    private static let persona = """
    You are Pip, a warm storytelling robot dog talking with a child aged three to ten.

    Rules for every reply:
    - One or two short sentences. Thirty words at most. It is read aloud.
    - Simple spoken English a young child follows easily. No emoji, no formatting.
    - Never correct or contradict a child's idea. Build on whatever they give you.
    - Never say a retelling was wrong or incomplete. Praise something specific they said.
    - Keep everything gentle: no violence, no frightening images, nothing sad at the end.
    - You are a character in the room, not a narrator describing one.
    """

    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }
    private struct Line: Decodable { let speak: String }

    func reply(_ moment: Moment) async -> String {
        let fallback = Self.fallback(moment)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        let body: [String: Any] = [
            "model": Secrets.defaultModel,
            "messages": [
                ["role": "system", "content": Self.persona],
                ["role": "user", "content": Self.prompt(moment)],
            ],
            "max_tokens": 90,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "pip_line", "strict": true,
                    "schema": [
                        "type": "object", "additionalProperties": false,
                        "required": ["speak"],
                        "properties": ["speak": ["type": "string"]],
                    ],
                ],
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
                  let line = try? JSONDecoder().decode(Line.self, from: raw) else { return fallback }
            let text = line.speak.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : text
        } catch {
            return fallback
        }
    }

    private static func prompt(_ moment: Moment) -> String {
        switch moment {
        case .answeredQuestion(let story, let question, let said):
            "During '\(story)' you asked: \"\(question)\". The child answered: \"\(said)\". Respond warmly to their answer in one sentence, then move the story on."
        case .finishedStory(let story, let theme):
            "'\(story)' has just ended. Its idea is: \(theme). Say a warm closing line to the child about it."
        case .retellingProgress(let story, let soFar, let round):
            "The child is retelling '\(story)'. So far they said: \"\(soFar)\". \(round < 3 ? "Praise one specific thing and ask what happens next." : "Praise their whole retelling warmly and finish up.")"
        case .startCreating(let inspiredBy, let theme):
            "Start a brand new made-up story for the child, in the spirit of '\(inspiredBy)' and about \(theme). Give only the opening — two sentences — then ask what happens next."
        case .continueCreating(let soFar, let childSaid, let isLast):
            "The story so far: \"\(soFar)\". The child just added: \"\(childSaid)\". \(isLast ? "Bring the story to a happy ending in two sentences." : "Continue their idea with one or two sentences, then ask what happens next.")"
        }
    }

    private static func fallback(_ moment: Moment) -> String {
        switch moment {
        case .answeredQuestion:
            "That is a lovely thought. Let us see what happens next."
        case .finishedStory(let story, _):
            "That is the end of \(story). Thank you for listening with me."
        case .retellingProgress(_, _, let round):
            round < 3 ? "You are telling it so well. What happens next?"
                      : "What a wonderful storyteller you are."
        case .startCreating:
            "Once upon a time, a small robot dog found a door in a tree. What happens next?"
        case .continueCreating(_, _, let isLast):
            isLast ? "And so they all went home happy, and slept very well indeed."
                   : "Ooh, I like that. And then what happens?"
        }
    }
}
