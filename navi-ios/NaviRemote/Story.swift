import Foundation

/// Tone of a single beat. Drives the narrator's voice, the eyes, and — sparingly — the body.
enum Emotion: String {
    case calm, cheerful, excited, worried, sad, sly, scared, proud, gentle

    /// Multipliers on the default speech rate. Slow enough for a three-year-old throughout.
    var rate: Float {
        switch self {
        case .calm: 0.90
        case .gentle: 0.86
        case .cheerful: 0.95
        case .excited: 1.06
        case .worried: 0.88
        case .sad: 0.82
        case .sly: 0.84
        case .scared: 1.10
        case .proud: 0.94
        }
    }

    var pitch: Float {
        switch self {
        case .calm: 1.00
        case .gentle: 1.05
        case .cheerful: 1.15
        case .excited: 1.25
        case .worried: 0.95
        case .sad: 0.88
        case .sly: 0.80
        case .scared: 1.32
        case .proud: 1.10
        }
    }

    /// Tail of silence after the line. Short: two sentences separated by half a second
    /// sounds like buffering, not storytelling.
    var tail: Double {
        switch self {
        case .excited, .scared: 0.05
        case .sad, .gentle: 0.20
        default: 0.10
        }
    }

    var face: FaceMood {
        switch self {
        case .cheerful, .excited, .proud: .happy
        case .worried, .sad, .scared, .sly: .unsure
        case .calm, .gentle: .speaking
        }
    }
}

/// Robot movements a story may call for. IN-PLACE ONLY — the phone is on the robot's back,
/// and a story that walked the robot across the room would drop it.
enum StoryAction: String {
    case nod, wiggle, bow, rearUp, wagTail, dance, sit, liedown

    var label: String { rawValue }
}

struct StoryBeat {
    let text: String
    let emotion: Emotion
    let action: StoryAction?
    /// A question for the child. Playback pauses here and listens.
    let ask: String?

    init(_ text: String, _ emotion: Emotion = .calm, action: StoryAction? = nil, ask: String? = nil) {
        self.text = text
        self.emotion = emotion
        self.action = action
        self.ask = ask
    }
}

struct Story: Identifiable {
    let id: String
    let title: String
    let emoji: String
    let ages: String
    let theme: String
    /// The face the robot wears while telling this one.
    let eyes: EyeStyle
    let beats: [StoryBeat]

    /// Rough spoken length. Used to keep every story inside the five-minute limit.
    var estimatedMinutes: Double {
        let words = beats.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let pauses = Double(beats.filter { $0.ask != nil }.count) * 12.0   // seconds per question
        return (Double(words) / 130.0) + pauses / 60.0
    }
}

/// Ten simplified retellings, written for ages 3–10 and delivered in English.
///
/// All ten are public-domain fables (Aesop, Grimm, Andersen). These are shortened and
/// rewritten for a young listener rather than copied — the originals run far past five
/// minutes and use vocabulary a four-year-old would not follow.
enum StoryLibrary {

    /// A written story matching what the child asked for, or nil — in which case one is
    /// composed from scratch.
    static func matching(_ said: String) -> Story? {
        let text = said.lowercased()
        let keys: [(String, Story)] = [
            ("tortoise", hareAndTortoise), ("hare", hareAndTortoise), ("rabbit", hareAndTortoise),
            ("lion", lionAndMouse), ("mouse", lionAndMouse),
            ("wolf", shepherdBoy), ("shepherd", shepherdBoy), ("sheep", shepherdBoy),
            ("fox", foxAndGrapes), ("grape", foxAndGrapes),
            ("grasshopper", grasshopperAndAnts), ("ant", grasshopperAndAnts),
            ("elves", elvesAndShoemaker), ("elf", elvesAndShoemaker), ("shoemaker", elvesAndShoemaker),
            ("musician", travellingMusicians), ("bremen", travellingMusicians), ("donkey", travellingMusicians),
            ("pig", threeLittlePigs),
            ("bear", threeBears), ("goldilocks", threeBears),
            ("emperor", emperorsClothes), ("king", emperorsClothes),
        ]
        return keys.first { text.contains($0.0) }?.1
    }

    static let all: [Story] = [
        hareAndTortoise, lionAndMouse, shepherdBoy, foxAndGrapes, grasshopperAndAnts,
        elvesAndShoemaker, travellingMusicians, threeLittlePigs, threeBears, emperorsClothes,
    ]

    // MARK: 1

