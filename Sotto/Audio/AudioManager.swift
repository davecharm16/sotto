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
            UserDefaults.standard.set(attenuation, forKey: SettingsStore.attenuationKey)
        }
    }
    @Published var isBypassed: Bool = false {
        didSet {
            controller.setAttenuation(isBypassed ? 0 : attenuation)
        }
    }
    /// Mirrors `SMAppService.mainApp.status`, which is the source of truth (nothing is stored in UserDefaults).
    @Published var launchAtLogin: Bool = false {
        didSet { if launchAtLogin != oldValue { setLaunchAtLogin(launchAtLogin) } }
    }
    @Published private(set) var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

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
        if error == .noMicPermission { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
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
        if let saved = SettingsStore.savedAttenuation() { attenuation = saved }
    }

    private func restoreLaunchAtLogin() {
        launchAtLogin = Self.isRequested(SMAppService.mainApp.status)
    }

    /// `.requiresApproval` means registered and waiting on the user, so the toggle stays on and we don't re-register.
    private static func isRequested(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Only talks to SMAppService when the request differs from its status, so restoring never re-registers.
    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != Self.isRequested(service.status) else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("Sotto: launch at login change failed: \(error)")
        }
        if enabled && service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = Self.isRequested(service.status)   // show what actually happened
    }

    /// Triggers the system prompt when undetermined (onboarding); a denied status can only be changed in Settings.
    func requestMicrophoneAccess() {
        Task {
            _ = await PipelineController.systemMicAccess()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    func shutdown() {
        stopProcessing()
        deviceMonitor?.stopMonitoring()
    }
}
