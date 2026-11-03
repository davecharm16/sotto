import Foundation

/// Pure UserDefaults reads, kept apart from `AudioManager` so they can be unit-tested headless.
enum SettingsStore {
    static let attenuationKey = "attenuation"
    static let onboardingKey = "hasCompletedOnboarding"

    /// nil only when never saved. A saved 0 (bypass strength) is a real value.
    static func savedAttenuation(_ defaults: UserDefaults = .standard) -> Float? {
        defaults.object(forKey: attenuationKey) == nil ? nil : defaults.float(forKey: attenuationKey)
    }
}

extension AudioStartError {
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// Where the user can fix this error, if System Settings is the place.
    var settingsURL: URL? { self == .noMicPermission ? Self.microphoneSettingsURL : nil }
}
