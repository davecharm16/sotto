---
stepsCompleted:
  - step-01-init
  - step-02-discovery
  - step-02b-vision
  - step-02c-executive-summary
  - step-03-success
  - step-04-journeys
  - step-05-domain
  - step-06-innovation
  - step-07-project-type
  - step-08-scoping
  - step-09-functional
  - step-10-nonfunctional
  - step-11-polish
  - step-12-complete
releaseMode: phased
completedAt: 2026-04-26
inputDocuments:
  - ADR-Sotto.md
workflowType: 'prd'
documentCounts:
  briefs: 0
  research: 0
  projectDocs: 1
  brainstorming: 0
classification:
  projectType: desktop_app
  domain: general
  complexity: low
  projectContext: greenfield
  platform: macOS-first, Windows later
  processing: offline-first
assumptions:
  - "Local processing (DeepFilterNet3) must match or approach RTX Voice quality. If quality gap is unacceptable, evaluate cloud/hybrid options as fallback."
  - "Online pivot only if local quality is unacceptable AND users would pay for the quality difference. Cloud costs would force a pricing model — defeats the no-subscription goal."
  - "DeepFilterNet3 is first choice, not only choice. If quality insufficient, evaluate alternative local models before considering cloud pivot. Building custom is last resort."
vision:
  statement: "Freedom to work anywhere without audio anxiety"
  differentiator: "RTX Voice quality on Mac — local, lightweight, free, no subscription"
  coreInsight: "Assemble proven pieces (Apple audio infra + open-source NC) into what's missing on Mac"
  valueProp: "RTX Voice for Mac — local, lightweight, free"
  keyRisk: "NC engine quality — DeepFilterNet3 first, alternatives if needed"
---

# Product Requirements Document - Sotto

**Author:** Dave
**Date:** 2026-04-26

## Executive Summary

**Sotto** is a local real-time noise cancellation app for macOS that delivers RTX Voice-quality audio processing without subscriptions, cloud dependencies, or background resource drain.

**Target User:** Remote workers and professionals who take calls from noisy environments (cafes, co-working spaces, airports) and need reliable noise suppression without managing mute buttons or apologizing for background noise.

**Problem:** Mac users who switch from Windows lose access to free, high-quality noise cancellation (RTX Voice). The primary alternative — Krisp — requires a $60-96/year subscription and consumes significant CPU even when idle. Apple's built-in voice processing exists but lacks configurability and quality for dynamic noise (conversations, espresso machines, music).

**Solution:** A lightweight menu bar app that captures microphone input, applies real-time noise cancellation locally, and routes clean audio through a virtual device (BlackHole) to any communication app (Zoom, Meet, Discord, Slack).

### What Makes This Special

- **Local-first processing:** All audio stays on-device. No cloud, no latency penalty, no privacy exposure, works offline (planes, weak wifi).
- **Zero recurring cost:** No subscription. Free for personal use.
- **Lightweight:** Near-zero CPU when not actively processing. No battery drain from idle background tasks.
- **Universal compatibility:** Works with any app that accepts a system microphone — no per-app integrations needed.

**Core Insight:** NVIDIA proved the quality bar with RTX Voice. Apple provides the audio infrastructure (AVAudioEngine, CoreAudio). DeepFilterNet3 provides an open-source NC engine. The opportunity is assembling these proven pieces into what's missing: a free, local, lightweight NC tool for Mac.

## Project Classification

| Dimension | Value |
|-----------|-------|
| **Project Type** | Desktop App (native macOS menu bar) |
| **Domain** | General / Productivity-Utility |
| **Complexity** | Low (no regulatory, compliance, or specialized domain concerns) |
| **Project Context** | Greenfield (new product, no existing codebase) |
| **Platform Strategy** | macOS first; Windows port later (separate native implementation) |
| **Processing Model** | Offline-first; cloud pivot only if local quality proves insufficient |

## Success Criteria

### User Success

| Outcome | Measure |
|---------|---------|
| **No more muting** | Complete a call without muting for noise reasons |
| **No complaints** | Call participants don't mention background noise |
| **Invisible operation** | Forget Sotto is running — no CPU/battery awareness |
| **Works anywhere** | Café, airport, plane (offline) — same experience |

**Success moment:** First call where you never muted, no one complained, and you weren't thinking about your environment.

### Business Success

| Metric | Target |
|--------|--------|
| **Personal use validated** | Sotto is Dave's daily driver for all calls |
| **Problem solved** | No longer avoiding calls or choosing locations based on noise |

