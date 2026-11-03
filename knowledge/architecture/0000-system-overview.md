# 0000 — System overview (as built)

**Snapshot:** 2026-10-03, HEAD `737dd8f` plus the uncommitted working-tree changes listed at the end.
**Scope:** how the system works today, not how it was planned. The decisions behind it are in
[`ADR-Sotto.md`](../../ADR-Sotto.md). The original plan is in
[`_bmad-output/planning-artifacts/architecture.md`](../../_bmad-output/planning-artifacts/architecture.md). Those are
linked here, not copied.

## What it is
A macOS 13+ menu-bar app (`LSUIElement`, SwiftUI `MenuBarExtra` in `.window` style) that captures a real mic, runs
DeepFilterNet3 noise cancellation in a Rust static library, and plays the result into the BlackHole 2ch virtual
device. Zoom, Meet and Discord then pick BlackHole as their mic. It is for personal use only: there is no sandbox
(`Sotto/Sotto.entitlements`) and no distribution pipeline.

## Module map

| Layer | File(s) | Responsibility |
|---|---|---|
| App shell | `Sotto/SottoApp.swift` | `MenuBarExtra` scene, state icon (`waveform.circle` / `.fill` / `waveform.slash`), global ⌘⇧N monitor |
| State / orchestration | `Sotto/Audio/AudioManager.swift` | The single `@MainActor ObservableObject`. Owns every UI-visible state and the settings persistence. Creates and destroys `AudioEngine` when the toggle flips |
| Audio pipeline | `Sotto/Audio/AudioEngine.swift`, `Sotto/Audio/RingBuffer.swift` | AVAudioEngine graph, input tap, RMS level, ring-buffer handoff, `SottoNCProcessing` thread, player node to output |
| NC seam (Swift) | `Sotto/Audio/NCProcessor.swift`, `Sotto/DeepFilter-Bridging-Header.h` | Owns the opaque `DeepFilterState*`. `NSLock` + `isDestroyed` guard calls to `df_*` |
| NC engine (Rust) | `DeepFilter/src/lib.rs`, `DeepFilter/Cargo.toml` | `staticlib` `libdeepfilter.a` built with tract-onnx 0.21, realfft and ndarray. Does STFT, ERB features, mask and ISTFT |
| Devices | `Sotto/Models/AudioDevice.swift`, `Sotto/Audio/DeviceMonitor.swift` | CoreAudio enumeration (UID, name, in/out streams, `isBlackHole`). Listens on `kAudioHardwarePropertyDevices` |
| Views | `Sotto/Views/SottoMenuView.swift`, `DevicePickerView.swift`, `AudioLevelView.swift`, `OnboardingView.swift` | Bind to `AudioManager` through `.environmentObject`. They hold no logic |
| Model assets | `Sotto/Resources/DeepFilterNet3/{enc,erb_dec,df_dec}.onnx`, `config.ini` | DeepFilterNet v0.5.6 exports, committed to git (about 8 MB) |
| Build | `project.yml` (XcodeGen) → `Sotto.xcodeproj` | A pre-build script runs `cargo build --release` only when the `.a` file is missing. Links `-ldeepfilter` |

## Main data flow
```
mic (selected AudioDevice) ──AU CurrentDevice──▶ engine.inputNode
  └─ installTap(bufferSize 480, hardware format) ── tap thread ───────────────────────────────┐
       ├─ vDSP RMS → onLevelUpdate → Task{@MainActor} → AudioManager.inputLevel → AudioLevelView
       ├─ write ch0 → inputRingBuffer (4800) ── NSCondition.signal ──▶ SottoNCProcessing thread
       │                                                   read 480 → NCProcessor.process → df_process
       │                                                   write 480 → outputRingBuffer (4800)
       └─ read frameCount from outputRingBuffer (or raw-input passthrough if short)
            → new AVAudioPCMBuffer(48 kHz mono) → playerNode.scheduleBuffer
playerNode → mainMixerNode → engine.outputNode ──AU CurrentDevice──▶ BlackHole 2ch → call app
```
Rust per frame (`lib.rs:202`): STFT (960 FFT, 480 hop, sin² window), then 32-band ERB magnitudes, then
`erb_decoder.run`, then the gain mask scaled by `attenuation` (`1 − a·(1 − m)`), then ISTFT.

