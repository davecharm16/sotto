import AVFoundation
import Foundation
import os

/// Device-free NC pipeline: ring A -> (SRC to 48 kHz) -> 480-frame chunks -> `NCProcessor` -> drift stage -> ring B.
///
/// Threads:
/// - capture side (real-time, e.g. an `AVAudioSinkNode` block) calls `push*`: no allocation, locks or ARC after init.
/// - `SottoNCProcessing` (a dedicated `Thread`) owns the converter, the `NCProcessor` calls and ring B's producer end.
/// - render side (real-time, e.g. an `AVAudioSourceNode` block) calls `pull`: it never blocks and never gets raw
///   audio; a shortfall is silence and is counted in `stats.ringBUnderrunSamples`.
///
/// Lifetime: `start()` creates the model on the NC thread (df_create takes ~170 ms), `stop()` joins that thread and
/// only then runs `df_destroy`. One start per instance; build a new core after a device or format change.
final class PipelineCore {
    struct Config {
        var modelPath: String
        var inputSampleRate: Double
        var attenuation: Float = 1.0
        /// true: ring B is kept near 30 ms by slipping samples (live). false: lossless offline mode where the NC
        /// thread waits for room in ring B instead (tests, file processing).
        var driftControl = true
    }

    struct Stats {
        var ringAOverrunFrames = 0
        var ringBOverrunSamples = 0
        var ringBUnderrunSamples = 0
        var chunksProcessed = 0
        var framesIn = 0
        var framesIngested = 0
        var slipInserted = 0
        var slipDropped = 0
        var skippedChunks = 0
        var ringBFill = 0
        var ringBFillPostWrite = 0
    }

    static let chunk = DriftControlledWriter.Policy.chunk   // the NC frame contract: 480 mono Float32 @ 48 kHz
    static let outputRate = 48_000.0
    private static let maxFramesPerRead = 4096
    private static let downmixSegment = 1024
    private static let signposter = OSSignposter(subsystem: "com.sotto.app", category: "NC")

    private let config: Config
    let ringA: SPSCFloatRing
    let ringB: SPSCFloatRing
    private let writer: DriftControlledWriter

    /// The NC thread polls ring A at this period instead of being signalled: a semaphore signal is not guaranteed
    /// real-time safe on the capture thread, and ring A holds ~1.4 s so 2 ms of polling latency is harmless.
    private static let pollMicroseconds: useconds_t = 2_000
    private let lifecycle = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private let stopFlag = SingleWriterCounter()
    private let framesIn = SingleWriterCounter()
    private let chunksProcessed = SingleWriterCounter()
    private let framesIngested = SingleWriterCounter()
    /// Set by the NC thread: proof that df_create ran off the main thread.
    private(set) var modelCreatedOffMainThread: Bool?
    private var thread: Thread?
    private var nc: NCProcessor?
    private var stopped = false

    // NC-thread state (allocated once in init).
    private let converter: AVAudioConverter?
    private let convIn: AVAudioPCMBuffer?
    private let convOut: AVAudioPCMBuffer?
    private let readBuf: UnsafeMutablePointer<Float>
    private let acc: UnsafeMutablePointer<Float>
    private var accCount = 0

    // Capture-side scratch for downmixing (producer thread only).
    private let mixScratch: UnsafeMutablePointer<Float>

