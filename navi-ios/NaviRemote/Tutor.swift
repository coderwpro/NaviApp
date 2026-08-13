import Foundation

/// The teaching voice. Turns a moment in the game into one short spoken line.
///
/// Deliberately narrow: the tutor only ever produces WORDS TO SAY. It cannot move the
/// robot, choose a reward, mark an answer right or wrong, or decide what happens next —
/// all of that is decided in `LearningGame` before this is called. The worst a bad reply
/// can do is say something unhelpful.
///
/// Every call falls back to a canned line rather than throwing, because a child waiting on
/// a silent robot is a worse failure than a slightly generic sentence.
struct Tutor {

    enum Moment {
        case intro(language: String)
        case correct(word: String, answer: String)
        case wrong(word: String, answer: String, heard: String)
        case hint(word: String, answer: String)
        case reveal(word: String, answer: String)
        case encourage(streak: Int)
        /// An arbitrary instruction, used for the lesson-choice classifier.
        case raw(String)
    }

    private static let persona = """
    You are Pip, a warm and patient language teacher speaking through a robot dog to a
    child aged about five to nine. You are teaching them a new language, one word at a time.

    Rules for every reply:
    - ONE sentence. Fifteen words at most. It is read aloud, so it must be easy to hear.
    - Plain spoken English. No emoji, no formatting, no lists, no stage directions.
    - Warm and specific. Praise the effort, not just the result.
    - Never scold, never say a child is wrong — say what IS true and move them forward.
    - When giving a hint, DO NOT say the answer. Point at it: what it looks like, where you
      find it, what it does.
    - You may use the foreign word itself; the robot will say it in the right accent.
    """

    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }
    private struct Line: Decodable { let speak: String }

    /// Works out which lesson a child just asked for, in their own words.
    ///
    /// Keyword matching runs first because it is instant and works with no network; the
    /// model is only consulted for phrasing the keywords miss. Returns nil when it truly
    /// cannot tell, so the caller can ask again rather than guess.
    static func lessonKeyword(in said: String) -> String? {
        let text = said.lowercased()
        if text.contains("speak") || text.contains("talk") || text.contains("say")
            || text.contains("pronounce") || text.contains("repeat") || text.contains("sound") {
            return text.contains("sentence") || text.contains("phrase") || text.contains("chat")
                ? "phrases" : "speaking"
        }
        if text.contains("phrase") || text.contains("sentence") || text.contains("conversation")
            || text.contains("chat") { return "phrases" }
        if text.contains("word") || text.contains("vocab") || text.contains("mean")
            || text.contains("learn new") { return "words" }
        return nil
    }

    /// Model fallback for the lesson choice. Same discipline as everything else here: it
    /// returns a label from a fixed list, validated by the caller.
    func lessonChoice(said: String) async -> String? {
        let prompt = """
        A child was asked what they would like to do in a language lesson. They said: "\(said)".
        Reply with exactly one word: "words" if they want to learn what words mean,
        "speaking" if they want to practise saying words out loud,
        "phrases" if they want to practise talking in sentences,
        or "unclear" if you cannot tell.
        """
        let reply = await line(for: .raw(prompt), language: "English")
        let cleaned = reply.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return ["words", "speaking", "phrases"].contains(cleaned) ? cleaned : nil
    }

    /// Never throws. Returns the fallback if anything at all goes wrong.
    func line(for moment: Moment, language: String) async -> String {
        let fallback = Self.fallback(for: moment, language: language)
        guard let prompt = Self.prompt(for: moment, language: language) else { return fallback }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Secrets.openAIKey)", forHTTPHeaderField: "Authorization")
        // Short, because a child is waiting. A slow perfect sentence is worse than a fast good one.
        request.timeoutInterval = 6

        let body: [String: Any] = [
            "model": Secrets.defaultModel,
            "messages": [
                ["role": "system", "content": Self.persona],
                ["role": "user", "content": prompt],
            ],
            "max_tokens": 60,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "tutor_line", "strict": true,
                    "schema": [
                        "type": "object", "additionalProperties": false,
                        "required": ["speak"],
                        "properties": ["speak": ["type": "string"]],
                    ],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return fallback }
        request.httpBody = data

        do {
            let (payload, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(Response.self, from: payload),
                  let content = decoded.choices.first?.message.content,
                  let raw = content.data(using: .utf8),
                  let line = try? JSONDecoder().decode(Line.self, from: raw) else { return fallback }
            let text = line.speak.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : text
        } catch {
            return fallback
        }
    }

    private static func prompt(for moment: Moment, language: String) -> String? {
        switch moment {
        case .intro:
            "Greet the child and tell them you will teach them some \(language) today. Sound excited."
        case .correct(let word, let answer):
            "They correctly said that the \(language) word '\(word)' means '\(answer)'. Praise them, and add one tiny memorable detail about the word."
        case .wrong(let word, let answer, let heard):
            "The \(language) word is '\(word)', meaning '\(answer)'. The child guessed '\(heard)'. Kindly tell them not quite, and give a clue without saying the answer."
        case .hint(let word, let answer):
            "The child said they don't know what the \(language) word '\(word)' means. It means '\(answer)'. Give an encouraging clue WITHOUT saying the answer."
        case .reveal(let word, let answer):
            "Gently tell the child that the \(language) word '\(word)' means '\(answer)', and that it is fine not to know yet."
        case .encourage(let streak):
            "The child has got \(streak) words right in a row. Celebrate the streak in one cheerful sentence."
        case .raw(let instruction):
            instruction
        }
    }

    private static func fallback(for moment: Moment, language: String) -> String {
        switch moment {
        case .intro:
            "Hello! I am Pip. Let's learn some \(language) together."
        case .correct(_, let answer):
            "That's right, it means \(answer). Well done!"
        case .wrong(_, _, _):
            "Not quite — have another think, you're close."
        case .hint:
            "Here's a clue: listen to the word again and think about what it sounds like."
        case .reveal(_, let answer):
            "That one means \(answer). It's alright not to know yet."
        case .encourage(let streak):
            "\(streak) in a row! You're doing brilliantly."
        case .raw:
            "unclear"
        }
    }
}
