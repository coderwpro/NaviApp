import SwiftUI

/// Reports press and release without a DragGesture, so it works inside a ScrollView.
/// `isPressed` is driven by the Button's own touch handling, which the scroll view
/// cooperates with rather than competing against.
struct HoldButtonStyle: ButtonStyle {
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(configuration.isPressed ? Color.white : Color.primary)
            .onChange(of: configuration.isPressed) { _, pressed in
                pressed ? onPress() : onRelease()
            }
    }
}

struct ContentView: View {
    // Owned by RootView so both tabs share one link to the robot.
    @ObservedObject var ble: NaviBLE
    @StateObject private var voice: VoiceController
    @State private var showLog = false
    @State private var showBench = false
    @Environment(\.scenePhase) private var scenePhase

    init(ble: NaviBLE) {
        _ble = ObservedObject(wrappedValue: ble)
        _voice = StateObject(wrappedValue: VoiceController(ble: ble))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    eStopButton
                    connectionCard
                    telemetryCard
                    if !ble.link.isReady { safetyCard } else { safetyCard; driveCard; skillsCard; voiceCard }
                    logCard
                }
                .padding()
            }
            .navigationTitle("Navi Remote")
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showBench) { SkillBenchView(ble: ble) }
        }
        .onChange(of: scenePhase) { _, phase in
            // The real runaway risk isn't a long hold, it's the app losing the foreground
            // mid-press — a call, the app switcher, the screen locking. The release event
            // never arrives, so stop here instead of waiting for the watchdog.
            if phase != .active { ble.stopDriving(reason: "app left the foreground") }
            // Backgrounded for real: hand the link back, so the robot is free for the next
            // run instead of holding a connection nobody is using.
            if phase == .background { ble.releaseEverything() }
        }
    }

    // MARK: - E-stop, always first and never disabled

    private var eStopButton: some View {
        Button(role: .destructive) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            ble.emergencyStop()
        } label: {
            Text("■  E-STOP")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity).padding(.vertical, 18)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    // MARK: - Cards

    private var connectionCard: some View {
        card("Connection") {
            HStack {
                Circle().fill(ble.link.isReady ? .green : .secondary).frame(width: 9, height: 9)
                Text(ble.link.label).font(.callout.monospaced())
                Spacer()
                if let rssi = ble.rssi {
                    Text("\(rssi) dBm").font(.caption.monospaced())
                        .foregroundStyle(rssi < -85 ? Color.orange : Color.secondary)
                }
                if !ble.deviceName.isEmpty { Text(ble.deviceName).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            if ble.deferredFrames > 0 {
                Text("\(ble.deferredFrames) frames deferred (radio buffer full — not dropped)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Button(ble.link.isReady ? "Reconnect" : "Scan & connect") { ble.startScan() }
                    .buttonStyle(.borderedProminent)
                Button("Disconnect") { ble.disconnect() }.buttonStyle(.bordered)
            }
            if !ble.candidates.isEmpty {
                Text(ble.candidates.joined(separator: "\n")).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Text("About a third of connection attempts fail on this robot. Retry — it is not the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var telemetryCard: some View {
        card("Telemetry — read this before you drive") {
            if ble.statusFrameCount == 0 {
                Text("No status frame yet. Until a battery number appears you cannot tell a bad frame from any other problem.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 20) {
                stat("\(ble.status?.battery ?? 0)%", "battery")
                stat(ble.status.map { $0.eStopLatched ? "1" : "0" } ?? "—", "e-stop")
                stat(ble.status.map { $0.isIdle ? "idle" : "busy" } ?? "—", "motion")
            }
            HStack {
                Text("action_id \(ble.status?.actionID ?? "—")")
                Spacer()
                Text("\(ble.statusFrameCount) frames")
            }
            .font(.caption.monospaced()).foregroundStyle(.secondary)
            if !ble.temperatures.isEmpty {
                Text("temps \(ble.temperatures.map(String.init).joined(separator: " / ")) °C")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let error = ble.lastError {
                Text(error).font(.caption.monospaced()).foregroundStyle(.red)
            }
        }
    }

    private var safetyCard: some View {
        card("Safety gate") {
            Toggle(isOn: $ble.safetyAcknowledged) {
                Text("One Navi powered on within 30 m · someone else holding the physical remote · robot elevated, all four feet off the ground")
                    .font(.caption)
            }
            Toggle(isOn: $ble.allowDrivingWithoutTelemetry) {
                Text("Override: drive with no telemetry").font(.caption).foregroundStyle(.orange)
            }
            if !ble.canDrive {
                // Say WHICH condition is missing. "Driving locked" on its own sends people
                // hunting through the app for a control that isn't the problem.
                Text(lockReason).font(.caption.bold()).foregroundStyle(.red)
            }
        }
    }

    private var driveCard: some View {
        card("Drive") {
            let speed = ble.driveSpeed, turn = ble.turnRate

            HStack {
                Text("speed").font(.caption).foregroundStyle(.secondary)
                Text("\(speed)").font(.body.monospaced().bold())
                Text("0x\(String(speed, radix: 16, uppercase: true))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                ForEach([30, 100, 127], id: \.self) { preset in
                    Button("\(preset)") { ble.setDriveSpeed(preset) }
                        .buttonStyle(.bordered).font(.caption2)
                        .tint(speed == preset ? .accentColor : .secondary)
                }
            }
            Slider(
                value: Binding(get: { Double(ble.driveSpeed) },
                               set: { ble.setDriveSpeed(Int($0)) }),
                in: 1...Double(NaviProtocol.axisLimit), step: 1
            )
            Text("127 is the maximum this protocol can express. The slider stops there because 128 is −128 on the wire — every value above 127 drives the robot backwards, and gets *slower* the higher you go.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Text("turn").font(.caption).foregroundStyle(.secondary)
                Text("\(turn)").font(.body.monospaced().bold())
                Slider(
                    value: Binding(get: { Double(ble.turnRate) },
                                   set: { ble.setTurnRate(Int($0)) }),
                    in: 1...Double(NaviProtocol.axisLimit), step: 1
                )
            }

            Divider()

            VStack(spacing: 8) {
                holdButton("▲", axes: .init(vx: speed))
                HStack(spacing: 8) {
                    holdButton("◀", axes: .init(wz: turn))
                    holdButton("▼", axes: .init(vx: -speed))
                    holdButton("▶", axes: .init(wz: -turn))
                }
                HStack(spacing: 8) {
                    holdButton("raise", axes: .init(raise: 30))
                    holdButton("bow", axes: .init(bow: 30))
                    holdButton("twist", axes: .init(twist: 30))
                }
            }
            Text("Hold to move, release to stop. Every axis is clamped to ±127 — above that the byte is negative and the robot reverses.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var skillsCard: some View {
        card("Skills — run these last") {
            // All sixteen firmware names, each showing what a bench test found. A skill
            // still marked untested runs from here — that is what this card is for — but
            // nothing else in the app will touch it until it has been classified.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                ForEach(SkillCatalog.all) { skill in
                    Button { ble.sendSkill(skill.name) } label: {
                        VStack(spacing: 1) {
                            Text(skill.name).font(.caption2.monospaced())
                            Text(SkillCatalog.verdict(skill.name).label)
                                .font(.system(size: 9))
                                .foregroundStyle(SkillCatalog.verdict(skill.name) == .tableSafe
                                                 ? Color.green : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Button {
                showBench = true
            } label: {
                Label("Bench test and classify", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
            }
            Text("After an animation the firmware can silently ignore the joystick. Drive first, skills after.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var voiceCard: some View {
        card("Voice") {
            Button {
                Task { voice.isListening ? voice.stop() : await voice.start() }
            } label: {
                Label(voice.isListening ? "listening — tap to stop" : "Talk", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(voice.isListening ? .green : .accentColor)

            LabeledContent("heard") { Text(voice.heard.isEmpty ? "—" : voice.heard).font(.caption.monospaced()) }
            LabeledContent("intent") {
                Text(voice.intent).font(.caption.monospaced())
                    .foregroundStyle(voice.intentIsGood ? Color.primary : Color.orange)
            }

            Picker("Route", selection: $voice.route) {
                ForEach(VoiceController.Route.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("motion \(voice.motionSeconds, specifier: "%.2f")s").font(.caption)
                Slider(value: $voice.motionSeconds, in: 0.25...NaviProtocol.maxVoiceMotion, step: 0.25)
            }
            TextField("model", text: $voice.model)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)

            Text("\"Stop\" is matched on-device before any model call, on partial speech. Every voice command is capped at \(Int(NaviProtocol.maxVoiceMotion))s.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var logCard: some View {
        card("Log") {
            DisclosureGroup("\(ble.log.count) lines", isExpanded: $showLog) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ble.log.suffix(60).reversed(), id: \.self) { line in
                        Text(line).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private func holdButton(_ title: String, axes: NaviProtocol.Axes) -> some View {
        // A Button with a press-reporting style, NOT a DragGesture. A DragGesture with
        // minimumDistance 0 competes with the enclosing ScrollView for the touch, and the
        // scroll view usually wins — the press then never registers, or never releases.
        Button {} label: {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 62)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoldButtonStyle(
            onPress: { ble.beginDrive(axes) },
            onRelease: { ble.endDrive() }
        ))
        .disabled(!ble.canDrive)
        .opacity(ble.canDrive ? 1 : 0.4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .bold, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var lockReason: String {
        if !ble.link.isReady { return "Driving locked — not connected." }
        if !ble.safetyAcknowledged { return "Driving locked — turn on the safety toggle above." }
        return "Driving locked — no status frame yet. Wait for a battery number, or use the override."
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
