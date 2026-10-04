# Lessons — Index

After any user correction or hard-won fix, write the pattern here so the same mistake isn't repeated in a future
session (the Self-Improvement Loop in `CLAUDE.md`). At the start of a session, skim this folder for anything
relevant before planning new work.

## How to write a lesson

- One file per lesson (or per tight cluster): `knowledge/lessons/<short-kebab-slug>.md`.
- Capture: **what happened**, **the root cause**, and **the rule for next time** — phrased so future-you can act on
  it without re-deriving the whole story.
- Prefer a rule that *prevents* the mistake (a check to run, an order to do things in) over a vague "be careful."
- When a lesson supersedes an older one, update or delete the stale file — don't let contradictory advice pile up.

## Lessons
- [`pin-transitive-deps-proven-in-spike.md`](pin-transitive-deps-proven-in-spike.md): when a git dependency
  only builds with exact transitive pins, copy the pins the spike proved. Don't trust semver ranges.
