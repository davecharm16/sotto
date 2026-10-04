import AVFoundation
import AudioToolbox
import Darwin

// Stats slots written from RT threads with relaxed atomics.
enum S: Int { case sinkCalls, sinkMin, sinkMax, sinkFrames, sinkNonZero, sinkPeakMicro, sinkT0s, sinkT0h, sinkT1s, sinkT1h,
              srcCalls, srcMin, srcMax, srcFrames, srcUnderrun, srcPeakMicro, srcT0s, srcT0h, srcT1s, srcT1h, ringBMin, ringBMax, firstUnderrunCall, inBlockAllocs, inBlockAllocCall, count }
let stats = UnsafeMutablePointer<Int64>.allocate(capacity: S.count.rawValue)
func resetStats() { stats.initialize(repeating: 0, count: S.count.rawValue); stats[S.sinkMin.rawValue] = .max; stats[S.srcMin.rawValue] = .max; stats[S.ringBMin.rawValue] = .max }
@inline(__always) func st(_ s: S) -> UnsafeMutablePointer<Int64> { stats + s.rawValue }
func ld(_ s: S) -> Int64 { sp_load_relaxed(st(s)) }

var tb = mach_timebase_info_data_t(); let _tb: Void = { mach_timebase_info(&tb) }()
func rate(_ s0: S, _ h0: S, _ s1: S, _ h1: S) -> Double {
    _ = _tb
    let ds = Double(ld(s1) - ld(s0)); let dh = Double(ld(h1) - ld(h0)) * Double(tb.numer) / Double(tb.denom) / 1e9
    return dh > 0 ? ds / dh : 0
}

/// Sink block body: downmix -> ring A -> stats -> signal NC thread. No alloc / locks / ObjC / ARC (captures are POD).
func makeSinkBlock(ringA: SPSCRing, scratch: UnsafeMutablePointer<Float>, sem: semaphore_t) -> AVAudioSinkNodeReceiverBlock {
    return { ts, frames, abl in
        rtguard_mark(0); let a0 = rtguard_allocs(); defer { let d = rtguard_allocs() - a0; if d > 0 { sp_add_relaxed(st(.inBlockAllocs), Int64(d)); sp_store_rel(st(.inBlockAllocCall), sp_load_relaxed(st(.sinkCalls))) } }
        let n = Int(frames)
        downmixToMono(abl, frames: n, into: scratch)
        ringA.write(scratch, n)
        var nz: Int64 = 0; var peak: Float = 0
        for i in 0..<n { let a = abs(scratch[i]); if a != 0 { nz += 1 }; if a > peak { peak = a } }
        sp_add_relaxed(st(.sinkCalls), 1); sp_add_relaxed(st(.sinkFrames), Int64(n)); sp_add_relaxed(st(.sinkNonZero), nz)
        sp_min_relaxed(st(.sinkMin), Int64(n)); sp_max_relaxed(st(.sinkMax), Int64(n)); sp_max_relaxed(st(.sinkPeakMicro), Int64(peak * 1e6))
        if sp_load_relaxed(st(.sinkT0h)) == 0 { sp_store_rel(st(.sinkT0s), Int64(ts.pointee.mSampleTime)); sp_store_rel(st(.sinkT0h), Int64(ts.pointee.mHostTime)) }
        sp_store_rel(st(.sinkT1s), Int64(ts.pointee.mSampleTime)); sp_store_rel(st(.sinkT1h), Int64(ts.pointee.mHostTime))
        semaphore_signal(sem)
        return noErr
    }
}

/// Source block body: pull ring B; underrun -> silence (never raw) + count. SPIKE: output zeroed after measuring (stand-in device = real speakers).
func makeSourceBlock(ringB: SPSCRing, primed: UnsafeMutablePointer<Int64>, target: Int) -> AVAudioSourceNodeRenderBlock {
    return { isSilence, ts, frames, abl in
        rtguard_mark(1); let a0 = rtguard_allocs(); defer { let d = rtguard_allocs() - a0; if d > 0 { sp_add_relaxed(st(.inBlockAllocs), Int64(d)); sp_store_rel(st(.inBlockAllocCall), -sp_load_relaxed(st(.srcCalls))) } }
        let n = Int(frames)
        let out = abl.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        let avail = ringB.availableToRead
        if sp_load_relaxed(primed) == 1 { sp_min_relaxed(st(.ringBMin), Int64(avail)); sp_max_relaxed(st(.ringBMax), Int64(avail)) }
        var got = 0
        if sp_load_relaxed(primed) == 0 { if avail >= target { sp_store_rel(primed, 1) } }
        else { got = ringB.read(out, n) }
        if got < n { memset(out + got, 0, (n - got) * 4); if sp_load_relaxed(primed) == 1 { ringB.noteUnderrun(n - got); sp_add_relaxed(st(.srcUnderrun), Int64(n - got)); if sp_load_relaxed(st(.firstUnderrunCall)) == 0 { sp_store_rel(st(.firstUnderrunCall), sp_load_relaxed(st(.srcCalls)) + 1) } } }
        var peak: Float = 0; for i in 0..<n { peak = max(peak, abs(out[i])) }
        memset(out, 0, n * 4)          // SPIKE ONLY: keep the speakers silent
        sp_add_relaxed(st(.srcCalls), 1); sp_add_relaxed(st(.srcFrames), Int64(n)); sp_max_relaxed(st(.srcPeakMicro), Int64(peak * 1e6))
        sp_min_relaxed(st(.srcMin), Int64(n)); sp_max_relaxed(st(.srcMax), Int64(n))
        if sp_load_relaxed(st(.srcT0h)) == 0 { sp_store_rel(st(.srcT0s), Int64(ts.pointee.mSampleTime)); sp_store_rel(st(.srcT0h), Int64(ts.pointee.mHostTime)) }
        sp_store_rel(st(.srcT1s), Int64(ts.pointee.mSampleTime)); sp_store_rel(st(.srcT1h), Int64(ts.pointee.mHostTime))
        return noErr
    }
}

/// NC thread: wait on semaphore, pump ring A -> converter -> 480 frames -> ring B.
func startNCThread(pump: NCPump, sem: semaphore_t, running: UnsafeMutablePointer<Int64>, ncNanos: UnsafeMutablePointer<UInt64>, ncCount: UnsafeMutablePointer<Int>) -> Thread {
    let t = Thread {
        while sp_load_acq(running) == 1 {
            _ = semaphore_timedwait(sem, mach_timespec_t(tv_sec: 0, tv_nsec: 20_000_000))
            _ = pump.pump { buf, n in
                let t0 = mach_absolute_time()
                var g: Float = 1; vDSP_vsmul(buf, 1, &g, buf, 1, vDSP_Length(n))   // stand-in for NCProcessor.process
                if ncCount.pointee < 100_000 { ncNanos[ncCount.pointee] = mach_absolute_time() - t0; ncCount.pointee += 1 }
            }
        }
    }
    t.name = "SottoNCProcessing"; t.qualityOfService = .userInteractive; t.start(); return t
}
import Accelerate
