---
stepsCompleted:
  - step-01-init
  - step-02-context
  - step-03-starter
  - step-04-decisions
  - step-05-patterns
  - step-06-structure
  - step-07-validation
  - step-08-complete
inputDocuments:
  - prd.md
  - ADR-Sotto.md
completedAt: 2026-04-26
---

# Architecture Document - Sotto

**Author:** Dave
**Date:** 2026-04-26
**Based on:** PRD v1.0, ADR-Sotto.md

## Executive Summary

Sotto is a native macOS menu bar application that provides real-time noise cancellation for microphone input. The architecture centers on a real-time audio processing pipeline that captures mic input, applies DeepFilterNet3 noise cancellation via Rust FFI, and routes clean audio to a virtual device (BlackHole) for consumption by communication apps.

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         macOS System                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌─────────────────────────────────────┐    │
│  │ Physical Mic │───▶│           Sotto.app                  │    │
│  │  (USB/Built) │    │  ┌─────────────────────────────────┐ │    │
│  └──────────────┘    │  │      SwiftUI MenuBarExtra       │ │    │
│                      │  │  (Toggle, Device Picker, Levels) │ │    │
│                      │  └─────────────────────────────────┘ │    │
│                      │                 │                     │    │
│                      │  ┌─────────────────────────────────┐ │    │
│                      │  │     AVAudioEngine Pipeline      │ │    │
│                      │  │  ┌───────┐  ┌───────┐  ┌─────┐  │ │    │
│                      │  │  │ Input │─▶│  NC   │─▶│Output│  │ │    │
│                      │  │  │ Tap   │  │Engine │  │ Node│  │ │    │
│                      │  │  └───────┘  └───────┘  └─────┘  │ │    │
│                      │  └─────────────────────────────────┘ │    │
│                      │                 │                     │    │
│                      │  ┌─────────────────────────────────┐ │    │
│                      │  │   DeepFilterNet3 (Rust/C FFI)   │ │    │
│                      │  │   libdf.a static library        │ │    │
│                      │  └─────────────────────────────────┘ │    │
│                      └─────────────────────────────────────┘    │
│                                        │                         │
│                                        ▼                         │
│  ┌──────────────────────┐    ┌─────────────────────────┐        │
│  │   BlackHole 2ch      │◀───│   CoreAudio Output      │        │
│  │   (Virtual Device)   │    │   (Processed Audio)     │        │
│  └──────────────────────┘    └─────────────────────────┘        │
│           │                                                      │
│           ▼                                                      │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Communication Apps (Zoom, Meet, Discord, Slack)         │    │
│  │  Select "BlackHole 2ch" as input device                  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Technology Stack

| Layer | Technology | Rationale |
|-------|------------|-----------|
| **UI Framework** | SwiftUI | Native macOS, MenuBarExtra support, modern declarative UI |
| **Audio Framework** | AVAudioEngine + CoreAudio | Low-level audio access, real-time processing, device enumeration |
| **NC Engine** | DeepFilterNet3 | Best open-source quality for dynamic noise, Rust implementation |
| **FFI Bridge** | Swift-C Interop | Rust → C → Swift bridge for audio buffer exchange |
| **Virtual Device** | BlackHole 2ch | Proven, open-source virtual audio driver |
| **Build System** | Xcode + Cargo | Swift compilation + Rust static library |
| **Min Platform** | macOS Ventura 13.0+ | MenuBarExtra API, modern AVAudioEngine features |

## Component Architecture

### 1. UI Layer (SwiftUI)

```swift
// SottoApp.swift - App entry point
@main
struct SottoApp: App {
    @StateObject var audioManager = AudioManager()
    
    var body: some Scene {
        MenuBarExtra("Sotto", systemImage: audioManager.isEnabled ? "waveform" : "waveform.slash") {
            SottoMenuView()
                .environmentObject(audioManager)
        }
        .menuBarExtraStyle(.window)
    }
}
```

**Components:**
- `SottoMenuView` — Main menu content (toggle, device picker, levels)
- `DevicePickerView` — Input device selection dropdown
- `AudioLevelView` — Real-time audio level indicator
- `OnboardingView` — BlackHole installation flow

### 2. Audio Manager Layer

```swift
// AudioManager.swift - Central audio coordination
class AudioManager: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var selectedDevice: AudioDevice?
    @Published var inputLevel: Float = 0.0
    @Published var isBlackHoleInstalled: Bool = false
    
    private let audioEngine: AudioEngine
    private let deviceMonitor: DeviceMonitor
    
    func toggleNC() { ... }
    func selectDevice(_ device: AudioDevice) { ... }
    func checkBlackHoleStatus() { ... }
}
```

**Responsibilities:**
- State management for UI
- Coordinate audio engine lifecycle
- Device enumeration and selection
- BlackHole detection

### 3. Audio Engine Layer

