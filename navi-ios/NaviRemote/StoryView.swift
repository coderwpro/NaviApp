import SwiftUI

struct StoryView: View {
    @ObservedObject var ble: NaviBLE
    @StateObject private var teller: StoryTeller

    init(ble: NaviBLE, speech: SpeechEngine) {
        self.ble = ble
        _teller = StateObject(wrappedValue: StoryTeller(ble: ble, speech: speech))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if teller.phase == .idle {
                library
            } else {
                playing
            }
        }
        .statusBarHidden(teller.phase != .idle)
        // Leaving the tab ends the session. Without this the ambient movement keeps running
        // on a screen nobody is looking at, and the robot carries on wiggling in the
        // Control tab.
        .onDisappear { teller.stop() }
    }

    // MARK: - Setup — a face and one button.
    //
    // The library, the mode picker and the blurbs are gone: the phone ends up on the
    // robot's back, so the whole conversation happens out loud.

    private var library: some View {
        VStack(spacing: 0) {
            Spacer()
            EyesView(mood: .idle)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
            Spacer()

            Button {
                teller.begin()
            } label: {
                Text("Start")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .padding(.horizontal, 40)

            Group {
                if let problem = teller.problem {
                    Text(problem).foregroundStyle(.orange)
                } else if !ble.link.isReady {
                    Text("Robot not connected — stories still play")
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
            if geo.size.width > geo.size.height {
                // Sideways on the robot's back: a face, and the one control that must stay.
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    EyesView(mood: teller.face, style: teller.eyes, cue: teller.cue, talking: teller.isTalking).ignoresSafeArea()
                    stopChip
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.0) { teller.stop() }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button("Stop") { teller.stop() }
                            .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        if let story = teller.story {
                            Text("\(teller.beatIndex + 1)/\(story.beats.count)")
                                .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        stopChip
                    }
                    .padding(.horizontal, 20).padding(.top, 10)

                    EyesView(mood: teller.face, style: teller.eyes, cue: teller.cue, talking: teller.isTalking).frame(maxHeight: .infinity)

                    VStack(spacing: 10) {
                        if let prompt = teller.prompt {
                            Text(prompt)
                                .font(.title3.weight(.bold)).foregroundStyle(.cyan)
                                .multilineTextAlignment(.center)
                        }
                        Text(teller.line)
                            .font(.body).foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                        if teller.phase == .waiting {
                            Text(teller.heard.isEmpty ? "listening…" : teller.heard)
                                .font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.4))
                                .lineLimit(2)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: teller.line)
                    .padding(.horizontal, 22).padding(.bottom, 24)
                }
            }
        }
    }

    private var stopChip: some View {
        HStack(spacing: 6) {
            // Recoverable in one tap: the e-stop latches, so without this a stop between
            // takes means power cycling the robot.
            if ble.isLatched {
                Button { ble.recoverFromEStop() } label: {
                    Text("RECOVER").font(.caption2.weight(.heavy))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(.orange, in: Capsule()).foregroundStyle(.white)
                }
            }
            Button { ble.emergencyStop() } label: {
                Text("E-STOP").font(.caption2.weight(.heavy))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(.red, in: Capsule()).foregroundStyle(.white)
            }
        }
        .padding(10)
    }
}
