import Foundation

/// One card: a word in the language being learned, and what it means.
struct WordPair: Identifiable, Equatable {
    let id = UUID()
    /// Shown on screen, in the language being learned.
    let word: String
    /// Rough pronunciation, for a child who cannot read the script yet.
    let say: String
    /// The answer. Matching is lenient and accepts any of these.
    let answers: [String]
    let emoji: String

    var answer: String { answers[0] }

    /// Everything that counts as having said this word out loud.
    ///
    /// Tone marks are stripped, so "shū" and "shu" are the same answer — a child learning
    /// their first words of Mandarin should not be failed on tone. The rough English
    /// spelling is accepted too, because an English recogniser hears 书 as "shoe", and
    /// that is a correct attempt, not a wrong one.
    var spokenForms: [String] {
        var forms = [word, speechText]      // "书 shū" and "书" both count
        forms += word.components(separatedBy: " ").dropFirst()   // pinyin half of "书 shū"
        forms.append(say)
        return forms
            .map { $0.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en")) }
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
    }

    /// What the synthesiser says.
    ///
    /// Mandarin cards carry the character plus its pinyin for the printed layout
    /// ("狗 gǒu"), and only the character should be read aloud. Everything else —
    /// including multi-word phrases like "por favor" or "s'il vous plaît" — must be spoken
    /// WHOLE. Splitting on the first space broke every phrase in the deck.
    var speechText: String {
        let hasCJK = word.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard hasCJK else { return word }
        return word.components(separatedBy: " ").first ?? word
    }
}

/// Words the recogniser genuinely confuses with an answer.
///
/// "sun" and "son" are acoustically identical in English — no recogniser can separate them
/// without context, so accepting both is the only correct behaviour. Curated rather than
/// computed: a generic phonetic match is far too loose here and would count "back" as
/// "book", which teaches a child the wrong thing.
enum Homophones {
    static let table: [String: [String]] = [
        "sun":   ["son", "sunn", "sunny"],
        "moon":  ["moan", "mune", "moons"],
        "blue":  ["blew", "bloo", "blu"],
        "red":   ["read", "redd"],
        "water": ["waiter", "wadder", "wata"],
        "house": ["hows", "howse", "haus"],
        "home":  ["hom", "holm"],
        "book":  ["buk", "booke"],
        "star":  ["starr", "stars", "starre"],
        "dog":   ["dawg", "doug", "dogg"],
        "cat":   ["kat", "catt"],
        "puppy": ["puppie", "poppy"],
        "kitty": ["kittie", "kiddie", "kitten"],
    ]

    static func accepted(for answer: String) -> [String] {
        let key = answer.lowercased()
        return [key] + (table[key] ?? [])
    }

    /// One edit apart — catches a single mis-heard sound without opening the door to
    /// genuinely different words. Deliberately tighter than a phonetic algorithm.
    static func isNearMiss(_ a: String, _ b: String) -> Bool {
        guard a.count >= 3, abs(a.count - b.count) <= 1 else { return false }
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[y.count] <= 1
    }
}

struct WordDeck: Identifiable, Equatable {
    let id: String
    let name: String
    let flag: String
    /// Voice used to speak the word aloud. Without this the synthesiser reads foreign
    /// spelling with an English voice, which is worse than useless for a child learning it.
    let locale: String
    /// Said first, in the language being learned, so the session opens like a hello and
    /// not like a test.
    let greeting: String
    let cards: [WordPair]
    /// Short everyday exchanges for the talking lesson. `word` is the phrase in the
    /// language being learned; `answers` is what it means.
    let phrases: [WordPair]

    static let all: [WordDeck] = [spanish, french, mandarin]

    /// Which language a child just asked for, in their own words. Instant and offline;
    /// the model is only consulted when this returns nil.
    static func matching(_ said: String) -> WordDeck? {
        let text = said.lowercased()
        if text.contains("span") || text.contains("espa") { return .spanish }
        if text.contains("french") || text.contains("fran") { return .french }
        if text.contains("mandarin") || text.contains("chin") || text.contains("中文") { return .mandarin }
        return nil
    }

    static let spanish = WordDeck(id: "es", name: "Spanish", flag: "🇪🇸", locale: "es-ES", greeting: "¡Hola! ¿Cómo estás?", cards: [
        WordPair(word: "perro",    say: "PEH-rro",     answers: ["dog", "puppy"],        emoji: "🐕"),
        WordPair(word: "gato",     say: "GAH-toh",     answers: ["cat", "kitty"],        emoji: "🐈"),
        WordPair(word: "rojo",     say: "ROH-hoh",     answers: ["red"],                 emoji: "🔴"),
        WordPair(word: "azul",     say: "ah-SOOL",     answers: ["blue"],                emoji: "🔵"),
        WordPair(word: "sol",      say: "sohl",        answers: ["sun"],                 emoji: "☀️"),
        WordPair(word: "luna",     say: "LOO-nah",     answers: ["moon"],                emoji: "🌙"),
        WordPair(word: "agua",     say: "AH-gwah",     answers: ["water"],               emoji: "💧"),
        WordPair(word: "casa",     say: "KAH-sah",     answers: ["house", "home"],       emoji: "🏠"),
        WordPair(word: "libro",    say: "LEE-broh",    answers: ["book"],                emoji: "📖"),
        WordPair(word: "estrella", say: "es-TREH-yah", answers: ["star"],                emoji: "⭐"),
    ],
    phrases: [
        WordPair(word: "hola",          say: "OH-lah",          answers: ["hello", "hi"],            emoji: "👋"),
        WordPair(word: "buenos días",   say: "BWEH-nos DEE-as", answers: ["good morning"],           emoji: "🌅"),
        WordPair(word: "gracias",       say: "GRAH-syas",       answers: ["thank you", "thanks"],    emoji: "🙏"),
        WordPair(word: "por favor",     say: "por fah-VOR",     answers: ["please"],                 emoji: "✨"),
        WordPair(word: "me llamo",      say: "meh YAH-mo",      answers: ["my name is", "i am called"], emoji: "🪪"),
        WordPair(word: "adiós",         say: "ah-DYOS",         answers: ["goodbye", "bye"],         emoji: "👋"),
    ])

