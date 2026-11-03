import XCTest
import CoreAudio
@testable import Sotto

final class SottoTests: XCTestCase {
    func testAudioDeviceEnumerationIncludesDefaultInput() throws {
        let defaultInput = try XCTUnwrap(Self.defaultInputDeviceID())
        try XCTSkipIf(defaultInput == kAudioObjectUnknown, "No audio input device on this Mac")

        let devices = AudioDevice.getDevices()
        XCTAssertTrue(devices.contains { $0.id == defaultInput && $0.isInput },
                      "The system default input should be enumerated as an input device")
    }

    private static func defaultInputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }
}
