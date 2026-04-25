import Foundation

class NCProcessor {
    private var handle: OpaquePointer?

    init(modelPath: String) throws {
        handle = df_create(modelPath)
        if handle == nil {
            throw NCProcessorError.modelLoadFailed
        }
    }

    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard let handle = handle else { return }
        df_process(handle, buffer, Int32(frameCount))
    }

    func setAttenuation(_ value: Float) {
        guard let handle = handle else { return }
        df_set_attenuation(handle, value)
    }

    deinit {
        if let handle = handle {
            df_destroy(handle)
        }
    }
}

enum NCProcessorError: Error {
    case modelLoadFailed
}
