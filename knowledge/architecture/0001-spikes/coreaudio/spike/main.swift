import AVFoundation
import AudioToolbox
import Darwin

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "two"
let secs = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 5
print("mode=\(mode) secs=\(secs) TCC mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
let mic = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
let outDev = allDevices().first { deviceName($0).contains("BlackHole") } ?? allDevices().first { channels($0, kAudioObjectPropertyScopeOutput) > 0 && $0 != mic }!
print("mic=\(mic) '\(deviceName(mic))'  render target=\(outDev) '\(deviceName(outDev))' (BlackHole stand-in)")
resetStats()
rtguard_install()
do { rtguard_mark(3); let b = rtguard_allocs(); let p = malloc(64); free(p); let c = rtguard_allocs()
     let arr = [Float](repeating: 1, count: Int(getpid() % 7) + 100); let d = rtguard_allocs(); rtguard_unmark(3)
     print("rtguard selftest from Swift: C malloc counted=\(c - b) (want>=1), Swift Array alloc counted=\(d - c) (want>=1) [\(arr.count)]") }
let fmt48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
var sem = semaphore_t(); semaphore_create(mach_task_self_, &sem, SYNC_POLICY_FIFO, 0)
let running = UnsafeMutablePointer<Int64>.allocate(capacity: 2); running.initialize(repeating: 0, count: 2) // [0]=running [1]=primed
let ncNanos = UnsafeMutablePointer<UInt64>.allocate(capacity: 100_000); let ncCount = UnsafeMutablePointer<Int>.allocate(capacity: 1); ncCount.pointee = 0
let ringA = SPSCRing(capacity: 16384), ringB = SPSCRing(capacity: 8192)
let target = 3 * 480

func pinDevice(_ au: AudioUnit, _ dev: AudioDeviceID, label: String, disableOutput: Bool = false) {
    var st = setAUDevice(au, dev)
    print("[\(label)] set CurrentDevice(\(deviceName(dev))) direct -> \(st)")
    if st != noErr && disableOutput {
        // TN2091: an input-only device needs output IO disabled on the AUHAL first.
        AudioUnitUninitialize(au)
        var zero: UInt32 = 0
        let e = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4)
        st = setAUDevice(au, dev)
        print("[\(label)] EnableIO(output)=0 -> \(e); set CurrentDevice again -> \(st)")
    }
    print("[\(label)] AU reports CurrentDevice=\(auCurrentDevice(au).1) '\(deviceName(auCurrentDevice(au).1))'")
}

var engines: [AVAudioEngine] = []
var hwRate = 48000.0
var aggID: AudioDeviceID = 0

if mode == "two" {
    // Capture engine: inputNode -> sink, pinned to the mic BEFORE reading formats.
    let cap = AVAudioEngine()
    pinDevice(cap.inputNode.audioUnit!, mic, label: "capture", disableOutput: true)
    let inFmt = cap.inputNode.outputFormat(forBus: 0); hwRate = inFmt.sampleRate
    print("[capture] inputNode hw format=\(inFmt)")
    let sink = AVAudioSinkNode(receiverBlock: makeSinkBlock(ringA: ringA, scratch: scratch, sem: sem))
    cap.attach(sink); cap.connect(cap.inputNode, to: sink, format: inFmt)
    // Render engine: source(48k mono) -> mainMixer -> output, pinned to output device; never touch inputNode.
    let ren = AVAudioEngine()
    pinDevice(ren.outputNode.audioUnit!, outDev, label: "render")
    let src = AVAudioSourceNode(format: fmt48, renderBlock: makeSourceBlock(ringB: ringB, primed: running + 1, target: target))
    ren.attach(src); ren.connect(src, to: ren.mainMixerNode, format: fmt48)
    print("[render] outputNode format=\(ren.outputNode.outputFormat(forBus: 0)) mixer out=\(ren.mainMixerNode.outputFormat(forBus: 0))")
    engines = [cap, ren]
} else if mode == "agg" {
    // One engine on a private aggregate (mic + output device), clock = output device, drift comp on mic.
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "SottoSpikeAggregate", kAudioAggregateDeviceUIDKey: "com.sotto.spike.agg.\(getpid())",
        kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceMainSubDeviceKey: uidOf(outDev),
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: uidOf(mic), kAudioSubDeviceDriftCompensationKey: 1],
            [kAudioSubDeviceUIDKey: uidOf(outDev), kAudioSubDeviceDriftCompensationKey: 0]]]
    let s = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
    print("[agg] AudioHardwareCreateAggregateDevice -> \(s) id=\(aggID) \(describe(aggID))")
    let e = AVAudioEngine()
    pinDevice(e.inputNode.audioUnit!, aggID, label: "agg")
    let inFmt = e.inputNode.outputFormat(forBus: 0); hwRate = inFmt.sampleRate
    print("[agg] inputNode hw format=\(inFmt) outputNode=\(e.outputNode.outputFormat(forBus: 0))")
    let sink = AVAudioSinkNode(receiverBlock: makeSinkBlock(ringA: ringA, scratch: scratch, sem: sem))
    e.attach(sink); e.connect(e.inputNode, to: sink, format: inFmt)
    let src = AVAudioSourceNode(format: fmt48, renderBlock: makeSourceBlock(ringB: ringB, primed: running + 1, target: target))
    e.attach(src); e.connect(src, to: e.mainMixerNode, format: fmt48)
    engines = [e]
}

