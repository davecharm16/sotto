# App shell & settings — High-Level Feature Brief

**Domain:** `app-settings`
**Status:** done (backfilled 2026-10-03, DoD-unverified). Keep this in sync with the rows in `../index.md`.

## Problem
Sotto should stay out of the way. It should live in the menu bar, show its state at a glance, and be controllable
without opening anything ("Invisible operation", PRD §Success Criteria and Journey 2).

## Scope (what ships)
- **Menu-bar shell + state icon**: an agent app (`LSUIElement`) with a `MenuBarExtra` popover 280 pt wide. The icon
  is `waveform.circle` when off, `waveform.circle.fill` when active and `waveform.slash` when bypassed.
- **Global hotkey ⌘⇧N** toggles NC through an `NSEvent` global monitor. It is only installed after the menu has been
  opened once, and it needs Accessibility permission.
- **Launch at login** uses `SMAppService.mainApp`. On an unsigned build it fails, and (in the uncommitted working
  tree) the toggle quietly turns itself back off.
- **Quit** calls `AudioManager.shutdown()`, which stops the engine and the device listener, then terminates the app.

Not shipped: an error-state UI (E6.2).

## Tie-back to product docs
PRD §MVP ("Menu bar app") and Growth ("Auto-start at login"). Epics E3.1 and E6.3. The hotkey and state icon came
from the Sprint 3 commit `1d5222c`.

## Domain entities & services touched
`SottoApp`, `SottoMenuView` (header/footer), `AudioManager.launchAtLogin / shutdown()`, and the `launchAtLogin` key
in UserDefaults.

## Stories
The original stories are in `_bmad-output/implementation-artifacts/epics-and-stories.md`. New stories go in
`stories/`.
