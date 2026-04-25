---
stepsCompleted:
  - step-01-init
  - step-02-context
  - step-03-epics
  - step-04-stories
  - step-05-validation
  - step-06-complete
inputDocuments:
  - prd.md
  - architecture.md
completedAt: 2026-04-26
---

# Epics & Stories - Sotto

**Author:** Dave
**Date:** 2026-04-26
**Based on:** PRD v1.0, Architecture v1.0

## Epic Overview

| Epic | Description | Priority | Stories |
|------|-------------|----------|---------|
| **E1** | Project Setup & Rust FFI | P0 | 4 |
| **E2** | Audio Pipeline Core | P0 | 5 |
| **E3** | Menu Bar UI | P0 | 4 |
| **E4** | BlackHole Integration | P0 | 3 |
| **E5** | Device Management | P1 | 4 |
| **E6** | Polish & Edge Cases | P1 | 4 |

**Total Stories:** 24

---

## Epic 1: Project Setup & Rust FFI

**Goal:** Establish Xcode project and Rust-Swift bridge for DeepFilterNet3.

**Acceptance Criteria:**
- Xcode project builds successfully
- Rust static library compiles for arm64 + x86_64
- Swift can call Rust functions via C FFI
- DeepFilterNet3 model loads and processes test audio

### Story 1.1: Create Xcode Project

**As a** developer  
**I want** a properly configured Xcode project  
**So that** I have a foundation for the macOS app

**Acceptance Criteria:**
- [ ] New macOS App project with SwiftUI lifecycle
- [ ] MenuBarExtra configured as app type
- [ ] Deployment target: macOS 13.0+
- [ ] Bundle identifier configured
- [ ] Microphone usage description in Info.plist
- [ ] .gitignore configured for Xcode + Rust

**Technical Notes:**
- Use `MenuBarExtra` scene type
- Add Accelerate.framework for BLAS operations

---

### Story 1.2: Set Up Rust Library Structure

**As a** developer  
**I want** a Rust library that compiles to a static library  
**So that** I can integrate DeepFilterNet3

**Acceptance Criteria:**
- [ ] Cargo.toml with `crate-type = ["staticlib"]`
- [ ] Dependencies: `deep_filter` crate
- [ ] Build targets: aarch64-apple-darwin, x86_64-apple-darwin
- [ ] Build script generates universal binary via `lipo`
- [ ] Library compiles without errors

**Technical Notes:**
```toml
[lib]
crate-type = ["staticlib"]

[dependencies]
deep_filter = "0.5"
```

---

### Story 1.3: Implement C FFI Bridge

**As a** developer  
**I want** C-compatible functions exported from Rust  
**So that** Swift can call DeepFilterNet3

**Acceptance Criteria:**
- [ ] `df_create(model_path)` → returns opaque handle
- [ ] `df_process(handle, buffer, frame_count)` → processes in-place
- [ ] `df_destroy(handle)` → cleans up resources
- [ ] Bridging header declares all functions
- [ ] Swift can import and call functions

**Technical Notes:**
```rust
#[no_mangle]
pub extern "C" fn df_create(model_path: *const c_char) -> *mut c_void
```

---

### Story 1.4: Create NCProcessor Swift Wrapper

**As a** developer  
**I want** a Swift class wrapping the Rust FFI  
**So that** the audio engine can use NC processing cleanly

**Acceptance Criteria:**
- [ ] `NCProcessor` class with init(modelPath:)
- [ ] `process(buffer:frameCount:)` method
- [ ] Proper resource cleanup in deinit
- [ ] Error handling for model load failures
- [ ] Unit test with synthetic audio buffer

**Technical Notes:**
- Model bundled in app at `Resources/DeepFilterNet3/model.onnx`
- Handle pointer stored as `OpaquePointer`

---

## Epic 2: Audio Pipeline Core

**Goal:** Implement real-time audio capture, processing, and routing.

**Acceptance Criteria:**
- Audio captured from selected input device
- NC processing applied in real-time
- Processed audio routed to BlackHole
- Latency under 30ms end-to-end

### Story 2.1: Implement AudioEngine Class

**As a** developer  
**I want** an AVAudioEngine wrapper  
**So that** I can manage the audio processing pipeline

