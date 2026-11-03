import AppKit
import AVFoundation
import Foundation
import os

/// Everything `start` and the recovery path can fail with. One enum for the app (assessment C6).
enum AudioStartError: Error, Equatable, LocalizedError {
    case noMicPermission
    case noInputDevice
    /// The target output (BlackHole 2ch in production) is not present.
    case outputDeviceMissing
    case engineStartFailed(OSStatus)
    case modelLoadFailed

    var errorDescription: String? {
        switch self {
        case .noMicPermission: return "Microphone access is off. Allow Sotto in System Settings > Privacy & Security > Microphone."
        case .noInputDevice: return "The selected microphone is not available."
        case .outputDeviceMissing: return "BlackHole 2ch is not installed or not available."
        case .engineStartFailed(let status): return "The audio engine could not start (error \(status))."
        case .modelLoadFailed: return "The noise-cancellation model could not be loaded."
        }
    }
}

struct CaptureFormat: Equatable {
    var sampleRate: Double
    var channelCount: Int
}

/// Capture side of the pipeline: one engine pinned to one input device. `stop()` must be idempotent and safe on an
/// engine that never started.
protocol CapturingEngine: AnyObject {
    /// Posted on the main queue. The controller decides whether it is a fault.
    var onConfigurationChange: (() -> Void)? { get set }
    /// false once the engine stopped itself or the hardware format no longer matches what `configure` negotiated.
    var isHealthy: Bool { get }
    /// 0...1, read from an atomic.
    var inputLevel: Float { get }
    var routing: String { get }
    /// Pins the device, then returns the hardware format. The core is built from this.
    func configure(device: AudioDevice) throws -> CaptureFormat
    func start(into core: PipelineCore) throws
    func stop()
}

protocol RenderingEngine: AnyObject {
    var onConfigurationChange: (() -> Void)? { get set }
    var isHealthy: Bool { get }
    var routing: String { get }
    func start(device: AudioDevice, from core: PipelineCore) throws
    func stop()
}

struct EngineFactory {
    var makeCapture: () -> CapturingEngine
    var makeRender: () -> RenderingEngine
}

/// Owns the live pipeline (capture engine -> `PipelineCore` -> render engine) and rebuilds it when the world changes.
///
/// Rebuild triggers (all debounced into one): engine configuration change that leaves an engine unhealthy, a device
/// list change that makes the pinned devices appear or vanish, wake from sleep. Pinned devices are explicit UIDs, so
/// default-device changes cannot affect the pipeline and are not observed.
/// If only the mic is gone, the render engine stays up and emits silence (never raw input) so the call app keeps its
/// BlackHole device; a later device event rebuilds with the mic.
@MainActor
final class PipelineController {
    enum State: Equatable {
        case stopped
        case running
        /// Something the user can fix is missing; the pipeline is as up as it can be.
        case degraded(AudioStartError)
        case sleeping
    }

    private final class Pipeline {
        let core: PipelineCore
        let capture: CapturingEngine?
        let render: RenderingEngine
        init(core: PipelineCore, capture: CapturingEngine?, render: RenderingEngine) {
            self.core = core; self.capture = capture; self.render = render
        }
        var isHealthy: Bool { render.isHealthy && (capture?.isHealthy ?? true) }
        /// Engines first (so no real-time block can touch the core), then the NC thread is joined before df_destroy.
        func teardown() {
            capture?.stop()
            render.stop()
            core.stop()
        }
    }

    private struct Target { var input: String; var output: String }

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    private let log = Logger(subsystem: "com.sotto.app", category: "Pipeline")
    private let modelPath: String?
    private let factory: EngineFactory
    private let micAccess: () async -> Bool
    private let lookupDevice: (String) -> AudioDevice?
    private let debounce: TimeInterval
    private let driftControl: Bool
    private var pipeline: Pipeline?
    private var target: Target?
    private var attenuation: Float = 1
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var systemObservers: [NSObjectProtocol] = []

