import Foundation

final class NCProcessor {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var isDestroyed = false

    init(modelPath: String) throws {
        handle = df_create(modelPath)
        if handle == nil {
            throw NCProcessorError.modelLoadFailed
        }
    }

    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard !isDestroyed, let handle = handle else { return }
        df_process(handle, buffer, Int32(frameCount))
    }

    func setAttenuation(_ value: Float) {
        lock.lock()
        defer { lock.unlock() }

        guard !isDestroyed, let handle = handle else { return }
        df_set_attenuation(handle, value)
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }

        guard !isDestroyed, let handle = handle else { return }
        isDestroyed = true
        df_destroy(handle)
        self.handle = nil
    }

    deinit {
        shutdown()
    }
}

enum NCProcessorError: Error {
    case modelLoadFailed
}