```swift
// AudioEngine.swift - AVAudioEngine wrapper
class AudioEngine {
    private let engine = AVAudioEngine()
    private let ncProcessor: NCProcessor
    private var inputNode: AVAudioInputNode
    private var outputNode: AVAudioOutputNode
    
    func start(inputDevice: AudioDevice, outputDevice: AudioDevice) throws { ... }
    func stop() { ... }
    func installTap(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { ... }
}
```

**Audio Pipeline:**
1. Input tap captures PCM buffers from selected mic
2. Buffers converted to 48kHz f32 mono (DeepFilterNet format)
3. Processed through NC engine via FFI
4. Output routed to BlackHole virtual device

### 4. NC Processor Layer (Rust FFI)

```swift
// NCProcessor.swift - DeepFilterNet bridge
class NCProcessor {
    private var dfHandle: OpaquePointer?
    
    init(modelPath: String) throws {
        dfHandle = df_create(modelPath)
    }
    
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        df_process(dfHandle, buffer, Int32(frameCount))
    }
    
    deinit {
        df_destroy(dfHandle)
    }
}
```

**C Interface (Bridging Header):**
```c
// DeepFilter-Bridging-Header.h
void* df_create(const char* model_path);
void df_process(void* handle, float* buffer, int32_t frame_count);
void df_destroy(void* handle);
```

**Rust Library:**
```rust
// lib.rs - C FFI exports
#[no_mangle]
pub extern "C" fn df_create(model_path: *const c_char) -> *mut DeepFilter { ... }

#[no_mangle]
pub extern "C" fn df_process(handle: *mut DeepFilter, buffer: *mut f32, frame_count: i32) { ... }

#[no_mangle]
pub extern "C" fn df_destroy(handle: *mut DeepFilter) { ... }
```

### 5. Device Monitor Layer

```swift
// DeviceMonitor.swift - CoreAudio device enumeration
class DeviceMonitor: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var blackHoleDevice: AudioDevice?
    
    private var propertyListener: AudioObjectPropertyListenerProc?
    
    func startMonitoring() { ... }
    func stopMonitoring() { ... }
    func refreshDevices() { ... }
}
```

**CoreAudio Integration:**
- Property listeners for device changes
- Device enumeration via AudioObjectGetPropertyData
- BlackHole detection by device UID

## Data Flow

### Audio Buffer Flow

```
Mic Input (48kHz, stereo or mono)
    │
    ▼
AVAudioInputNode.installTap()
    │
    ├── Convert to 48kHz f32 mono (if needed)
    │
    ▼
NCProcessor.process(buffer)  ─────────────┐
    │                                      │
    │  ┌───────────────────────────────────┤
    │  │ DeepFilterNet3 (Rust)             │
    │  │ - Load model once at startup      │
    │  │ - Process 480-sample frames       │
    │  │ - Return denoised samples         │
    │  └───────────────────────────────────┘
    │
    ▼
Convert back to output format
    │
    ▼
AVAudioPlayerNode → BlackHole 2ch
    │
    ▼
Communication App reads from BlackHole
```

### Buffer Specifications

| Parameter | Value | Notes |
|-----------|-------|-------|
| Sample Rate | 48000 Hz | DeepFilterNet native rate |
| Format | Float32 | Single precision |
| Channels | Mono | DeepFilterNet processes mono |
| Frame Size | 480 samples | 10ms at 48kHz |
| Latency Budget | <30ms | Processing + routing |

## Project Structure

```
Sotto/
├── Sotto.xcodeproj/
│   └── project.pbxproj
├── Sotto/
│   ├── SottoApp.swift                 # App entry point
│   ├── Info.plist
│   ├── Sotto.entitlements
│   │
│   ├── Views/
│   │   ├── SottoMenuView.swift        # Main menu view
│   │   ├── DevicePickerView.swift     # Device selection
│   │   ├── AudioLevelView.swift       # Level indicator
│   │   └── OnboardingView.swift       # BlackHole setup
│   │
│   ├── Audio/
│   │   ├── AudioManager.swift         # Central coordinator
│   │   ├── AudioEngine.swift          # AVAudioEngine wrapper
│   │   ├── NCProcessor.swift          # DeepFilterNet bridge
│   │   └── DeviceMonitor.swift        # Device enumeration
│   │
│   ├── Models/
│   │   ├── AudioDevice.swift          # Device model
│   │   └── AppState.swift             # App state model
│   │
│   ├── Utilities/
│   │   ├── BlackHoleInstaller.swift   # .pkg installation
│   │   └── Preferences.swift          # UserDefaults wrapper
│   │
│   └── Resources/
│       ├── Assets.xcassets/
│       ├── DeepFilterNet3/
│       │   └── model.onnx             # ~10MB NC model
│       └── BlackHole-2ch.pkg          # Bundled installer
│
├── DeepFilter/                         # Rust library
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                     # C FFI exports
│   │   └── processor.rs               # DeepFilterNet wrapper
│   └── build.rs                       # Build script
│
├── DeepFilter-Bridging-Header.h        # Swift-C bridge
│
├── Tests/
│   ├── AudioEngineTests.swift
│   ├── NCProcessorTests.swift
│   └── DeviceMonitorTests.swift
│
└── README.md
```

