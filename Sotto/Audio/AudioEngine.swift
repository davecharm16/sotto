import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio

// Two one-shot AVAudioEngines, each owning exactly one device direction. On macOS `inputNode` and `outputNode` of one
// engine share a single AUHAL, so a second `CurrentDevice` write silently re-targets the first (overview smell 13).
//
//   CaptureEngine: inputNode(mic) -> AVAudioSinkNode  -> PipelineCore.push*
//   RenderEngine:  PipelineCore.pull -> AVAudioSourceNode -> mainMixer -> outputNode(BlackHole or any output device)
//
// Engines are never reused: after a configuration change the controller builds new ones. The blocks only call
// `PipelineCore.push*` / `pull` through an unretained reference and touch atomics; the controller guarantees the
// core outlives `stop()` of both engines.

/// Pins the engine's I/O unit to `deviceID`. Must happen before any format is read.
private func pin(_ deviceID: AudioDeviceID, on node: AVAudioIONode) throws {
    guard let unit = node.audioUnit else { throw AudioStartError.engineStartFailed(kAudioUnitErr_Uninitialized) }
    var id = deviceID
    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    if status != noErr { throw AudioStartError.engineStartFailed(status) }
}

/// The device the unit actually holds: the routing proof for smell 13.
private func currentDevice(of node: AVAudioIONode) -> AudioDeviceID? {
    guard let unit = node.audioUnit else { return nil }
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
    return status == noErr ? id : nil
}

private func describe(_ role: String, _ device: AudioDevice, node: AVAudioIONode, format: AVAudioFormat) -> String {
    let held = currentDevice(of: node)
    let heldUID = held.flatMap { AudioDevice(deviceID: $0)?.uid } ?? "?"
    let au = node.audioUnit.map { String(describing: $0) } ?? "nil"
    return "\(role): \(device.name) uid=\(device.uid) id=\(device.id); AU holds id=\(held.map(String.init) ?? "?") uid=\(heldUID) "
        + "(\(au)); format \(format.sampleRate) Hz x\(format.channelCount) \(format.commonFormat.rawValue)"
}

private func mapEngineError(_ error: Error) -> AudioStartError {
    (error as? AudioStartError) ?? .engineStartFailed(OSStatus((error as NSError).code))
}

// MARK: - capture

/// State the sink block reads. Allocated before the engine starts, freed after it stops.
private final class CaptureBlockState {
    let core: Unmanaged<PipelineCore>
    let channels: Int
    let ptrs: UnsafeMutablePointer<UnsafePointer<Float>>
    let level = SingleWriterCounter()

    init(core: PipelineCore, channels: Int) {
        self.core = Unmanaged.passUnretained(core)
        self.channels = channels
        ptrs = .allocate(capacity: channels)
    }
    deinit { ptrs.deallocate() }
}

final class CaptureEngine: CapturingEngine {
    var onConfigurationChange: (() -> Void)?

    private let engine = AVAudioEngine()
    private var device: AudioDevice?
    private var negotiated: CaptureFormat?
    private var state: CaptureBlockState?
    private var observer: NSObjectProtocol?
    private(set) var routing = "capture: not started"

    var inputLevel: Float {
        guard let state else { return 0 }
        let rms = Float(bitPattern: UInt32(truncatingIfNeeded: state.level.value))
        let db = 20 * log10(max(rms, 0.0001))
        return max(0, min(1, (db + 60) / 60))
    }

    var isHealthy: Bool {
        guard engine.isRunning, let negotiated else { return false }
        let hw = engine.inputNode.outputFormat(forBus: 0)
        return hw.sampleRate == negotiated.sampleRate && Int(hw.channelCount) == negotiated.channelCount
    }

    func configure(device: AudioDevice) throws -> CaptureFormat {
        let input = engine.inputNode
        try pin(device.id, on: input)   // before any format is read
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0, hw.commonFormat == .pcmFormatFloat32 else {
            throw AudioStartError.engineStartFailed(kAudioUnitErr_FormatNotSupported)
        }
        self.device = device
        let format = CaptureFormat(sampleRate: hw.sampleRate, channelCount: Int(hw.channelCount))
        negotiated = format
        routing = describe("capture", device, node: input, format: hw)
        return format
    }

    func start(into core: PipelineCore) throws {
        guard let negotiated, let device else { throw AudioStartError.engineStartFailed(kAudioUnitErr_Uninitialized) }
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        let state = CaptureBlockState(core: core, channels: negotiated.channelCount)
        self.state = state

        let sink = AVAudioSinkNode { _, frames, abl in
            let frameCount = Int(frames)
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard list.count > 0, let first = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            var rms: Float = 0
            if list.count == 1 {   // interleaved (or mono)
                state.core._withUnsafeGuaranteedRef { $0.push(interleaved: first, channelCount: state.channels, frames: frameCount) }
                vDSP_rmsqv(first, 1, &rms, vDSP_Length(frameCount * state.channels))
            } else {
                let m = min(list.count, state.channels)
                for c in 0..<m {
                    state.ptrs[c] = UnsafePointer(list[c].mData?.assumingMemoryBound(to: Float.self) ?? first)
                }
                state.core._withUnsafeGuaranteedRef { $0.push(planar: state.ptrs, channelCount: m, frames: frameCount) }
                vDSP_rmsqv(first, 1, &rms, vDSP_Length(frameCount))
            }
            state.level.set(Int(rms.bitPattern))
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: hw)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }
        do { try engine.start() } catch { stop(); throw mapEngineError(error) }
        routing = describe("capture", device, node: input, format: hw)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        // `state` stays alive until deinit: the engine is stopped, so no block can run, and the level stays readable.
    }
}

// MARK: - render

final class RenderEngine: RenderingEngine {
    var onConfigurationChange: (() -> Void)?

    private let engine = AVAudioEngine()
    private let outputVolume: Float
    private var observer: NSObjectProtocol?
    private(set) var routing = "render: not started"

    /// `outputVolume` 0 keeps the whole pipeline pulling while playing nothing (hardware smoke tests on speakers).
    init(outputVolume: Float = 1) { self.outputVolume = outputVolume }

    var isHealthy: Bool { engine.isRunning }

    func start(device: AudioDevice, from core: PipelineCore) throws {
        let out = engine.outputNode          // never touch inputNode here: it would enable input on this unit
        try pin(device.id, on: out)          // before the mixer connection reads the output format
        let format = AVAudioFormat(standardFormatWithSampleRate: PipelineCore.outputRate, channels: 1)!
        let core = Unmanaged.passUnretained(core)
        let source = AVAudioSourceNode(format: format) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count > 0, let dst = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            core._withUnsafeGuaranteedRef { $0.pull(into: dst, frames: Int(frames)) }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = outputVolume
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }
        do { try engine.start() } catch { stop(); throw mapEngineError(error) }
        routing = describe("render", device, node: out, format: out.outputFormat(forBus: 0))
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
    }
}

extension EngineFactory {
    static let live = EngineFactory(makeCapture: { CaptureEngine() }, makeRender: { RenderEngine() })
}
