import SwiftUI

struct LearningView: View {
    @ObservedObject var ble: NaviBLE
    @StateObject private var game: LearningGame

    init(ble: NaviBLE, speech: SpeechEngine) {
        self.ble = ble
        _game = StateObject(wrappedValue: LearningGame(ble: ble, speech: speech))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch game.phase {
            case .setup:
                setup
            case .choosingLanguage, .choosing, .playing:
                playing
            }
        }
        .statusBarHidden(game.phase != .setup)
    }

    // MARK: - Setup — a face and one button, nothing else.
    //
    // Everything that used to live here (language picker, toggles, instructions) is now
    // asked out loud, because the phone ends up on the robot's back and out of reach.

    private var setup: some View {
        VStack(spacing: 0) {
            Spacer()
            EyesView(mood: .idle)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
            Spacer()

            Button {
                Task { await game.start() }
            } label: {
                Text("Start")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .padding(.horizontal, 40)

            Group {
                if let problem = game.micProblem {
                    Text(problem).foregroundStyle(.orange)
                } else if !ble.link.isReady {
                    Text("Robot not connected — no celebrations")
                        .foregroundStyle(.white.opacity(0.35))
                } else if !ble.canDrive {
                    Text("Driving locked in Control — no celebrations")
                        .foregroundStyle(.white.opacity(0.35))
                } else {
                    Text("Robot ready").foregroundStyle(.green.opacity(0.6))
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Playing

    private var playing: some View {
        GeometryReader { geo in
            // Held horizontally, the phone is a face and nothing else. The conversation is
            // audible, so there is nothing to read.
            if geo.size.width > geo.size.height {
                faceOnly
            } else {
                portraitPlaying
            }
        }
    }

    private var faceOnly: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            EyesView(mood: game.mood).ignoresSafeArea()

            // The one control that stays, because it has to. Small, but always tappable.
            Button { ble.emergencyStop() } label: {
                Text("STOP").font(.caption2.weight(.heavy))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(14)
        }
        // Tap the face to hear it again; press and hold to leave.
        .contentShape(Rectangle())
        .onTapGesture { game.repeatQuestion() }
        .onLongPressGesture(minimumDuration: 1.0) { game.stop() }
    }

    private var portraitPlaying: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Stop") { game.stop() }
                    .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                VStack(spacing: 1) {
                    if game.phase == .playing {
                        Text("\(game.correct) / \(game.asked)")
                            .font(.callout.monospaced()).foregroundStyle(.white.opacity(0.65))
                        Text("\(game.deck.name) · \(game.lesson.rawValue)")
                            .font(.caption2).foregroundStyle(.cyan.opacity(0.7))
                    }
                }
                Spacer()
                Button { ble.emergencyStop() } label: {
                    Text("E-STOP").font(.caption.weight(.heavy))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.red, in: Capsule()).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12)

            EyesView(mood: game.mood).frame(maxHeight: .infinity)

            VStack(spacing: 10) {
                if let banner = game.banner {
                    Text(banner)
                        .font(.title3.weight(.bold)).foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                        .transition(.scale.combined(with: .opacity))
                } else if game.phase == .playing, let card = game.current {
                    // Portrait keeps the printed word as a crutch for an adult helping out.
                    // Turn the phone sideways and it all disappears — just eyes and audio.
                    Text(card.emoji).font(.system(size: 46))
                    Text(card.word)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button {
                        game.repeatQuestion()
                    } label: {
                        Label("say it again", systemImage: "speaker.wave.2.fill")
                            .font(.callout).foregroundStyle(.cyan)
                    }
                }

                if let line = game.tutorLine {
                    Text(line)
                        .font(.callout.italic()).foregroundStyle(.cyan.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Text(game.heard.isEmpty ? "listening…" : game.heard)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).padding(.top, 4)
            }
            .animation(.spring(response: 0.35), value: game.banner)
            .animation(.easeInOut(duration: 0.25), value: game.tutorLine)
            .padding(.bottom, 26).padding(.horizontal, 20)
        }
    }
}
