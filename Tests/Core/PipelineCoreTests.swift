import XCTest

final class PipelineCoreTests: XCTestCase {
    private var modelPath: String {
        // The unhosted bundle carries no app resources, so load the model from the repo checkout.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sotto/Resources/DeepFilterNet3").path
    }

    private func makeCore(rate: Double, attenuation: Float, driftControl: Bool = false) throws -> PipelineCore {
        try PipelineCore(config: .init(modelPath: modelPath, inputSampleRate: rate,
                                       attenuation: attenuation, driftControl: driftControl))
    }

    /// Offline driver: feeds `channels` (all the same length) in random chunk sizes 1...8192 using the planar
    /// capture path, drains ring B as it goes, and returns everything the render side would have received.
    private func run(_ core: PipelineCore, channels: [[Float]], seed: UInt64 = 1) async throws -> [Float] {
        try await core.start()
        defer { core.stop() }
        var rng = SeededRNG(seed)
        let total = channels[0].count
        var out = [Float]()
        var tmp = [Float](repeating: 0, count: 16384)
        func drain() {
            let n = min(core.ringB.availableToRead, tmp.count)
            if n > 0 { core.pull(into: &tmp, frames: n); out += tmp[0..<n] }
        }
        var sent = 0
        while sent < total {
            let n = min(Int.random(in: 1...8192, using: &rng), total - sent)
            while core.inputFramesFree < n { drain(); usleep(500) }
            channels.map { $0.withUnsafeBufferPointer { $0.baseAddress! + sent } }.withUnsafeBufferPointer { ptrs in
                core.push(planar: ptrs.baseAddress!, channelCount: channels.count, frames: n)
            }
            sent += n
            drain()
        }
        let deadline = Date().addingTimeInterval(20)
        while core.stats.framesIngested < total, Date() < deadline { drain(); usleep(500) }
        usleep(20_000); drain()
        return out
    }

    // MARK: format / chunking / ordering

    func testNoLossOrFallbackAcrossFormatsAndChunkSizes() async throws {
        // (rate, channels): hardware-like formats, bypass mode so the output must be the input delayed and resampled.
        for (rate, channels) in [(44_100.0, 2), (16_000.0, 1), (48_000.0, 1), (96_000.0, 2)] {
            let core = try makeCore(rate: rate, attenuation: 0)
            let frames = Int(rate * 5)
            let tone = TestSignals.sine(frames: frames, rate: rate, hz: 1000, amplitude: 0.3)
            let out = try await run(core, channels: Array(repeating: tone, count: channels))
            let s = core.stats

            XCTAssertEqual(s.framesIn, frames, "\(rate)/\(channels)ch: every pushed frame reached ring A")
            XCTAssertEqual(s.framesIngested, frames)
            XCTAssertEqual(s.ringAOverrunFrames, 0)
            XCTAssertEqual(s.ringBOverrunSamples, 0)
            XCTAssertEqual(s.ringBUnderrunSamples, 0, "pull is only called with available data here")
            XCTAssertEqual(out.count % PipelineCore.chunk, 0, "output arrives in whole 480-frame chunks")
            XCTAssertEqual(out.count, s.chunksProcessed * PipelineCore.chunk)

            let expected = Int(Double(frames) * 48_000 / rate)
            XCTAssertLessThanOrEqual(out.count, expected)
            XCTAssertGreaterThanOrEqual(out.count, expected - PipelineCore.chunk - 160, "\(rate): lost samples")

            // Content: a clean 1 kHz tone of the right level (L=R downmix keeps amplitude), no raw fallback, no clicks.
            let body = out[4800...]
            let fit = TestSignals.sineFit(body, rate: 48_000, hz: 1000)
            let d2 = TestSignals.maxSecondDifference(body)
            print("pipeline \(Int(rate)) Hz x\(channels): out \(out.count) of ~\(expected), amplitude \(String(format: "%.4f", fit.amplitude)), residual \(String(format: "%.1f", fit.residualDB)) dB, max|d2| \(d2)")
            XCTAssertEqual(fit.amplitude, 0.3, accuracy: 0.3 * 0.03)
            XCTAssertLessThan(fit.residualDB, -40)
            XCTAssertLessThan(d2, 0.3 * 0.1309 * 0.1309 * 1.5, "no discontinuity beyond the tone's own curvature")
        }
    }

    func testStereoWithSilentRightChannelIsAveraged() async throws {
        let core = try makeCore(rate: 44_100, attenuation: 0)
        let tone = TestSignals.sine(frames: 44_100 * 2, rate: 44_100, hz: 1000, amplitude: 0.4)
        let out = try await run(core, channels: [tone, [Float](repeating: 0, count: tone.count)])
        let fit = TestSignals.sineFit(out[4800...], rate: 48_000, hz: 1000)
        XCTAssertEqual(fit.amplitude, 0.2, accuracy: 0.006, "downmix is the channel average")
    }

    func testInterleavedPushMatchesPlanar() async throws {
        let core = try makeCore(rate: 48_000, attenuation: 0)
        try await core.start()
        defer { core.stop() }
        let tone = TestSignals.sine(frames: 4800, rate: 48_000, hz: 1000, amplitude: 0.3)
        let inter = tone.flatMap { [$0, $0 * 0.5, -$0] }          // 3 channels, mean = $0 / 6 ... checked below
        inter.withUnsafeBufferPointer { core.push(interleaved: $0.baseAddress!, channelCount: 3, frames: 4800) }
        var out = [Float](), tmp = [Float](repeating: 0, count: 4800)
        let deadline = Date().addingTimeInterval(10)
        while out.count < 4800, Date() < deadline {
            let n = min(core.ringB.availableToRead, 4800 - out.count)
            if n > 0 { core.pull(into: &tmp, frames: n); out += tmp[0..<n] }
            usleep(500)
        }
        XCTAssertEqual(out.count, 4800)
        let fit = TestSignals.sineFit(out[1920...], rate: 48_000, hz: 1000)
        XCTAssertEqual(fit.amplitude, 0.3 * 0.5 / 3, accuracy: 0.003)
    }