let pump = NCPump(ringA: ringA, ringB: ringB, hwRate: hwRate)
sp_store_rel(running, 1)
let nc = startNCThread(pump: pump, sem: sem, running: running, ncNanos: ncNanos, ncCount: ncCount)
var cfgChanges = 0
let obs = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { n in cfgChanges += 1; let i = engines.firstIndex { $0 === (n.object as AnyObject) } ?? -1; print("  AVAudioEngineConfigurationChange from engine[\(i)] at sinkCalls=\(ld(.sinkCalls)) srcCalls=\(ld(.srcCalls)) running=\(engines.map { $0.isRunning })") }
for (i, e) in engines.enumerated() {
    e.prepare()
    do { try e.start(); print("engine[\(i)] started: isRunning=\(e.isRunning)") } catch { print("engine[\(i)] start threw \(error)") }
}
Thread.sleep(forTimeInterval: secs)
let rtA = rtguard_allocs(), rtF = rtguard_frees()
for e in engines { e.stop() }
sp_store_rel(running, 0); semaphore_signal(sem); Thread.sleep(forTimeInterval: 0.05)
if aggID != 0 { print("[agg] destroy -> \(AudioHardwareDestroyAggregateDevice(aggID))") }

let sinkFrames = ld(.sinkFrames), srcFrames = ld(.srcFrames)
print("SINK  : calls=\(ld(.sinkCalls)) frames/call min=\(ld(.sinkMin)) max=\(ld(.sinkMax)) total=\(sinkFrames) nonZero=\(ld(.sinkNonZero)) (\(sinkFrames > 0 ? 100*ld(.sinkNonZero)/sinkFrames : 0)%) peak=\(Double(ld(.sinkPeakMicro))/1e6) measuredRate=\(String(format: "%.2f", rate(.sinkT0s, .sinkT0h, .sinkT1s, .sinkT1h)))")
print("SOURCE: calls=\(ld(.srcCalls)) frames/call min=\(ld(.srcMin)) max=\(ld(.srcMax)) total=\(srcFrames) peakPulled=\(Double(ld(.srcPeakMicro))/1e6) measuredRate=\(String(format: "%.2f", rate(.srcT0s, .srcT0h, .srcT1s, .srcT1h)))")
print("RINGS : A.overruns=\(ringA.overruns) B.overruns=\(ringB.overruns) B.underrunSamples(after prime)=\(ringB.underruns) B.fill min=\(ld(.ringBMin)) firstUnderrunAtSrcCall=\(ld(.firstUnderrunCall)) max=\(ld(.ringBMax)) target=\(target)")
let n = ncCount.pointee; var arr = Array(UnsafeBufferPointer(start: ncNanos, count: n)).sorted()
let toUs = { (t: UInt64) in Double(t) * Double(tb.numer) / Double(tb.denom) / 1000 }
print("NC    : frames=\(pump.framesEmitted) badChunks=\(pump.badChunks) converter=\(pump.converter != nil) cfgChangeNotifs=\(cfgChanges) stand-in process p99=\(n > 0 ? toUs(arr[n*99/100]) : 0)us")
print("RT-HYGIENE: mallocs on sink/source IO threads while running = \(rtA), frees = \(rtF); inside our blocks = \(ld(.inBlockAllocs)) (last at call \(ld(.inBlockAllocCall)); +sink/-source)")