    static let hareAndTortoise = Story(
        id: "hare", title: "The Hare and the Tortoise", emoji: "🐢",
        ages: "4–8", theme: "Persistence · don't underestimate others",
        eyes: .tortoise,
        beats: [
            StoryBeat("Once there was a hare who could run faster than anyone in the whole wood.", .cheerful, action: .nod),
            StoryBeat("He liked to tell everybody about it. \"Look at my legs! Nobody can beat me!\"", .proud, action: .rearUp),
            StoryBeat("One day a slow old tortoise said, quietly, \"I will race you.\"", .gentle),
            StoryBeat("The hare laughed and laughed. \"You? You can hardly walk!\"", .cheerful,
                      ask: "Who do you think will win the race?"),
            StoryBeat("The race began. The hare shot away like the wind, and the tortoise plodded slowly behind.", .excited, action: .wiggle),
            StoryBeat("Soon the hare was so far ahead he thought, \"I have time for a little nap.\" And he fell fast asleep under a tree.", .calm, action: .liedown),
            StoryBeat("Step. Step. Step. The tortoise never stopped. Not once.", .gentle),
            StoryBeat("When the hare woke up, the tortoise was crossing the finish line!", .scared, action: .rearUp),
            StoryBeat("Slow and steady wins the race.", .proud, action: .dance,
                      ask: "What do you think the hare learned?"),
        ])

    // MARK: 2

    static let lionAndMouse = Story(
        id: "lion", title: "The Lion and the Mouse", emoji: "🦁",
        ages: "4–8", theme: "Kindness · helping each other",
        eyes: .lion,
        beats: [
            StoryBeat("A great lion lay sleeping in the sun, and a tiny mouse ran right across his paw.", .calm, action: .liedown),
            StoryBeat("The lion woke with a mighty ROAR and caught the little mouse in his claws.", .scared, action: .rearUp),
            StoryBeat("\"Please let me go,\" squeaked the mouse. \"One day I may help you.\"", .worried),
            StoryBeat("The lion laughed. How could such a small creature ever help him? But he let her go.", .cheerful,
                      ask: "Do you think a tiny mouse could help a big lion?"),
            StoryBeat("Some days later, hunters caught the lion in a great rope net. He could not move at all.", .worried, action: .bow),
            StoryBeat("He roared and roared. And who came running? The little mouse.", .excited, action: .wiggle),
            StoryBeat("Nibble, nibble, nibble. She chewed the ropes until the lion was free.", .gentle),
            StoryBeat("\"You were right,\" said the lion. \"Even the smallest friend can be the greatest help.\"", .proud, action: .wagTail,
                      ask: "Can you think of a time someone small helped you?"),
        ])

    // MARK: 3

    static let shepherdBoy = Story(
        id: "wolf", title: "The Shepherd's Boy and the Wolf", emoji: "🐑",
        ages: "4–8", theme: "Honesty · trust",
        eyes: .wolf,
        beats: [
            StoryBeat("A boy looked after sheep on a lonely hill. It was quiet. It was slow. He was bored.", .calm),
            StoryBeat("So he had an idea. He ran down shouting, \"Wolf! Wolf! A wolf is eating the sheep!\"", .excited, action: .rearUp),
            StoryBeat("The villagers dropped everything and ran up the hill. But there was no wolf. The boy laughed and laughed.", .sly, action: .wiggle),
            StoryBeat("The next day he did it again. \"Wolf! Wolf!\" And again the villagers came running for nothing.", .sly,
                      ask: "How do you think the villagers felt?"),
            StoryBeat("Then, one evening, a real wolf came out of the trees.", .scared, action: .bow),
            StoryBeat("\"Wolf! WOLF!\" screamed the boy. \"Please! This time it's real!\"", .scared),
            StoryBeat("But down in the village, everyone shook their heads. \"He is only joking again.\" Nobody came.", .sad, action: .liedown),
            StoryBeat("When we tell lies, people stop believing us — even when we tell the truth.", .gentle,
                      ask: "What should the boy have done instead?"),
        ])

    // MARK: 4

    static let foxAndGrapes = Story(
        id: "fox", title: "The Fox and the Grapes", emoji: "🦊",
        ages: "5–9", theme: "Facing failure · self-awareness",
        eyes: .fox,
        beats: [
            StoryBeat("A hungry fox was walking through a garden when he saw them: fat purple grapes, high on a vine.", .cheerful),
            StoryBeat("They looked juicy. They looked sweet. His mouth watered.", .gentle),
            StoryBeat("He jumped. He missed. He backed up and ran and jumped higher. He missed again.", .excited, action: .rearUp,
                      ask: "What would you do if you couldn't reach something?"),
            StoryBeat("He tried and tried until his legs were tired and his fur was full of leaves.", .worried, action: .wiggle),
            StoryBeat("At last he walked away with his nose in the air. \"I didn't want them anyway,\" he said. \"They were probably sour.\"", .sly, action: .bow),
            StoryBeat("But the grapes were not sour. The fox just could not reach them.", .calm),
            StoryBeat("It is easy to say we never wanted the thing we could not have.", .gentle,
                      ask: "Was the fox being honest with himself?"),
        ])