**Acceptance Criteria:**
- [ ] `AudioEngine` class with start/stop methods
- [ ] AVAudioEngine configured for input processing
- [ ] Engine handles format conversion (to 48kHz mono)
- [ ] Engine can be started/stopped without crashes
- [ ] Basic error handling for audio session issues

**Technical Notes:**
- Use `AVAudioEngine.inputNode` for capture
- Use `AVAudioPlayerNode` for output to BlackHole

---

### Story 2.2: Implement Input Tap

**As a** developer  
**I want** to capture audio buffers from the microphone  
**So that** they can be processed by NC

**Acceptance Criteria:**
- [ ] `installTap(on:)` configured on input node
- [ ] Buffers received at 48kHz sample rate
- [ ] Format converted to Float32 mono if needed
- [ ] Tap removal on engine stop
- [ ] No memory leaks in buffer handling

**Technical Notes:**
- Tap format: 48000 Hz, Float32, mono
- Buffer size: 480 samples (10ms)

---

### Story 2.3: Integrate NC Processing in Pipeline

**As a** developer  
**I want** NC processing applied to each audio buffer  
**So that** noise is removed in real-time

**Acceptance Criteria:**
- [ ] NCProcessor called from input tap callback
- [ ] Processing happens on audio thread (no allocations)
- [ ] Processed buffers passed to output
- [ ] Bypass mode when NC disabled
- [ ] Latency measurement shows <15ms processing

**Technical Notes:**
- Pre-allocate processing buffers at engine start
- Measure with `CACurrentMediaTime()`

---

### Story 2.4: Implement Output Routing

**As a** developer  
**I want** processed audio sent to BlackHole  
**So that** communication apps receive clean audio

**Acceptance Criteria:**
- [ ] AVAudioPlayerNode configured for output
- [ ] Output device set to BlackHole 2ch
- [ ] Continuous playback without glitches
- [ ] Format matches BlackHole expectations
- [ ] Volume/level preserved correctly

**Technical Notes:**
- Use `AVAudioEngine.outputNode` aggregate with BlackHole
- May need manual AudioUnit configuration for device selection

---

### Story 2.5: Implement Audio Level Metering

**As a** developer  
**I want** to measure input audio levels  
**So that** the UI can show a level indicator

**Acceptance Criteria:**
- [ ] RMS level calculated from input buffers
- [ ] Level published to UI at ~10Hz refresh
- [ ] Level range normalized to 0.0-1.0
- [ ] CPU-efficient calculation
- [ ] Works independent of NC enable state

**Technical Notes:**
- Calculate in tap callback, publish via Combine
- Use `vDSP_rmsqv` from Accelerate for efficiency

---

## Epic 3: Menu Bar UI

**Goal:** Create the SwiftUI menu bar interface.

**Acceptance Criteria:**
- App appears in menu bar with icon
- Toggle turns NC on/off
- Device picker shows available mics
- Audio level indicator visible

### Story 3.1: Implement MenuBarExtra App

**As a** user  
**I want** Sotto in my menu bar  
**So that** I can access it easily

**Acceptance Criteria:**
- [ ] App icon appears in menu bar
- [ ] Icon changes state (enabled/disabled visual)
- [ ] Menu opens on click
- [ ] App has no Dock icon
- [ ] App stays running after menu closes

**Technical Notes:**
- Use `.menuBarExtraStyle(.window)` for custom content
- Set `LSUIElement = true` in Info.plist for no Dock icon

---

### Story 3.2: Implement NC Toggle Control

**As a** user  
**I want** to toggle noise cancellation  
**So that** I can enable/disable it with one action

**Acceptance Criteria:**
- [ ] Toggle switch in menu view
- [ ] Toggle state reflects actual NC state
- [ ] Toggle triggers audio engine start/stop
- [ ] Visual feedback on toggle change
- [ ] Toggle disabled if BlackHole not installed

**Technical Notes:**
- Bind to `AudioManager.isEnabled`
- Add loading state during engine startup

---

### Story 3.3: Implement Device Picker

**As a** user  
**I want** to select my input microphone  
**So that** I can choose which mic to process

**Acceptance Criteria:**
- [ ] Dropdown shows all input devices
- [ ] Current selection highlighted
- [ ] Selection triggers device change
- [ ] List updates when devices change
- [ ] Device names displayed clearly

**Technical Notes:**
- Use SwiftUI `Picker` with `.menu` style
- Bind to `AudioManager.selectedDevice`

---

