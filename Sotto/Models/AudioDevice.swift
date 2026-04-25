import Foundation
import CoreAudio

typealias AudioDeviceID = UInt32

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isInput: Bool
    let isOutput: Bool

    var isBlackHole: Bool {
        uid.contains("BlackHole")
    }

    static func getDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        return deviceIDs.compactMap { AudioDevice(deviceID: $0) }
    }

    init?(deviceID: AudioDeviceID) {
        self.id = deviceID

        guard let uid = AudioDevice.getStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = AudioDevice.getStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString) else {
            return nil
        }

        self.uid = uid
        self.name = name
        self.isInput = AudioDevice.hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
        self.isOutput = AudioDevice.hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func getStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var result: CFString?

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &result
        )

        guard status == noErr, let cfString = result else { return nil }
        return cfString as String
    }

    private static func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }
}
