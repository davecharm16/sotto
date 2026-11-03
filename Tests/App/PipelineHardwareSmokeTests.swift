import AVFoundation
import CoreAudio
import XCTest
@testable import Sotto

/// Real devices, hosted in Sotto.app. Both tests XCTSkip when the hardware or the mic grant is missing.
/// The render engine runs at volume 0, so nothing audible (and no mic -> speaker feedback) is ever produced.
@MainActor
final class PipelineHardwareSmokeTests: XCTestCase {
    private var modelPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sotto/Resources/DeepFilterNet3").path
    }

    private func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return AudioDevice(deviceID: id)
    }

    /// Render engine only (no mic permission needed): source block pulls from the core and the AU holds the target.
    func testRenderEngineDrivesAnyOutputDevice() async throws {
        let out = try XCTUnwrap(defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) ?? nil,
                                "no default output device")
        try XCTSkipIf(out.isBlackHole || !out.isOutput, "default output unsuitable for the smoke test")

        let core = try PipelineCore(config: .init(modelPath: modelPath, inputSampleRate: 48_000))
        try await core.start()
        defer { core.stop() }
        let render = RenderEngine(outputVolume: 0)
        defer { render.stop() }
        try render.start(device: out, from: core)
        print("ROUTING \(render.routing)")
        XCTAssertTrue(render.routing.contains("AU holds id=\(out.id)"), "the output AU must hold the requested device")

        // Feed 48 kHz sine as the capture side would, ~3 s paced in real time.
        let tone = TestTone.sine(frames: 480, rate: 48_000)
        for _ in 0..<300 {
            tone.withUnsafeBufferPointer { core.push(mono: $0.baseAddress!, frames: 480) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let s = core.stats
        print("STATS render-only \(s)")
        XCTAssertTrue(render.isHealthy)
        XCTAssertGreaterThan(s.chunksProcessed, 250)
        XCTAssertEqual(s.ringAOverrunFrames, 0)
        XCTAssertEqual(s.ringBOverrunSamples, 0)
    }

    /// Smell 13 proof: the capture engine's AU holds the mic and the render engine's AU holds the output, on two
    /// different AudioUnits. Touching `inputNode` without a mic grant blocks on the TCC prompt, so this needs one.
    func testEnginesPinTheirOwnDevice() throws {
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          "microphone permission not granted to the test host")
        let mic = try XCTUnwrap(defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) ?? nil, "no input device")
        let out = try XCTUnwrap(defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) ?? nil, "no output device")
        try XCTSkipIf(mic.isBlackHole || !mic.isInput || out.isBlackHole || !out.isOutput)
        let capture = CaptureEngine()
        let format = try capture.configure(device: mic)
        print("ROUTING \(capture.routing)")
        XCTAssertTrue(capture.routing.contains("AU holds id=\(mic.id)"), capture.routing)
        XCTAssertGreaterThan(format.sampleRate, 0)

        let core = try PipelineCore(config: .init(modelPath: modelPath, inputSampleRate: format.sampleRate))
        let render = RenderEngine(outputVolume: 0)
        try render.start(device: out, from: core)
        defer { render.stop(); core.stop() }
        print("ROUTING \(render.routing)")
        XCTAssertTrue(render.routing.contains("AU holds id=\(out.id)"), render.routing)
        XCTAssertNotEqual(capture.routing.components(separatedBy: "(0x").last, render.routing.components(separatedBy: "(0x").last,
                          "two engines, two AudioUnits")
    }

    /// Full path: real mic -> sink -> core -> source -> built-in output (muted). Needs a granted mic permission.
    func testCaptureToRenderCounters() async throws {
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          "microphone permission not granted to the test host")
        let mic = try XCTUnwrap(defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) ?? nil, "no input device")
        try XCTSkipIf(mic.isBlackHole || !mic.isInput, "no real input device")
        let out = try XCTUnwrap(defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) ?? nil)
        try XCTSkipIf(out.isBlackHole || !out.isOutput)

        let controller = PipelineController(
            modelPath: modelPath,
            factory: EngineFactory(makeCapture: { CaptureEngine() }, makeRender: { RenderEngine(outputVolume: 0) }),
            observeSystemSleep: false)
        try await controller.start(input: mic, output: out)
        defer { controller.stop() }
        for line in controller.routingLog { print("ROUTING \(line)") }

        try await Task.sleep(nanoseconds: 5_000_000_000)
        let s = try XCTUnwrap(controller.stats)
        print("STATS capture->render 5 s \(s) level=\(controller.inputLevel)")
        XCTAssertEqual(controller.state, .running, "the start-time configuration change must not degrade the pipeline")
        XCTAssertGreaterThan(s.chunksProcessed, 400, "~500 chunks expected in 5 s")
        XCTAssertEqual(s.ringAOverrunFrames, 0)
        XCTAssertEqual(s.ringBOverrunSamples, 0)
        XCTAssertLessThan(s.ringBUnderrunSamples, 4800, "at most a startup transient (100 ms)")
        XCTAssertTrue(controller.routingLog.joined().contains("AU holds id=\(mic.id)"))
    }
    /// Control for the E2E test: a known tone through core -> render -> BlackHole must be recorded on BlackHole.
    func testToneThroughBlackHoleIsRecorded() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/tmp/sotto-e2e"), "opt-in: touch /tmp/sotto-e2e")
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "no mic grant")
        let bh = try XCTUnwrap(AudioDevice.getDevices().first { $0.isBlackHole && $0.isOutput && $0.isInput })
        let rec = LevelRecorder(); try rec.start(device: bh)
        let core = try PipelineCore(config: .init(modelPath: modelPath, inputSampleRate: 48_000, driftControl: true))
        try await core.start()
        let render = RenderEngine(); try render.start(device: bh, from: core)
        defer { render.stop(); core.stop(); rec.stop() }
        let tone = TestTone.sine(frames: 480, rate: 48_000)
        for _ in 0..<400 { tone.withUnsafeBufferPointer { core.push(mono: $0.baseAddress!, frames: 480) }; try await Task.sleep(nanoseconds: 10_000_000) }
        print("CONTROL tone via BlackHole: samples \(rec.count) peak \(rec.peak) dBFS \(rec.db) core \(core.stats)")
        XCTAssertGreaterThan(rec.peak, 1e-5, "BlackHole recorded digital silence for a known tone (NC attenuates pure tones, so only nonzero is asserted)")
    }

    /// End to end (opt-in: SOTTO_E2E=1): real mic -> pipeline -> BlackHole, while a second tap records the raw mic
    /// and a third engine records what arrives on BlackHole. Play steady noise from the speakers meanwhile
    /// (`afplay`); the BlackHole level must be well below the raw mic level.
    func testEndToEndNoiseReductionThroughBlackHole() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOTTO_E2E"] == "1" || FileManager.default.fileExists(atPath: "/tmp/sotto-e2e"),
                          "opt-in: touch /tmp/sotto-e2e")
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "no mic grant")
        let devices = AudioDevice.getDevices()
        let bh = try XCTUnwrap(devices.first { $0.isBlackHole && $0.isOutput && $0.isInput }, "BlackHole 2ch not visible")
        let mic = try XCTUnwrap(defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) ?? nil)
        try XCTSkipIf(mic.isBlackHole)

        let rawRec = LevelRecorder(), bhRec = LevelRecorder()
        try rawRec.start(device: mic)
        try bhRec.start(device: bh)
        let controller = PipelineController(modelPath: modelPath, factory: .live, observeSystemSleep: false)
        try await controller.start(input: mic, output: bh)
        defer { controller.stop(); rawRec.stop(); bhRec.stop() }
        for line in controller.routingLog { print("ROUTING \(line)") }

        try await Task.sleep(nanoseconds: 4_000_000_000)
        rawRec.reset(); bhRec.reset()          // drop warm-up/latency transient
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let rawDB = rawRec.db, bhDB = bhRec.db
        print("E2E peaks raw \(rawRec.peak) bh \(bhRec.peak)")
        print("E2E samples raw \(rawRec.count) bh \(bhRec.count) pipelineLevel \(controller.inputLevel)")
        print("E2E raw mic \(rawDB) dBFS, BlackHole \(bhDB) dBFS, reduction \(rawDB - bhDB) dB, stats \(String(describing: controller.stats))")
        XCTAssertEqual(controller.state, .running)
        XCTAssertGreaterThan(rawRec.count, 100_000, "raw mic recorder got no samples")
        XCTAssertGreaterThan(bhRec.count, 100_000, "BlackHole recorder got no samples")
        XCTAssertGreaterThan(rawDB, -70, "no noise reached the mic: is afplay running?")
        XCTAssertGreaterThan(rawDB - bhDB, 10, "NC must cut steady noise by >= 10 dB end to end")
    }
}

/// Taps one input device and accumulates mean-square (mono-averaged). Test-only.
private final class LevelRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var sumSq = 0.0, n = 0.0
    var count: Double { lock.lock(); defer { lock.unlock() }; return n }
    var peak = 0.0
    var db: Double { lock.lock(); defer { lock.unlock() }; return 10 * log10(max(sumSq / max(n, 1), 1e-12)) }
    func reset() { lock.lock(); sumSq = 0; n = 0; peak = 0; lock.unlock() }
    func start(device: AudioDevice) throws {
        var id = device.id
        let au = engine.inputNode.audioUnit!
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        print("E2E recorder dev=\(device.name) id=\(id) fmt=\(fmt)")
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [self] buf, _ in
            guard let ch = buf.floatChannelData else { return }
            var s = 0.0
            for i in 0..<Int(buf.frameLength) { let v = Double(ch[0][i]); s += v * v }
            lock.lock(); sumSq += s; n += Double(buf.frameLength); for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(Double(ch[0][i]))) }; lock.unlock()
        }
        try engine.start()
    }
    func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop() }
}

private enum TestTone {
    static func sine(frames: Int, rate: Double) -> [Float] {
        (0..<frames).map { 0.1 * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
    }
}