    init(config: Config) throws {
        self.config = config
        ringA = SPSCFloatRing(minimumCapacity: 1 << 17)
        ringB = SPSCFloatRing(minimumCapacity: 1 << 13)
        writer = DriftControlledWriter(ring: ringB)
        readBuf = .allocate(capacity: Self.maxFramesPerRead)
        readBuf.initialize(repeating: 0, count: Self.maxFramesPerRead)
        mixScratch = .allocate(capacity: Self.downmixSegment)
        mixScratch.initialize(repeating: 0, count: Self.downmixSegment)

        var maxOut = Self.maxFramesPerRead
        if config.inputSampleRate == Self.outputRate {
            converter = nil; convIn = nil; convOut = nil
        } else {
            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: config.inputSampleRate, channels: 1, interleaved: false),
                  let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
                throw PipelineError.unsupportedInputFormat(sampleRate: config.inputSampleRate)
            }
            conv.primeMethod = .none
            maxOut = Int((Double(Self.maxFramesPerRead) * Self.outputRate / config.inputSampleRate).rounded(.up)) + 64
            converter = conv
            convIn = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(Self.maxFramesPerRead))
            convOut = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(maxOut))
        }
        acc = .allocate(capacity: Self.chunk + maxOut)
        acc.initialize(repeating: 0, count: Self.chunk + maxOut)
    }

    deinit {
        stop()
        readBuf.deallocate(); acc.deallocate(); mixScratch.deallocate()
    }

    // MARK: lifecycle (main actor / any non-real-time thread)

    /// Spawns `SottoNCProcessing` and returns once the model is loaded. Throws if the model cannot be created.
    func start() async throws {
        let t = Thread { [self] in run() }
        t.name = "SottoNCProcessing"
        t.qualityOfService = .userInteractive
        lifecycle.lock()
        let allowed = thread == nil && !stopped
        lifecycle.unlock()
        guard allowed else { throw PipelineError.notStartable }
        if config.driftControl { writer.prime() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // `thread` is published in the same critical section that starts it, so stop() only ever joins a thread
            // that is running (or was never started and is a no-op).
            lifecycle.lock()
            if thread != nil || stopped {
                lifecycle.unlock()
                c.resume(throwing: PipelineError.notStartable)
                return
            }
            startResult = c
            thread = t
            t.start()
            lifecycle.unlock()
        }
    }

    /// Stops and joins the NC thread, then destroys the model. Idempotent.
    func stop() {
        lifecycle.lock()
        let wasStopped = stopped
        stopped = true
        let started = thread != nil
        lifecycle.unlock()
        guard !wasStopped, started else { return }
        stopFlag.set(1)
        done.wait()
        nc?.shutdown()       // df_destroy strictly after the df_process thread is gone
        nc = nil
    }

    func setAttenuation(_ value: Float) { nc?.setAttenuation(value) }

    var stats: Stats {
        Stats(ringAOverrunFrames: ringA.overrunSamples,
              ringBOverrunSamples: ringB.overrunSamples,
              ringBUnderrunSamples: ringB.underrunSamples,
              chunksProcessed: chunksProcessed.value,
              framesIn: framesIn.value,
              framesIngested: framesIngested.value,
              slipInserted: writer.insertedSamples.value,
              slipDropped: writer.droppedSamples.value,
              skippedChunks: writer.skippedChunks.value,
              ringBFill: ringB.availableToRead,
              ringBFillPostWrite: writer.lastPostWriteFill.value)
    }

    // MARK: capture side (real-time safe)

    /// Free room in ring A in input frames (for back-pressure in offline callers).
    var inputFramesFree: Int { ringA.availableToWrite }

    /// Mono samples at `inputSampleRate`.
    func push(mono: UnsafePointer<Float>, frames: Int) {
        let n = ringA.write(mono, count: frames)
        framesIn.add(n)
    }

    /// One pointer per channel (the AudioBufferList layout of a non-interleaved sink node). Channels are averaged.
    func push(planar channels: UnsafePointer<UnsafePointer<Float>>, channelCount: Int, frames: Int) {
        if channelCount == 1 { return push(mono: channels[0], frames: frames) }
        let inv = 1 / Float(channelCount)
        var done = 0
        while done < frames {
            let n = min(Self.downmixSegment, frames - done)
            for i in 0..<n { mixScratch[i] = channels[0][done + i] }
            for c in 1..<channelCount {
                let p = channels[c] + done
                for i in 0..<n { mixScratch[i] += p[i] }
            }
            for i in 0..<n { mixScratch[i] *= inv }
            framesIn.add(ringA.write(mixScratch, count: n))
            done += n
        }
    }

    /// Interleaved frames (an interleaved AudioBufferList). Channels are averaged.
    func push(interleaved data: UnsafePointer<Float>, channelCount: Int, frames: Int) {
        if channelCount == 1 { return push(mono: data, frames: frames) }
        let inv = 1 / Float(channelCount)
        var done = 0
        while done < frames {
            let n = min(Self.downmixSegment, frames - done)
            for i in 0..<n {
                var s: Float = 0
                let base = (done + i) * channelCount
                for c in 0..<channelCount { s += data[base + c] }
                mixScratch[i] = s * inv
            }
            framesIn.add(ringA.write(mixScratch, count: n))
            done += n
        }
    }

    // MARK: render side (real-time safe)

    /// Fills `out` with `frames` 48 kHz mono samples: processed audio, then silence on underrun (counted).
    /// Returns the number of real samples delivered.
    @discardableResult
    func pull(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        ringB.readPaddingSilence(out, count: frames)
    }

    // MARK: NC thread

    private var startResult: CheckedContinuation<Void, Error>?

    private func run() {
        defer { done.signal() }
        do {
            modelCreatedOffMainThread = !Thread.isMainThread
            let model = try NCProcessor(modelPath: config.modelPath)
            model.setAttenuation(config.attenuation)
            nc = model
            startResult?.resume()
        } catch {
            startResult?.resume(throwing: error)
            return
        }
        startResult = nil
        while stopFlag.value == 0 {
            drain()
            usleep(Self.pollMicroseconds)
        }
    }

    private func drain() {
        while stopFlag.value == 0 {
            let n = min(ringA.availableToRead, Self.maxFramesPerRead)
            if n == 0 { return }
            ringA.read(readBuf, count: n)
            ingest(frames: n)
            framesIngested.add(n)
        }
    }

    /// Converts `frames` samples from `readBuf` to 48 kHz, appends them to the accumulator and runs full chunks.
    private func ingest(frames: Int) {
        if let converter, let convIn, let convOut {
            convIn.floatChannelData![0].update(from: readBuf, count: frames)
            convIn.frameLength = AVAudioFrameCount(frames)
            convOut.frameLength = 0
            var supplied = false
            var error: NSError?
            converter.convert(to: convOut, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return convIn
            }
            let produced = Int(convOut.frameLength)
            (acc + accCount).update(from: convOut.floatChannelData![0], count: produced)
            accCount += produced
        } else {
            (acc + accCount).update(from: readBuf, count: frames)
            accCount += frames
        }
        guard let nc else { return }
        var pos = 0
        while accCount - pos >= Self.chunk, stopFlag.value == 0 {
            if !config.driftControl {
                // Lossless mode: wait for the (test) consumer to make room instead of dropping.
                while ringB.availableToWrite < Self.chunk, stopFlag.value == 0 { usleep(200) }
                if stopFlag.value != 0 { break }
            }
            let frame = acc + pos
            let state = Self.signposter.beginInterval("NCProcessor.process")
            nc.process(buffer: frame, frameCount: Self.chunk)
            Self.signposter.endInterval("NCProcessor.process", state)
            if config.driftControl { writer.push(frame) } else { ringB.write(frame, count: Self.chunk) }
            chunksProcessed.add(1)
            pos += Self.chunk
        }
        if pos > 0 {
            accCount -= pos
            acc.update(from: acc + pos, count: accCount)   // overlapping move, forward-safe
        }
    }
}

enum PipelineError: Error {
    case unsupportedInputFormat(sampleRate: Double)
    /// start() twice, or after stop().
    case notStartable
}
