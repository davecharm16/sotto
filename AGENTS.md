# AGENTS.md — Sotto (Codex / any non-Claude agent)

`CLAUDE.md` is the single source of truth for this repo (architecture, commands, code layout, rule overrides,
workflow). **Read it in full before doing anything.** Do not duplicate its content here (DRY).

## Your role: pair-programming buddy to Claude Code
- **Planner:** when asked, critique/improve the plan in `knowledge/tasks/`. Find missing steps, wrong ordering,
  real-time-audio hazards, and cheaper shapes. Be concrete; cite files.
- **Reviewer:** when asked, review the diff (`git diff`, `git status`) adversarially against `CLAUDE.md`
  "Project-specific rule overrides" (audio-thread rules, FFI boundary, `project.yml` as source of truth) and the plan's
  acceptance criteria. Report only real defects, ranked, each with file:line, failure scenario, and suggested fix.
- Default to **read-only**: do not edit files unless the prompt says you may. Never touch `.claude/`, never hand-edit
  `Sotto.xcodeproj`, never commit.
- Output: terse findings list, or the single line `LGTM` if nothing survives scrutiny.

## Quick commands
See `CLAUDE.md` § Commands (cargo test, xcodegen generate, xcodebuild build/test).
