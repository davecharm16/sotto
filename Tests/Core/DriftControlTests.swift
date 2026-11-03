import XCTest

/// Offline, virtual-time simulation of ring B: the producer pushes 480-sample chunks of a 440 Hz sine on the nominal
/// 48 kHz clock, the consumer pulls `block` samples per callback on a clock that is `ppm` fast (+) or slow (-).
final class DriftControlTests: XCTestCase {
    private typealias Policy = DriftControlledWriter.Policy

    private struct Disturbance { var consumerStart = 0.0; var stalls: [(at: Double, duration: Double)] = [] }

    private struct Result {
        var minFill = Int.max, maxFill = 0          // post-write fill after the settle window
        var worstD2: Float = 0
        var underrunAfterSettle = 0, overrun = 0
        var inserted = 0, dropped = 0, skipped = 0
    }

    private func simulate(ppm: Double, seconds: Double, block: Int = 512, prime: Bool = true,
                          disturbance: Disturbance = Disturbance(), settle: Double = 4.0) -> Result {
        let ring = SPSCFloatRing(minimumCapacity: 8192)
        let writer = DriftControlledWriter(ring: ring)
        if prime { writer.prime() }

        let chunkDt = Double(Policy.chunk) / 48_000
        let consumerRate = 48_000 * (1 + ppm * 1e-6)
        var tProducer = 0.0, tConsumer = disturbance.consumerStart
        var phase = 0.0
        let dphi = 2 * Double.pi * 440 / 48_000
        var chunk = [Float](repeating: 0, count: Policy.chunk)
        var out = [Float](repeating: 0, count: block)
        var tail: (Float, Float) = (0, 0)           // last two consumed samples, for the running second difference
        var r = Result()
        let lastDisturbance = max(disturbance.consumerStart, disturbance.stalls.map { $0.at + $0.duration }.max() ?? 0)
        let settledAt = lastDisturbance + settle
        var underrunAtSettle: Int?
        var consumed = 0

        while tProducer < seconds {
            if tProducer <= tConsumer {
                for i in 0..<Policy.chunk { chunk[i] = 0.5 * Float(sin(phase)); phase += dphi }
                if phase > 2 * Double.pi * 1000 { phase -= 2 * Double.pi * 1000 }   // 1000 whole cycles, keeps precision
                chunk.withUnsafeBufferPointer { writer.push($0.baseAddress!) }
                if tProducer >= settledAt {
                    let fill = writer.lastPostWriteFill.value
                    r.minFill = min(r.minFill, fill); r.maxFill = max(r.maxFill, fill)
                }
                tProducer += chunkDt
            } else {
                if let s = disturbance.stalls.first(where: { tConsumer >= $0.at && tConsumer < $0.at + $0.duration }) {
                    tConsumer = s.at + s.duration
                    continue
                }
                if tConsumer >= settledAt && underrunAtSettle == nil { underrunAtSettle = ring.underrunSamples }
                _ = out.withUnsafeMutableBufferPointer { ring.readPaddingSilence($0.baseAddress!, count: block) }
                for v in out {
                    if tConsumer >= settledAt && consumed >= 2 {
                        r.worstD2 = max(r.worstD2, abs(v - 2 * tail.1 + tail.0))
                    }
                    tail = (tail.1, v); consumed += 1
                }
                tConsumer += Double(block) / consumerRate
            }
        }
        r.underrunAfterSettle = ring.underrunSamples - (underrunAtSettle ?? 0)
        r.overrun = ring.overrunSamples
        r.inserted = writer.insertedSamples.value; r.dropped = writer.droppedSamples.value
        r.skipped = writer.skippedChunks.value
        return r
    }

    private func dbfs(_ v: Float) -> Double { 20 * log10(Double(max(v, 1e-9))) }

