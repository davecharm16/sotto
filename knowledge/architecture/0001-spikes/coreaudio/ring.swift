import Foundation
import AVFoundation
import Accelerate

/// Lock-free SPSC ring. A struct of raw pointers: no ARC, no locks, no allocation after init.
struct SPSCRing {
    let capacity: Int, mask: Int
    let buf: UnsafeMutablePointer<Float>
    let ctr: UnsafeMutablePointer<Int64> // 0 write idx, 1 read idx, 2 overrun samples, 3 underrun samples
    init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "power of two")
        self.capacity = capacity; mask = capacity - 1
        buf = .allocate(capacity: capacity); buf.initialize(repeating: 0, count: capacity)
        ctr = .allocate(capacity: 4); ctr.initialize(repeating: 0, count: 4)
    }
    var availableToRead: Int { Int(sp_load_acq(ctr) - sp_load_acq(ctr + 1)) }
    var overruns: Int64 { sp_load_relaxed(ctr + 2) }
    var underruns: Int64 { sp_load_relaxed(ctr + 3) }
    func noteUnderrun(_ n: Int) { sp_add_relaxed(ctr + 3, Int64(n)) }
    @discardableResult @inline(__always)
    func write(_ src: UnsafePointer<Float>, _ n: Int) -> Int {
        let w = sp_load_relaxed(ctr), r = sp_load_acq(ctr + 1)
        let k = min(n, capacity - Int(w - r))
        if k < n { sp_add_relaxed(ctr + 2, Int64(n - k)) }
        guard k > 0 else { return 0 }
        let s = Int(w) & mask, first = min(k, capacity - s)
        memcpy(buf + s, src, first * 4)
        if k > first { memcpy(buf, src + first, (k - first) * 4) }
        sp_store_rel(ctr, w + Int64(k)); return k
    }
    @inline(__always)
    func read(_ dst: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        let r = sp_load_relaxed(ctr + 1), w = sp_load_acq(ctr)
        let k = min(n, Int(w - r)); guard k > 0 else { return 0 }
        let s = Int(r) & mask, first = min(k, capacity - s)
        memcpy(dst, buf + s, first * 4)
        if k > first { memcpy(dst + first, buf, (k - first) * 4) }
        sp_store_rel(ctr + 1, r + Int64(k)); return k
    }
}

/// NC thread side: drain ring A (mono @ hw rate), convert once to 48 kHz if needed, emit exactly-480 frames to ring B.
final class NCPump {
    static let frameSize = 480
    let ringA: SPSCRing, ringB: SPSCRing
    let converter: AVAudioConverter?
    let inBuf: AVAudioPCMBuffer, outBuf: AVAudioPCMBuffer
    let frame = UnsafeMutablePointer<Float>.allocate(capacity: NCPump.frameSize)
    var fill = 0, framesEmitted = 0, badChunks = 0
    init(ringA: SPSCRing, ringB: SPSCRing, hwRate: Double) {
        self.ringA = ringA; self.ringB = ringB
        let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwRate, channels: 1, interleaved: false)!
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        converter = hwRate == 48000 ? nil : AVAudioConverter(from: inFmt, to: outFmt)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4096)!
        outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 1024)!
    }
    private func emit(_ src: UnsafePointer<Float>, _ n: Int, _ process: (UnsafeMutablePointer<Float>, Int) -> Void) {
        var off = 0
        while off < n {
            let k = min(NCPump.frameSize - fill, n - off)
            memcpy(frame + fill, src + off, k * 4); fill += k; off += k
            if fill == NCPump.frameSize {
                process(frame, NCPump.frameSize)
                if ringB.write(frame, NCPump.frameSize) != NCPump.frameSize { badChunks += 1 }
                framesEmitted += 1; fill = 0
            }
        }
    }
    /// Returns NC frames emitted.
    func pump(_ process: (UnsafeMutablePointer<Float>, Int) -> Void) -> Int {
        let before = framesEmitted
        guard let conv = converter else {
            while ringA.availableToRead >= NCPump.frameSize {
                _ = ringA.read(frame, NCPump.frameSize)
                process(frame, NCPump.frameSize)
                if ringB.write(frame, NCPump.frameSize) != NCPump.frameSize { badChunks += 1 }
                framesEmitted += 1
            }
            return framesEmitted - before
        }
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { want, status in
                let n = self.ringA.read(self.inBuf.floatChannelData![0], min(Int(want), Int(self.inBuf.frameCapacity)))
                if n == 0 { status.pointee = .noDataNow; return nil }
                self.inBuf.frameLength = AVAudioFrameCount(n); status.pointee = .haveData; return self.inBuf
            }
            let got = Int(outBuf.frameLength)
            emit(outBuf.floatChannelData![0], got, process)
            if st != .haveData || got == 0 { break }
        }
        return framesEmitted - before
    }
}

/// Sink-side downmix of a deinterleaved ABL into a preallocated mono scratch (vDSP, RT-safe).
@inline(__always)
func downmixToMono(_ abl: UnsafePointer<AudioBufferList>, frames: Int, into dst: UnsafeMutablePointer<Float>) {
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
    let nb = list.count
    let ch0 = list[0].mData!.assumingMemoryBound(to: Float.self)
    if nb == 1 { memcpy(dst, ch0, frames * 4); return }
    memcpy(dst, ch0, frames * 4)
    for i in 1..<nb { vDSP_vadd(dst, 1, list[i].mData!.assumingMemoryBound(to: Float.self), 1, dst, 1, vDSP_Length(frames)) }
    var g = 1 / Float(nb); vDSP_vsmul(dst, 1, &g, dst, 1, vDSP_Length(frames))
}