Control flow: `AudioManager.isEnabled.didSet` runs `startProcessing()`, which builds a new `AudioEngine` and starts
it, or runs `stopProcessing()`. Strength and bypass both go through `setAttenuation`, with bypass sending 0. That
value reaches `df_set_attenuation`.

## Data model and persistence
- `AudioDevice` (value type): `id: AudioDeviceID`, `uid`, `name`, `isInput`, `isOutput`. A device counts as
  `isBlackHole` when its UID contains `"BlackHole"`.
- `UserDefaults` keys: `selectedDeviceUID`, `attenuation`, `launchAtLogin`. `isEnabled` and `isBypassed` are not
  persisted, so NC always starts off.
- There is no other storage and no network. That is ADR-0005: local-only.

## External integrations / seams
- **CoreAudio HAL** for device enumeration and the hot-plug listener (`AudioDevice`, `DeviceMonitor`).
- **BlackHole 2ch**, a third-party driver. It is detected by UID. `installBlackHole()` opens the bundled
  `BlackHole-2ch.pkg` if one is present (it is not committed) and otherwise opens existential.audio. It re-checks
  after 10 s.
- **Rust FFI**: `df_create / df_process / df_set_attenuation / df_destroy` (and `df_get_sample_rate` /
  `df_get_frame_size`, which nothing calls).
- **SMAppService** for launch at login, which needs a signed app (see the WIP note below). **NSEvent global monitor**
  for the hotkey.

## Tests
`Tests/SottoTests.swift` has one test, `AudioDevice.getDevices()` is non-empty, and it depends on hardware. There
are no Rust tests, no linter and no CI.

## Smells / open questions
1. ✅ *Fixed in the engine, Phase 1 (2026-10-04): libDF wrap, 7 cargo tests.* **NC is not suppressing anything.** *Confirmed at runtime 2026-10-03: 600/600 frames fail with "Expected 5 got
   1". See [0001](0001-rearchitecture-assessment.md) §2.* Parsing the bundled ONNX graphs shows that `erb_dec.onnx` expects
   `(emb, e3, e2, e1, e0)` from `enc.onnx`. `lib.rs:211` passes one raw `(1,1,32)` ERB tensor instead. The run should
   fail, `if let Ok` swallows the error, and the audio comes out as STFT→ISTFT resynthesis. The encoder, the
   `df_dec` deep-filter stage, the feature normalisation and the GRU state (`enc_hidden`… at `lib.rs:37-40`) are all
   loaded or declared but never used. None of this has been verified at runtime. Before fixing it, check whether the
   official `libDF` / `deep_filter` crate (tract streaming) would be a better replacement than a hand-rolled port.
2. ✅ *Fixed in Phase 1: the hand-rolled STFT was replaced by libDF.* **The window probably breaks reconstruction.** A sin² window used for both analysis and synthesis at 50 % overlap
   does not sum to a constant (it ripples between 0.5 and 1.0). The DeepFilterNet reference uses a Vorbis window.
3. **Formats are assumed, not converted.** The tap uses the input node's hardware format and only ever reads channel
   0. Nothing resamples to the 48 kHz mono that the docs and the model assume (`AudioEngine.swift:86-88`).
4. **Tap buffer size against ring capacity.** *Confirmed 2026-10-03: the tap delivers 4800 frames per callback
   and every write is rejected, so NC never ran. See [0001](0001-rearchitecture-assessment.md) §2.* `bufferSize: 480` is only a hint, and macOS often delivers larger
   buffers. `RingBuffer.write` rejects any single write of 4800 frames or more (capacity 4800), so in that case NC
   never runs and output falls back to raw passthrough. Check the real `frameLength`.