    init(modelPath: String?,
         factory: EngineFactory,
         micAccess: @escaping () async -> Bool = PipelineController.systemMicAccess,
         lookupDevice: @escaping (String) -> AudioDevice? = { uid in AudioDevice.getDevices().first { $0.uid == uid } },
         debounce: TimeInterval = 0.3,
         driftControl: Bool = true,
         observeSystemSleep: Bool = true) {
        self.modelPath = modelPath
        self.factory = factory
        self.micAccess = micAccess
        self.lookupDevice = lookupDevice
        self.debounce = debounce
        self.driftControl = driftControl
        if observeSystemSleep {
            let nc = NSWorkspace.shared.notificationCenter
            systemObservers = [
                nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.systemWillSleep() }
                },
                nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.systemDidWake() }
                },
            ]
        }
    }

    deinit {
        for o in systemObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    static func systemMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: public API

    /// (Re)starts the pipeline on explicit devices. Calling it while running replaces the pipeline. On failure
    /// everything started is unwound and the state is `.stopped`.
    func start(input: AudioDevice, output: AudioDevice) async throws {
        halt()
        let token = generation
        target = Target(input: input.uid, output: output.uid)
        do {
            guard input.isInput else { throw AudioStartError.noInputDevice }
            guard output.isOutput else { throw AudioStartError.outputDeviceMissing }
            guard await micAccess() else { throw AudioStartError.noMicPermission }
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            pipeline = try await assemble(input: input, output: output, token: token)
            state = .running
        } catch {
            if token == generation { target = nil; state = .stopped }
            throw error
        }
    }

    func stop() {
        halt()
        target = nil
        state = .stopped
    }

    /// Strength 0...1 (0 = bypass). Applies at the next frame.
    func setAttenuation(_ value: Float) {
        attenuation = value
        pipeline?.core.setAttenuation(value)
    }

    var inputLevel: Float { pipeline?.capture?.inputLevel ?? 0 }
    var stats: PipelineCore.Stats? { pipeline?.core.stats }
    /// One line per engine: device name, UID, the device ID the AudioUnit actually holds, and the negotiated format.
    var routingLog: [String] { [pipeline?.capture?.routing, pipeline?.render.routing].compactMap { $0 } }

    // MARK: environment events (called by AudioManager's DeviceMonitor wiring and by the engines)

    func devicesChanged() {
        guard let target, state != .sleeping, state != .stopped else { return }
        if wantedState(for: target) != state { scheduleRebuild() }
    }

    func systemWillSleep() {
        guard target != nil else { return }
        halt()
        state = .sleeping
    }

    func systemDidWake() {
        guard target != nil, state == .sleeping else { return }
        scheduleRebuild()
    }

    private func engineConfigurationChanged(token: Int) {
        guard token == generation, let pipeline, state == .running else { return }
        // AVAudioEngine posts one change while the capture engine starts. It is harmless when the engines are still
        // running with the negotiated format, so only an unhealthy engine triggers a rebuild.
        if pipeline.isHealthy { return }
        scheduleRebuild()
    }

    // MARK: build / rebuild

    private func wantedState(for target: Target) -> State {
        guard lookupDevice(target.output)?.isOutput == true else { return .degraded(.outputDeviceMissing) }
        guard lookupDevice(target.input)?.isInput == true else { return .degraded(.noInputDevice) }
        return .running
    }

    private func scheduleRebuild() {
        generation += 1          // invalidates any rebuild already in flight, so it cannot publish a stale pipeline
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        guard let target else { return }
        debounceTask = nil      // this task is the debounce task: halt() must not cancel the rebuild it is running
        halt()
        let token = generation
        guard let output = lookupDevice(target.output), output.isOutput else {
            state = .degraded(.outputDeviceMissing); return
        }
        let input = lookupDevice(target.input).flatMap { $0.isInput ? $0 : nil }
        do {
            guard await micAccess() else { throw AudioStartError.noMicPermission }
            guard !Task.isCancelled, token == generation else { return }
            let built = try await assemble(input: input, output: output, token: token)
            guard !Task.isCancelled, token == generation else { built.teardown(); return }
            pipeline = built
            state = input == nil ? .degraded(.noInputDevice) : .running
        } catch is CancellationError {
            return
        } catch {
            if token == generation { state = .degraded((error as? AudioStartError) ?? .engineStartFailed(-1)) }
        }
    }

    /// Invalidates in-flight builds and tears the current pipeline down.
    private func halt() {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pipeline?.teardown()
        pipeline = nil
    }

    /// Builds a started pipeline or throws with nothing left running. `input == nil` builds the silent-render form.
    private func assemble(input: AudioDevice?, output: AudioDevice, token: Int) async throws -> Pipeline {
        let capture = input == nil ? nil : factory.makeCapture()
        let render = factory.makeRender()
        var rate = PipelineCore.outputRate
        let core: PipelineCore
        do {
            if let input, let capture { rate = try capture.configure(device: input).sampleRate }
            guard let modelPath else { throw AudioStartError.modelLoadFailed }
            core = try PipelineCore(config: .init(modelPath: modelPath, inputSampleRate: rate,
                                                  attenuation: attenuation, driftControl: driftControl))
        } catch { throw Self.map(error) }

        let p = Pipeline(core: core, capture: capture, render: render)
        do {
            try await core.start()
            guard token == generation else { throw CancellationError() }
            let changed: () -> Void = { [weak self] in
                Task { @MainActor in self?.engineConfigurationChanged(token: token) }
            }
            capture?.onConfigurationChange = changed
            render.onConfigurationChange = changed
            try render.start(device: output, from: core)   // BlackHole is alive (silent) before the mic opens
            try capture?.start(into: core)
        } catch {
            p.teardown()
            throw Self.map(error)
        }
        for line in [capture?.routing, render.routing].compactMap({ $0 }) { log.info("\(line, privacy: .public)") }
        return p
    }

    private static func map(_ error: Error) -> Error {
        switch error {
        case is AudioStartError, is CancellationError: return error
        case NCProcessorError.modelLoadFailed: return AudioStartError.modelLoadFailed
        case PipelineError.unsupportedInputFormat: return AudioStartError.engineStartFailed(kAudioUnitErr_FormatNotSupported)
        default: return AudioStartError.engineStartFailed(OSStatus((error as NSError).code))
        }
    }
}
