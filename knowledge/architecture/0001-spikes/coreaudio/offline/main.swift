import Foundation
import AVFoundation
import Accelerate

var rng = SystemRandomNumberGenerator()

// 1) Two-thread SPSC stress: ramp in random chunks 1..8192, consumer reads 480s, checks continuity.
do {
    let ring = SPSCRing(capacity: 16384)
    let total = 4_000_000
    let done = DispatchSemaphore(value: 0)
    var maxChunk = 0, partialWrites = 0
    Thread {
        let src = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        var next = 0
        while next < total {
            let n = min(Int.random(in: 1...8192, using: &rng), total - next)
            for i in 0..<n { src[i] = Float((next + i) % 1_000_000) }
            maxChunk = max(maxChunk, n)
            var off = 0
            while off < n { let k = ring.write(src + off, n - off); if k < n - off { partialWrites += 1 }; off += k; if off < n { sched_yield() } }
            next += n
        }
        done.signal()
    }.start()
    let dst = UnsafeMutablePointer<Float>.allocate(capacity: 480)
    var expect = 0, errors = 0, chunks = 0
    while expect < total - total % 480 {
        if ring.availableToRead < 480 { sched_yield(); continue }
        let k = ring.read(dst, 480); precondition(k == 480); chunks += 1
        for i in 0..<480 where dst[i] != Float((expect + i) % 1_000_000) { errors += 1 }
        expect += 480
    }
    done.wait()
    print("[ringstress] samples=\(expect) chunks480=\(chunks) maxWriteChunk=\(maxChunk) partialWritesRetried=\(partialWrites) continuityErrors=\(errors) overrunCounter=\(ring.overruns)")
    precondition(errors == 0)
}

// 2) Converter chunking: 44.1 kHz stereo 440 Hz sine, random sink chunks 1..8192, downmix in "sink", AVAudioConverter on "NC thread".
do {
    let srIn = 44100.0, secs = 10.0, nIn = Int(srIn * secs)
    let ringA = SPSCRing(capacity: 16384), ringB = SPSCRing(capacity: 1 << 20)
    let pump = NCPump(ringA: ringA, ringB: ringB, hwRate: srIn)
    // fake deinterleaved stereo ABL
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    let L = UnsafeMutablePointer<Float>.allocate(capacity: 8192), R = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    let mono = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    var pos = 0, writes = 0, writesGE4800 = 0, rejected = 0, chunkSizesSeen = Set<Int>()
    var frameSizes = Set<Int>(), pumpNanos: [UInt64] = []
    while pos < nIn {
        let n = min(Int.random(in: 1...8192, using: &rng), nIn - pos)
        for i in 0..<n { let s = Float(0.5 * sin(2 * .pi * 440 * Double(pos + i) / srIn)); L[i] = s; R[i] = s }
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: L)
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: R)
        downmixToMono(abl.unsafePointer, frames: n, into: mono)
        let k = ringA.write(mono, n); if k != n { rejected += 1 }
        writes += 1; if n >= 4800 { writesGE4800 += 1 }; chunkSizesSeen.insert(n)
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = pump.pump { _, c in frameSizes.insert(c) }
        pumpNanos.append(DispatchTime.now().uptimeNanoseconds - t0)
        pos += n
    }
    let outN = ringB.availableToRead
    let out = UnsafeMutablePointer<Float>.allocate(capacity: outN); _ = ringB.read(out, outN)
    // frequency check on the steady-state middle second
    var zc = 0; for i in 48000..<96000 where (out[i-1] < 0) != (out[i] < 0) { zc += 1 }
    var rms: Float = 0; vDSP_rmsqv(out + 48000, 1, &rms, 48000)
    let expected = Int(Double(nIn) * 48000 / srIn)
    pumpNanos.sort()
    print("[chunks] in=\(nIn)@44.1k stereo writes=\(writes) writes>=4800=\(writesGE4800) rejectedWrites=\(rejected) ringA.overruns=\(ringA.overruns)")
    print("[chunks] out=\(outN)@48k mono (expected~\(expected), missing=\(expected - outN) = converter priming + <480 tail) NCframes=\(pump.framesEmitted) frameSizesSeen=\(frameSizes.sorted()) badChunks=\(pump.badChunks)")
    print("[chunks] 1s window: zeroCrossings=\(zc) -> \(Double(zc)/2) Hz (want 440), rms=\(rms) (want 0.354)")
    print("[chunks] pump() p50=\(Double(pumpNanos[pumpNanos.count/2])/1e3)us p99=\(Double(pumpNanos[pumpNanos.count*99/100])/1e3)us")
    precondition(rejected == 0 && frameSizes == [480] && abs(Double(zc)/2 - 440) < 2)
}
print("OFFLINE OK")
