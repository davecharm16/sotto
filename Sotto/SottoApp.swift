import SwiftUI

@main
struct SottoApp: App {
    @StateObject private var audioManager = AudioManager()

    var body: some Scene {
        MenuBarExtra {
            SottoMenuView()
                .environmentObject(audioManager)
        } label: {
            Label("Sotto", systemImage: audioManager.isEnabled ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
