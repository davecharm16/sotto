import AppKit
import Carbon.HIToolbox

/// Owns launch-time work. A `MenuBarExtra`'s content only renders when the menu opens, so nothing that must run at
/// launch can live in a view's `.onAppear`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let audioManager = AudioManager()
    private var toggleHotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted XCTest runs launch the full app: don't grab ⌘⇧N there, so nothing can start audio.
        // Check presence only: XCTest blanks the value once it has read it (seen with Xcode 26).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        toggleHotkey = GlobalHotkey(keyCode: kVK_ANSI_N, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.audioManager.isEnabled.toggle()
        }
    }
}
