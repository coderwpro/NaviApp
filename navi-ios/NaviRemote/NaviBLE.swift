import Foundation
import CoreBluetooth
import UIKit   // willTerminateNotification

/// The BLE link. Owns the scan, the connection, the 20 Hz drive loop and every safety
/// limit. Nothing else in the app writes to the robot.
///
/// Note the app must run on a **physical iPhone** — the iOS Simulator has no Bluetooth
/// hardware and `CBCentralManager` never leaves `.unsupported` there.
@MainActor
final class NaviBLE: NSObject, ObservableObject {

    enum LinkState: Equatable {
        case idle, scanning, connecting, ready, failed(String)

        var label: String {
            switch self {
            case .idle: "idle"
            case .scanning: "scanning…"
            case .connecting: "connecting…"
            case .ready: "connected"
            case .failed(let why): "failed: \(why)"
            }
        }
        var isReady: Bool { self == .ready }
    }

    // MARK: - Published state

    @Published private(set) var link: LinkState = .idle
    @Published private(set) var deviceName: String = ""
    @Published private(set) var status: NaviProtocol.Status?
    @Published private(set) var temperatures: [Int] = []
    @Published private(set) var statusFrameCount = 0
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var candidates: [String] = []
    @Published private(set) var rssi: Int?
    /// Frames the radio was not ready to accept. A steadily climbing number means the link
    /// is saturated, not that the robot is ignoring you — worth seeing rather than guessing.
    @Published private(set) var deferredFrames = 0

    /// Ticked by the UI. Driving is refused until a status frame has arrived, unless the
    /// operator explicitly overrides — you cannot tell a bad frame from any other problem
    /// with no telemetry on screen.
    @Published var safetyAcknowledged = false
    @Published var allowDrivingWithoutTelemetry = false

    /// Forward/back speed for the drive controls and for voice. 128 and above are negative
    /// on the wire and drive the robot backwards with no error anywhere, so this is clamped
    /// — but in the setter METHOD, never in a `didSet`. Assigning to an `@Published`
    /// property inside its own `didSet` re-enters the wrapper's setter and recurses until
    /// the stack overflows.
    @Published private(set) var driveSpeed: Int = 30

    /// Turn rate is its own value: the cheat sheet measures 10 as slight and 50 as fast,
    /// and there is no evidence it scales with forward speed.
    @Published private(set) var turnRate: Int = 50

    func setDriveSpeed(_ value: Int) {
        driveSpeed = min(max(value, 1), NaviProtocol.axisLimit)
    }

    func setTurnRate(_ value: Int) {
        turnRate = min(max(value, 1), NaviProtocol.axisLimit)
    }

    var canDrive: Bool {
        link.isReady && safetyAcknowledged && (statusFrameCount > 0 || allowDrivingWithoutTelemetry)
    }

    /// Whether motion the *app* started on its own — ambient wiggles, a companion reaction —
    /// may run. Stricter than `canDrive`: a latched e-stop closes it.
    ///
    /// Deliberately not folded into `canDrive`. The e-stop latches and only `cmd|recover`
    /// clears it, so gating the manual controls on it would lock an operator out of the one
    /// screen that can recover. A robot moving by itself after somebody hit e-stop is a
    /// different matter.
    var motionAllowed: Bool {
        canDrive && !(status?.eStopLatched ?? false)
    }

    // MARK: - CoreBluetooth

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var joystickChar: CBCharacteristic?
    private var eventChar: CBCharacteristic?

    private var axes = NaviProtocol.Axes.zero
    private var driveTimer: Timer?
    private var holdStartedAt: Date?
    private var voiceTimer: Timer?

    /// Reconnection. About a third of attempts to this robot fail outright and live
    /// sessions drop on their own; the cause is robot-side and unfixed. The app cannot
    /// stop that happening, so it retries instead of sitting there looking broken.
    private var connectTimeout: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var attempt = 0
    private let maxAttempts = 5
    private var userAskedToDisconnect = false

