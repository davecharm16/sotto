# Best Practices — Index

This folder holds researched best-practice notes for this project. Each non-trivial new feature, pattern, or
unfamiliar piece of tech gets its own file here, written *before* implementation (see the rule in `CLAUDE.md`'s
Continuous Best-Practice & Architecture Review section). This file is the folder's index and the one place that
holds the standing developer principles every other best-practice doc and every implementation should be checked
against.

## Developer Principles

### YAGNI — You Aren't Gonna Need It
Build for the requirement in front of you, not the one you can imagine. No speculative config options, no
abstraction layers for a second implementation that doesn't exist yet, no generalized framework where a concrete
function will do. If a future need shows up, add for it then — it's cheaper to add later than to carry unused
flexibility now.

### DRY — Don't Repeat Yourself
Before writing new code, check for an existing structure, component, or utility doing something similar and extend
or reuse it rather than duplicating. DRY is about knowledge duplication (the same rule/decision expressed twice),
not about literal line-of-code duplication — three similar lines with no shared meaning are fine; the same business
rule encoded in two places is not.

### SOLID
- **S — Single Responsibility**: a module/class/function should have one reason to change. If describing what it
  does needs "and," it's probably two things.
- **O — Open/Closed**: prefer extending behavior (new implementation, new case) over modifying stable, working code
  paths that other things already depend on.
- **L — Liskov Substitution**: an implementation of an interface/abstraction must be usable anywhere the
  abstraction is expected, without surprising the caller (no narrower preconditions, no weaker guarantees).
- **I — Interface Segregation**: don't force a caller to depend on methods/fields it doesn't use — split fat
  interfaces along actual usage lines.
- **D — Dependency Inversion**: depend on an abstraction (interface, contract) rather than a concrete
  implementation, especially across the boundaries that matter (external providers, third-party APIs, swappable
  integrations) — so swapping an implementation doesn't ripple through the codebase.

These four principles are the baseline lens for every best-practice doc in this folder and every non-trivial code
review — apply them together with the project-specific Continuous Best-Practice & Architecture Review process in
`CLAUDE.md`, not as a replacement for researching what's specific to the feature at hand.

## Topic docs
- [`audio-threading.md`](audio-threading.md): which threads exist (tap, `SottoNCProcessing`, main actor), the ring
  buffers that pass audio between them, the 480-sample NC frame contract, and known real-time deviations.
- [`rust-ffi-boundary.md`](rust-ffi-boundary.md) (rewritten 2026-10-04 for the libDF wrap): the opaque handle, the hand-maintained C header, `NCProcessor` as
  the only Swift owner, the embedded model, `catch_unwind`, atomic attenuation, the delayed bypass and the exact
  pins.
