# Virtual mic setup — High-Level Feature Brief

**Domain:** `virtual-mic-setup`
**Status:** done for detection and install. Setup guidance is in-progress. Backfilled 2026-10-03, DoD-unverified.
Keep this in sync with `../index.md`.

## Problem
Sotto only works when a virtual mic exists (ADR-0001 and ADR-0002), and each call app has to be pointed at it once.
The first-time setup should take under 3 minutes (PRD Journey 1).

## Scope (what ships)
- **BlackHole detection**: any CoreAudio device whose UID contains "BlackHole". The menu shows the setup prompt
  instead of the controls until one is found.
- **Install trigger + re-check**: "Get BlackHole" opens the bundled `BlackHole-2ch.pkg`. That file is not committed,
  so in practice the button opens existential.audio. The app re-checks automatically after 10 s, and the user can
  press "Check Again".
- **Per-app setup guidance** (in-progress): `OnboardingView` has the three steps ("open Zoom/Meet/Discord → Audio
  Settings → pick BlackHole 2ch"), but nothing presents it.

Out of scope: a custom or branded virtual audio driver, which ADR-0002 defers until distribution.

## Tie-back to product docs
PRD §MVP ("Bundled BlackHole .pkg installer") and Journey 1. Epics E4.1–E4.3.

## Domain entities & services touched
`AudioManager.isBlackHoleInstalled / checkBlackHoleStatus() / installBlackHole()`, `AudioDevice.isBlackHole`,
`SottoMenuView.blackHolePrompt`, `OnboardingView`, and `Sotto/Resources/BlackHole/`.

## Stories
The original stories are in `_bmad-output/implementation-artifacts/epics-and-stories.md` (E4.1–E4.3). New stories go
in `stories/`.
