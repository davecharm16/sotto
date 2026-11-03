# Audio threading — tap thread, processing thread, main actor

Backfilled on 2026-10-03 from `Sotto/Audio/AudioEngine.swift`, `RingBuffer.swift`, `NCProcessor.swift` and commit
`0994ee6` ("thread safety and audio thread constraints"). This file covers the conventions the code follows today
and where it falls short of them.

## The three threads and what each may do
| Thread | Owner | Allowed | Never |
|---|---|---|---|
| **Tap callback** (AVAudioEngine `installTap` block) | `AudioEngine.handleAudioBuffer` | Copy samples into `inputRingBuffer`, signal the condition, read finished frames from `outputRingBuffer`, schedule them on `playerNode`, compute the RMS level | Run NC inference, wait on a condition, call into `AudioManager` or SwiftUI directly |
| **`SottoNCProcessing`** (`Thread`, `.userInteractive`) | `AudioEngine.processingLoop` | Wait on `NSCondition` until at least 480 samples are buffered, then `NCProcessor.process` in place, then write to `outputRingBuffer` | Touch UI state |
| **Main actor** | `AudioManager` (`@MainActor`) | Every `@Published` state, engine creation and teardown, UserDefaults | Per-sample work |

## Rules
1. **Inference stays off the tap thread.** The tap and the inference thread pass audio to each other only through
   the two `RingBuffer`s, each holding 4800 samples (about 100 ms). Do not add a direct call from the tap into
   `NCProcessor`.
2. **The NC frame contract is 480 samples of Float32 mono at 48 kHz.** `df_process` silently does nothing for any
   other `frame_count`. Size every new buffer that feeds NC from `frameSize` and not from a literal.
3. **Cross to the UI with `Task { @MainActor in … }`**, as `onLevelUpdate` and `DeviceMonitor` do. Capture `self`
   weakly.
4. **Teardown order:** set `isRunning = false`, signal the condition, stop the player, remove the tap, stop the
   engine, then `ncProcessor.shutdown()`. `NCProcessor` guards against a frame that is still in flight with its lock
   and the `isDestroyed` flag, so `shutdown()` is idempotent and safe while the thread drains.

## Known deviations
These are real, but do not copy them into new code.
- The tap allocates a new `AVAudioPCMBuffer` on every callback. Use a preallocated buffer pool or reuse one buffer
  instead.
- `RingBuffer` takes an `NSLock` on both read and write. It is not lock-free, although commit `0994ee6` calls it
  that. If you need real-time-safe handoff, use an SPSC ring with atomics and no lock on the tap side.
- `onLevelUpdate` creates one `Task` per buffer. Throttling or atomically storing the level and polling it from the
  UI would be cheaper.

## Principles check
- **SRP:** capture/output, inference and state each have one owner and one thread.
- **YAGNI:** a single SPSC pair is enough. Do not add a general-purpose audio scheduler.

## Update 2026-11-03 (Tier B): two engines, controller-owned lifecycle
The sections above describe the pre-rearchitecture tap design and are superseded by this one.
- **Capture engine** (`CaptureEngine`): `inputNode` pinned to the mic, then `AVAudioSinkNode`. The block only calls
  `PipelineCore.push*` (through `Unmanaged._withUnsafeGuaranteedRef`, no retain), `vDSP_rmsqv` and one atomic store.
- **Render engine** (`RenderEngine`): `AVAudioSourceNode` -> `mainMixerNode` -> `outputNode` pinned to the output
  device. The block only calls `PipelineCore.pull`. Underrun = silence, counted. Never touch `inputNode` on this engine.
- Pin the device **before** reading any format. Each engine owns one direction (smell 13 fix). Engines are one-shot.
- **Teardown order** (`PipelineController`): capture.stop, render.stop, `core.stop()` (joins the NC thread, then
  `df_destroy`). The blocks hold the core unretained, so the core must outlive both engines' `stop()`.
- A config-change notification only schedules a debounced rebuild (never rebuilds inside the handler), and only if an
  engine is unhealthy (stopped, or hardware format differs from the negotiated one).
- Touching `inputNode` without a mic grant blocks on the TCC prompt (observed in a hosted test), so the controller
  asks for permission before it configures the capture engine.
