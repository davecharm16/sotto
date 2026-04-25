import SwiftUI
import Carbon.HIToolbox

@main
struct SottoApp: App {
    @StateObject private var audioManager = AudioManager()
    @State private var hotkeyMonitor: Any?

    var body: some Scene {
        MenuBarExtra {
            SottoMenuView()
                .environmentObject(audioManager)
                .onAppear {
                    setupGlobalHotkey()
                }
        } label: {
            Label("Sotto", systemImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        if !audioManager.isEnabled {
            return "waveform.circle"
        } else if audioManager.isBypassed {
            return "waveform.slash"
        } else {
            return "waveform.circle.fill"
        }
    }

    private func setupGlobalHotkey() {
        guard hotkeyMonitor == nil else { return }

        // Cmd+Shift+N to toggle NC
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 45 { // N key
                Task { @MainActor in
                    audioManager.isEnabled.toggle()
                }
            }
        }
    }
}
