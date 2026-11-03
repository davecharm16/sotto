import SwiftUI

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        SottoMenuBar(audioManager: appDelegate.audioManager)
    }
}

/// A separate `Scene` observing the manager, so the menu-bar icon follows state changes made outside the menu
/// (for example the ⌘⇧N hotkey while the menu is closed).
private struct SottoMenuBar: Scene {
    @ObservedObject var audioManager: AudioManager

    var body: some Scene {
        MenuBarExtra {
            SottoMenuView()
                .environmentObject(audioManager)
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
}
