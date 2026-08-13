import SwiftUI

/// What the face is doing. Shared by every screen that shows the eyes.
enum FaceMood {
    case idle, listening, speaking, happy, unsure
}

/// Pupil geometry. The single biggest cue that a pair of eyes is not human.
enum PupilShape {
    case round          // people, dogs, bears
    case verticalSlit   // foxes, cats, wolves at night
    case horizontalBar  // sheep, goats, tortoises
}

/// How a pair of eyes is drawn. Stories each carry their own, so the robot's face becomes
/// the character it is narrating.
struct EyeStyle {
    var iris: [Color]           // inner → outer
    var pupil: PupilShape = .round
    var lashes = true
    var brow = true
    var sclera: Color = Color(red: 0.85, green: 0.80, blue: 0.79)
    var glow: Color = .cyan

    /// The default face: the hazel human eye used everywhere outside a story.
    static let human = EyeStyle(iris: [
        Color(red: 0.72, green: 0.56, blue: 0.28),
        Color(red: 0.55, green: 0.39, blue: 0.19),
        Color(red: 0.34, green: 0.23, blue: 0.11),
    ])

    static let tortoise = EyeStyle(
        iris: [Color(red: 0.80, green: 0.68, blue: 0.34), Color(red: 0.46, green: 0.36, blue: 0.15),
               Color(red: 0.20, green: 0.16, blue: 0.07)],
        pupil: .horizontalBar, lashes: false, brow: false,
        sclera: Color(red: 0.78, green: 0.76, blue: 0.66), glow: .green)

    static let lion = EyeStyle(
        iris: [Color(red: 0.98, green: 0.83, blue: 0.36), Color(red: 0.85, green: 0.58, blue: 0.14),
               Color(red: 0.44, green: 0.26, blue: 0.05)],
        pupil: .round, lashes: false, brow: true,
        sclera: Color(red: 0.90, green: 0.83, blue: 0.68), glow: .orange)

    static let wolf = EyeStyle(
        iris: [Color(red: 0.90, green: 0.92, blue: 0.55), Color(red: 0.62, green: 0.72, blue: 0.28),
               Color(red: 0.22, green: 0.30, blue: 0.10)],
        pupil: .verticalSlit, lashes: false, brow: true,
        sclera: Color(red: 0.84, green: 0.85, blue: 0.78), glow: .yellow)

    static let fox = EyeStyle(
        iris: [Color(red: 0.98, green: 0.74, blue: 0.30), Color(red: 0.83, green: 0.45, blue: 0.12),
               Color(red: 0.36, green: 0.16, blue: 0.04)],
        pupil: .verticalSlit, lashes: false, brow: false,
        sclera: Color(red: 0.90, green: 0.84, blue: 0.72), glow: .orange)

    static let insect = EyeStyle(
        iris: [Color(red: 0.35, green: 0.60, blue: 0.32), Color(red: 0.18, green: 0.36, blue: 0.16),
               Color(red: 0.05, green: 0.12, blue: 0.05)],
        pupil: .round, lashes: false, brow: false,
        sclera: Color(red: 0.62, green: 0.68, blue: 0.55), glow: .green)

    static let elf = EyeStyle(
        iris: [Color(red: 0.72, green: 0.98, blue: 0.80), Color(red: 0.28, green: 0.78, blue: 0.58),
               Color(red: 0.08, green: 0.36, blue: 0.28)],
        pupil: .round, lashes: true, brow: false,
        sclera: Color(white: 0.92), glow: .mint)

    static let donkey = EyeStyle(
        iris: [Color(red: 0.52, green: 0.40, blue: 0.30), Color(red: 0.34, green: 0.24, blue: 0.16),
               Color(red: 0.14, green: 0.09, blue: 0.05)],
        pupil: .horizontalBar, lashes: true, brow: false,
        sclera: Color(red: 0.82, green: 0.78, blue: 0.72), glow: .brown)

    static let pig = EyeStyle(
        iris: [Color(red: 0.68, green: 0.48, blue: 0.42), Color(red: 0.46, green: 0.28, blue: 0.24),
               Color(red: 0.22, green: 0.12, blue: 0.10)],
        pupil: .round, lashes: true, brow: false,
        sclera: Color(red: 0.94, green: 0.86, blue: 0.85), glow: .pink)

