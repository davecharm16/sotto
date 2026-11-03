import AVFoundation
import CoreAudio
import AudioToolbox

func halGet<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = initial; var size = UInt32(MemoryLayout<T>.size)
    _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
    return v
}
func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "<id \(id): no name>" }
    return n.takeRetainedValue() as String
}
func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}
func describe(_ id: AudioDeviceID) -> String {
    let sr: Float64 = halGet(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0)
    let cd: UInt32 = halGet(id, kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal, 0)
    let bs: UInt32 = halGet(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, 0)
    let li: UInt32 = halGet(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, 0)
    let lo: UInt32 = halGet(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0)
    let si: UInt32 = halGet(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, 0)
    let so: UInt32 = halGet(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, 0)
    return "id=\(id) '\(deviceName(id))' in=\(channels(id, kAudioObjectPropertyScopeInput))ch out=\(channels(id, kAudioObjectPropertyScopeOutput))ch nominalSR=\(sr) clockDomain=\(cd) ioBuf=\(bs) latIn=\(li) latOut=\(lo) safetyIn=\(si) safetyOut=\(so)"
}
func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID { halGet(AudioObjectID(kAudioObjectSystemObject), sel, kAudioObjectPropertyScopeGlobal, 0) }
func auCurrentDevice(_ au: AudioUnit) -> (OSStatus, AudioDeviceID) {
    var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
    return (st, id)
}
func setAUDevice(_ au: AudioUnit, _ id: AudioDeviceID) -> OSStatus {
    var id = id
    return AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
}
func firstDevice(input: Bool) -> AudioDeviceID? {
    allDevices().first { channels($0, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput) > 0 && (input || channels($0, kAudioObjectPropertyScopeInput) == 0 || true) }
}
func uidOf(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &s) == noErr, let v = s else { return "?" }
    return v.takeRetainedValue() as String
}
