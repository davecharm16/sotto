# 0001 — Re-architecture assessment: patch, restructure or redesign?

**Date:** 2026-10-03. **Status:** proposed, waiting on the user decisions in §7.
**Method:** three role agents (`dsp-engineer`, `coreaudio-engineer`, `macos-app-engineer`) each assessed their lane
read-only and ran experiments in a scratchpad. The orchestrator reproduced the key experiments independently. The
spike sources are kept in [`0001-spikes/`](0001-spikes/README.md).

## 1. Verdict
**This is not a rewrite.** Keep the product shape: a menu-bar app that sends the mic through NC into BlackHole,
`AudioManager` as the single UI state object, `NCProcessor` as the only caller of the 4-function C seam, a Rust
staticlib, and XcodeGen. Two internals get replaced, and the app shell gets light restructuring.

| Lane | Verdict | Effort | Why, in one line |
|---|---|---|---|
| NC engine (`DeepFilter/`) | **Replace internals:** wrap upstream libDF `DfTract` behind the *same* `df_*` exports | S–M | The current port never runs the model. The wrap matches the upstream CLI to −70.8 dB residual. |
| Audio pipeline (`Sotto/Audio/`) | **Redesign internals:** two engines, SPSC rings, NC-thread conversion, lifecycle controller | M | One `AVAudioEngine` has one AUHAL unit, which drives one device. The design needs two, so the mic is lost today. |
| App shell and structure | **Light restructure:** `AppDelegate`, an unhosted core test target, build hygiene, signing | M | The test and Release paths are broken, and launch-time work hangs off view lifecycle. |

**Not doing:**
- An SPM package or framework split. An unhosted test target already gives headless tests, so the split is YAGNI.
- A hand port of DFN3.
- A single engine on a private aggregate device. That stays the fallback (§5).

## 2. What works today: nothing in the core audio path
All of the following was measured, not inferred. ✔ = the orchestrator reproduced it.

| # | Finding | Evidence |
|---|---|---|
| 1 | **The model never runs.** ✔ | 600/600 frames fail with `erb_decoder.run error: Wrong number of inputs for model. Expected 5 got 1`. Output is input −2.26 dB, the same at attenuation 1.0 and at 0. (`0001-spikes/dsp/current/tests/smell1.rs`) |
| 2 | **The STFT can't reconstruct the signal.** ✔ | Σw² ranges 0.500–1.000, a 6.02 dB ripple. The null residual is −10.3 dB. |
| 3 | **The mic is lost.** ✔ | `inputNode.audioUnit === outputNode.audioUnit`. With the WIP pinning order the read-back device is `0`. An output-only device makes `init` throw `deviceConfigurationFailed`. A device with both directions makes `start()` throw `-10875`. On macOS 26 the shared unit defaults to a hidden `CADefaultDeviceAggregate`. |
| 4 | **NC never ran, even with HEAD's routing.** | `installTap(bufferSize: 480)` delivers **4800** frames per callback, and `RingBuffer.write(4800)` returns `false`. The output was always the raw fallback. |
| 5 | **Only Debug builds, and only with the WIP.** | The `project.yml`/pbxproj at HEAD doesn't build. Release fails with `Undefined symbols for architecture x86_64: _df_create…` because the `.a` is arm64 only. `xcodebuild test` fails because `SottoTests` has no Info.plist. |
| 6 | **Every rebuild loses the mic grant.** | `codesign -dv` shows `Signature=adhoc`, with a designated requirement of `cdhash H"…"`. Hardened runtime is set but not applied. |
| 7 | **The shell lies or never wires things up.** | The hotkey sits in content `.onAppear` and needs Accessibility. `OnboardingView` is never shown. There's no mic gate. `isEnabled` stays true after a failed start. Launch-at-login re-registers on every launch. A saved attenuation of 0 is dropped. |

**Worth keeping:**
- The three-thread split: IO, NC worker, main actor.
- `NCProcessor` as the only caller of `df_*`, and the 4-function C surface.
- `AudioManager` as the UI state object.
- `DeviceMonitor`'s HAL listener, the menu UI and style, and XcodeGen.

## 3. Target architecture
```
[Mic] ─AUHAL─▶ Capture engine: inputNode → AVAudioSinkNode
                 (RT block: copy → ring A, level → atomic, signal. Nothing else)
                        │  SPSC ring A (C atomics, partial writes, overrun counter)
                        ▼
   SottoNCProcessing thread: AVAudioConverter → 48 kHz mono (skipped if native) → 480-frame chunks
        → df_process (libDF DfTract wrap; 1440-sample lookahead; allocates, so never on an IO thread)
        → drift control (hold ring B ≈ 1440 samples; drop or insert with a short crossfade)
                        │  SPSC ring B
                        ▼
[BlackHole] ◀─AUHAL─ Render engine: AVAudioSourceNode → mainMixer
                 (RT block: read ring B; silence on underrun, counted, never raw input)

@MainActor  AppDelegate ─owns─▶ AudioManager (UI state, settings, lastError) ◀─▶ PipelineController
            (Carbon hotkey,      (start(input:output:) throws AudioStartError; handles config change,
             onboarding window)   device loss, default-device change, sleep/wake → debounce → rebuild)
```
**Failure isolation:** if the mic disappears, the render engine keeps BlackHole alive with silence, so the call app
doesn't lose its mic device.

