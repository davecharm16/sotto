import XCTest

final class CoreTests: XCTestCase {
    func testRingRoundTrip() {
        let ring = RingBuffer(capacity: 4800)
        var input = (0..<480).map { Float($0) }
        var output = [Float](repeating: 0, count: 480)
        XCTAssertTrue(ring.write(&input, count: 480))
        XCTAssertTrue(ring.read(&output, count: 480))
        XCTAssertEqual(input, output)
    }

    func testNCProcessorRunsHeadless() throws {
        let nc = try NCProcessor(modelPath: "/Users/davecharm.bulaquena/Documents/personal/sotto/Sotto/Resources/DeepFilterNet3")
        var frame = [Float](repeating: 0, count: 480)
        let frames = 500
        let start = Date()
        for _ in 0..<frames {
            for i in 0..<480 { frame[i] = Float.random(in: -0.1...0.1) }
            frame.withUnsafeMutableBufferPointer { nc.process(buffer: $0.baseAddress!, frameCount: 480) }
        }
        let msPerFrame = Date().timeIntervalSince(start) * 1000 / Double(frames)
        print("SPIKE ms/frame (Debug test, release .a) = \(String(format: "%.3f", msPerFrame))")
        XCTAssertTrue(frame.allSatisfy { $0.isFinite })
    }
}
