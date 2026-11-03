import XCTest

final class NCProcessorSmokeTests: XCTestCase {
    private let ncFrameSize = 480

    func testProcessesOneFrameHeadless() throws {
        // The unhosted bundle carries no app resources, so load the model from the repo checkout.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let modelDir = repoRoot.appendingPathComponent("Sotto/Resources/DeepFilterNet3").path
        let nc = try NCProcessor(modelPath: modelDir)

        var frame = (0..<ncFrameSize).map { Float(sin(Double($0) * 0.05) * 0.1) }
        frame.withUnsafeMutableBufferPointer { nc.process(buffer: $0.baseAddress!, frameCount: $0.count) }

        XCTAssertTrue(frame.allSatisfy(\.isFinite), "NC output must be finite")
    }
}