## 4. Cross-lane contracts (resolved)
| # | Contract | Decision |
|---|---|---|
| C1 | NC frame | Unchanged: 480 Float32 mono at 48 kHz, processed in place. |
| C2 | C surface | The `df_*` signatures are unchanged. `df_create(NULL)` uses the **embedded** model, and a path is still accepted. Swift drops the `config.ini` guard (`AudioEngine.swift:38`) and calls `df_create` **off the main thread**, because it takes about 170 ms. |
| C3 | Threading | `df_process` runs only on `SottoNCProcessing`. `df_set_attenuation` becomes an atomic store that applies at the next frame. `df_destroy` runs only after the NC thread has been joined. `NCProcessor`'s lock goes away. |
| C4 | Latency | The algorithmic latency is 1440 samples (30 ms). End to end is about **65–90 ms**: 90 ms as spiked, 65 ms with 2-frame ring B and 256-frame IO buffers, which is not yet measured. |
| C5 | Bypass | **This lives in Rust.** Output is an exact copy of the input delayed by 1440 samples, with the model kept warm and a 1-hop crossfade. That gives one implementation and no jump on toggle, which settles "real bypass" (dsp) vs. "no discontinuity" (coreaudio). |
| C6 | Errors | **One** `AudioStartError` enum. Coreaudio defines `noInput`, `blackHoleMissing`, `deviceUnavailable(OSStatus)` and `engineStartFailed(OSStatus)`. The app gate adds `micPermissionDenied`. `AudioManager.lastError` is `@Published`, and `isEnabled` resets on failure. This merges the two enums the lanes proposed. |
| C7 | Atomics | A C shim, `Sotto/Audio/SottoAtomics.h` (about 8 lines), included from the bridging header, which dsp signs off. There's no swift-atomics dependency, and the stdlib `Atomic` needs macOS 15. |
| C8 | Tests | An unhosted `SottoCoreTests` target in `Tests/Core/` covers the ring, frame adapter, converter and `NCProcessor`, linking `-ldeepfilter`. The hosted `SottoTests` moves to `Tests/App/` and calls `XCTSkip` when no hardware is present. The DSP acceptance tests stay in `cargo test`. |
| C9 | Rust build | tract is pinned at `=0.21.4`, plus `kstring 2.0.2` (tract 0.21.15+ moved to ndarray 0.16, which libDF can't use). The first build needs the network; after that `--locked` works from `~/.cargo/git`. The pre-build script **always** runs cargo, which takes 0.5 s when there's nothing to do, with `~/.cargo/bin` on `PATH`. |
| C10 | Assets | `Resources/DeepFilterNet3` comes out of `project.yml` only **after** Swift calls `df_create(NULL)`. The binary grows by about 7.9 MB and the bundle shrinks by 8.2 MB. |

## 5. Rejected options
**DSP**
- *Patch in place*: it can't work without the encoder, GRU state, normalisation and the deep-filter stage.
- *Own port*: about 800 lines, and we'd own parity with upstream for no gain.

**Audio**
- *Tap + bigger ring*: the tap isn't real-time and arrives in 100 ms chunks, which adds at least 100 ms of latency
  and keeps the allocations and locks.
- *One engine on a private aggregate*: it works, and it's the **fallback** if drift control misbehaves. But
  unplugging the mic kills BlackHole's output, the aggregate's input carries BlackHole's loopback channels, and
  Bluetooth mic rates are untested.

**App**
- *Patch only*: onboarding still needs a window owner, so it ends up as the light restructure anyway.
- *SottoCore SPM package*: the unhosted target already gives headless tests, and SPM can't run cargo.

## 6. Build order
Each slice is owned by one lane and verified independently, following `/sotto-team` Step 4.
`AudioManager.swift` is serialised: S3 (if it touches it), then CA6, then S4, then S5.

| Phase | Slice (lane) | Acceptance |
|---|---|---|
| 0 | Decisions D1–D3 and D10 (user) | Answered. |
| 1, parallel | **S0** build hygiene (app) | Debug `test` passes. Release `build` passes. Editing `lib.rs` triggers a relink. |
| 1 | **S1** `SottoCoreTests` unhosted target (app) | The ring and NC tests pass, and no menu-bar icon appears. |
| 1 | **S2** signing (app, if D1 = yes). Do it early, because it keeps every later manual check stable | `codesign` shows an Authority and TeamIdentifier, the runtime flag is set, the requirement isn't a cdhash, and the mic grant survives a rebuild. |
| 1 | **D1** libDF wrap and in-repo tests (dsp) | The 5 tests pass at the spike numbers: noise-only −23.9 dB pink and −43.6 dB white; SI-SDR +10.0 to +14.6 dB; bit-exact bypass; 1440 samples; p99 < 2 ms. |
| 1 | **D2** atomic attenuation, plus a delayed warm bypass with crossfade (dsp) | Bypass equals input delayed by 1440, bit-exact. Toggling shows no discontinuity above −40 dB. Clean under TSan. |
| 1 | **S3** `AppDelegate` and Carbon hotkey (app) | `grep addGlobalMonitor` finds nothing. There's no Accessibility prompt. Manual: ⌘⇧N works before the menu is ever opened. |
| 2 (needs S1, D1) | **CA1** SPSC ring, atomics shim, NC pump (coreaudio) | Random chunks of 1–8192: 0 writes rejected, every frame exactly 480, 0 continuity errors. |
| 2 | **CA2** render engine with a source node (coreaudio) | An offline manual render: underrun gives silence and is counted. |
| 2 | **CA3** capture engine with a sink node (coreaudio, needs D3) | The routing log shows the mic and BlackHole. 0 allocations inside the blocks. Counters at 0 over 60 s. |
| 2 | **CA4** NC on its thread, atomics, `df_create(NULL)` off main (coreaudio) | Signpost p99 < 10 ms. |
| 3 | **CA5** drift control (coreaudio) | A ±50 ppm offline injection keeps ring B at 960–1920 samples. A 60-minute BlackHole run has 0 underruns. |
| 3 | **CA6** `PipelineController` and `AudioStartError` (coreaudio) | A picker change, unplug/replug and sleep/wake each recover in under 1 s. A failure sets `isEnabled = false` and `lastError`. |
| 4 (needs CA6) | **S4** mic gate and error UI (app) | After `tccutil reset Microphone com.sotto.app` the first enable prompts. Deny gives toggle off plus an error. No BlackHole gives an error. |
| 4 | **S5** onboarding window, login item from `.status`, the attenuation-0 fix, and dropping the model assets (app) | With the flag deleted, onboarding shows at launch. `sfltool dumpbtm` lists the app. A saved 0 % survives. The app runs NC with no bundled ONNX files. |
| Gate | Orchestrator Step 4, plus a **user listen test** in a real call app through BlackHole, plus a 60-minute run | All green. |

## 7. Decisions only you can make
**Needed before Phase 1:**
- **D1 Signing:** sign with your Apple Development identity (team `5QT5U69BN8`) in the tracked `project.yml`, and
  amend ADR-0006 to say there is still no notarization or distribution? *Recommended: yes.* Without it, every
  rebuild asks for the mic again.
- **D2 Intel:** build arm64-only Release, or a universal `.a` (which needs the `x86_64-apple-darwin` target and
  `lipo`)? *Recommended: arm64-only, unless you own an Intel Mac.*
- **D3 BlackHole:** install BlackHole 2ch on this Mac? *Recommended: yes.* CA3, CA5 and the listen test can't be
  verified without it.
- **D10 WIP:** commit the WIP `project.yml` and pbxproj now as a baseline, since HEAD doesn't build without them.
  *Recommended.* The WIP changes to `AudioEngine.swift` and `AudioManager.swift` are superseded by the redesign, and
  the WIP `AudioEngine` can't start at all. Commit them for history, or discard them? *Your call.*

**Can default to the recommendation:**
- **D4 Latency:** accept about 65–90 ms end to end, then measure and revisit. The low-latency
  `DeepFilterNet3_ll` model is untested.
- **D5 Mic disappears mid-call:** keep BlackHole alive with silence and fall back to the default input, *or* stop.
  *Recommended: the first.*
- **D6 Bluetooth headset mics** (16–24 kHz): the two-engine design handles any rate. This mainly affects the test
  matrix.
- **D7 Slider curve:** a linear ×100 dB mapping leaves the top half dead (0.5 gives −23.7 dB and 1.0 gives −23.9 dB
  on pink noise). *Recommended: remap to 0–40 dB, with the top of the slider meaning no limit.*
- **D8 Hotkey:** a hand-written Carbon hotkey (about 40 lines, fixed ⌘⇧N) *(recommended)*, or the KeyboardShortcuts
  package, which can be rebound.
- **D9 Launch at login:** our own ~15 lines of `SMAppService` code *(recommended)*, or LaunchAtLogin-Modern.

## 8. Risks
- **Drift control is new code.** The mic measured −7 ppm, so without it ring B runs dry in about 40 minutes.
  Mitigation: CA5's offline ±50 ppm test, and the aggregate-device fallback.
- **Exact tract and kstring pins are brittle.** An upgrade waits for libDF to move to ndarray 0.16. Upstream's last
  commit was 2024-09. Acceptable for personal use, because the rev is pinned.
- **libDF allocates about 2,100 times per frame.** That's safe only off the IO thread (C3). The worst frame was
  8.8 ms on the first run and 1.8 ms on a re-run, and ring B absorbs it.
- **The capture engine posts one config change at start.** The `PipelineController` must not treat that as a fault.
- **The first Rust build needs the network.**

## Outcome
_Appended when the slices land, noting where reality diverged from this design._
