import Foundation
import Combine
import AVFoundation
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
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedDevice: AudioDevice? {
        didSet {
            if selectedDevice != oldValue {
                saveSelectedDevice()
            }
        }
    }
    @Published var isBlackHoleInstalled: Bool = false
    @Published var attenuation: Float = 1.0 {
        didSet {
            audioEngine?.setAttenuation(isBypassed ? 0 : attenuation)
            UserDefaults.standard.set(attenuation, forKey: "attenuation")
        }
    }
    @Published var isBypassed: Bool = false {
        didSet {
            audioEngine?.setAttenuation(isBypassed ? 0 : attenuation)
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            setLaunchAtLogin(launchAtLogin)
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }

    private var audioEngine: AudioEngine?
    private var deviceMonitor: DeviceMonitor?
    private var cancellables = Set<AnyCancellable>()

    init() {
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
        guard let inputDevice = selectedDevice else {
            print("No input device selected")
            return
        }

        let blackHoleDevice = AudioDevice.getDevices().first { $0.isBlackHole && $0.isOutput }
        guard let outputDevice = blackHoleDevice else {
            print("BlackHole output device not found")
            return
        }

        do {
            audioEngine = try AudioEngine(inputDevice: inputDevice, outputDevice: outputDevice)
            audioEngine?.onLevelUpdate = { [weak self] level in
                Task { @MainActor in
                    self?.inputLevel = level
                }
            }
            try audioEngine?.start()
        } catch {
            print("Failed to start audio engine: \(error)")
            isEnabled = false
        }
    }

    private func stopProcessing() {
        audioEngine?.stop()
        audioEngine = nil
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
                print("Failed to set launch at login: \(error)")
            }
        }
    }

    func shutdown() {
        stopProcessing()
        deviceMonitor?.stopMonitoring()
    }
}