### Technical Success

| Metric | Target |
|--------|--------|
| **NC Quality** | Matches RTX Voice on dynamic noise (talking, machines, music) |
| **Latency** | <30ms total (imperceptible on calls) |
| **Idle CPU** | <1% when not actively processing |
| **Active CPU** | Low enough to not drain battery noticeably |
| **Compatibility** | Works with Zoom, Meet, Discord, Slack |

### Measurable Outcomes

- [ ] 10 consecutive café calls with zero muting for noise
- [ ] No "where are you?" or "what's that noise?" comments
- [ ] Battery life indistinguishable from Sotto-off baseline

## Product Scope

### MVP (Phase 1)

- DeepFilterNet3 noise cancellation (Rust + Swift C interop)
- BlackHole virtual audio device routing
- Bundled BlackHole .pkg installer (one-click setup)
- Menu bar app with on/off toggle
- Input device selection
- Basic audio level indicator
- macOS only (Ventura 13.0+)

> **PRD Decision — Supersedes ADR-0004:**
> DeepFilterNet3 is Phase 1, not Phase 2. Apple Voice Processing is relegated to fallback for older hardware. Rationale: MVP must solve the actual problem (dynamic café noise), not just validate architecture.

### Growth Features (Phase 2)

- Device hot-swap handling (USB mic plug/unplug)
- Auto-start at login
- Echo cancellation (WebRTC AEC3 if needed)
- Audio passthrough/bypass mode

### Vision (Future)

- Windows port (WinUI 3 or Tauri + WASAPI)
- Alternative NC engines if DeepFilterNet insufficient
- Distribution (signing, notarization, installer)
- Potential open-source release

## User Journeys

### Journey 1: First-Time Setup

**Opening Scene:**
Dave just switched from Windows to Mac. He's at his usual café, about to join a client call in 20 minutes. He remembers RTX Voice "just worked" on Windows. He Googles "noise cancellation Mac free" and finds Sotto.

**Rising Action:**
- Downloads Sotto, drags to Applications, launches it
- Sotto detects BlackHole isn't installed
- Shows: "Sotto needs a virtual audio device to work. Install now?" → [Install] button
- Clicks Install → macOS installer runs → completes in 30 seconds
- Sotto restarts, detects BlackHole is now present
- Shows "Select your microphone" — he picks his USB mic
- Sotto prompts: "Now select 'BlackHole 2ch' as your input in Zoom" (with screenshot or link to Zoom audio settings)
- Opens Zoom → Audio Settings → switches input to BlackHole 2ch

**Climax:**
Joins the call. Espresso machine fires up behind him. He braces for the apology — but no one reacts. The call continues. *It's working.*

**Resolution:**
Call ends. No one mentioned noise. He didn't mute once. Total setup time: under 3 minutes. This is his new normal.

### Journey 2: Daily Use

**Opening Scene:**
Tuesday, 2pm. Dave opens his laptop at a busy café. Standup in 5 minutes.

**Rising Action:**
- Sotto is already running (auto-start or click menu bar icon)
- Glances at menu bar — Sotto icon shows it's active
- Joins Google Meet. BlackHole is already his default input.
- Blender fires up at the counter. Someone laughs loudly at the next table.

**Climax:**
The call proceeds normally. Nobody asks "where are you?" or "what's that noise?"

**Resolution:**
Standup ends. Dave gets back to work. He didn't think about Sotto once during the call. That's the point.

### Journey 3: Something Goes Wrong

**Opening Scene:**
Dave plugs in a new USB mic. Joins a call. The other person says: "You're really quiet — I can barely hear you."

**Rising Action:**
- Checks Sotto — it's active, but input device still shows the old mic
- Opens Sotto's device picker, selects the new USB mic
- Audio levels jump back to normal in the menu bar indicator

**Climax:**
"Can you hear me now?" — "Yeah, perfect."

**Resolution:**
Mental note: when swapping mics, check Sotto's input device. Takes 5 seconds. Not a big deal.

### Journey Requirements Summary

| Journey | Capabilities Revealed |
|---------|----------------------|
| **First-time setup** | BlackHole detection, bundled .pkg installer, device picker, per-app setup guidance |
| **Daily use** | Auto-start, persistent device selection, silent background operation |
| **Recovery** | Device picker, audio level indicator, clear status feedback |

## Desktop App Specific Requirements

### Platform Support