    static let bear = EyeStyle(
        iris: [Color(red: 0.42, green: 0.28, blue: 0.16), Color(red: 0.26, green: 0.16, blue: 0.08),
               Color(red: 0.10, green: 0.06, blue: 0.03)],
        pupil: .round, lashes: false, brow: true,
        sclera: Color(red: 0.78, green: 0.72, blue: 0.66), glow: .brown)

    static let emperor = EyeStyle(
        iris: [Color(red: 0.86, green: 0.76, blue: 0.42), Color(red: 0.58, green: 0.46, blue: 0.20),
               Color(red: 0.28, green: 0.20, blue: 0.08)],
        pupil: .round, lashes: true, brow: true,
        sclera: Color(white: 0.95), glow: .yellow)
}

/// The robot's face: a pair of realistic eyes.
///
/// Drawn entirely as vectors so it scales to any screen and stays crisp across a room.
/// The iris is rendered in a `Canvas` rather than stacked views — forty-odd striations per
/// eye as individual shapes would mean ~100 views redrawing every animation frame.
struct EyesView: View {
    let mood: FaceMood
    var style: EyeStyle = .human

    @State private var lidClosed = false
    @State private var gaze = CGSize.zero
    @State private var blinkTimer: Timer?

    // Per-mood movement. Each is driven by a mood CHANGE, not by the render pass, so
    // entering a state has a moment rather than just a new resting pose.
    @State private var talkBob: CGFloat = 0        // gentle rhythm while speaking
    @State private var pop: CGFloat = 1            // squash-and-stretch on a correct answer
    @State private var sparkle: Double = 0         // extra catchlight flare when pleased
    @State private var tilt: Double = 0            // head-tilt while thinking
    @State private var breathe: CGFloat = 1        // slow swell while listening
    @State private var celebrating = false

    /// How open the lids are, 0 = shut.
    private var openness: CGFloat {
        if lidClosed { return 0.04 }
        switch mood {
        case .happy: return 0.42        // squeezed up in a smile
        case .speaking: return 0.82
        case .listening: return 1.0
        case .unsure: return 0.72
        case .idle: return 0.9
        }
    }

    /// Pupils widen when listening and contract when pleased — the same thing real eyes do,
    /// and the only mood cue left once the iris is a fixed colour.
    private var pupilScale: CGFloat {
        switch mood {
        case .listening: 0.46
        case .speaking: 0.40
        case .happy: 0.33
        case .unsure: 0.43
        case .idle: 0.42
        }
    }

    /// Mood still tints the glow, but each style has its own base so a fox never looks
    /// like a person with orange contact lenses.
    private var glow: Color {
        switch mood {
        case .happy: .green
        case .speaking: style.glow
        case .listening: style.glow
        case .unsure: .orange
        case .idle: style.glow
        }
    }

