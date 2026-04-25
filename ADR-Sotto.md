# Sotto — Architecture Decision Records

**Project:** Sotto — local real-time noise cancellation desktop app
**Tagline:** Your voice. Nothing else.
**Owner:** Dave
**Last updated:** 2026-04-25
**Scope phase:** Personal-use MVP (macOS), Windows port later

---

## ADR-0001 — Use a virtual audio device pattern for real-time mic NC

**Status:** Accepted — 2026-04-25

### Context

Goal is to clean the user's microphone input before it reaches any communication app (Zoom, Google Meet, Discord, Slack huddles). These apps acquire the system microphone directly via OS-level audio APIs — they do not read from arbitrary processes. Any approach that processes audio inside our own app without exposing it as an input device cannot service third-party apps.

### Decision

Adopt the **virtual audio device pattern**:

```
[Real mic]  →  [Sotto: capture + NC]  →  [Virtual mic]  →  [Zoom/Meet/Discord/etc.]
```

The user selects the virtual mic as their input in any communication app. This is the same architecture used by Krisp, NVIDIA Broadcast, and Microsoft Voice Clarity.

### Consequences

- **+** Works universally with any app that accepts a system microphone.
- **+** Decouples the NC engine from any specific communication app's SDK or API.
- **−** Requires a virtual audio device to exist on the system (see ADR-0002).
- **−** Adds one device-selection step in each communication app (one-time per app).

---

## ADR-0002 — Use BlackHole as the virtual audio device (personal-use phase)

**Status:** Accepted — 2026-04-25 · Revisit before distribution

### Context

Implementing the virtual mic ourselves on macOS requires writing a CoreAudio HAL plugin or AudioDriverKit driver, which in turn requires:

1. Apple Developer Program membership ($99/year).
2. A DriverKit entitlement, requested from Apple via a manual review process. Apple is selective and approval can take weeks.
3. Code-signing and notarization for distribution.

For a personal-use MVP, none of that delivers user value — it only delivers shippability.

