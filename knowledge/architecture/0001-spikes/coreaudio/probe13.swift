// Replicates AudioEngine.configureAudioSession() from the uncommitted WIP (AudioEngine.swift:50-71).
import AVFoundation
import AudioToolbox

print("== CoreAudio devices ==")
for d in allDevices() { print("  " + describe(d)) }
let defIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
let defOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
print("default input=\(defIn) '\(deviceName(defIn))'  default output=\(defOut) '\(deviceName(defOut))'")
let blackhole = allDevices().first { deviceName($0).contains("BlackHole") }
print("BlackHole present: \(blackhole != nil)")

// Stand-ins: mic = default input; "BlackHole" = an output-only device (speakers) because BlackHole is absent.
let mic = defIn
let out = blackhole ?? allDevices().first { channels($0, kAudioObjectPropertyScopeOutput) > 0 && $0 != mic }!

let engine = AVAudioEngine()
let inAU = engine.inputNode.audioUnit!
let outAU = engine.outputNode.audioUnit!
print("\ninputNode.audioUnit === outputNode.audioUnit : \(inAU == outAU)  (\(inAU) vs \(outAU))")
print("before: inAU.CurrentDevice=\(auCurrentDevice(inAU)) outAU.CurrentDevice=\(auCurrentDevice(outAU))")

// Exactly what WIP configureAudioSession() does: input first, then output.
let s1 = setAUDevice(inAU, mic)
print("set inputNode AU -> \(mic) '\(deviceName(mic))' status=\(s1)")
let (_, a) = auCurrentDevice(inAU); let (_, b) = auCurrentDevice(outAU)
print("  readback: inAU='\(deviceName(a))' outAU='\(deviceName(b))'")
let s2 = setAUDevice(outAU, out)
print("set outputNode AU -> \(out) '\(deviceName(out))' status=\(s2)")
let (_, c) = auCurrentDevice(inAU); let (_, d) = auCurrentDevice(outAU)
print("  readback: inAU='\(deviceName(c))' (id \(c))  outAU='\(deviceName(d))' (id \(d))")
print("inputNode.outputFormat(bus 0)  = \(engine.inputNode.outputFormat(forBus: 0))")
print("inputNode.inputFormat(bus 0)   = \(engine.inputNode.inputFormat(forBus: 0))")
print("outputNode.outputFormat(bus 0) = \(engine.outputNode.outputFormat(forBus: 0))")
print("VERDICT smell13: input direction now on '\(deviceName(c))' -> \(c == mic ? "mic kept (REFUTED)" : "mic LOST (CONFIRMED)")")
