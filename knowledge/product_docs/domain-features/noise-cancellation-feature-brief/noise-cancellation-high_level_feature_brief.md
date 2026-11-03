# Noise cancellation — High-Level Feature Brief

**Domain:** `noise-cancellation`
**Status:** done (backfilled 2026-10-03, DoD-unverified). Keep this in sync with the rows in `../index.md`.

## Problem
Remote workers on calls from cafés and airports want background noise gone without muting and without paying for a
subscription (PRD §Executive Summary). All processing has to happen on the device (ADR-0005).

## Scope (what ships)
- **DeepFilterNet3 engine**: a Rust staticlib that loads `enc`/`erb_dec`/`df_dec.onnx` and processes 480-sample
  frames at 48 kHz on a dedicated `SottoNCProcessing` thread.
- **NC on/off toggle**: a menu switch with a status dot (green when active, orange when bypassed). The ⌘⇧N hotkey
  also toggles it (see `app-settings`).
- **Strength**: a slider from 0 to 100 % that maps to `df_set_attenuation`. It is persisted.
- **Bypass**: sets attenuation to 0 and disables the slider. It is not persisted.

Not shipped: echo cancellation, the RNNoise and Apple Voice Processing fallbacks (ADR-0004), and performance
validation (E6.4).

**Open issue:** the engine very likely applies no mask today, because `erb_dec` is fed the wrong inputs. See smells
1 and 2 in `knowledge/architecture/0000-system-overview.md`. Any NC work starts by proving suppression end to end.

## Tie-back to product docs
PRD §Product Scope MVP ("DeepFilterNet3 noise cancellation", "on/off toggle") and Growth ("bypass mode").
Epics E1.2–E1.4 and E2.3 cover the engine, and E3.2 covers the toggle. Strength and bypass came from the Sprint 3
commit `1d5222c`.

## Domain entities & services touched
`AudioManager.isEnabled / attenuation / isBypassed` → `AudioEngine.setAttenuation` → `NCProcessor` →
`df_*` FFI (`DeepFilter/src/lib.rs`). The `attenuation` key in UserDefaults.

## Stories
The original stories are in `_bmad-output/implementation-artifacts/epics-and-stories.md` (E1.2–E1.4, E2.3, E3.2).
New stories go in `stories/`.
