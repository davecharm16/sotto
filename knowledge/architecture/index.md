# Architecture — Index

Record architecture decisions, designs, and diagrams here as they're made. One file per significant design:
`knowledge/architecture/YYYY-MM-DD-<short-slug>-design.md`.

A design/spec doc is where a non-trivial feature starts (per the Plan Node Default in `CLAUDE.md`). It feeds the
knowledge base rather than replacing it: at spec time you also create/extend the feature's domain brief and its
row in `knowledge/product_docs/domain-features/index.md`.

## What a design doc should cover

- **Problem / goal** and the constraints that shape it.
- **Approach** chosen, and the main alternatives rejected (with why).
- **The seams / boundaries** it introduces or relies on (interfaces, providers, data contracts).
- **Data model / migration** impact, if any.
- **Risks & open questions.**
- **Outcome** note appended once built, if reality diverged from the design.

## Designs
- [`0000-system-overview.md`](0000-system-overview.md): the as-built system map from the brownfield backfill
  (2026-10-03), with a smells and open-questions list.
- [`0001-rearchitecture-assessment.md`](0001-rearchitecture-assessment.md): patch vs. restructure vs. redesign
  per lane, backed by experiments. It covers the target architecture, cross-lane contracts, build order and open
  user decisions. The spike sources are in [`0001-spikes/`](0001-spikes/README.md).

## Pre-existing decision records (linked, not copied)
- [`ADR-Sotto.md`](../../ADR-Sotto.md) has ADR-0001 to ADR-0006 (virtual mic, BlackHole, native SwiftUI, NC
  phasing, local-only, personal-use scope). The PRD supersedes ADR-0004's phasing.
- [`_bmad-output/planning-artifacts/architecture.md`](../../_bmad-output/planning-artifacts/architecture.md) is the
  original planned architecture. The overview above records where the code differs from it.
