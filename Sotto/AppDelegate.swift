import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns launch-time work. A `MenuBarExtra`'s content only renders when the menu opens, so nothing that must run at
/// launch can live in a view's `.onAppear`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let audioManager = AudioManager()
    private var toggleHotkey: GlobalHotkey?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted XCTest runs launch the full app: don't grab ⌘⇧N there, so nothing can start audio.
        // Check presence only: XCTest blanks the value once it has read it (seen with Xcode 26).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        toggleHotkey = GlobalHotkey(keyCode: kVK_ANSI_N, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.audioManager.isEnabled.toggle()
        }

        showOnboardingIfNeeded()
    }

    /// Shown once: the flag is set on presentation, so a closed window is not nagged about again.
    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: SettingsStore.onboardingKey) else { return }
        UserDefaults.standard.set(true, forKey: SettingsStore.onboardingKey)

        let view = OnboardingView { [weak self] in self?.onboardingWindow?.close() }
            .environmentObject(audioManager)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Sotto"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
