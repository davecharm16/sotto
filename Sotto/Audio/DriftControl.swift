import Foundation

/// Keeps ring B near a target fill although the producer (NC thread, fed by the mic clock) and the consumer
/// (BlackHole render clock) run on different clocks.
///
/// Everything runs on the producer (NC) thread; the consumer stays a plain `read`. Per 480-frame chunk it looks at the
/// smoothed post-write fill and, outside a dead band, stretches (insert) or squeezes (drop) that chunk by a few
/// samples, with a short crossfade so the slip is not a click.
///
/// Bounds, all in `Policy`: at most `maxSlip` samples per 480-sample chunk (4/480 = 8333 ppm, only reached during
/// transients; a 50 ppm clock skew needs ~1/480 of that), a dead band of +/-128 around the target, and a gross-error
/// path that skips whole chunks when the fill exceeds `resyncHigh` (consumer stalled or started late) until it is
/// back at the target.
/// Priming ring B with silence up to the target before the consumer starts is the caller's job (`prime()`).
///
/// The raw post-write fill also carries the consumer's block granularity (about +/- one I/O block), so the
/// 960...1920 band holds for I/O blocks up to ~512 frames; the smoothed fill stays in band for any block size.
final class DriftControlledWriter {
    enum Policy {
        static let chunk = 480
        static let target = 1440          // 30 ms: ring B fill after a write
        static let deadBand = 128
        static let maxSlip = 4
        static let resyncHigh = 3840      // 80 ms: above this the incoming chunk is skipped
        static let smoothing = 1.0 / 32.0 // EMA weight per chunk (320 ms time constant)
        static let crossfade = 64
    }

    let ring: SPSCFloatRing
    let insertedSamples = SingleWriterCounter()
    let droppedSamples = SingleWriterCounter()
    let skippedChunks = SingleWriterCounter()
    let lastPostWriteFill = SingleWriterCounter()

    private let scratch: UnsafeMutablePointer<Float>
    private var smoothed: Double?
    private var resyncing = false

    init(ring: SPSCFloatRing) {
        self.ring = ring
        scratch = .allocate(capacity: Policy.chunk + Policy.maxSlip)
        scratch.initialize(repeating: 0, count: Policy.chunk + Policy.maxSlip)
    }

    deinit { scratch.deallocate() }

    /// Fill ring B with silence so the first chunk lands at the target. Call before the consumer starts.
    func prime() {
        let zeros = [Float](repeating: 0, count: Policy.target - Policy.chunk)
        _ = zeros.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    /// Producer thread only. `chunk` holds exactly `Policy.chunk` samples.
    func push(_ chunk: UnsafePointer<Float>) {
        let post = ring.availableToRead + Policy.chunk
        // Gross error (consumer stalled or late): skip chunks until the fill is back at the target, one short gap
        // instead of seconds of maximum-rate slipping.
        if post > Policy.resyncHigh { resyncing = true }
        if resyncing {
            if post > Policy.target {
                skippedChunks.add(1)
                smoothed = nil
                lastPostWriteFill.set(post - Policy.chunk)
                return
            }
            resyncing = false
        }
        let s = smoothed.map { $0 + (Double(post) - $0) * Policy.smoothing } ?? Double(post)
        let slip = Self.slip(forError: s - Double(Policy.target))   // >0 insert, <0 drop
        let n = Self.apply(slip: slip, to: chunk, into: scratch)
        ring.write(scratch, count: n)
        smoothed = s + Double(slip)
        if slip > 0 { insertedSamples.add(slip) } else if slip < 0 { droppedSamples.add(-slip) }
        lastPostWriteFill.set(post + slip)
    }

    /// Positive = insert samples (fill below target), negative = drop.
    static func slip(forError e: Double) -> Int {
        let excess = abs(e) - Double(Policy.deadBand)
        guard excess > 0 else { return 0 }
        let mag = min(Policy.maxSlip, 1 + Int(excess / 160))
        return e < 0 ? mag : -mag
    }

    /// Writes `chunk` stretched or squeezed by `slip` samples into `out` and returns the output length.
    /// Both directions keep the first and last output sample aligned with the input, so chunk joins stay continuous.
    @discardableResult
    static func apply(slip: Int, to x: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) -> Int {
        let len = Policy.chunk, w = Policy.crossfade
        if slip == 0 {
            out.update(from: x, count: len)
            return len
        }
        if slip < 0 {
            // Drop d samples: fade from the aligned stream into the stream d samples ahead at the chunk start.
            let d = -slip
            let n = len - d
            for i in 0..<w {
                let f = Float(i) / Float(w)
                out[i] = (1 - f) * x[i] + f * x[i + d]
            }
            (out + w).update(from: x + w + d, count: n - w)
            return n
        }
        // Insert d samples: fade into the stream d samples behind, finishing before the chunk end.
        let d = slip
        let n = len + d
        let s = len - d - w
        out.update(from: x, count: s)
        for k in s..<(s + w) {
            let f = Float(k - s) / Float(w)
            out[k] = (1 - f) * x[k] + f * x[k - d]
        }
        for k in (s + w)..<n { out[k] = x[k - d] }
        return n
    }
}
