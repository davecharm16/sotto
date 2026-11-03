# Audio routing & devices — High-Level Feature Brief

**Domain:** `audio-routing`
**Status:** done (backfilled 2026-10-03, DoD-unverified). Keep this in sync with the rows in `../index.md`.

## Problem
Users need to pick which real mic Sotto listens to and have the cleaned audio reach their call apps reliably. That
has to keep working when mics are plugged in and out (PRD Journey 3).

## Scope (what ships)
- **Mic → NC → BlackHole routing**: AVAudioEngine input tap → ring buffers → player node → output IO unit set to
  BlackHole 2ch (`AudioEngine.swift`).
- **Input device picker**: a `.menu` picker over the CoreAudio input devices, with BlackHole excluded. The choice is
  persisted by UID and restored at launch. It falls back to the first input.
- **Device list refresh on hot-plug**: `DeviceMonitor` listens on `kAudioHardwarePropertyDevices` and calls
  `refreshDevices()`.
- **Input level meter**: a vDSP RMS value mapped from -60 dB to 0 dB onto 0 to 1, shown as a 60×8 bar that turns
  yellow above 0.5 and red above 0.8.

Not shipped or partial: a running engine is not restarted when the selected device changes or is unplugged (E5.3).
Device validation (E5.4) and sleep/wake handling (E6.1) are not built. Input is never resampled to 48 kHz mono (see
overview smell 3).

## Tie-back to product docs
PRD §MVP ("BlackHole virtual audio device routing", "Input device selection", "Basic audio level indicator") and
Growth ("Device hot-swap handling"). Epics E2.1, E2.2, E2.4, E2.5, E3.3, E3.4, E5.1 and E5.2.

## Domain entities & services touched
`AudioDevice` (`Sotto/Models/AudioDevice.swift`), `DeviceMonitor`, `AudioEngine`, `RingBuffer`, and
`AudioManager.inputDevices / selectedDevice / inputLevel`. The `selectedDeviceUID` key in UserDefaults.

## Stories
The original stories are in `_bmad-output/implementation-artifacts/epics-and-stories.md`. New stories go in
`stories/`.
