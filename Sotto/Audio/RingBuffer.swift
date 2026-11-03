import Foundation

/// Lock-free single-producer / single-consumer ring of Float samples.
///
/// One thread may call `write`, one (other) thread may call `read`/`discard`. No allocation, locks or ARC traffic
/// after `init`. Writes and reads are partial: they transfer what fits and report it, and the shortfall is added to
/// `overrunSamples` (producer side) or `underrunSamples` (consumer side). `reset()` is only legal while both
/// threads are quiescent.
final class SPSCFloatRing {
    let capacity: Int                       // power of two
    private let mask: UInt64
    private let storage: UnsafeMutablePointer<Float>
    // Each counter lives on its own 128-byte line (16 x UInt64) so the two threads do not false-share.
    private let ctl: UnsafeMutablePointer<UInt64>
    private static let head = 0, tail = 16, overrun = 32, underrun = 48

    init(minimumCapacity: Int) {
        var cap = 2
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = UInt64(cap - 1)
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
        ctl = UnsafeMutableRawPointer.allocate(byteCount: 64 * MemoryLayout<UInt64>.stride, alignment: 128)
            .bindMemory(to: UInt64.self, capacity: 64)
        ctl.initialize(repeating: 0, count: 64)
    }

    deinit {
        storage.deallocate()
        UnsafeMutableRawPointer(ctl).deallocate()
    }

    /// Samples ready to read. Exact on the consumer thread, a lower bound elsewhere.
    var availableToRead: Int {
        Int(sotto_load_acquire(ctl + Self.tail) &- sotto_load_relaxed(ctl + Self.head))
    }

    /// Free space. Exact on the producer thread, a lower bound elsewhere.
    var availableToWrite: Int { capacity - availableToRead }

    /// Total samples a producer could not store.
    var overrunSamples: Int { Int(sotto_load_relaxed(ctl + Self.overrun)) }
    /// Total samples a consumer asked for and did not get.
    var underrunSamples: Int { Int(sotto_load_relaxed(ctl + Self.underrun)) }

    /// Producer only. Returns the number of samples stored (`< count` means overrun).
    @discardableResult
    func write(_ data: UnsafePointer<Float>, count: Int) -> Int {
        let t = sotto_load_relaxed(ctl + Self.tail)
        let h = sotto_load_acquire(ctl + Self.head)
        let free = capacity - Int(t &- h)
        let n = min(count, free)
        if n > 0 {
            let start = Int(t & mask)
            let first = min(n, capacity - start)
            storage.advanced(by: start).update(from: data, count: first)
            if n > first { storage.update(from: data + first, count: n - first) }
            sotto_store_release(ctl + Self.tail, t &+ UInt64(n))
        }
        if n < count {
            sotto_store_relaxed(ctl + Self.overrun, sotto_load_relaxed(ctl + Self.overrun) &+ UInt64(count - n))
        }
        return n
    }

    /// Consumer only. Returns the number of samples read (`< count` means underrun; the rest of `out` is untouched).
    @discardableResult
    func read(_ out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let h = sotto_load_relaxed(ctl + Self.head)
        let t = sotto_load_acquire(ctl + Self.tail)
        let n = min(count, Int(t &- h))
        if n > 0 {
            let start = Int(h & mask)
            let first = min(n, capacity - start)
            out.update(from: storage + start, count: first)
            if n > first { (out + first).update(from: storage, count: n - first) }
            sotto_store_release(ctl + Self.head, h &+ UInt64(n))
        }
        if n < count {
            sotto_store_relaxed(ctl + Self.underrun, sotto_load_relaxed(ctl + Self.underrun) &+ UInt64(count - n))
        }
        return n
    }

    /// Consumer only: like `read`, but zero-fills the shortfall so the caller always owns `count` valid samples.
    @discardableResult
    func readPaddingSilence(_ out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let n = read(out, count: count)
        if n < count { (out + n).update(repeating: 0, count: count - n) }
        return n
    }

    /// Quiescent use only (no concurrent reader or writer). Counters are kept.
    func reset() {
        sotto_store_release(ctl + Self.head, 0)
        sotto_store_release(ctl + Self.tail, 0)
    }
}

/// A counter written by one thread and read by any other (stats, flags). Lock-free, relaxed ordering.
final class SingleWriterCounter {
    private let cell: UnsafeMutablePointer<UInt64>
    init(_ initial: UInt64 = 0) {
        cell = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 128).bindMemory(to: UInt64.self, capacity: 16)
        cell.initialize(to: initial)
    }
    deinit { UnsafeMutableRawPointer(cell).deallocate() }
    var value: Int { Int(sotto_load_relaxed(cell)) }
    func set(_ v: Int) { sotto_store_release(cell, UInt64(v)) }
    func add(_ n: Int) { sotto_store_relaxed(cell, sotto_load_relaxed(cell) &+ UInt64(n)) }
}