5. **Unprocessed audio can leak.** When the output ring runs short, the raw input is scheduled instead
   (`AudioEngine.swift:181`), so clean and unprocessed audio interleave.
6. **The tap thread is not real-time-clean.** It allocates a new `AVAudioPCMBuffer` per callback, takes `NSLock`
   inside `RingBuffer` and the `NSCondition`, and creates a `Task` per buffer for the level meter. Commit `0994ee6`
   calls the ring buffer "lock-free", but it is not.
7. **State can lie.** `startProcessing()` returns early when there is no device or no BlackHole output, and leaves
   `isEnabled == true` (`AudioManager.swift:99-108`). Errors only go to `print`, so the UI has no error state
   (planned as E6.2).
8. **Device changes need a restart.** Changing `selectedDevice` while NC is on only saves the UID. It does not
   restart the engine. Hot-plug refreshes the list but does not rebuild the engine (E5.3).
9. ✅ *Fixed in Phase 1: a Carbon hotkey registered at launch, with no Accessibility needed.* **The hotkey is not installed until the menu has been opened once** (`SottoApp.swift:13-15`). A global key
   monitor also needs Accessibility permission, which the app never asks for.
10. **Dead or unwired code:** `OnboardingView` is never presented (E4.3 guidance is not reachable), and nothing calls
    `df_get_*`.
11. ◐ *Bypass is fixed in Phase 1 (delayed and warm, bit-exact). Restoring a saved 0 % is still open (S5).* **Bypass is not true passthrough.** It sets attenuation to 0 but still runs the STFT/ISTFT path, so any window
    artefacts (item 2) remain. Saving an attenuation of 0 does not survive a restart: `restoreAttenuation` only
    accepts values > 0.
12. ◐ *The signing part is fixed in Phase 1: ADR-0006 amended, builds signed. ADR-0004 vs. the PRD is still open.* **Docs disagree with each other.** ADR-0004 phases Apple Voice Processing first. The PRD supersedes that with
    DeepFilterNet3 first, and the code uses no Voice Processing and no AEC. ADR-0006 says "no signing", but
    `project.yml` sets `CODE_SIGN_STYLE: Automatic` + hardened runtime.
13. **The mic is not being captured (added and confirmed 2026-10-03; see [0001](0001-rearchitecture-assessment.md)
    §2).** On macOS, `engine.inputNode.audioUnit` and
    `engine.outputNode.audioUnit` are the **same** AUHAL unit. A compiled probe on this Mac returned `true`, which
    matches [Apple forums thread 683348](https://developer.apple.com/forums/thread/683348).
    `AudioEngine.configureAudioSession()` (`AudioEngine.swift:51-52`) sets `kAudioOutputUnitProperty_CurrentDevice`
    on it twice, and BlackHole wins. So the tap most likely records BlackHole's own loopback, not the mic. This has
    not been confirmed inside the running app. The fix direction is one engine per device: a capture engine on the
    mic and a render engine on BlackHole. Owner: `coreaudio-engineer`.

## Working-tree WIP (uncommitted at snapshot time; these files were deliberately left as they were)
- `AudioEngine.swift` routes by setting `kAudioOutputUnitProperty_CurrentDevice` on the engine's own IO audio units.
  HEAD instead changed the system-wide default input and output devices.
- `AudioManager.swift`: when `SMAppService` fails (unsigned build), the launch-at-login toggle now quietly turns
  itself back off.
- `project.yml` excludes `**/README.md` from resources. `project.pbxproj` has been regenerated. The pbxproj at HEAD
  is missing `RingBuffer.swift` and the ONNX/`config.ini` resources, so it is not buildable as committed.
