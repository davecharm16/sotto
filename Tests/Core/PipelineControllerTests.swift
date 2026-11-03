import XCTest

/// Controller state machine with fake engines: no hardware, no permissions, real `PipelineCore` and model.
@MainActor
final class PipelineControllerTests: XCTestCase {
    private var modelPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sotto/Resources/DeepFilterNet3").path
    }

    private let mic = AudioDevice(id: 10, uid: "mic", name: "Mic", isInput: true, isOutput: false)
    private let sink = AudioDevice(id: 20, uid: "sink", name: "BlackHole 2ch", isInput: true, isOutput: true)

    private final class Env {
        var log: [String] = []
        var captures: [FakeCapture] = []
        var renders: [FakeRender] = []
        var devices: [String: AudioDevice] = [:]
        var mic = true
        var renderFails: OSStatus?
        var micDelay: TimeInterval = 0
    }

    private final class FakeCapture: CapturingEngine {
        let env: Env
        var onConfigurationChange: (() -> Void)?
        var isHealthy = true
        var inputLevel: Float = 0
        var routing = "fake capture"
        var rate = 44_100.0
        var core: PipelineCore?
        init(_ env: Env) { self.env = env }
        func configure(device: AudioDevice) throws -> CaptureFormat {
            env.log.append("capture.configure"); return CaptureFormat(sampleRate: rate, channelCount: 2)
        }
        func start(into core: PipelineCore) throws { self.core = core; env.log.append("capture.start") }
        func stop() { env.log.append("capture.stop(coreDestroyed=\(core?.isDestroyed ?? false))") }
    }

    private final class FakeRender: RenderingEngine {
        let env: Env
        var onConfigurationChange: (() -> Void)?
        var isHealthy = true
        var routing = "fake render"
        var core: PipelineCore?
        init(_ env: Env) { self.env = env }
        func start(device: AudioDevice, from core: PipelineCore) throws {
            if let s = env.renderFails { env.log.append("render.start(fail)"); throw AudioStartError.engineStartFailed(s) }
            self.core = core; env.log.append("render.start")
        }
        func stop() { env.log.append("render.stop(coreDestroyed=\(core?.isDestroyed ?? false))") }
    }

    private func make(_ env: Env, model: String? = nil, debounce: TimeInterval = 0.02) -> PipelineController {
        env.devices = ["mic": mic, "sink": sink]
        return PipelineController(
            modelPath: model ?? modelPath,
            factory: EngineFactory(
                makeCapture: { let c = FakeCapture(env); env.captures.append(c); return c },
                makeRender: { let r = FakeRender(env); env.renders.append(r); return r }),
            micAccess: { if env.micDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(env.micDelay * 1e9)) }; return env.mic },
            lookupDevice: { env.devices[$0] },
            debounce: debounce,
            driftControl: true,
            observeSystemSleep: false)
    }

    private func settle(_ seconds: TimeInterval = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    func testStartOrderAndTeardownOrder() async throws {
        let env = Env(); let c = make(env)
        try await c.start(input: mic, output: sink)
        XCTAssertEqual(c.state, .running)
        XCTAssertEqual(env.log, ["capture.configure", "render.start", "capture.start"], "render is up before the mic opens")
        XCTAssertEqual(c.routingLog, ["fake capture", "fake render"])
        env.log = []
        c.stop()
        XCTAssertEqual(env.log, ["capture.stop(coreDestroyed=false)", "render.stop(coreDestroyed=false)"],
                       "both engines stop while the core is still live; the core stops after")
        XCTAssertTrue(env.renders[0].core?.isDestroyed ?? false, "NC thread joined and df_destroy ran after both engine stops")
        XCTAssertEqual(c.state, .stopped)
        c.stop()   // idempotent
    }

    func testPartialStartFailureUnwindsEverything() async throws {
        let env = Env(); env.renderFails = -50
        let c = make(env)
        do { try await c.start(input: mic, output: sink); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? AudioStartError, .engineStartFailed(-50)) }
        XCTAssertEqual(c.state, .stopped)
        XCTAssertTrue(env.log.contains("capture.stop(coreDestroyed=false)") && env.log.contains("render.stop(coreDestroyed=false)"))
        XCTAssertTrue(env.renders[0].core == nil || env.renders[0].core!.isStopped)
        XCTAssertNil(c.stats, "no pipeline left behind")
    }

    func testTypedStartErrors() async throws {
        var env = Env(); var c = make(env); env.mic = false
        await assertThrows(.noMicPermission) { try await c.start(input: self.mic, output: self.sink) }
        XCTAssertTrue(env.captures.isEmpty, "nothing is built without permission")

        env = Env(); c = make(env)
        await assertThrows(.outputDeviceMissing) { try await c.start(input: self.mic, output: self.mic) }
        await assertThrows(.noInputDevice) { try await c.start(input: self.sink.with(isInput: false), output: self.sink) }

        env = Env(); c = make(env, model: "/nonexistent")
        await assertThrows(.modelLoadFailed) { try await c.start(input: self.mic, output: self.sink) }
        XCTAssertEqual(c.state, .stopped)
        XCTAssertTrue(env.log.contains(where: { $0.hasPrefix("capture.stop") }), "failed model load unwinds the engines")
    }

    func testHealthyConfigChangeIsIgnoredUnhealthyRebuildsOnce() async throws {
        let env = Env(); let c = make(env)
        try await c.start(input: mic, output: sink)
        env.captures[0].onConfigurationChange?()     // the single change posted at capture start
        await settle()
        XCTAssertEqual(env.captures.count, 1, "healthy engines: no rebuild")

        env.captures[0].isHealthy = false
        for _ in 0..<5 { env.captures[0].onConfigurationChange?(); env.renders[0].onConfigurationChange?() }
        await settle()
        XCTAssertEqual(env.captures.count, 2, "a burst of notifications collapses into one rebuild")
        XCTAssertEqual(c.state, .running)
        XCTAssertTrue(env.renders[0].core?.isStopped ?? false, "old core was stopped")
        // A stale engine from the replaced pipeline must not trigger anything.
        env.captures[0].onConfigurationChange?()
        await settle()
        XCTAssertEqual(env.captures.count, 2)
    }

    func testMicLossKeepsRenderAliveThenRecovers() async throws {
        let env = Env(); let c = make(env)
        var states: [PipelineController.State] = []
        c.onStateChange = { states.append($0) }
        try await c.start(input: mic, output: sink)

        env.devices["mic"] = nil
        c.devicesChanged()
        await settle()
        XCTAssertEqual(c.state, .degraded(.noInputDevice))
        XCTAssertEqual(env.captures.count, 1, "no capture engine while the mic is gone")
        XCTAssertEqual(env.renders.count, 2, "render rebuilt and running: BlackHole stays alive")
        XCTAssertFalse(env.renders[1].core?.isStopped ?? true)
        // Silence, never raw audio: nothing was pushed, so everything pulled is zero and counted as underrun.
        var out = [Float](repeating: 1, count: 480)
        env.renders[1].core?.pull(into: &out, frames: 480)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })

        c.devicesChanged()                  // unrelated event while still missing: no churn
        await settle()
        XCTAssertEqual(env.renders.count, 2)

        env.devices["mic"] = mic
        c.devicesChanged()
        await settle()
        XCTAssertEqual(c.state, .running)
        XCTAssertEqual(env.captures.count, 2)
        XCTAssertEqual(states, [.running, .degraded(.noInputDevice), .running])
    }

    func testSupersededRebuildNeverPublishesStalePipeline() async throws {
        let env = Env(); let c = make(env)
        try await c.start(input: mic, output: sink)
        env.micDelay = 0.3                       // every permission check from now on is slow
        env.captures[0].isHealthy = false
        env.captures[0].onConfigurationChange?() // rebuild #1 snapshots the mic and suspends in micAccess
        await settle(0.1)
        env.devices["mic"] = nil
        c.devicesChanged()                       // rebuild #2 supersedes it mid-await
        await settle(1.2)
        XCTAssertEqual(c.state, .degraded(.noInputDevice), "only the newest target is published")
        XCTAssertEqual(env.captures.count, 1, "the stale rebuild must not assemble a capture engine")
    }

    func testOutputLossThenRecovery() async throws {
        let env = Env(); let c = make(env)
        try await c.start(input: mic, output: sink)
        env.devices["sink"] = nil
        c.devicesChanged(); await settle()
        XCTAssertEqual(c.state, .degraded(.outputDeviceMissing))
        XCTAssertTrue(env.log.last?.hasPrefix("render.stop") ?? false)
        env.devices["sink"] = sink
        c.devicesChanged(); await settle()
        XCTAssertEqual(c.state, .running)
    }

    func testSleepTearsDownAndWakeRebuilds() async throws {
        let env = Env(); let c = make(env)
        try await c.start(input: mic, output: sink)
        c.systemWillSleep()
        XCTAssertEqual(c.state, .sleeping)
        XCTAssertTrue(env.renders[0].core?.isStopped ?? false)
        c.devicesChanged(); await settle()
        XCTAssertEqual(env.captures.count, 1, "device events while asleep do nothing")
        c.systemDidWake(); await settle()
        XCTAssertEqual(c.state, .running)
        XCTAssertEqual(env.captures.count, 2)
    }

    func testRestartWhileRunningReplacesPipelineAndStopDuringStartCancels() async throws {
        let env = Env(); let c = make(env)
        try await c.start(input: mic, output: sink)
        try await c.start(input: mic, output: sink)
        XCTAssertEqual(env.captures.count, 2)
        XCTAssertTrue(env.renders[0].core?.isStopped ?? false)

        let pending = Task { try await c.start(input: self.mic, output: self.sink) }
        await settle(0.05)   // the build is now suspended in the 170 ms model load
        c.stop()
        do { try await pending.value } catch is CancellationError {} catch { XCTFail("\(error)") }
        await settle(0.1)
        XCTAssertEqual(c.state, .stopped)
        XCTAssertNil(c.stats)
    }

    func testAttenuationBeforeAndWhileRunningSurvivesRebuild() async throws {
        let env = Env(); let c = make(env)
        c.setAttenuation(0.25)
        try await c.start(input: mic, output: sink)
        c.setAttenuation(0)
        env.captures[0].isHealthy = false
        env.captures[0].onConfigurationChange?()
        await settle()
        XCTAssertEqual(c.state, .running)   // rebuilt core is created with the latest attenuation (0)
    }

    // MARK: helpers

    private func assertThrows(_ expected: AudioStartError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AudioStartError, expected, file: file, line: line) }
    }
}

private extension AudioDevice {
    func with(isInput: Bool) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, isInput: isInput, isOutput: isOutput)
    }
}
