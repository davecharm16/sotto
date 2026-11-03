import Foundation
import Combine
import AVFoundation
import AppKit
import ServiceManagement

@MainActor
class AudioManager: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startProcessing()
            } else {
                stopProcessing()
            }
        }
    }

    @Published var inputLevel: Float = 0.0
    /// Why the last start (or an automatic recovery) failed; nil while healthy.
    @Published var lastError: AudioStartError?
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedDevice: AudioDevice? {
        didSet {
            if selectedDevice != oldValue {
                saveSelectedDevice()
                if isEnabled { startProcessing() }   // picker change while running: rebuild on the new mic
            }
        }
    }
    @Published var isBlackHoleInstalled: Bool = false
    @Published var attenuation: Float = 1.0 {
        didSet {
            controller.setAttenuation(isBypassed ? 0 : attenuation)
            UserDefaults.standard.set(attenuation, forKey: "attenuation")
        }
    }
    @Published var isBypassed: Bool = false {
        didSet {
            controller.setAttenuation(isBypassed ? 0 : attenuation)
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            setLaunchAtLogin(launchAtLogin)
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }

    private let controller = PipelineController(
        modelPath: Bundle.main.path(forResource: "config", ofType: "ini", inDirectory: "DeepFilterNet3")
            .map { ($0 as NSString).deletingLastPathComponent },
        factory: .live)
    private var levelTimer: Timer?
    private var deviceMonitor: DeviceMonitor?
    private var cancellables = Set<AnyCancellable>()

    init() {
        controller.onStateChange = { [weak self] state in
            // Automatic recovery can degrade or restore the pipeline without the user touching anything.
            if case .degraded(let error) = state { self?.lastError = error }
            else if state == .running { self?.lastError = nil }
        }
        setupDeviceMonitor()
        refreshDevices()
        restoreSelectedDevice()
        restoreAttenuation()
        restoreLaunchAtLogin()
        checkBlackHoleStatus()
    }

    private func setupDeviceMonitor() {
        deviceMonitor = DeviceMonitor()
        deviceMonitor?.onDevicesChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshDevices()
                self?.controller.devicesChanged()
            }
        }
        deviceMonitor?.startMonitoring()
    }

    func refreshDevices() {
        let allDevices = AudioDevice.getDevices()
        inputDevices = allDevices.filter { $0.isInput && !$0.isBlackHole }
        isBlackHoleInstalled = allDevices.contains { $0.isBlackHole }

        if selectedDevice == nil || !inputDevices.contains(where: { $0.id == selectedDevice?.id }) {
            selectedDevice = inputDevices.first
        }
    }

    func checkBlackHoleStatus() {
        let devices = AudioDevice.getDevices()
        isBlackHoleInstalled = devices.contains { $0.isBlackHole }
    }

    func installBlackHole() {
        if let pkgPath = Bundle.main.path(forResource: "BlackHole-2ch", ofType: "pkg") {
            let url = URL(fileURLWithPath: pkgPath)
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://existential.audio/blackhole/") {
            NSWorkspace.shared.open(url)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkBlackHoleStatus()
        }
    }

    private func startProcessing() {
        lastError = nil
        guard let inputDevice = selectedDevice else {
            fail(.noInputDevice); return
        }
        guard let outputDevice = AudioDevice.getDevices().first(where: { $0.isBlackHole && $0.isOutput }) else {
            fail(.outputDeviceMissing); return
        }
        Task {
            do {
                try await controller.start(input: inputDevice, output: outputDevice)
                startLevelTimer()
            } catch is CancellationError {
                // superseded by a newer start or by stop
            } catch {
                fail((error as? AudioStartError) ?? .engineStartFailed(-1))
            }
        }
    }

    private func fail(_ error: AudioStartError) {
        lastError = error
        isEnabled = false
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.inputLevel = self.controller.inputLevel
            }
        }
    }

    private func stopProcessing() {
        controller.stop()
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
    }

    private func saveSelectedDevice() {
        if let uid = selectedDevice?.uid {
            UserDefaults.standard.set(uid, forKey: "selectedDeviceUID")
        }
    }

    private func restoreSelectedDevice() {
        guard let savedUID = UserDefaults.standard.string(forKey: "selectedDeviceUID") else { return }
        selectedDevice = inputDevices.first { $0.uid == savedUID }
    }

    private func restoreAttenuation() {
        let saved = UserDefaults.standard.float(forKey: "attenuation")
        if saved > 0 {
            attenuation = saved
        }
    }

    private func restoreLaunchAtLogin() {
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // SMAppService requires code signing — silently ignore for unsigned builds
                if launchAtLogin {
                    launchAtLogin = false
                }
            }
        }
    }

    func shutdown() {
        stopProcessing()
        deviceMonitor?.stopMonitoring()
    }
}
