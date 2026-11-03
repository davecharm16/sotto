import XCTest

final class SettingsStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "sotto.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testUnsavedAttenuationIsNil() {
        XCTAssertNil(SettingsStore.savedAttenuation(freshDefaults()))
    }

    func testSavedZeroSurvives() {
        let d = freshDefaults()
        d.set(Float(0), forKey: SettingsStore.attenuationKey)
        XCTAssertEqual(SettingsStore.savedAttenuation(d), 0)
    }

    func testSavedValueRoundTrips() {
        let d = freshDefaults()
        d.set(Float(0.35), forKey: SettingsStore.attenuationKey)
        XCTAssertEqual(SettingsStore.savedAttenuation(d), 0.35)
    }

    func testEveryErrorHasHumanTextAndOnlyMicLinksToSettings() {
        let all: [AudioStartError] = [.noMicPermission, .noInputDevice, .outputDeviceMissing,
                                      .engineStartFailed(-1), .modelLoadFailed]
        for e in all {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
            XCTAssertEqual(e.settingsURL != nil, e == .noMicPermission)
        }
        XCTAssertEqual(AudioStartError.noMicPermission.settingsURL?.scheme, "x-apple.systempreferences")
    }
}
