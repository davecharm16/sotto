# Product Docs — Index

Source of truth for **product intent** — what to build and why. Keep this separate from `architecture/` (how the
system is built) and `design/` (how it looks).

## Structure

- **The PRD / product spec** — the top-level "what & why." Put it here as `<Project>_PRD.md` and edit the Markdown
  (not any exported `.docx`/PDF, which is archival). Reconcile against it when a requirement seems to have changed
  instead of silently drifting.
- `domain-features/` — feature briefs derived from the PRD, one folder per business/domain aspect, plus the
  registry (`index.md`) that tracks every feature's status, tags, dependencies, and Definition of Done. See the
  "Feature Planning Must Separate by Domain" rule in `CLAUDE.md`.

## PRD
The PRD predates this knowledge base and stays where it is. It is linked here, not copied, so there is one source:
- [`_bmad-output/planning-artifacts/prd.md`](../../_bmad-output/planning-artifacts/prd.md): Sotto PRD (2026-04-26).
  The MVP puts DeepFilterNet3 in phase 1 and supersedes ADR-0004.
- [`_bmad-output/implementation-artifacts/epics-and-stories.md`](../../_bmad-output/implementation-artifacts/epics-and-stories.md):
  epics E1–E6 and 24 stories. The domain briefs cite these story IDs. Unshipped stories (E5.3–E5.4, E6.x) live
  there until they are picked up.
