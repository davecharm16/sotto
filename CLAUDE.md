# Sotto

**Your voice. Nothing else.**

Local real-time noise cancellation desktop app for macOS using DeepFilterNet3.

## Architecture

```
[Real mic] → [Sotto: capture + DeepFilterNet3 NC] → [Virtual mic (BlackHole)] → [Zoom/Meet/Discord]
```

- **Virtual audio device:** BlackHole 2ch (bundled .pkg installer)
- **UI:** SwiftUI menu bar app (`MenuBarExtra`)
- **Audio:** AVAudioEngine + CoreAudio for device routing (48kHz f32 mono, 480-sample frames)
- **NC Engine:** DeepFilterNet3 via Rust static library + Swift C FFI

## Key Decisions (see ADR-Sotto.md)

- **Local-only processing** — no audio leaves the device
- **Personal-use scope** — no code signing, sandboxing, or notarization
- **Platform:** macOS 13.0+ (SwiftUI + AVAudioEngine)
- **NC engine** — Rust staticlib for cross-platform reuse

## Development

Prerequisites:
- Xcode 15+
- Rust toolchain (`rustup`)
- xcodegen (`brew install xcodegen`)

## Project Structure

```
Sotto/
├── DeepFilter/              # Rust staticlib for DeepFilterNet3
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/lib.rs
├── Sotto/                   # Swift source
│   ├── Audio/               # AudioManager, AudioEngine, NCProcessor, DeviceMonitor
│   ├── Models/              # AudioDevice
│   ├── Views/               # SottoMenuView, DevicePickerView, AudioLevelView, OnboardingView
│   ├── Resources/           # DeepFilterNet3 model, BlackHole .pkg
│   ├── SottoApp.swift
│   ├── Info.plist
│   ├── Sotto.entitlements
│   └── DeepFilter-Bridging-Header.h
├── Tests/
├── project.yml              # XcodeGen config
└── Sotto.xcodeproj          # Generated
```

## Commands

```bash
# Build Rust library
cd DeepFilter && cargo build --release

# Regenerate Xcode project
xcodegen generate

# Build app (requires Xcode)
xcodebuild -scheme Sotto -configuration Debug build

# Run
open build/Debug/Sotto.app
```

## Required Resources

Before building, add:
1. `Sotto/Resources/DeepFilterNet3/model.onnx` — from DeepFilterNet releases
2. `Sotto/Resources/BlackHole/BlackHole-2ch.pkg` — from existential.audio/blackhole

## Current Phase

**Sprint 1: Foundation** — Menu bar app with audio pipeline and DeepFilterNet3 integration
