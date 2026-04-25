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

    private let frameSize = 480
    private let inputRingBuffer: RingBuffer
    private let outputRingBuffer: RingBuffer
    private var processingThread: Thread?
    private var isRunning = false
    private let processingLock = NSCondition()

    init(inputDevice: AudioDevice, outputDevice: AudioDevice) throws {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice

        // Ring buffers: ~100ms capacity (4800 samples at 48kHz)
        self.inputRingBuffer = RingBuffer(capacity: 4800)
        self.outputRingBuffer = RingBuffer(capacity: 4800)

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
        isRunning = true
        inputRingBuffer.reset()
        outputRingBuffer.reset()

        startProcessingThread()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { [weak self] buffer, time in
            self?.handleAudioBuffer(buffer)
        }

        try engine.start()
        playerNode.play()
    }

    func stop() {
        isRunning = false

        processingLock.lock()
        processingLock.signal()
        processingLock.unlock()

        processingThread = nil

        playerNode.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        ncProcessor?.shutdown()
    }

    func setAttenuation(_ value: Float) {
        ncProcessor?.setAttenuation(value)
    }

    private func startProcessingThread() {
        processingThread = Thread { [weak self] in
            self?.processingLoop()
        }
        processingThread?.name = "SottoNCProcessing"
        processingThread?.qualityOfService = .userInteractive
        processingThread?.start()
    }

    private func processingLoop() {
        var processBuffer = [Float](repeating: 0, count: frameSize)

        while isRunning {
            processingLock.lock()

            while isRunning && inputRingBuffer.availableToRead < frameSize {
                processingLock.wait()
            }

            guard isRunning else {
                processingLock.unlock()
                break
            }

            processingLock.unlock()

            processBuffer.withUnsafeMutableBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }

                if inputRingBuffer.read(base, count: frameSize) {
                    ncProcessor?.process(buffer: base, frameCount: frameSize)
                    _ = outputRingBuffer.write(base, count: frameSize)
                }
            }
        }
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let inputData = channelData[0]

        let level = calculateRMSLevel(inputData, frameCount: frameCount)
        onLevelUpdate?(level)

        // Write to input ring buffer for processing thread
        if inputRingBuffer.write(inputData, count: frameCount) {
            processingLock.lock()
            processingLock.signal()
            processingLock.unlock()
        }

        // Read processed audio from output ring buffer
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        outputBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let outputData = outputBuffer.floatChannelData?[0] else { return }

        if outputRingBuffer.read(outputData, count: frameCount) {
            playerNode.scheduleBuffer(outputBuffer, completionHandler: nil)
        } else {
            // Not enough processed audio yet, output silence or passthrough
            memcpy(outputData, inputData, frameCount * MemoryLayout<Float>.size)
            playerNode.scheduleBuffer(outputBuffer, completionHandler: nil)
        }
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