    var body: some View {
        GeometryReader { geo in
            let eyeWidth = min(geo.size.width * 0.40, geo.size.height * 1.15)
            HStack(spacing: eyeWidth * 0.34) {
                eye(width: eyeWidth).scaleEffect(x: -1)   // left eye mirrors the right
                eye(width: eyeWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(pop * breathe)
            .rotationEffect(.degrees(tilt))
            .offset(y: talkBob)
        }
        .onAppear { scheduleBlink(); scheduleGaze(); enter(mood) }
        .onDisappear { blinkTimer?.invalidate() }
        .onChange(of: mood) { _, new in enter(new) }
    }

    private func eye(width: CGFloat) -> some View {
        let height = width * 0.62
        let irisSize = width * 0.46

        return ZStack {
            let lids = AlmondEye(openness: openness)

            // Sclera. Not pure white — a flat white eyeball reads as plastic.
            lids.fill(
                RadialGradient(colors: [Color(white: 0.97), style.sclera],
                               center: .center, startRadius: width * 0.05, endRadius: width * 0.55)
            )

            IrisView(size: irisSize, pupilScale: pupilScale, style: style, sparkle: sparkle)
                .frame(width: irisSize, height: irisSize)
                .offset(x: gaze.width, y: gaze.height)
                .clipShape(lids)

            // Shadow cast by the upper lid onto the eyeball.
            lids.fill(
                LinearGradient(colors: [.black.opacity(0.38), .clear],
                               startPoint: .top, endPoint: .center)
            )

            // Lash line and lashes.
            lids.stroke(Color(white: 0.08), lineWidth: height * 0.055)
            if style.lashes {
                Lashes(openness: openness)
                    .stroke(Color(white: 0.06), style: StrokeStyle(lineWidth: height * 0.028, lineCap: .round))
                    .opacity(lidClosed ? 0.9 : 1)
            }

            // A soft fold just above the lash line — low, subtle, not a second arch.
            Crease(openness: openness)
                .stroke(Color(white: 0.55).opacity(0.22), lineWidth: height * 0.018)

            // Brow. The single strongest feature of a real eye at a distance.
            if style.brow {
                Brow()
                    .fill(Color(white: 0.10))
                    .offset(y: -height * 0.62)
            }
        }
        .frame(width: width, height: height)
        .shadow(color: glow.opacity(0.30), radius: width * 0.07)
        .animation(.easeInOut(duration: 0.09), value: lidClosed)
        .animation(.easeInOut(duration: 0.3), value: mood)
    }

    // MARK: - Entering a mood

    /// One-shot movement when the face changes state. Without this every mood is just a
    /// different resting pose, and the face reads as a picture rather than a creature.
    private func enter(_ mood: FaceMood) {
        settle()
        switch mood {
        case .speaking:  startTalking()
        case .happy:     celebrate()
        case .unsure:    startThinking()
        case .listening: startListeningSwell()
        case .idle:      break
        }
    }

    /// Cancel anything repeating. A `repeatForever` animation keeps running until something
    /// sets the value again WITHOUT one.
    private func settle() {
        withAnimation(.easeOut(duration: 0.25)) {
            talkBob = 0
            tilt = 0
            breathe = 1
        }
    }

    /// Speaking: a small rhythmic bob, like a head moving with speech.
    private func startTalking() {
        withAnimation(.easeInOut(duration: 0.26).repeatForever(autoreverses: true)) {
            talkBob = -3.5
        }
    }

    /// Listening: a slow swell, like breathing. Attention without motion noise.
    private func startListeningSwell() {
        withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
            breathe = 1.035
        }
    }

    /// Thinking: glance up and away with a small head tilt — what a person does when
    /// they are not sure.
    private func startThinking() {
        withAnimation(.easeInOut(duration: 0.5)) {
            tilt = 4.5
            gaze = CGSize(width: 11, height: -7)
        }
    }

    /// Correct answer: a pop, a sparkle, and two quick delighted blinks.
    private func celebrate() {
        guard !celebrating else { return }
        celebrating = true
        Task { @MainActor in
            withAnimation(.spring(response: 0.20, dampingFraction: 0.42)) { pop = 1.16 }
            withAnimation(.easeOut(duration: 0.18)) { sparkle = 1 }
            try? await Task.sleep(nanoseconds: 200_000_000)

            withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) { pop = 1.0 }
            // Two fast blinks — the giveaway that something is pleased rather than posed.
            for _ in 0..<2 {
                lidClosed = true
                try? await Task.sleep(nanoseconds: 70_000_000)
                lidClosed = false
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
            withAnimation(.easeOut(duration: 0.6)) { sparkle = 0 }
            celebrating = false
        }
    }

    // MARK: - Idle life

    private func scheduleBlink() {
        blinkTimer?.invalidate()
        // Irregular: a metronome blink looks mechanical rather than alive.
        // Blink rate follows attention: quick while listening, sleepy when idle. A constant
        // rate is what makes a face look animatronic.
        let window: ClosedRange<Double> = switch mood {
        case .listening: 1.8...3.6
        case .speaking:  2.6...4.6
        case .unsure:    2.0...3.4
        default:         3.2...6.5
        }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: window), repeats: false) { _ in
            Task { @MainActor in
                guard !celebrating else { scheduleBlink(); return }
                lidClosed = true
                try? await Task.sleep(nanoseconds: 95_000_000)
                lidClosed = false
                // Occasional double blink.
                if Bool.random() && Bool.random() {
                    try? await Task.sleep(nanoseconds: 130_000_000)
                    lidClosed = true
                    try? await Task.sleep(nanoseconds: 85_000_000)
                    lidClosed = false
                }
                scheduleBlink()
            }
        }
    }

    private func scheduleGaze() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 1.6...4.0) * 1_000_000_000))
                // Held still while thinking or celebrating — those states own the gaze.
                guard mood != .unsure, !celebrating else { continue }
                // Listening looks straight at you; other moods wander further.
                let range: ClosedRange<CGFloat> = mood == .listening ? -4...4 : -9...9
                // Saccades are fast; the eye snaps rather than glides.
                withAnimation(.easeOut(duration: 0.16)) {
                    gaze = CGSize(width: .random(in: range), height: .random(in: -4...4))
                }
            }
        }
    }
}