    // MARK: NC effect

    func testNoiseIsAttenuatedByAtLeast15dB() async throws {
        for (rate, channels) in [(44_100.0, 2), (48_000.0, 1)] {
            let core = try makeCore(rate: rate, attenuation: 1.0)
            let noise = TestSignals.scaled(TestSignals.pink(Int(rate * 4), seed: 0x5eed), toDBFS: -30)
            let out = try await run(core, channels: Array(repeating: noise, count: channels))
            // Skip the first second (model warm-up and converter start) on both sides.
            let pIn = TestSignals.meanSquare(noise[Int(rate)...])
            let pOut = TestSignals.meanSquare(out[48_000...])
            let change = TestSignals.db(pOut) - TestSignals.db(pIn)
            print("NC effect \(Int(rate)) Hz x\(channels): in \(String(format: "%.1f", TestSignals.db(pIn))) dBFS, out \(String(format: "%.1f", TestSignals.db(pOut))) dBFS, change \(String(format: "%+.1f", change)) dB")
            XCTAssertLessThanOrEqual(change, -15)
        }
    }

    // MARK: lifecycle

    func testModelIsCreatedOffMainThreadAndStopJoinsBeforeDestroy() async throws {
        for _ in 0..<3 {
            let core = try makeCore(rate: 16_000, attenuation: 1)
            try await core.start()
            XCTAssertEqual(core.modelCreatedOffMainThread, true, "df_create must not run on the main thread")
            let tone = TestSignals.sine(frames: 16_000, rate: 16_000, hz: 300, amplitude: 0.2)
            tone.withUnsafeBufferPointer { core.push(mono: $0.baseAddress!, frames: $0.count) }
            core.stop()      // joins SottoNCProcessing, then df_destroy; must not crash with audio in flight
            core.stop()      // idempotent
        }
    }

    func testStartFailsForMissingModel() async throws {
        let core = try PipelineCore(config: .init(modelPath: "/nonexistent/model.tar.gz", inputSampleRate: 48_000))
        do {
            try await core.start()
            XCTFail("expected modelLoadFailed")
        } catch {
            XCTAssertTrue(error is NCProcessorError)
        }
        core.stop()
    }

    /// stop() racing start() must neither hang nor crash; start() after stop() is refused.
    func testStopRacingStartNeverHangs() async throws {
        for i in 0..<10 {
            let core = try makeCore(rate: 48_000, attenuation: 1)
            let stopper = Task.detached { usleep(UInt32(i * 20_000)); core.stop() }
            do { try await core.start() } catch { XCTAssertTrue(error is PipelineError, "\(error)") }
            await stopper.value
            core.stop()
        }
        let core = try makeCore(rate: 48_000, attenuation: 1)
        core.stop()
        do { try await core.start(); XCTFail("start after stop must fail") } catch { XCTAssertTrue(error is PipelineError) }
    }

    func testStopBeforeStartIsHarmless() throws {
        let core = try makeCore(rate: 48_000, attenuation: 1)
        core.stop()
    }

    /// Live mode wiring (drift control on, primed ring B) paced roughly in real time.
    func testLiveModeKeepsRingBPrimedAndBounded() async throws {
        let core = try makeCore(rate: 48_000, attenuation: 1, driftControl: true)
        try await core.start()
        defer { core.stop() }
        let tone = TestSignals.sine(frames: 480, rate: 48_000, hz: 440, amplitude: 0.1)
        var out = [Float](repeating: 0, count: 512)
        var nextProducer = Date(), nextConsumer = Date().addingTimeInterval(0.02)
        let end = Date().addingTimeInterval(2.0)
        var minFill = Int.max
        while Date() < end {
            let now = Date()
            if now >= nextProducer {
                tone.withUnsafeBufferPointer { core.push(mono: $0.baseAddress!, frames: 480) }
                nextProducer += 0.01
            }
            if now >= nextConsumer {
                core.pull(into: &out, frames: 512)
                if now.timeIntervalSince(end.addingTimeInterval(-1.5)) > 0 { minFill = min(minFill, core.stats.ringBFill) }
                nextConsumer += 512.0 / 48_000
            }
            usleep(200)
        }
        let s = core.stats
        print("live: fill now \(s.ringBFill), min \(minFill), inserted \(s.slipInserted) dropped \(s.slipDropped) skipped \(s.skippedChunks) underrun \(s.ringBUnderrunSamples)")
        XCTAssertEqual(s.ringAOverrunFrames, 0)
        XCTAssertEqual(s.ringBOverrunSamples, 0)
        XCTAssertEqual(s.skippedChunks, 0)
        // ponytail: wall-clock smoke test; +/-1 chunk slack for scheduler jitter. The strict 960–1920 band is asserted
        // deterministically in DriftControlTests.
        XCTAssertLessThanOrEqual(s.ringBFillPostWrite, 1920 + 480)
        XCTAssertGreaterThanOrEqual(s.ringBFillPostWrite, 960 - 480)
    }
}

/// SplitMix64: reproducible chunk-size sequences.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
