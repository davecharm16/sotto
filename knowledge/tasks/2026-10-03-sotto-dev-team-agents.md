# Task — Sotto dev team: 3 role agents + 1 orchestrator skill

## Goal
Three project subagents in `.claude/agents/`, one per role needed to make NC actually work, plus one orchestrator
skill in `.claude/skills/` that routes work to them in dependency order. Each agent carries internet references
that have been checked to resolve, and the existing skills that fit its role.

| Agent | Forte | Owns |
|---|---|---|
| `dsp-engineer` | Rust, DeepFilterNet3, STFT/ERB, tract/ONNX, NC quality measurement | `DeepFilter/`, `Sotto/Resources/DeepFilterNet3/` |
| `coreaudio-engineer` | AVAudioEngine, CoreAudio HAL, real-time threads, resampling, device lifecycle | `Sotto/Audio/`, `Sotto/Models/` |
| `macos-app-engineer` | SwiftUI `MenuBarExtra`, permissions, login items, hotkeys, XcodeGen/signing | `Sotto/Views/`, `SottoApp.swift`, `project.yml` |

## Plan
- [x] Confirm the Claude Code subagent and skill frontmatter format (fields, how `skills` preloads, `tools`).
- [x] Research verified references per role, in parallel subagents, one per role.
- [x] Confirm or refute that libDF has a C API that can replace the hand-rolled `lib.rs`.
- [x] Write the 3 agent files, which reuse `knowledge/best-practices/audio-threading.md` and `rust-ffi-boundary.md`.
- [x] Write the orchestrator skill: routing, order (DSP → Core Audio → app), handoff contract, verify gates,
      knowledge updates.
- [x] Lint: frontmatter parses, every URL in the files was verified, and the skill names referenced exist.

## Verification
- A YAML frontmatter parse of all 4 files.
- Every URL listed was fetched successfully by a research agent.
- Every skill named in `skills:` exists on this machine.

## Outcome / Review
Shipped 2026-10-03:
- `.claude/agents/dsp-engineer.md`, `coreaudio-engineer.md` and `macos-app-engineer.md`. Each covers its lane, what
  to read first, its forte, the known work in its lane, its verify gates, and the references that were verified.
  Each preloads `anthropic-skills:{system-comprehension,code-craft,debugging-method}` and `ponytail:ponytail`.
- `.claude/skills/sotto-team/SKILL.md`, the orchestrator. It runs in the main thread, because subagents can't nest.
  It covers lanes, triage, plan, dispatch template, independent verification, closing the loop, and a "make NC
  work" roadmap.
- Verification: the YAML frontmatter parses in all 4 files. All 4 preloaded skills resolve on disk. All 85 URLs
  return HTTP 200, re-checked with full URLs including parentheses.
- What research found that changed the plan:
  - libDF's own capi is **not** linkable as-is: its symbols clash, it panics across FFI, and it needs a tar.gz
    path. Wrap `DfTract` behind Sotto's exports instead.
  - New smell 13: input and output share one AUHAL unit, so the mic is likely never captured. Added to the
    overview.
- Not done: no agent has been run yet. `.claude/` is gitignored in this repo, so the team stays local to this
  machine.