[BlackHole](https://github.com/ExistentialAudio/BlackHole) is a mature, open-source virtual audio device for macOS, installable via Homebrew, and already trusted in the audio community.

### Decision

Use **BlackHole 2ch** as the virtual audio device for the personal-use phase. Sotto writes processed audio into BlackHole; communication apps select BlackHole 2ch as their input.

Defer building a custom virtual audio device until (and unless) the project moves toward distribution.

### Consequences

- **+** Bypass Apple's driver entitlement and signing process entirely for v1.
- **+** Battle-tested driver — not our problem if it has bugs.
- **+** Frees us to focus engineering effort on the NC pipeline.
- **−** Not a one-installer experience for any future end-user.
- **−** A name collision is possible if the user already uses BlackHole for other routing setups.
- **!** If Sotto is later productized, a forked/branded BlackHole or a from-scratch driver becomes a hard requirement. Plan for ~4–8 weeks of additional work at that point.

---

## ADR-0003 — Native SwiftUI + AVAudioEngine on macOS, separate Windows port

**Status:** Accepted — 2026-04-25

### Context

Sotto must run on macOS (priority) and Windows (later). Implementation options:

| Option | Pros | Cons |
|---|---|---|
| Native Swift (Mac) + native Windows app | Best UX per platform, lowest latency, full OS audio API access | Two UIs to build |
| Electron | One codebase | Heavyweight, audio APIs awkward, poor Mac feel |
| Tauri (Rust + web UI) | Lightweight, can share Rust audio core | Web UI still doesn't feel native; audio I/O still platform-specific |
| Flutter | One codebase | Real-time audio support is immature, FFI overhead for NC engine |

The audio I/O layer is platform-specific in *every* option — only the UI is portable. That makes the "shared codebase" benefit of Electron/Tauri/Flutter much smaller than it appears.

### Decision

- **Mac:** SwiftUI menu bar app (`MenuBarExtra`) + AVAudioEngine + CoreAudio for device routing.
- **NC engine:** built as a self-contained, language-agnostic core (see ADR-0004) so it can be reused on Windows.
- **Windows port:** native, separate. WinUI 3 or a thin Tauri shell for UI; WASAPI for audio I/O; reuse the same NC engine core.

### Consequences

- **+** Native menu bar integration, lowest possible audio latency, idiomatic Mac UX.
- **+** NC engine is reusable across both platforms — only UI and audio I/O are duplicated.
- **−** Two UI codebases. Acceptable since the UI is small (toggle, levels, device picker).
- **−** Windows version ships later — explicit, accepted trade-off.

---

## ADR-0004 — Phased NC engine: Apple Voice Processing first, DeepFilterNet3 next

**Status:** Accepted — 2026-04-25

### Context

Available real-time noise suppression options:

| Engine | Quality | Latency | Footprint | Distribution |
|---|---|---|---|---|
| Apple Voice Processing (built into AVAudioEngine) | Good on stationary noise; weaker on dynamic | ~10 ms | Zero — ships with macOS | Native API |
| RNNoise | Decent; weaker on non-stationary noise | ~10 ms | Tiny (~85 KB model) | C library, well-supported |
| DeepFilterNet3 | Best open-source quality, handles dynamic noise (TV, keyboards, crowds) | 10–20 ms | ~10 MB model, modest CPU | Rust crate (`libdf`) with C FFI; ONNX models available |
| Krisp SDK | Excellent | ~10 ms | Closed | Commercial license |
| NVIDIA Broadcast | Excellent | Low | Closed | NVIDIA GPUs only |

Local-only processing is required (ADR-0005), eliminating cloud APIs.

### Decision

**Phase 1 (MVP):** Apple's `AVAudioInputNode.setVoiceProcessingEnabled(true)`. Zero dependencies, ships immediately, validates the pipeline (mic → process → BlackHole → consumer app).

**Phase 2 (Quality upgrade):** Replace with **DeepFilterNet3**, integrated as a Rust static library via Swift's C interop. Tap the input node, convert each `AVAudioPCMBuffer` to 48 kHz f32 mono, run inference, push output through an `AVAudioPlayerNode` into the main mixer. Disable Apple's voice processing once DeepFilterNet is active — do not double-process.

RNNoise is held in reserve as a fallback if DeepFilterNet's CPU footprint becomes a problem on older hardware.

### Consequences

- **+** Phase 1 is deliverable in days, end-to-end working.
- **+** Phase 2 has a clear, measurable upgrade path — A/B testable.
- **+** DeepFilterNet's Rust core is the same artifact reusable in the Windows port (ADR-0003).
- **−** Adds Rust toolchain to the build pipeline at phase 2.
- **−** DeepFilterNet model needs to be bundled (~10 MB) — increases app size from negligible to noticeable.

---

## ADR-0005 — Local-only audio processing

**Status:** Accepted — 2026-04-25

### Context

Real-time mic NC could be implemented via cloud APIs (e.g., commercial services that stream audio to a server, denoise, stream back). Trade-offs: potentially better models server-side, but introduces latency, network dependency, privacy exposure, and recurring cost.

Local-only is also a brand commitment for Sotto — the product premise (calm, reliable, worry-free for working in public) collapses if the audio gets streamed somewhere.

### Decision

All audio processing happens **locally on the user's device**. No network calls during the audio path.

### Consequences

- **+** Zero per-minute cost.
- **+** No microphone audio ever leaves the device — strong privacy posture and aligned with the brand.
- **+** Works offline (planes, weak hotel wifi, outages) — the exact scenario Sotto is designed for.
- **+** Latency bounded only by local compute.
- **−** Cannot leverage future cloud-only models if they prove materially better.
- **−** All compute happens on the user's CPU; older hardware may be impacted (mitigated by ADR-0004 fallback to RNNoise).

---

## ADR-0006 — Personal-use scope; defer signing, sandboxing, distribution

**Status:** Accepted — 2026-04-25 · Revisit if scope changes

### Context

Productizing a macOS audio app involves: Apple Developer Program enrollment, code signing, notarization, App Sandbox compliance with audio-input entitlements, hardened runtime configuration, possibly an installer for BlackHole + the app together, and a support story for users with audio routing already configured.

For a tool the developer builds for themselves, none of this is necessary.

### Decision

- Build Sotto for **personal use only** in the current phase.
- Disable App Sandbox locally to simplify CoreAudio device routing.
- Skip code signing, notarization, and installer work.
- Document setup as developer-facing (Xcode + Homebrew), not consumer-facing.

### Consequences

- **+** Faster iteration; no Apple-process gating.
- **+** Free — no Developer Program fee yet.
- **−** Not shareable with non-developer users.
- **−** Each macOS major version upgrade may require a rebuild and re-grant of permissions.
- **!** A scope change to "share with friends" or "ship publicly" requires revisiting ADR-0002 (driver), this ADR (signing), and adding new ADRs for installer and update mechanism.

---

## Open questions / future ADRs

- **Echo cancellation:** Apple's voice processing handles AEC out of the box. DeepFilterNet does not. If phase 2 produces noticeable echo on calls, we'll need an explicit AEC stage (WebRTC AEC3 is the standard reference).
- **Input device hot-swap:** what happens when the user plugs/unplugs a USB mic mid-session? Likely needs CoreAudio device-change notifications and a clean engine restart.
- **Launch at login:** `SMAppService.mainApp.register()` — trivial, defer to phase 3.
- **Telemetry:** none planned, consistent with ADR-0005 and Sotto's brand. Reaffirm if scope changes.
