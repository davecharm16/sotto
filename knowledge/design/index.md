# Design — Index

This folder is the source of truth for this project's design decisions and visual system — kept separate from
`product_docs/` (what to build) and `architecture/` (how the system is built), since design choices have their own
lifecycle and need to stay consistent across every screen/surface.

## Structure

- `decisions.md` — the design decision log. One entry per non-trivial design decision (a pattern chosen, a
  direction rejected and why, a tradeoff made). Append-only, most recent at the top — this is a log, not a doc to
  rewrite.
- `syncs/` — dated notes from design syncs/reviews. One file per sync: `YYYY-MM-DD-topic.md`. Raw discussion notes
  live here; only decisions that came out of a sync get promoted into `decisions.md`.
- `references/` — saved design references (screenshots, exports, inspiration) that decisions point back to.
- `style-guide.md` — the single source of truth for palette, typography/font, and other tokens (spacing, radii,
  etc. as they get decided) that every surface must stay consistent with. Fill in as real decisions are made;
  don't invent values speculatively.

## Rule

Before styling any new surface, check `style-guide.md` first and reuse what's there — don't introduce a new color
or font ad hoc. If a new value is genuinely needed, add it to `style-guide.md` as part of the same change and log
the reasoning in `decisions.md`, rather than letting visual inconsistency accumulate silently.