### Story 3.4: Implement Audio Level Display

**As a** user  
**I want** to see my audio input level  
**So that** I know my mic is working

**Acceptance Criteria:**
- [ ] Level bar/indicator in menu view
- [ ] Updates in real-time (~10 FPS)
- [ ] Visual scale from silent to loud
- [ ] Works when NC is both on and off
- [ ] Doesn't impact CPU significantly

**Technical Notes:**
- Use SwiftUI animation for smooth updates
- Consider `ProgressView` or custom shape

---

## Epic 4: BlackHole Integration

**Goal:** Detect, install, and integrate with BlackHole virtual device.

**Acceptance Criteria:**
- App detects if BlackHole is installed
- User can install BlackHole with one click
- App verifies installation success
- Guidance provided for app configuration

### Story 4.1: Implement BlackHole Detection

**As a** developer  
**I want** to detect if BlackHole is installed  
**So that** I can prompt installation if needed

**Acceptance Criteria:**
- [ ] Check for BlackHole 2ch device in CoreAudio
- [ ] Detection runs on app launch
- [ ] Detection result available to UI
- [ ] Detection handles edge cases (partially installed)
- [ ] Detection is fast (<100ms)

**Technical Notes:**
- Query `kAudioHardwarePropertyDevices`
- Check device UID for "BlackHole2ch"

---

### Story 4.2: Implement BlackHole Installer Trigger

**As a** user  
**I want** to install BlackHole with one click  
**So that** I don't need to use Terminal

**Acceptance Criteria:**
- [ ] "Install" button in onboarding view
- [ ] Button triggers bundled .pkg installer
- [ ] macOS installer UI appears
- [ ] App waits for installation to complete
- [ ] Success/failure feedback shown

**Technical Notes:**
- Bundle `BlackHole-2ch.pkg` in app resources
- Use `NSWorkspace.open()` or `Process` to run installer
- Poll for device appearance after install

---

### Story 4.3: Implement App Configuration Guidance

**As a** user  
**I want** guidance for configuring Zoom/Meet  
**So that** I know how to use BlackHole

**Acceptance Criteria:**
- [ ] Instructions shown after BlackHole install
- [ ] Step-by-step for Zoom, Meet, Discord
- [ ] Screenshots or visual aids (if feasible)
- [ ] Link to open app audio settings
- [ ] Dismissable once understood

**Technical Notes:**
- Simple instructional view with text
- Consider deep links: `zoommtg://` if possible

---

## Epic 5: Device Management

**Goal:** Handle device enumeration, selection, and changes.

**Acceptance Criteria:**
- All input devices enumerated
- Device selection persisted
- Device changes handled gracefully
- BlackHole identified as output target

### Story 5.1: Implement DeviceMonitor Class

**As a** developer  
**I want** to enumerate audio devices  
**So that** the user can select their microphone

**Acceptance Criteria:**
- [ ] `DeviceMonitor` class with device list
- [ ] Both input and output devices enumerated
- [ ] Device properties: name, UID, channels
- [ ] BlackHole device identified by UID
- [ ] List refreshes on hardware change

**Technical Notes:**
- Use `AudioObjectGetPropertyData`
- Register property listener for `kAudioHardwarePropertyDevices`

---

### Story 5.2: Implement Device Selection Persistence

**As a** user  
**I want** my device selection remembered  
**So that** I don't have to choose every time

**Acceptance Criteria:**
- [ ] Selected device UID saved to UserDefaults
- [ ] Device restored on app launch
- [ ] Fallback to default if saved device unavailable
- [ ] Selection updates when user changes device
- [ ] No crash if saved device removed

**Technical Notes:**
- Store device UID string, not device ID (IDs can change)

---

### Story 5.3: Implement Device Change Handling

**As a** user  
**I want** Sotto to handle device changes  
**So that** I can plug/unplug mics safely

**Acceptance Criteria:**
- [ ] Device list updates on hardware change
- [ ] Active device removal detected
- [ ] Audio engine stops gracefully on removal
- [ ] User notified of device change
- [ ] No crash during hot-swap

**Technical Notes:**
- CoreAudio property listener callback
- Engine restart may be needed on device change

---

### Story 5.4: Implement Device Validation

**As a** developer  
**I want** to validate device before use  
**So that** we avoid errors with invalid devices