    // MARK: 5

    static let grasshopperAndAnts = Story(
        id: "grasshopper", title: "The Grasshopper and the Ants", emoji: "🐜",
        ages: "5–9", theme: "Planning · responsibility · diligence",
        eyes: .insect,
        beats: [
            StoryBeat("All summer long the grasshopper sang. Chirp, chirp, chirp! The sun was warm and the grass was green.", .cheerful, action: .dance),
            StoryBeat("Nearby, the ants worked. Up and down, up and down, carrying grain to their nest.", .calm, action: .nod),
            StoryBeat("\"Why work on such a lovely day?\" laughed the grasshopper. \"Come and sing with me!\"", .cheerful),
            StoryBeat("\"We are storing food,\" said an ant. \"Winter is coming.\" The grasshopper only laughed.", .gentle,
                      ask: "Do you think the grasshopper should help?"),
            StoryBeat("Then the leaves fell. The wind turned cold. Snow covered the field.", .worried, action: .bow),
            StoryBeat("The grasshopper had no food at all. Shivering, he knocked at the ants' door.", .sad),
            StoryBeat("The ants were warm inside, with plenty to eat, because they had thought ahead.", .calm),
            StoryBeat("There is a time to play and a time to get ready.", .gentle, action: .nod,
                      ask: "What is something you get ready for?"),
        ])

    // MARK: 6

    static let elvesAndShoemaker = Story(
        id: "elves", title: "The Elves and the Shoemaker", emoji: "👞",
        ages: "5–9", theme: "Kindness · gratitude · mutual help",
        eyes: .elf,
        beats: [
            StoryBeat("A poor shoemaker had leather for just one last pair of shoes. He cut it out and went to bed, worried.", .worried),
            StoryBeat("In the morning — what a surprise! There on the bench stood the finest shoes he had ever seen.", .excited, action: .rearUp,
                      ask: "Who do you think made them?"),
            StoryBeat("They sold at once, for enough money to buy leather for two more pairs.", .cheerful),
            StoryBeat("And every night it happened again. Cut the leather, go to sleep, wake to beautiful shoes.", .gentle, action: .nod),
            StoryBeat("So one night the shoemaker and his wife hid behind a curtain, and they watched.", .sly),
            StoryBeat("At midnight, two tiny elves crept in — with no clothes at all — and stitched and hammered until dawn.", .excited, action: .wiggle),
            StoryBeat("\"They have helped us all winter,\" whispered the wife. \"Let us make them something warm.\"", .gentle),
            StoryBeat("They sewed two little coats and two little pairs of boots and left them on the bench.", .cheerful, action: .wagTail),
            StoryBeat("The elves danced with joy, and skipped away into the world. And the shoemaker was never poor again.", .proud, action: .dance,
                      ask: "How would you say thank you to someone who helped you?"),
        ])

    // MARK: 7

    static let travellingMusicians = Story(
        id: "musicians", title: "The Travelling Musicians", emoji: "🎺",
        ages: "6–10", theme: "Teamwork · courage",
        eyes: .donkey,
        beats: [
            StoryBeat("An old donkey was too tired to work, so he left to become a musician in the town of Bremen.", .calm, action: .nod),
            StoryBeat("On the road he met a dog, then a cat, then a rooster — all old, all sad, all with nowhere to go.", .sad),
            StoryBeat("\"Come with me,\" said the donkey. \"Together we will make music.\"", .cheerful, action: .wagTail,
                      ask: "Why is it better to travel together?"),
            StoryBeat("That night they found a little house in the woods, full of robbers eating a fine supper.", .sly),
            StoryBeat("The four friends made a plan. The dog climbed on the donkey. The cat on the dog. The rooster on top.", .excited, action: .rearUp),
            StoryBeat("Then they all sang at once! HEE-HAW! WOOF! MEOW! COCK-A-DOODLE-DOO!", .excited, action: .dance),
            StoryBeat("The robbers had never heard such a terrible noise. They ran away into the dark and never came back.", .scared, action: .wiggle),
            StoryBeat("And the four old friends lived in that house happily, for the rest of their days.", .proud,
                      ask: "What could you do with friends that you couldn't do alone?"),
        ])

