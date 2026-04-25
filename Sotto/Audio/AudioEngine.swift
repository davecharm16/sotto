import AVFoundation
import CoreAudio
import Accelerate

class AudioEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let ncProcessor: NCProcessor?

    private let inputDevice: AudioDevice
    private let outputDevice: AudioDevice

    var onLevelUpdate: ((Float) -> Void)?

    private let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 1,
        interleaved: false
    )!

    init(inputDevice: AudioDevice, outputDevice: AudioDevice) throws {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice

        if let configPath = Bundle.main.path(forResource: "config", ofType: "ini", inDirectory: "DeepFilterNet3") {
            let modelDir = (configPath as NSString).deletingLastPathComponent
            self.ncProcessor = try? NCProcessor(modelPath: modelDir)
        } else {
            self.ncProcessor = nil
            print("Warning: DeepFilterNet model not found, running in passthrough mode")
        }

        try configureAudioSession()
        setupAudioGraph()
    }

    private func configureAudioSession() throws {
        try setInputDevice(inputDevice.id)
        try setOutputDevice(outputDevice.id)
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        var deviceID = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )

        if status != noErr {
            throw AudioEngineError.deviceConfigurationFailed
        }
    }

    private func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        var deviceID = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )

        if status != noErr {
            throw AudioEngineError.deviceConfigurationFailed
        }
    }

    private func setupAudioGraph() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: processingFormat)
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { [weak self] buffer, time in
            self?.processBuffer(buffer)
        }

        try engine.start()
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func setAttenuation(_ value: Float) {
        ncProcessor?.setAttenuation(value)
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let inputData = channelData[0]

        let level = calculateRMSLevel(inputData, frameCount: frameCount)
        onLevelUpdate?(level)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        outputBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let outputData = outputBuffer.floatChannelData?[0] else { return }

        memcpy(outputData, inputData, frameCount * MemoryLayout<Float>.size)

        ncProcessor?.process(buffer: outputData, frameCount: frameCount)

        playerNode.scheduleBuffer(outputBuffer, completionHandler: nil)
    }

    private func calculateRMSLevel(_ data: UnsafeMutablePointer<Float>, frameCount: Int) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(frameCount))
        let db = 20 * log10(max(rms, 0.0001))
        let normalized = (db + 60) / 60
        return max(0, min(1, normalized))
    }
}

enum AudioEngineError: Error {
    case deviceConfigurationFailed
    case engineStartFailed
}