    private func assertHealthy(_ r: Result, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        print("drift[\(label)] fill \(r.minFill)...\(r.maxFill)  max|d2| \(String(format: "%.1f", dbfs(r.worstD2))) dBFS  inserted \(r.inserted) dropped \(r.dropped) skipped \(r.skipped) underrun(after settle) \(r.underrunAfterSettle) overrun \(r.overrun)")
        XCTAssertGreaterThanOrEqual(r.minFill, 960, "\(label): fill left the band (low)", file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxFill, 1920, "\(label): fill left the band (high)", file: file, line: line)
        XCTAssertEqual(r.underrunAfterSettle, 0, "\(label)", file: file, line: line)
        XCTAssertEqual(r.overrun, 0, "\(label)", file: file, line: line)
        XCTAssertLessThan(dbfs(r.worstD2), -40, "\(label): discontinuity above -40 dBFS", file: file, line: line)
    }

    func testNoSkewStaysQuiet() {
        let r = simulate(ppm: 0, seconds: 120)
        assertHealthy(r, "0 ppm")
        XCTAssertLessThan(r.inserted + r.dropped, 400, "no skew: only the one-off settle onto the target, no running correction")
    }

    func testConsumerClockFast50ppm() {
        let r = simulate(ppm: +50, seconds: 400)
        assertHealthy(r, "+50 ppm")
        // 50 ppm over 400 s is ~960 samples; the controller must have absorbed it by inserting.
        XCTAssertGreaterThan(r.inserted - r.dropped, 600)
        XCTAssertLessThan(r.inserted - r.dropped, 1500)
    }

    func testConsumerClockSlow50ppm() {
        let r = simulate(ppm: -50, seconds: 400)
        assertHealthy(r, "-50 ppm")
        XCTAssertGreaterThan(r.dropped - r.inserted, 400)
        XCTAssertLessThan(r.dropped - r.inserted, 1500)
    }

    func testStartupTransientConsumerStartsLateThenStalls() {
        // Consumer starts 150 ms late (ring B would overfill), then stalls 100 ms at t = 20 s, with 50 ppm skew.
        // The gross-error resync may glitch once per event; after it settles, the band and -40 dB hold again.
        let d = Disturbance(consumerStart: 0.150, stalls: [(at: 20, duration: 0.100)])
        let r = simulate(ppm: +50, seconds: 120, disturbance: d)
        assertHealthy(r, "late start + stall, +50 ppm")
        XCTAssertGreaterThan(r.skipped, 0, "the overfill must have been resynced by skipping chunks, not overrun")
    }

    func testStartupWithoutPrimingRecoversWithBoundedSlip() {
        // No priming: ring B starts at 0. The consumer underruns while the controller inserts at <= maxSlip/chunk.
        let r = simulate(ppm: 0, seconds: 60, prime: false, settle: 10)
        assertHealthy(r, "unprimed start")
        XCTAssertLessThanOrEqual(Double(r.inserted), 60.0 / 0.01 * Double(Policy.maxSlip))
    }

    func testSlipShapesAreContinuousAndBounded() {
        // Every slip size, both directions: output length, aligned endpoints, no step at the chunk join.
        let x = TestSignals.sine(frames: Policy.chunk * 2, rate: 48_000, hz: 440, amplitude: 0.5)
        var out = [Float](repeating: 0, count: Policy.chunk + Policy.maxSlip)
        for slip in -Policy.maxSlip...Policy.maxSlip {
            let n = x.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { DriftControlledWriter.apply(slip: slip, to: src.baseAddress!, into: $0.baseAddress!) }
            }
            XCTAssertEqual(n, Policy.chunk + slip)
            XCTAssertEqual(out[0], x[0], accuracy: 1e-6)
            XCTAssertEqual(out[n - 1], x[Policy.chunk - 1], accuracy: 1e-6)
            let joined = Array(out[0..<n]) + Array(x[Policy.chunk...])   // slipped chunk followed by the next raw chunk
            XCTAssertLessThan(dbfs(TestSignals.maxSecondDifference(joined[...])), -40, "slip \(slip)")
        }
    }
}