    // MARK: 8

    static let threeLittlePigs = Story(
        id: "pigs", title: "The Story of the Three Little Pigs", emoji: "🐷",
        ages: "4–8", theme: "Planning · effort · problem solving",
        eyes: .pig,
        beats: [
            StoryBeat("Three little pigs set off to build their own houses.", .cheerful, action: .nod),
            StoryBeat("The first was in a hurry. He built his house of straw, and finished before lunch.", .cheerful),
            StoryBeat("The second built his of sticks. A little stronger, and finished by tea time.", .calm),
            StoryBeat("The third worked all week, laying brick upon brick upon brick.", .calm, action: .nod,
                      ask: "Whose house do you think is strongest?"),
            StoryBeat("Along came the wolf. \"Little pig, little pig, let me come in!\"", .sly),
            StoryBeat("\"Not by the hair on my chinny chin chin!\" So he huffed, and he puffed, and he blew the straw house down!", .scared, action: .rearUp),
            StoryBeat("The sticks blew down too. Both pigs ran to their brother's house of brick.", .worried, action: .wiggle),
            StoryBeat("The wolf huffed. He puffed. He huffed again — but the bricks did not move at all.", .excited),
            StoryBeat("The work that takes longest often lasts longest.", .proud, action: .dance,
                      ask: "What is something worth taking your time over?"),
        ])

    // MARK: 9

    static let threeBears = Story(
        id: "bears", title: "The Story of the Three Bears", emoji: "🐻",
        ages: "4–8", theme: "Respecting boundaries · consequences",
        eyes: .bear,
        beats: [
            StoryBeat("Three bears lived in a little house in the wood: a great big bear, a middle-sized bear, and a small wee bear.", .calm, action: .nod),
            StoryBeat("One morning their porridge was too hot, so they went for a walk while it cooled.", .gentle),
            StoryBeat("While they were out, a girl called Goldilocks opened their door and walked straight in.", .sly,
                      ask: "Should she go inside someone's house without asking?"),
            StoryBeat("She tasted the big bowl — too hot! The middle bowl — too cold! The little bowl — just right. She ate it all up.", .cheerful),
            StoryBeat("She sat in the great chair — too hard. The middle chair — too soft. The little chair — just right. And it broke!", .scared, action: .wiggle),
            StoryBeat("Upstairs she tried the beds, and fell fast asleep in the smallest one.", .gentle, action: .liedown),
            StoryBeat("Home came the bears. \"Somebody has been eating my porridge!\" \"And mine!\" \"And mine — and it's all gone!\"", .worried),
            StoryBeat("\"Somebody is sleeping in my bed — and here she is!\" Goldilocks woke, jumped up, and ran all the way home.", .scared, action: .rearUp),
            StoryBeat("Other people's things are theirs. It is kind to ask first.", .gentle,
                      ask: "What should Goldilocks have done instead?"),
        ])

    // MARK: 10

    static let emperorsClothes = Story(
        id: "emperor", title: "The Emperor's New Clothes", emoji: "👑",
        ages: "6–10", theme: "Honesty · independent thinking",
        eyes: .emperor,
        beats: [
            StoryBeat("There was once an emperor who cared about nothing so much as his beautiful clothes.", .proud, action: .rearUp),
            StoryBeat("Two clever tricksters came to town. \"We weave a magic cloth,\" they said. \"Only clever people can see it. Fools see nothing at all.\"", .sly),
            StoryBeat("They were given gold and silk, and they pretended to weave on empty looms.", .sly, action: .wiggle),
            StoryBeat("The emperor sent his wisest minister to look. He saw nothing. Nothing at all!", .worried,
                      ask: "Do you think he told the truth?"),
            StoryBeat("But he was afraid to seem a fool, so he said, \"Oh! How beautiful!\" And everyone else said the same.", .worried),
            StoryBeat("So the emperor put on his new clothes — which were no clothes — and paraded through the town.", .cheerful, action: .nod),
            StoryBeat("Everybody cheered. \"What wonderful colours!\" they cried, because nobody wanted to look silly.", .cheerful),
            StoryBeat("Then one small child said, out loud, \"But he isn't wearing anything at all!\"", .excited, action: .rearUp),
            StoryBeat("And it was true. And once one person said it, everybody knew it had been true all along.", .gentle),
            StoryBeat("It takes courage to say what you really see.", .proud, action: .wagTail,
                      ask: "When is it hard to say what you think?"),
        ])
}
