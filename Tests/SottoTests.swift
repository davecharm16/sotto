import XCTest
@testable import Sotto

final class SottoTests: XCTestCase {
    func testAudioDeviceEnumeration() {
        let devices = AudioDevice.getDevices()
        XCTAssertFalse(devices.isEmpty, "Should detect at least one audio device")
    }
}