    /// Latest-wins frame held back because the radio's buffer was full. A stale stick
    /// position is worthless, so it is replaced rather than queued.
    private var deferredFrame: Data?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        // Being killed while connected is what leaves the robot holding a dead link.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseEverything() }
        }
    }

    /// Drop every link this device holds to the robot, including ones iOS is holding on
    /// the app's behalf.
    ///
    /// CoreBluetooth connections outlive the app: force-quit it, crash it, or re-run from
    /// Xcode while connected, and iOS keeps the GATT link open. The robot still believes it
    /// has a client and refuses the next connection — which is why it needed power-cycling
    /// between runs. Clearing this on the way in and on the way out removes the need.
    func releaseEverything() {
        let service = CBUUID(string: NaviProtocol.serviceUUID)
        for stale in central.retrieveConnectedPeripherals(withServices: [service]) {
            note("releasing a link iOS was still holding: \(stale.name ?? stale.identifier.uuidString)")
            central.cancelPeripheralConnection(stale)
        }
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - Connection

    func startScan() {
        guard central.state == .poweredOn else {
            link = .failed("Bluetooth is \(stateName(central.state))")
            return
        }
        userAskedToDisconnect = false
        attempt = 0
        // Clear anything left over from a previous run BEFORE scanning, then give the
        // stack a moment to actually tear it down.
        releaseEverything()
        link = .scanning
        note("clearing old connections…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, !self.userAskedToDisconnect else { return }
            self.beginScan()
        }
    }

    private func beginScan() {
        reconnectWork?.cancel()
        candidates.removeAll()
        link = .scanning
        note("scanning for \(NaviProtocol.namePrefix)… (attempt \(attempt + 1)/\(maxAttempts))")
        // Filtering on nil rather than the service UUID on purpose: many units never put
        // the service in their advertisement, so a service filter finds nothing.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// CoreBluetooth's `connect` never times out on its own — without this the UI can sit
    /// on "connecting…" forever against a robot that is never going to answer.
    private func attemptConnect(_ target: CBPeripheral) {
        attempt += 1
        peripheral = target
        target.delegate = self
        link = .connecting
        central.connect(target)
        connectTimeout?.invalidate()
        connectTimeout = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.connectTimedOut() }
        }
    }

    private func connectTimedOut() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
        note("no answer in 8s — retrying")
        retryOrGiveUp()
    }

    private func retryOrGiveUp() {
        guard !userAskedToDisconnect else { return }
        guard attempt < maxAttempts else {
            link = .failed("gave up after \(maxAttempts) attempts")
            note("gave up. This robot refuses roughly a third of attempts — try again, and check nothing else is connected to it.")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.beginScan() }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func disconnect() {
        userAskedToDisconnect = true
        reconnectWork?.cancel()
        connectTimeout?.invalidate()
        central.stopScan()
        stopDriving(reason: "disconnect")
        releaseEverything()
    }

    // MARK: - Commands

    func send(_ verb: NaviProtocol.Verb) {
        guard let commandChar, let peripheral else { note("dropped \(verb.rawValue) — no link"); return }
        peripheral.writeValue(NaviProtocol.commandData(verb), for: commandChar, type: .withResponse)
        note("TX \(verb.rawValue)")
    }

    /// Returns roughly how long the animation runs, so a caller scheduling movement can wait
    /// it out instead of writing a posture frame over a skill the firmware is still playing.
    /// Zero means nothing was sent.
    @discardableResult
    func sendSkill(_ name: String) -> TimeInterval {
        guard NaviProtocol.skills.contains(name) else { note("refused unknown skill \(name)"); return 0 }
        guard let commandChar, let peripheral else { note("dropped skill — no link"); return 0 }
        peripheral.writeValue(NaviProtocol.skillData(named: name), for: commandChar, type: .withResponse)
        note("TX skill \(name) — joystick may be ignored until the animation ends")
        return SkillCatalog.seconds(name)
    }

    /// Sends a skill name that is NOT in the allow-list, on purpose.
    ///
    /// The firmware's action vocabulary is larger than the sixteen names we know, and the
    /// only way to find out whether `send_skill` accepts `nod_head` or `look_around` is to
    /// send it and watch. Deliberately a separate entry point from `sendSkill`, so probing
    /// is always an explicit act and never something a caller does by accident.
    func probeSkill(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let commandChar, let peripheral else { note("probe dropped — no link"); return }
        peripheral.writeValue(NaviProtocol.skillData(named: trimmed), for: commandChar, type: .withResponse)
        note("PROBE skill \"\(trimmed)\" — watch the robot AND action_id. An unknown name is "
           + "accepted silently: no motion, no error, action_id unchanged.")
    }

    /// Emergency stop. Clears any motion first, then jumps the queue. Never gated on
    /// `canDrive` — it must work in every state.
    func emergencyStop() {
        stopDriving(reason: "e-stop")
        send(.eStop)
    }

    /// Clears a latched e-stop.
    ///
    /// The e-stop latches and only `cmd|recover` releases it. Until this existed the app
    /// could stop the robot but never start it again — which on a shooting day means power
    /// cycling the robot between takes.
    func recoverFromEStop() {
        send(.recover)
        note("recover sent — the e-stop latch should clear on the next status frame")
    }

    /// True when the robot is sitting in a latched e-stop and will ignore motion until it
    /// is recovered.
    var isLatched: Bool { status?.eStopLatched ?? false }

    // MARK: - Driving

    func beginDrive(_ requested: NaviProtocol.Axes) {
        guard canDrive else { note("refused — safety gate closed"); return }
        axes = requested
        holdStartedAt = Date()
        startTicking()
    }

    func endDrive() { stopDriving(reason: "released") }

    /// Rail 1: voice may only start motion that stops itself. The duration is clamped here,
    /// so no caller — including a model — can ask for an open-ended move.
    func driveForVoice(_ requested: NaviProtocol.Axes, seconds: TimeInterval) {
        guard canDrive else { note("voice refused — safety gate closed"); return }
        let capped = min(max(seconds, 0.25), NaviProtocol.maxVoiceMotion)
        beginDrive(requested)
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: capped, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopDriving(reason: "voice time limit") }
        }
        note("voice drive for \(String(format: "%.2f", capped))s")
    }

    private func startTicking() {
        guard driveTimer == nil else { return }
        driveTimer = Timer.scheduledTimer(withTimeInterval: NaviProtocol.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func tick() {
        guard canDrive else { stopDriving(reason: "gate closed mid-drive"); return }
        if let started = holdStartedAt, Date().timeIntervalSince(started) > NaviProtocol.maxHold {
            note("watchdog: \(Int(NaviProtocol.maxHold))s with no release — assuming the touch was lost, zeroing")
            stopDriving(reason: "watchdog")
            return
        }
        write(NaviProtocol.joystickFrame(axes))
    }

    func stopDriving(reason: String) {
        driveTimer?.invalidate(); driveTimer = nil
        voiceTimer?.invalidate(); voiceTimer = nil
        holdStartedAt = nil
        axes = .zero
        guard joystickChar != nil else { return }
        // The joystick channel never acknowledges anything, so one stop frame is not enough.
        for index in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * NaviProtocol.tickInterval) { [weak self] in
                self?.write(NaviProtocol.zeroFrame)
            }
        }
        note("stop (\(reason)) — zero frame ×3")
    }

    private func write(_ data: Data) {
        guard let peripheral, let joystickChar else { return }
        guard joystickChar.properties.contains(.writeWithoutResponse) else {
            peripheral.writeValue(data, for: joystickChar, type: .withResponse)
            return
        }
        // withoutResponse gives no ack, which is what a 20 Hz stick needs — but iOS drops
        // the write on the floor when its buffer is full. Without this check the frames
        // simply vanish, which looks exactly like a robot ignoring you.
        guard peripheral.canSendWriteWithoutResponse else {
            deferredFrame = data
            deferredFrames += 1
            return
        }
        peripheral.writeValue(data, for: joystickChar, type: .withoutResponse)
    }

    // MARK: - Logging

    private func note(_ text: String) {
        let stamp = Self.formatter.string(from: Date())
        log.append("\(stamp)  \(text)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "on"
        case .poweredOff: "off — turn Bluetooth on"
        case .unauthorized: "unauthorised — allow Bluetooth in Settings"
        case .unsupported: "unsupported — this must run on a real iPhone, not the Simulator"
        case .resetting: "resetting"
        default: "unknown"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension NaviBLE: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            note("bluetooth \(stateName(central.state))")
            if central.state != .poweredOn, link != .idle {
                link = .failed(stateName(central.state))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name ?? ""
        guard name.uppercased().hasPrefix(NaviProtocol.namePrefix) else { return }

        Task { @MainActor in
            let entry = "\(name)  RSSI \(RSSI)"
            if !candidates.contains(entry) { candidates.append(entry) }
            // This link has no authentication — any powered-on Navi in range may answer.
            // More than one candidate means stop and find out what else is switched on.
            guard candidates.count == 1 else {
                central.stopScan()
                link = .failed("\(candidates.count) Navis in range — power the others off")
                note("STOP: \(candidates.count) candidates. Confirm what else is on before connecting.")
                return
            }
            central.stopScan()
            deviceName = name
            rssi = RSSI.intValue
            note("found \(name) at \(RSSI) dBm — connecting")
            if RSSI.intValue < -85 {
                note("weak signal — move closer; most drops on this link are range, not code")
            }
            attemptConnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectTimeout?.invalidate()
            note("GATT connected — discovering services")
            peripheral.discoverServices([CBUUID(string: NaviProtocol.serviceUUID)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectTimeout?.invalidate()
            note("connect failed: \(error?.localizedDescription ?? "unknown")")
            retryOrGiveUp()      // known robot-side flakiness — retry rather than stop
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectTimeout?.invalidate()
            // Motion stops FIRST, before any reconnect thinking. A dropped link must never
            // leave the robot driving.
            stopDriving(reason: "link lost")
            commandChar = nil; joystickChar = nil; eventChar = nil
            deferredFrame = nil

            if userAskedToDisconnect {
                link = .idle
                note("disconnected")
            } else {
                link = .failed("dropped — reconnecting")
                note("dropped mid-session (\(error?.localizedDescription ?? "no reason given")) — reconnecting")
                attempt = 0
                retryOrGiveUp()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension NaviBLE: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: NaviProtocol.serviceUUID)
            }) else {
                link = .failed("service not found"); return
            }
            peripheral.discoverCharacteristics([
                CBUUID(string: NaviProtocol.charCommand),
                CBUUID(string: NaviProtocol.charJoystick),
                CBUUID(string: NaviProtocol.charEvent),
            ], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid.uuidString.uppercased() {
                case NaviProtocol.charCommand.uppercased():  commandChar = characteristic
                case NaviProtocol.charJoystick.uppercased(): joystickChar = characteristic
                case NaviProtocol.charEvent.uppercased():
                    eventChar = characteristic
                    // Subscribe before anything is sent. Telemetry first, always.
                    peripheral.setNotifyValue(true, for: characteristic)
                default: break
                }
            }
            if commandChar != nil, joystickChar != nil, eventChar != nil {
                link = .ready
                attempt = 0
                note("ready — waiting for status frames")
            } else {
                link = .failed("missing characteristics")
            }
        }
    }

    /// The radio has drained its buffer. Send whatever the stick wants *now* — not what it
    /// wanted when the buffer filled.
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let frame = deferredFrame else { return }
            deferredFrame = nil
            write(frame)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task { @MainActor in
            for line in text.split(whereSeparator: \.isNewline) {
                handle(NaviProtocol.parse(String(line)), raw: String(line))
            }
        }
    }

    private func handle(_ frame: NaviProtocol.Frame, raw: String) {
        switch frame {
        case .status(let s):
            status = s
            statusFrameCount += 1
            lastFrameAt = Date()
        case .temperature(let t):
            temperatures = t
        case .charging(let on):
            note("charging: \(on)")
        case .error(let code, let message):
            lastError = "\(code): \(message)"
            note("robot error \(code) \(message)")
        case .unrecognised(let line):
            note("unrecognised: \(line)")
        }
    }
}