| Platform | Phase | Implementation |
|----------|-------|----------------|
| **macOS** | MVP | SwiftUI + AVAudioEngine + CoreAudio |
| **Minimum Version** | MVP | macOS Ventura 13.0+ |
| **Windows** | Future | Separate native app (WinUI 3 or Tauri + WASAPI) |

### System Integration

| Integration | Approach |
|-------------|----------|
| **Menu Bar** | MenuBarExtra (SwiftUI) — persistent, unobtrusive |
| **Audio Capture** | AVAudioEngine input tap on selected device |
| **Audio Output** | Route processed audio to BlackHole virtual device |
| **Virtual Device** | BlackHole 2ch — bundled .pkg installer for one-click setup |
| **NC Engine** | DeepFilterNet3 via Rust static library + Swift C interop |

### Update Strategy

| Phase | Approach |
|-------|----------|
| **MVP** | Manual rebuild from source (personal use) |
| **Future** | Sparkle framework or manual .dmg distribution |

### Offline Capabilities

- All audio processing local — no network dependency
- NC model bundled in app (~10MB)
- Works on planes, weak wifi, anywhere
- Zero telemetry or cloud calls

## Project Scoping & Phased Development

### MVP Strategy & Philosophy

**MVP Approach:** Problem-solving MVP — the minimum that makes café calls work without muting.

**Resource Requirements:** Solo developer (Dave), Rust + Swift skills, no external dependencies except BlackHole.

### Risk Mitigation Strategy

| Risk Type | Risk | Mitigation |
|-----------|------|------------|
| **Technical** | DeepFilterNet3 quality doesn't match RTX Voice | Test early with real café noise; fallback to Apple VP or evaluate alternatives |
| **Technical** | Rust ↔ Swift interop complexity | Start with minimal C FFI surface; prototype audio buffer passing first |
| **Technical** | Latency budget too tight | Profile full pipeline early; optimize buffer sizes if needed |
| **Resource** | Solo developer, limited time | Personal use scope keeps it lean; no distribution overhead |
| **Market** | Apple ships native NC in macOS | Ship fast; window is ~18 months |

## Functional Requirements

### Audio Processing

- **FR1:** User can enable/disable noise cancellation with a single action
- **FR2:** System can capture audio from any selected input device in real-time
- **FR3:** System can apply DeepFilterNet3 noise cancellation to captured audio
- **FR4:** System can route processed audio to BlackHole virtual device
- **FR5:** System can process audio with latency under 30ms

### Device Management

- **FR6:** User can view list of available input devices
- **FR7:** User can select which input device to use for capture
- **FR8:** System can detect when BlackHole is not installed
- **FR9:** System can remember the last selected input device between sessions
- **FR10:** System can detect when selected input device becomes unavailable

### Setup & Onboarding

- **FR11:** System can trigger BlackHole .pkg installation when not present
- **FR12:** User can view guidance for configuring communication apps to use BlackHole
- **FR13:** System can verify BlackHole installation was successful

### User Interface

- **FR14:** User can access Sotto from the macOS menu bar
- **FR15:** User can see current NC status (on/off) at a glance
- **FR16:** User can see audio input level indicator
- **FR17:** User can quit the application from the menu bar

### System Behavior

- **FR18:** System can run in background without user interaction after setup
- **FR19:** System can operate without network connectivity
- **FR20:** System can start processing immediately when NC is enabled

## Non-Functional Requirements

### Performance

- **NFR1:** Audio processing latency must be <30ms end-to-end (imperceptible on calls)
- **NFR2:** NC toggle must take effect within 100ms
- **NFR3:** App launch to ready state must complete within 3 seconds
- **NFR4:** Device list must refresh within 500ms of hardware change

### Resource Efficiency

- **NFR5:** Idle CPU usage must be <1% when NC is disabled
- **NFR6:** Active CPU usage must remain <15% during processing on M1/M2 Macs
- **NFR7:** Memory footprint must stay under 150MB including model
- **NFR8:** No measurable battery impact when idle

### Reliability

- **NFR9:** App must not crash during active audio processing
- **NFR10:** Audio pipeline must recover gracefully if device becomes unavailable
- **NFR11:** App must handle sleep/wake without user intervention

### Privacy & Security

- **NFR12:** No audio data may be transmitted over network
- **NFR13:** No telemetry or usage data may be collected
- **NFR14:** App must request only necessary macOS permissions (microphone)

### Integration

- **NFR15:** Must work with any app that accepts system microphone input
- **NFR16:** Must coexist with other audio applications without conflict
