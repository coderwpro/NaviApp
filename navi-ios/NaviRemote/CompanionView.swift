import SwiftUI

/// Free play. Eyes, a voice, and a dog that answers.
///
/// Same shape as the other two child-facing screens: a face and one button to start, then
/// the phone goes on the robot's back and everything happens out loud. Turned sideways it is
/// nothing but a face.
struct CompanionView: View {
    @ObservedObject var ble: NaviBLE
    @StateObject private var companion: Companion
    @State private var showBlocks = false
    @State private var onFloor = SkillCatalog.onFloor

    init(ble: NaviBLE, speech: SpeechEngine) {
        self.ble = ble
        _companion = StateObject(wrappedValue: Companion(ble: ble, speech: speech))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if companion.phase == .idle {
                start
            } else {
                playing
            }
        }
        .statusBarHidden(companion.phase != .idle)
        .sheet(isPresented: $showBlocks) {
            BlockEditorView(runner: companion.runner, ble: ble)
        }
        // Leaving the tab ends the session — the mic is released and the robot stops.
        .onDisappear { companion.stop() }
    }

    // MARK: - Start

    private var start: some View {
        VStack(spacing: 0) {
            Spacer()
            EyesView(mood: .idle)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
            Spacer()

            Button {
                companion.begin()
            } label: {
                Text("Start")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal, 40)

            Button {
                showBlocks = true
            } label: {
                Label("Build a program", systemImage: "square.stack.3d.up")
                    .font(.callout.weight(.semibold))
            }
            .padding(.top, 16)
            .tint(.orange)

            VStack(spacing: 6) {
                Toggle(isOn: $onFloor) {
                    Text("Robot is on the floor — walking allowed").font(.caption)
                }
                .onChange(of: onFloor) { _, value in SkillCatalog.onFloor = value }
                Toggle(isOn: $companion.chatty) {
                    Text("Answer commands out loud").font(.caption)
                }
                Text(companion.chatty
                     ? "Turn this off for filming: the sound of a command should be the child's voice and the servos, not the app."
                     : "Quiet — commands get a face and a movement, no speech. Conversation still talks.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.leading)
            }
            .tint(.orange)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 40).padding(.top, 18)

            Group {
                if let problem = companion.problem {
                    Text(problem).foregroundStyle(.orange)
                } else if !ble.link.isReady {
                    Text("Robot not connected — Navi still talks")
                        .foregroundStyle(.white.opacity(0.35))
                } else if !ble.canDrive {
                    Text("Driving locked in Control — Navi talks but will not move")
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
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    eyes.ignoresSafeArea()
                    stopChip
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.0) { companion.stop() }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button("Stop") { companion.stop() }
                            .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        Button { showBlocks = true } label: {
                            Image(systemName: "square.stack.3d.up")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        Spacer()
                        stopChip
                    }
                    .padding(.horizontal, 20).padding(.top, 10)

                    eyes.frame(maxHeight: .infinity)

                    VStack(spacing: 8) {
                        Text(companion.line)
                            .font(.body).foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                        Text(companion.heard.isEmpty ? "listening…" : companion.heard)
                            .font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.4))
                            .lineLimit(2)
                        // Not decoration: "it ignored me" and "it never heard me" look
                        // identical from outside without this.
                        if !companion.lastRoute.isEmpty {
                            Text(companion.lastRoute)
                                .font(.caption2.monospaced()).foregroundStyle(.orange.opacity(0.55))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: companion.line)
                    .padding(.horizontal, 22).padding(.bottom, 24)
                }
            }
        }
    }

    private var eyes: some View {
        EyesView(mood: companion.face, cue: companion.cue, talking: companion.isTalking)
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

// MARK: - Block programming

/// A child picks actions, puts them in the order they want, and presses run.
///
/// The block labelled `wave` sends the `wave` skill. Nothing is renamed for presentation and
/// nothing is quietly dropped at run time, because the camera shows this screen and the robot
/// in the same frame — a mismatch between the two is visible.
///
/// Native SwiftUI rather than a web view: the program is data, executed by `RoutineRunner`,
/// so there is no downloaded executable code and App Store rule 2.5.2 never comes into it.
struct BlockEditorView: View {
    @ObservedObject var runner: RoutineRunner
    @ObservedObject var ble: NaviBLE
    @Environment(\.dismiss) private var dismiss

    /// Mirrors the app-wide setting so the toggle animates; the stored value is the truth.
    @State private var onFloor = SkillCatalog.onFloor

    private var palette: [BlockAction] {
        BlockAction.allCases.filter { $0.isAvailable(onFloor: onFloor) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                placement
                paletteStrip
                Divider()
                programList
                runBar
            }
            .navigationTitle("My program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { runner.stop(); dismiss() }
                }
            }
        }
    }

    private var placement: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $onFloor) {
                Text("Robot is on the floor").font(.callout)
            }
            .onChange(of: onFloor) { _, value in SkillCatalog.onFloor = value }
            Text(onFloor
                 ? "Every skill is available, including untested ones. Keep the space clear."
                 : "On a table with the phone on its back — only skills a bench test cleared as staying in place are offered.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private var paletteStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(palette) { action in
                    Button {
                        runner.program.append(RoutineBlock(action: action))
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.symbol).font(.title3)
                            Text(action.label).font(.caption2)
                        }
                        .frame(width: 82, height: 62)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 78)
    }

    private var programList: some View {
        List {
            if runner.program.isEmpty {
                Text("Tap the pictures above to add them. Drag to change the order.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(runner.program.enumerated()), id: \.element.id) { index, block in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 20)
                    Image(systemName: block.action.symbol)
                        .foregroundStyle(runner.runningIndex == index ? Color.accentColor : .primary)
                    Text(block.action.label)
                        .font(.body.weight(runner.runningIndex == index ? .bold : .regular))
                    Spacer()
                    if runner.runningIndex == index {
                        Image(systemName: "play.fill").foregroundStyle(.green)
                    }
                }
            }
            .onDelete { runner.program.remove(atOffsets: $0) }
            .onMove { runner.program.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
    }

    private var runBar: some View {
        VStack(spacing: 8) {
            if !ble.motionAllowed {
                Text(ble.link.isReady
                     ? "The robot will not move: check the safety gate in Control, or clear the e-stop."
                     : "Not connected — connect in the Control tab first.")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    ble.emergencyStop()
                } label: {
                    Text("E-STOP").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(.red)

                Button {
                    runner.isRunning ? runner.stop() : runner.run(runner.program)
                } label: {
                    Label(runner.isRunning ? "Stop" : "Run", systemImage: runner.isRunning ? "stop.fill" : "play.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(runner.program.isEmpty || !ble.motionAllowed)
            }
            Text("Runs in this exact order, every time. The random movements Navi makes on its own never touch a program.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}