**Acceptance Criteria:**
- [ ] Check device supports required format
- [ ] Verify device is not in use exclusively
- [ ] Confirm device channels >= 1
- [ ] Handle validation failures gracefully
- [ ] Error messages are user-friendly

**Technical Notes:**
- Query `kAudioDevicePropertyStreamConfiguration`

---

## Epic 6: Polish & Edge Cases

**Goal:** Handle edge cases and improve reliability.

**Acceptance Criteria:**
- Sleep/wake handled without issues
- Error states communicated clearly
- App is robust under various conditions
- Memory and CPU within targets

### Story 6.1: Implement Sleep/Wake Handling

**As a** user  
**I want** Sotto to work after sleep/wake  
**So that** I don't have to restart it

**Acceptance Criteria:**
- [ ] Audio engine stops on sleep
- [ ] Audio engine restarts on wake
- [ ] Device list refreshed on wake
- [ ] NC state preserved across sleep
- [ ] No crash or audio glitch on wake

**Technical Notes:**
- Use `NSWorkspace.didWakeNotification`
- May need brief delay before engine restart

---

### Story 6.2: Implement Error State UI

**As a** user  
**I want** clear feedback when something goes wrong  
**So that** I know what to do

**Acceptance Criteria:**
- [ ] Error icon/state in menu bar
- [ ] Error message in menu view
- [ ] Actionable guidance (settings link, retry)
- [ ] Errors don't cause crashes
- [ ] Error states recoverable

**Technical Notes:**
- Error states: no mic permission, no BlackHole, engine failure
- Use SwiftUI `Alert` or inline messaging

---

### Story 6.3: Implement Quit Functionality

**As a** user  
**I want** to quit Sotto cleanly  
**So that** resources are released

**Acceptance Criteria:**
- [ ] Quit option in menu
- [ ] Audio engine stopped on quit
- [ ] Rust resources freed
- [ ] No zombie processes
- [ ] Preferences saved before quit

**Technical Notes:**
- Call `NSApplication.shared.terminate()`
- Ensure `df_destroy()` called in cleanup

---

### Story 6.4: Performance Validation

**As a** developer  
**I want** to verify performance targets  
**So that** the app is lightweight as promised

**Acceptance Criteria:**
- [ ] Idle CPU <1% verified
- [ ] Active CPU <15% on M1/M2 verified
- [ ] Memory <150MB verified
- [ ] Latency <30ms verified
- [ ] Battery impact negligible when idle

**Technical Notes:**
- Use Instruments for profiling
- Document baseline measurements

---

## Story Dependency Map

```
E1: Project Setup
  1.1 ──▶ 1.2 ──▶ 1.3 ──▶ 1.4
                           │
                           ▼
E2: Audio Pipeline ◀───────┘
  2.1 ──▶ 2.2 ──▶ 2.3 ──▶ 2.4
           │               │
           └──▶ 2.5        │
                           ▼
E3: Menu Bar UI ◀──────────┘
  3.1 ──▶ 3.2 ──▶ 3.3 ──▶ 3.4

E4: BlackHole (parallel with E2/E3)
  4.1 ──▶ 4.2 ──▶ 4.3

E5: Device Management (after E2)
  5.1 ──▶ 5.2 ──▶ 5.3 ──▶ 5.4

E6: Polish (after E1-E5)
  6.1 ──┬──▶ 6.3
  6.2 ──┘    │
             ▼
            6.4
```

## Sprint Suggestions

### Sprint 1: Foundation
- E1.1, E1.2, E1.3, E1.4 (Project + Rust FFI)
- E4.1 (BlackHole detection)

### Sprint 2: Core Pipeline
- E2.1, E2.2, E2.3, E2.4 (Audio pipeline)
- E4.2, E4.3 (BlackHole install + guidance)

### Sprint 3: UI & Integration
- E3.1, E3.2, E3.3, E3.4 (Menu bar UI)
- E2.5 (Audio levels)

### Sprint 4: Polish
- E5.1, E5.2, E5.3, E5.4 (Device management)
- E6.1, E6.2, E6.3, E6.4 (Edge cases + performance)

---

## Definition of Done

Each story is complete when:
- [ ] Code implemented and compiles
- [ ] Acceptance criteria met
- [ ] Unit tests pass (where applicable)
- [ ] Manual testing completed
- [ ] No regressions in existing functionality
- [ ] Code reviewed (self-review for solo dev)