## Key Technical Decisions

### ADR-001: Virtual Audio Device Pattern
**Decision:** Route processed audio through BlackHole virtual device.
**Rationale:** Universal compatibility with any app that accepts system mic input. No per-app integration needed.

### ADR-002: DeepFilterNet3 in Phase 1 (PRD Override)
**Decision:** Ship with DeepFilterNet3 from day one, not Apple Voice Processing.
**Rationale:** MVP must solve the actual problem (dynamic café noise). Apple VP is fallback only.

### ADR-003: Rust Static Library via C FFI
**Decision:** Build DeepFilterNet3 as static library with C interface.
**Rationale:** Clean boundary between Swift and Rust. No runtime dependencies. Single binary output.

### ADR-004: Bundled BlackHole Installer
**Decision:** Bundle BlackHole .pkg and trigger installation from app.
**Rationale:** One-click setup experience. No Homebrew dependency.

### ADR-005: 48kHz Mono Processing
**Decision:** Convert all audio to 48kHz f32 mono for processing.
**Rationale:** DeepFilterNet native format. Simplifies pipeline. Quality preserved.

## Build Process

### Rust Library Build

```bash
# Build static library for both architectures
cd DeepFilter
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

# Create universal binary
lipo -create \
  target/aarch64-apple-darwin/release/libdeepfilter.a \
  target/x86_64-apple-darwin/release/libdeepfilter.a \
  -output libdeepfilter.a
```

### Xcode Integration

1. Add `libdeepfilter.a` to Xcode project
2. Add `DeepFilter-Bridging-Header.h` to build settings
3. Link against Accelerate.framework (BLAS operations)
4. Bundle `model.onnx` in app resources

### Build Phases

1. Run Cargo build script (Rust → static library)
2. Compile Swift sources
3. Link static library
4. Copy resources (model, BlackHole.pkg)
5. Sign and notarize (future distribution phase)

## Performance Considerations

### Real-Time Audio Thread

The audio processing callback runs on a real-time thread with strict constraints:

**Prohibited:**
- Memory allocation
- Locks/mutexes
- System calls
- Objective-C message dispatch

**Required:**
- Pre-allocated buffers
- Lock-free data structures
- Inline processing

### Memory Layout

```
┌─────────────────────────────────┐
│ App Memory (~150MB total)       │
├─────────────────────────────────┤
│ DeepFilterNet Model: ~10MB      │
│ Audio Buffers: ~2MB             │
│ Swift Runtime: ~50MB            │
│ UI/Framework: ~80MB             │
└─────────────────────────────────┘
```

### Latency Budget

| Stage | Budget | Actual (Target) |
|-------|--------|-----------------|
| Input capture | 10ms | ~5ms |
| NC processing | 15ms | ~10ms |
| Output routing | 5ms | ~3ms |
| **Total** | **30ms** | **~18ms** |

## Security & Privacy

### Permissions Required

```xml
<!-- Info.plist -->
<key>NSMicrophoneUsageDescription</key>
<string>Sotto needs microphone access to apply noise cancellation.</string>
```

### Data Handling

- **Audio data:** Processed in-memory only, never persisted
- **Telemetry:** None
- **Network:** None
- **Storage:** Device preference only (UserDefaults)

## Error Handling

### Graceful Degradation

| Scenario | Behavior |
|----------|----------|
| BlackHole not installed | Show installation prompt |
| Mic permissions denied | Show settings link |
| Device disconnected | Stop processing, show status |
| NC engine error | Passthrough mode (no processing) |
| Model load failure | Error alert, suggest reinstall |

## Testing Strategy

### Unit Tests
- `AudioEngine`: Mock AVAudioEngine, verify tap installation
- `NCProcessor`: Test buffer processing with known inputs
- `DeviceMonitor`: Mock CoreAudio responses

### Integration Tests
- Full pipeline: Mic → NC → Output
- Device hot-swap handling
- Sleep/wake recovery

### Manual Testing
- Real café environment validation
- Latency measurement with audio tools
- Battery impact profiling

## Future Considerations

### Phase 2 Additions
- Device hot-swap (CoreAudio property listeners)
- Auto-start at login (SMAppService)
- Echo cancellation (WebRTC AEC3 if needed)

### Windows Port
- Separate codebase: WinUI 3 or Tauri
- WASAPI for audio
- Same Rust NC engine (cross-platform)

### Distribution
- Apple Developer Program enrollment
- Code signing and notarization
- Custom virtual audio driver (replace BlackHole dependency)