// MARK: - Iris

private struct IrisView: View {
    let size: CGFloat
    let pupilScale: CGFloat
    let style: EyeStyle
    var sparkle: Double = 0

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2

            // Iris body — hazel, lighter towards the pupil.
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: style.iris),
                    center: centre, startRadius: radius * 0.18, endRadius: radius)
            )

            // Radial striations. Alternating length and opacity, otherwise it reads as a
            // printed pattern rather than tissue.
            let spokes = 56
            for i in 0..<spokes {
                let angle = Double(i) / Double(spokes) * 2 * .pi
                let inner = radius * (0.30 + (i % 3 == 0 ? 0.03 : 0))
                let outer = radius * (i % 2 == 0 ? 0.93 : 0.80)
                var path = Path()
                path.move(to: CGPoint(x: centre.x + cos(angle) * inner,
                                      y: centre.y + sin(angle) * inner))
                path.addLine(to: CGPoint(x: centre.x + cos(angle) * outer,
                                         y: centre.y + sin(angle) * outer))
                context.stroke(path,
                               with: .color(Color(red: 0.86, green: 0.72, blue: 0.42)
                                   .opacity(i % 2 == 0 ? 0.34 : 0.17)),
                               lineWidth: radius * 0.035)
            }

            // Limbal ring — the dark edge that makes an iris look like an iris.
            context.stroke(Path(ellipseIn: rect.insetBy(dx: radius * 0.04, dy: radius * 0.04)),
                           with: .color(Color(red: 0.13, green: 0.09, blue: 0.05).opacity(0.85)),
                           lineWidth: radius * 0.13)

            // Pupil — shape is what makes an eye read as animal rather than human.
            let pupilRadius = radius * pupilScale
            let pupilRect: CGRect
            switch style.pupil {
            case .round:
                pupilRect = CGRect(x: centre.x - pupilRadius, y: centre.y - pupilRadius,
                                   width: pupilRadius * 2, height: pupilRadius * 2)
            case .verticalSlit:
                let w = pupilRadius * 0.42
                pupilRect = CGRect(x: centre.x - w, y: centre.y - radius * 0.92,
                                   width: w * 2, height: radius * 1.84)
            case .horizontalBar:
                let h = pupilRadius * 0.46
                pupilRect = CGRect(x: centre.x - radius * 0.86, y: centre.y - h,
                                   width: radius * 1.72, height: h * 2)
            }
            let pupilPath = Path(roundedRect: pupilRect,
                                 cornerSize: CGSize(width: pupilRect.width / 2,
                                                    height: pupilRect.height / 2))
            context.fill(pupilPath, with: .color(.black))
            context.stroke(pupilPath, with: .color(.black.opacity(0.6)), lineWidth: radius * 0.05)

            // Catchlights, upper left, exactly as a light source above and to the side.
            let bigR = radius * 0.19
            context.fill(Path(ellipseIn: CGRect(x: centre.x - radius * 0.42,
                                                y: centre.y - radius * 0.52,
                                                width: bigR * 2, height: bigR * 2)),
                         with: .color(.white.opacity(0.92)))
            let smallR = radius * 0.10
            context.fill(Path(ellipseIn: CGRect(x: centre.x - radius * 0.03,
                                                y: centre.y - radius * 0.60,
                                                width: smallR * 2, height: smallR * 2)),
                         with: .color(.white.opacity(0.75)))

            // Delight: the catchlights flare and a third appears low on the iris.
            if sparkle > 0.01 {
                context.fill(Path(ellipseIn: CGRect(x: centre.x - radius * 0.46,
                                                    y: centre.y - radius * 0.56,
                                                    width: bigR * 2.5, height: bigR * 2.5)),
                             with: .color(.white.opacity(0.55 * sparkle)))
                let spark = radius * 0.13
                context.fill(Path(ellipseIn: CGRect(x: centre.x + radius * 0.26,
                                                    y: centre.y + radius * 0.30,
                                                    width: spark * 2, height: spark * 2)),
                             with: .color(.white.opacity(0.85 * sparkle)))
            }

        }
        .animation(.easeInOut(duration: 0.3), value: pupilScale)
        .animation(.easeInOut(duration: 0.25), value: sparkle)
    }
}

