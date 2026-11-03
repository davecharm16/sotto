# Design Decisions — Log

Append-only. One entry per non-trivial design decision, most recent at the top. Record the decision, the
alternatives considered, and *why* — so a future session doesn't relitigate a settled choice or silently drift
from it. Promote decisions here out of `syncs/` notes; don't leave them buried in raw sync discussion.

<!-- Template — copy for each new decision:

## YYYY-MM-DD — <short title>
**Decision:** …
**Alternatives considered:** …
**Why:** …
**Affects:** <surfaces / tokens touched>

-->

## 2026-04-26 — Native system styling, with state shown by icon and colour (backfilled 2026-10-03)
**Decision:** Use stock SwiftUI controls with system semantic colours and text styles, and no custom palette. NC
state is shown in two places: the menu-bar SF Symbol (`waveform.circle` / `.fill` / `waveform.slash`) and a green or
orange dot next to the toggle.
**Alternatives considered:** None are recorded. ADR-0003 rejected web-UI shells (Electron, Tauri, Flutter) because
they don't feel like a Mac app.
**Why:** ADR-0003 asks for idiomatic Mac UX in a small UI (toggle, levels, device picker). The Sprint 3 commit
`1d5222c` added the icon and dot so the state is readable without opening the menu, which supports the PRD's
"invisible operation".
**Affects:** `Sotto/SottoApp.swift` (menuBarIcon), `Sotto/Views/SottoMenuView.swift`, and `style-guide.md`.