    static let french = WordDeck(id: "fr", name: "French", flag: "🇫🇷", locale: "fr-FR", greeting: "Bonjour ! Comment ça va ?", cards: [
        WordPair(word: "chien",   say: "shyahn",     answers: ["dog", "puppy"],   emoji: "🐕"),
        WordPair(word: "chat",    say: "shah",       answers: ["cat", "kitty"],   emoji: "🐈"),
        WordPair(word: "rouge",   say: "roozh",      answers: ["red"],            emoji: "🔴"),
        WordPair(word: "bleu",    say: "bluh",       answers: ["blue"],           emoji: "🔵"),
        WordPair(word: "soleil",  say: "so-LAY",     answers: ["sun"],            emoji: "☀️"),
        WordPair(word: "lune",    say: "loon",       answers: ["moon"],           emoji: "🌙"),
        WordPair(word: "eau",     say: "oh",         answers: ["water"],          emoji: "💧"),
        WordPair(word: "maison",  say: "may-ZOHN",   answers: ["house", "home"],  emoji: "🏠"),
        WordPair(word: "livre",   say: "LEE-vruh",   answers: ["book"],           emoji: "📖"),
        WordPair(word: "étoile",  say: "ay-TWAHL",   answers: ["star"],           emoji: "⭐"),
    ],
    phrases: [
        WordPair(word: "bonjour",       say: "bon-ZHOOR",     answers: ["hello", "good day"],      emoji: "👋"),
        WordPair(word: "merci",         say: "mair-SEE",      answers: ["thank you", "thanks"],    emoji: "🙏"),
        WordPair(word: "s'il vous plaît", say: "seel voo PLEH", answers: ["please"],               emoji: "✨"),
        WordPair(word: "je m'appelle", say: "zhuh ma-PELL",  answers: ["my name is", "i am called"], emoji: "🪪"),
        WordPair(word: "ça va",         say: "sah VAH",       answers: ["how are you", "i am fine"], emoji: "🙂"),
        WordPair(word: "au revoir",     say: "oh ruh-VWAR",   answers: ["goodbye", "bye"],         emoji: "👋"),
    ])

    static let mandarin = WordDeck(id: "zh", name: "Mandarin", flag: "🇨🇳", locale: "zh-CN", greeting: "你好！你好吗？", cards: [
        WordPair(word: "狗 gǒu",     say: "goh",        answers: ["dog", "puppy"],  emoji: "🐕"),
        WordPair(word: "猫 māo",     say: "mao",        answers: ["cat", "kitty"],  emoji: "🐈"),
        WordPair(word: "红 hóng",    say: "hong",       answers: ["red"],           emoji: "🔴"),
        WordPair(word: "蓝 lán",     say: "lahn",       answers: ["blue"],          emoji: "🔵"),
        WordPair(word: "太阳 tàiyáng", say: "tie-yang",  answers: ["sun"],           emoji: "☀️"),
        WordPair(word: "月亮 yuèliàng", say: "yweh-liang", answers: ["moon"],        emoji: "🌙"),
        WordPair(word: "水 shuǐ",    say: "shway",      answers: ["water"],         emoji: "💧"),
        WordPair(word: "家 jiā",     say: "jyah",       answers: ["house", "home"], emoji: "🏠"),
        WordPair(word: "书 shū",     say: "shoo",       answers: ["book"],          emoji: "📖"),
        WordPair(word: "星 xīng",    say: "shing",      answers: ["star"],          emoji: "⭐"),
    ],
    phrases: [
        WordPair(word: "你好 nǐ hǎo",       say: "nee how",        answers: ["hello", "hi"],         emoji: "👋"),
        WordPair(word: "谢谢 xièxie",       say: "shyeh-shyeh",    answers: ["thank you", "thanks"], emoji: "🙏"),
        WordPair(word: "请 qǐng",           say: "ching",          answers: ["please"],              emoji: "✨"),
        WordPair(word: "我叫 wǒ jiào",      say: "wor jyow",       answers: ["my name is", "i am called"], emoji: "🪪"),
        WordPair(word: "你好吗 nǐ hǎo ma",  say: "nee how mah",    answers: ["how are you"],         emoji: "🙂"),
        WordPair(word: "再见 zàijiàn",      say: "dzai-jyen",      answers: ["goodbye", "bye"],      emoji: "👋"),
    ])
}
