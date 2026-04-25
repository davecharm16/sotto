import Foundation
import Accelerate

final class RingBuffer {
    private let capacity: Int
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    var availableToRead: Int {
        lock.lock()
        defer { lock.unlock() }
        let available = writeIndex - readIndex
        return available >= 0 ? available : capacity + available
    }

    var availableToWrite: Int {
        return capacity - availableToRead - 1
    }

    func write(_ data: UnsafePointer<Float>, count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard count <= capacity - 1 else { return false }

        let available = capacity - 1 - ((writeIndex - readIndex + capacity) % capacity)
        guard count <= available else { return false }

        let firstPart = min(count, capacity - writeIndex)
        let secondPart = count - firstPart

        buffer.withUnsafeMutableBufferPointer { ptr in
            memcpy(ptr.baseAddress! + writeIndex, data, firstPart * MemoryLayout<Float>.size)
            if secondPart > 0 {
                memcpy(ptr.baseAddress!, data + firstPart, secondPart * MemoryLayout<Float>.size)
            }
        }

        writeIndex = (writeIndex + count) % capacity
        return true
    }

    func read(_ data: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let available = (writeIndex - readIndex + capacity) % capacity
        guard count <= available else { return false }

        let firstPart = min(count, capacity - readIndex)
        let secondPart = count - firstPart

        buffer.withUnsafeBufferPointer { ptr in
            memcpy(data, ptr.baseAddress! + readIndex, firstPart * MemoryLayout<Float>.size)
            if secondPart > 0 {
                memcpy(data + firstPart, ptr.baseAddress!, secondPart * MemoryLayout<Float>.size)
            }
        }

        readIndex = (readIndex + count) % capacity
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        readIndex = 0
    }
}
