import SwiftUI

@main
struct NaviRemoteApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// Owns the single BLE link and hands it to both screens. One connection, one safety gate,
/// one e-stop — switching tabs must never mean a second robot session.
struct RootView: View {
    @StateObject private var ble = NaviBLE()
    @StateObject private var speech = SpeechEngine()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView(ble: ble)
                .tabItem { Label("Control", systemImage: "gamecontroller.fill") }
                .tag(0)

            LearningView(ble: ble, speech: speech)
                .tabItem { Label("Word Play", systemImage: "graduationcap.fill") }
                .tag(1)

            StoryView(ble: ble, speech: speech)
                .tabItem { Label("Stories", systemImage: "book.fill") }
                .tag(2)

            CompanionView(ble: ble, speech: speech)
                .tabItem { Label("Companion", systemImage: "pawprint.fill") }
                .tag(3)
        }
        .onChange(of: tab) { _, _ in
            // Leaving a screen mid-command must not leave the robot moving, and the two
            // screens must never hold the microphone at the same time.
            ble.stopDriving(reason: "switched screen")
            speech.stop()      // two screens must never talk over each other
        }
    }
}