// MARK: - Lid geometry

/// Almond outline: a strong upper curve and a shallower lower one, meeting at the corners.
private struct AlmondEye: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let lift = rect.height * 0.5 * max(openness, 0.02)
        let midY = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: midY),
                          control: CGPoint(x: rect.midX - rect.width * 0.04, y: midY - lift * 2.05))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: midY),
                          control: CGPoint(x: rect.midX + rect.width * 0.02, y: midY + lift * 1.45))
        path.closeSubpath()
        return path
    }
}

/// Lashes rooted ON the lash line and sweeping up and out, longest at the outer corner.
/// The earlier version drew them inside the eye, which read as a comb rather than lashes.
private struct Lashes: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let lift = rect.height * 0.5 * max(openness, 0.02)
        let midY = rect.midY
        let controlX = rect.midX - rect.width * 0.04
        let controlY = midY - lift * 2.05
        var path = Path()

        let count = 14
        for i in 1...count {
            let t = CGFloat(i) / CGFloat(count + 1)
            let x = pow(1 - t, 2) * rect.minX + 2 * (1 - t) * t * controlX + pow(t, 2) * rect.maxX
            let y = pow(1 - t, 2) * midY + 2 * (1 - t) * t * controlY + pow(t, 2) * midY

            // Longest two thirds of the way out, tapering back in at the corners.
            let taper = sin(t * .pi)
            let length = rect.height * (0.09 + 0.24 * taper) * (0.6 + 0.4 * t)
            // Tangent of the lid, so each lash leaves the lid perpendicular-ish.
            let dx = 2 * (1 - t) * (controlX - rect.minX) + 2 * t * (rect.maxX - controlX)
            let dy = 2 * (1 - t) * (controlY - midY) + 2 * t * (midY - controlY)
            let norm = max(sqrt(dx * dx + dy * dy), 0.0001)
            // (dy, -dx), not (-dy, dx): along a left-to-right lid curve the latter points
            // INTO the eye, which drew the lashes across the sclera like spider legs.
            let outX = dy / norm, outY = -dx / norm
            let flick = rect.width * 0.05 * t            // outer lashes curl outward

            let tip = CGPoint(x: x + outX * length + flick, y: y + outY * length)
            let control = CGPoint(x: x + outX * length * 0.5 + flick * 0.15,
                                  y: y + outY * length * 0.6)
            path.move(to: CGPoint(x: x, y: y))
            path.addQuadCurve(to: tip, control: control)
        }
        return path
    }
}

/// The lid fold: low and shallow, following the lash line rather than arching over it.
private struct Crease: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let lift = rect.height * 0.5 * max(openness, 0.02)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.midY - lift * 0.9))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.midY - lift * 1.05),
                          control: CGPoint(x: rect.midX, y: rect.midY - lift * 2.45))
        return path
    }
}

/// A tapered brow: thick through the middle, pointed at both ends.
private struct Brow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        // Upper edge, inner point to outer tail.
        path.move(to: CGPoint(x: rect.minX + w * 0.04, y: rect.midY - h * 0.02))
        path.addCurve(to: CGPoint(x: rect.maxX - w * 0.02, y: rect.midY + h * 0.06),
                      control1: CGPoint(x: rect.minX + w * 0.30, y: rect.midY - h * 0.34),
                      control2: CGPoint(x: rect.maxX - w * 0.32, y: rect.midY - h * 0.24))
        // Lower edge back again, closer to the eye, giving the taper.
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.04, y: rect.midY - h * 0.02),
                      control1: CGPoint(x: rect.maxX - w * 0.34, y: rect.midY - h * 0.02),
                      control2: CGPoint(x: rect.minX + w * 0.30, y: rect.midY - h * 0.12))
        path.closeSubpath()
        return path
    }
}
