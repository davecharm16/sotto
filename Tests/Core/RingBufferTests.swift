import XCTest

final class RingBufferTests: XCTestCase {
    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(SPSCFloatRing(minimumCapacity: 4800).capacity, 8192)
        XCTAssertEqual(SPSCFloatRing(minimumCapacity: 8192).capacity, 8192)
    }

    /// The old ring rejected any write of 4800+ samples; a write that fits must now always be accepted.
    func testLargeWriteIsAcceptedAndWraps() {
        let ring = SPSCFloatRing(minimumCapacity: 16384)
        var src = (0..<8192).map { Float($0) }
        var dst = [Float](repeating: 0, count: 8192)
        for round in 0..<5 {   // 8192-sample writes walk the head around the wrap point
            XCTAssertEqual(ring.write(&src, count: 8192), 8192, "round \(round)")
            XCTAssertEqual(ring.read(&dst, count: 8192), 8192)
            XCTAssertEqual(dst, src)
        }
        XCTAssertEqual(ring.overrunSamples, 0)
        XCTAssertEqual(ring.underrunSamples, 0)
    }

    func testPartialWriteCountsOverrunAndPartialReadCountsUnderrun() {
        let ring = SPSCFloatRing(minimumCapacity: 16384)
        var src = [Float](repeating: 1, count: 20000)
        XCTAssertEqual(ring.write(&src, count: 20000), 16384)
        XCTAssertEqual(ring.overrunSamples, 20000 - 16384)
        var dst = [Float](repeating: 7, count: 16394)
        XCTAssertEqual(ring.read(&dst, count: 16394), 16384)
        XCTAssertEqual(ring.underrunSamples, 10)
        XCTAssertEqual(dst[16384], 7, "shortfall must be left untouched by read")
        var padded = [Float](repeating: 7, count: 4)
        XCTAssertEqual(ring.readPaddingSilence(&padded, count: 4), 0)
        XCTAssertEqual(padded, [0, 0, 0, 0], "render side gets silence, never stale data")
        XCTAssertEqual(ring.underrunSamples, 14)
    }

    /// Two threads, random chunk sizes 1...8192 on both sides, exact order, nothing rejected.
    func testTwoThreadRandomChunksKeepExactOrder() {
        let ring = SPSCFloatRing(minimumCapacity: 16384)
        let total = 8_000_000          // below 2^24 so every index is exactly representable as Float
        var rejectedWrites = 0         // a write that fit (by the producer's own view) but was not fully accepted
        let consumerDone = expectation(description: "consumer")
        var continuityErrors = 0
        var received = 0

        let consumer = Thread {
            var rng = SystemRandomNumberGenerator()
            var buf = [Float](repeating: 0, count: 8192)
            var next: Float = 0
            while received < total {
                let want = Int.random(in: 1...8192, using: &rng)
                let n = buf.withUnsafeMutableBufferPointer { ring.read($0.baseAddress!, count: min(want, ring.availableToRead)) }
                for i in 0..<n {
                    if buf[i] != next { continuityErrors += 1 }
                    next += 1
                }
                received += n
            }
            consumerDone.fulfill()
        }
        consumer.start()

        var rng = SystemRandomNumberGenerator()
        var src = [Float](repeating: 0, count: 8192)
        var sent = 0
        while sent < total {
            let n = min(Int.random(in: 1...8192, using: &rng), total - sent)
            for i in 0..<n { src[i] = Float(sent + i) }
            var off = 0
            while off < n {
                let fits = ring.availableToWrite >= n - off
                let w = src.withUnsafeBufferPointer { ring.write($0.baseAddress! + off, count: n - off) }
                if fits && w != n - off { rejectedWrites += 1 }
                off += w
                if w == 0 { sched_yield() }
            }
            sent += n
        }
        wait(for: [consumerDone], timeout: 60)
        XCTAssertEqual(rejectedWrites, 0)
        XCTAssertEqual(continuityErrors, 0)
        XCTAssertEqual(received, total)
        XCTAssertEqual(ring.underrunSamples, 0, "consumer only asks for what is available")
    }
}
