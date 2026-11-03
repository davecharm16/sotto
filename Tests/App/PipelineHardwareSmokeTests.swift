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
}

private enum TestTone {
    static func sine(frames: Int, rate: Double) -> [Float] {
        (0..<frames).map { 0.1 * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
    }
}
