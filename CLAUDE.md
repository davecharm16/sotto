# Sotto

**Your voice. Nothing else.**

Local real-time noise cancellation desktop app for macOS using DeepFilterNet3.

<!-- ════════════ PROJECT FACTS — derived from the real code; keep current ════════════ -->

## Project status

- Personal-use macOS 13+ menu-bar agent app (`LSUIElement`, SwiftUI `MenuBarExtra`). It routes the mic through
  DeepFilterNet3 (a Rust staticlib) into BlackHole 2ch, and call apps select BlackHole as their input.
- **Shipped** (git log, all 2026-04-26): Sprint 1 foundation, Sprint 2 DeepFilterNet3 ONNX inference with the
  strength slider, and Sprint 3 bypass, state icon, ⌘⇧N hotkey, launch at login and persisted settings. Commit
  `0994ee6` then added thread safety: ring-buffer handoff, a processing thread and an `NCProcessor` lock.
- **The NC engine is proven offline (Phase 1, 2026-10-04).** `DeepFilter/` wraps upstream libDF `DfTract`, and 7
  `cargo test` acceptance tests pass: noise is cut by −24 dB (pink) and −44 dB (white), SI-SDR improves by +8 to
  +14 dB, latency is 1440 samples. Phase 2–4 landed (2026-11-04) and the pipeline measured −48 dB on speaker pink noise through the real mic → BlackHole
  path. ⚠ Still **not heard in a real call app**, and the 60-minute drift run is pending.
- **Specs:** the PRD is `_bmad-output/planning-artifacts/prd.md`. The planned architecture is
  `_bmad-output/planning-artifacts/architecture.md`. Epics and stories (E1–E6) are in
  `_bmad-output/implementation-artifacts/epics-and-stories.md`. Decisions are in `ADR-Sotto.md` (the PRD supersedes
  ADR-0004: DeepFilterNet3 is phase 1). The as-built map is `knowledge/architecture/0000-system-overview.md`. The
  feature registry is `knowledge/product_docs/domain-features/index.md`.
- **Quality gates today:** one hardware-dependent XCTest (`Tests/SottoTests.swift`). There are no Rust tests, no
  linter and no CI.

## Current Phase

**Re-architecture**, on branch `rearch/phase-1`. The plan is `knowledge/architecture/0001-rearchitecture-assessment.md`
§6, and `/sotto-team` runs it.
- **Phase 1 done (2026-10-04):** build, tests, signing, the Carbon hotkey, and the libDF wrap.
- **Next, Phase 2:** the two-engine audio pipeline (`coreaudio-engineer`). It needs BlackHole 2ch installed.

## Architecture

```
[Real mic] → [Sotto: capture + DeepFilterNet3 NC] → [Virtual mic (BlackHole)] → [Zoom/Meet/Discord]
```

- **Virtual audio device:** BlackHole 2ch (optional bundled .pkg; not committed — "Get BlackHole" falls back to existential.audio)
- **UI:** SwiftUI menu bar app (`MenuBarExtra`)
- **Audio:** AVAudioEngine + CoreAudio for device routing (48kHz f32 mono, 480-sample frames)
  - That is the NC and player format. The input tap is not resampled to it yet; see overview smell 3.
- **NC Engine:** DeepFilterNet3 via Rust static library + Swift C FFI

## Development

Prerequisites:
- Xcode 15+
- Rust toolchain (`rustup`). The first build needs network access, for the libDF git dependency; after that it is
  cached in `~/.cargo/git`.
- xcodegen (`brew install xcodegen`)
- The Apple Development identity for team `5QT5U69BN8` in the keychain, used for signing.

## Commands

```bash
# Build Rust library
cd DeepFilter && cargo build --release --locked

# NC acceptance tests (noise reduction, SI-SDR, latency, bypass, slider, perf)
cd DeepFilter && cargo test --release --locked -- --test-threads=1

# Regenerate Xcode project
xcodegen generate

# Build app (requires Xcode)
xcodebuild -scheme Sotto -configuration Debug build

# Run
open ~/Library/Developer/Xcode/DerivedData/Sotto-*/Build/Products/Debug/Sotto.app  # -scheme builds go to DerivedData, not ./build

# Test: SottoCoreTests runs headless; SottoTests (hosted) skips when there's no input device
xcodebuild -scheme Sotto -configuration Debug test

# Release build (arm64 only)
xcodebuild -scheme Sotto -configuration Release build

# Refresh the code graph (no LLM)
graphify update .
```

- The Xcode pre-build script **always** runs `cargo build --release --locked`, which takes about 0.5 s when nothing
  changed. It unsets `MACOSX_DEPLOYMENT_TARGET`, and `DeepFilter/.cargo/config.toml` pins that variable to 13.0, so
  Xcode and terminal builds share one cache. `DeepFilter/Cargo.lock` is committed and holds exact pins; see
  `knowledge/lessons/pin-transitive-deps-proven-in-spike.md`.
- There is no linter, formatter or CI, and no env vars, secrets or seed data. Settings live in `UserDefaults` under
  the keys `selectedDeviceUID`, `attenuation` and `hasCompletedOnboarding` (launch at login mirrors `SMAppService` status).

## Required Resources

Before building: nothing to add — the DeepFilterNet3 model ships in the repo.
1. `Sotto/Resources/DeepFilterNet3/` — `enc.onnx`, `erb_dec.onnx`, `df_dec.onnx`, `config.ini` (DeepFilterNet v0.5.6, committed). If missing, `AudioEngine` runs in passthrough.
2. Optional: `Sotto/Resources/BlackHole/BlackHole-2ch.pkg` — from existential.audio/blackhole (not committed; without it the app opens the BlackHole website)

## Code layout

This is the binding map. Put new code where its layer already lives.
- **App entry / scenes:** `Sotto/SottoApp.swift`. Launch-time work lives in `Sotto/AppDelegate.swift`: it owns
  `AudioManager` and registers the ⌘⇧N Carbon hotkey from `Sotto/GlobalHotkey.swift`.
- **State and orchestration:** `Sotto/Audio/AudioManager.swift`. This is the single `@MainActor ObservableObject`.
  It owns every UI-visible state and every `UserDefaults` write. It is injected with `.environmentObject`.
- **Audio pipeline (engine graph, tap, processing thread):** `Sotto/Audio/AudioEngine.swift` + `RingBuffer.swift`
- **NC seam (Swift ↔ Rust):** `Sotto/Audio/NCProcessor.swift` ↔ `Sotto/DeepFilter-Bridging-Header.h` ↔
  `DeepFilter/src/lib.rs`
- **Device discovery and hot-plug:** `Sotto/Models/AudioDevice.swift`, `Sotto/Audio/DeviceMonitor.swift`
- **Views (binding only, no logic):** `Sotto/Views/`
- **Design tokens:** none are centralised. They are inline system styles in `Sotto/Views/*.swift`, documented in
  `knowledge/design/style-guide.md`.
- **Model assets:** `Sotto/Resources/DeepFilterNet3/`
- **Build config:** `project.yml` is the source of truth. `Sotto.xcodeproj` is generated from it.
- **Knowledge base:** `knowledge/`. Product specs are in `_bmad-output/`.

## Project Structure

```
Sotto/
├── DeepFilter/              # Rust staticlib for DeepFilterNet3
│   ├── Cargo.toml, Cargo.lock   # exact libDF/tract pins
│   ├── .cargo/config.toml       # MACOSX_DEPLOYMENT_TARGET=13.0
│   ├── build.rs
│   ├── src/lib.rs               # thin FFI wrap over libDF DfTract
│   └── tests/nc_offline.rs      # NC acceptance tests (+ CMU ARCTIC fixtures)
├── Sotto/                   # Swift source
│   ├── Audio/               # AudioManager, AudioEngine, NCProcessor, DeviceMonitor, RingBuffer
│   ├── Models/              # AudioDevice
│   ├── Views/               # SottoMenuView, DevicePickerView, AudioLevelView, OnboardingView
│   ├── Resources/           # DeepFilterNet3 ONNX models + config.ini (committed); BlackHole/ (README; optional .pkg)
│   ├── Assets.xcassets      # AppIcon set (empty)
│   ├── SottoApp.swift
│   ├── AppDelegate.swift    # owns AudioManager, registers the hotkey at launch
│   ├── GlobalHotkey.swift   # Carbon RegisterEventHotKey (no Accessibility)
│   ├── Info.plist
│   ├── Sotto.entitlements
│   └── DeepFilter-Bridging-Header.h
├── Tests/
│   ├── Core/                # SottoCoreTests: unhosted, headless (NC smoke test)
│   └── App/                 # SottoTests: hosted, skips without an input device
├── _bmad-output/            # PRD, planned architecture, epics & stories
├── knowledge/               # daVinci knowledge base (architecture, domain features, best practices, design)
├── ADR-Sotto.md             # Architecture decision records
├── project.yml              # XcodeGen config
└── Sotto.xcodeproj          # Generated
```

<!-- ════════════ PROJECT RULES — the project's own; these WIN over the workflow baseline below ════════════ -->

## Key Decisions (see ADR-Sotto.md)

- **Local-only processing** — no audio leaves the device
- **Personal-use scope**: signed with a personal Apple Development identity (team `5QT5U69BN8`) so TCC grants stay
  stable. No sandboxing, notarization or distribution. See ADR-0006, amended 2026-10-04.
- **Platform:** macOS 13.0+ (SwiftUI + AVAudioEngine)
- **NC engine** — Rust staticlib for cross-platform reuse

## Project-specific rule overrides

- Where anything here conflicts with the workflow baseline below, **this section and Key Decisions win**.
- **`project.yml` is the source of truth.** Never hand-edit `Sotto.xcodeproj`. After adding, removing or renaming
  any source or resource, run `xcodegen generate` and include the regenerated project in the same change. The pbxproj
  at HEAD already missed `RingBuffer.swift` and the ONNX models.
- **Audio threads:** never run NC inference, block, or touch UI state in the input-tap callback. Pass audio through
  `RingBuffer` to the `SottoNCProcessing` thread, and reach the UI only through `Task { @MainActor in … }`. NC frames
  are exactly 480 Float32 mono samples. See `knowledge/best-practices/audio-threading.md`.
- **FFI boundary:** only `NCProcessor` calls `df_*`. The C header `Sotto/DeepFilter-Bridging-Header.h` is maintained
  by hand and must change in the same commit as any `extern "C"` signature in `DeepFilter/src/lib.rs`. No panics may
  cross the boundary. See `knowledge/best-practices/rust-ffi-boundary.md`.
- **What the Definition of Done means here:** "lint green" does not apply because there is no linter. "Build + tests
  green" means `xcodebuild … build` and `… test` both pass on a Mac with an audio input. For any NC or routing
  change, "verified end-to-end" means recording through BlackHole and confirming the noise is actually reduced, not
  just that audio passes through.
- `.claude/` is gitignored in this repo, so its skills and hooks are local-only. `CLAUDE.md` and `knowledge/` are
  tracked.

<!-- ════════════ daVinci WORKFLOW BASELINE — project-agnostic ════════════ -->

> ## ⛔ #1 RULE — NEVER tell the user to stop/settle when blocked
> When you hit a blocker, you do **NOT** say "that's good enough", "let's pause",
> or "do it later". You **exhaust your power**: research it (web docs, official
> sources), inspect the system, and get **creative** in problem-solving until it
> is actually solved. Suggesting the user give up on what they asked for is a
> failure. Keep going until the goal works.

## Workflow Orchestration

### 1. Plan Node Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately - don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One tack per subagent for focused execution

### 3. Self-Improvement Loop
- After ANY correction from the user: update knowledge/lessons/ with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes - don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests - then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. *Plan First*: Write plan to knowledge/tasks/ with checkable items
2. *Verify Plan*: Check in before starting implementation
3. *Track Progress*: Mark items complete as you go
4. *Explain Changes*: High-level summary at each step
5. *Document Results*: Add review section to the task plan in knowledge/tasks/
6. *Capture Lessons*: Update knowledge/lessons/ after corrections

## Core Principles

- *Simplicity First*: Make every change as simple as possible. Impact minimal code.
- *No Laziness*: Find root causes. No temporary fixes. Senior developer standards.
- *Minimal Impact*: Changes should only touch what's necessary. Avoid introducing bugs.
- *YAGNI*: Think like a senior dev, embrace the principle of You are not gonna need it. This is to avoid over engineering of things but making things simple as possible 
- *DRY*: Don't repeat yourself, check for every existing or similar code structure or components, check how you can abstract or extend it.
- *ASK WHEN YOU NEED HUMAN HELP*: Clarify with the user if you encounter a problem that you think the user will be able to help. Creative ideas, confirmations, being stuck on a problem. Think of them as your co-worker, ONLY ASK when you exhausted all your brain power and still don't solve it. Explain the context of your approach first and what have you already done for better context alignment.

## Continuous Best-Practice & Architecture Review

- Best practices and architecture are never "done" — revisit them on every non-trivial task, not just at project setup.
- Before committing to a design or pattern, research it like a senior developer would: check current official docs,
  known idioms for the stack in use, and
  known pitfalls — don't rely purely on training-data memory for anything that moves fast (API versions, SDK
  breaking changes, security guidance).
- When a better pattern is found, update this CLAUDE.md's architecture sections (and `knowledge/` docs) in the same
  change — don't let the written architecture drift from what's actually implemented.

### RULE — Best practice doc before anything genuinely new

Before implementing a feature, integration, or pattern that's genuinely new to this codebase (a new provider
integration, a new architectural pattern, the first use of a library/technique in the project — not a routine
addition following an already-established pattern), write the researched best-practice doc first:
`knowledge/best-practices/[topic].md`. Research it like a senior developer would (per above), write down the
approach and the reasoning, *then* implement against it. Every best-practice doc is checked against the baseline
developer principles (YAGNI, DRY, SOLID) in `knowledge/best-practices/index.md` — read that file first; it's the
folder's index, not just another entry.

## RULE — Feature Planning Must Separate by Domain

Every feature planned from the product docs **must** be filed under its own business/domain aspect — never as one
flat pile of feature notes. Structure, following the template already in the repo:

```
knowledge/product_docs/domain-features/[domain]-feature-brief/[name]-high_level_feature_brief.md
knowledge/product_docs/domain-features/[domain]-feature-brief/stories/
```

- `[domain]` = the business/domain aspect the feature belongs to, not a UI component or code module. Derive it from
  the product's capability areas — introduce a new domain only when a feature genuinely doesn't fit an existing
  one, and prefer reusing an existing domain folder over creating a near-duplicate.
- `[name]-high_level_feature_brief.md` is the single high-level brief for that feature: problem, scope, tie-back to
  the relevant product-doc section, and which domain entities/services it touches.
- `stories/` under the same domain-feature-brief folder holds the user stories broken down from that brief — keep
  stories next to the brief they came from, not in a separate global stories folder.
- Before writing a new brief, check whether the domain folder already exists and whether a similar brief is already
  there — extend/reference it instead of duplicating.
- Do not skip this structure for "small" features — a thin brief in the right domain folder is still required so the
  knowledge base stays navigable as it grows.

### RULE — The knowledge base is the northstar (specs/plans MUST be replicated into it)

Spec-driven development artifacts (specs in `knowledge/architecture/`, plans in `knowledge/tasks/`) do NOT replace
the domain knowledge base — they feed it. For every feature, in the same phase the work happens:
- **At spec time**: create/extend the domain feature brief and add/refresh the feature's row in
  `knowledge/product_docs/domain-features/index.md` (the registry: domain, tags, depends-on, status).
- **At plan time**: break the plan's user-facing capabilities into story files under the brief's `stories/` folder
  (thin is fine; an empty `stories/` folder for planned work is a bug).
- **At ship time**: flip the registry row to `done` ONLY when the standing Definition of Done in the registry's
  `index.md` (plus any per-row `DoD+`) is met, with the date.
Dependencies and tags between features live in the registry, since backlog items all pertain to one product.

## Loop Learning via the Knowledge Base

Claude is responsible for closing the learning loop using `knowledge/`, not just reading it passively:
- `knowledge/lessons/` — after any user correction or hard-won fix, write the pattern here so the same mistake isn't
  repeated in a future session (per the Self-Improvement Loop above).
- `knowledge/tasks/` — task plans and their outcomes/review notes live here (`todo.md`-style), so progress and
  decisions survive across sessions.
- `knowledge/architecture/` — record architecture decisions/diagrams here as they're made.
- `knowledge/best-practices/` — `index.md` holds the standing developer principles (YAGNI, DRY, SOLID); every other
  file is a per-topic best-practice doc written *before* implementing something genuinely new (per the RULE above),
  so research isn't repeated from scratch each time.
- `knowledge/product_docs/` — source of truth for product intent (the PRD / product spec; edit the source
  markdown) and, per the domain-feature rule above, `domain-features/` for feature briefs derived from it;
  reconcile against the product docs when a requirement seems to have changed instead of silently drifting from it.
- `knowledge/design/` — `style-guide.md` is the single source of truth for palette/typography/tokens; check it
  before styling any new surface instead of introducing colors/fonts ad hoc. `decisions.md` logs why a design
  choice was made (append-only). `syncs/` holds dated raw notes from design syncs — promote only the actual
  decisions from a sync into `decisions.md`. See `knowledge/design/index.md`.
- At the start of a session, check `knowledge/lessons/` and `knowledge/tasks/` for anything relevant before planning
  new work.
- Don't let this file accumulate decision-by-decision detail — park specific decisions/lessons in the right
  `knowledge/` subfolder and leave only a one-line pointer here.

## graphify (code/knowledge graph)

**graphify** is the approved on-device code/knowledge-graph tool (`github.com/Graphify-Labs/graphify`, MIT,
tree-sitter, no telemetry). It is already installed (`~/.local/bin/graphify`), and its skill and `/graphify` trigger
are registered globally (see `~/.claude/CLAUDE.md`). If you ever need to reinstall it, install it ISOLATED only, with
`uv tool install graphifyy` or `pipx install graphifyy`. NEVER use plain `pip … --break-system-packages`. Output
lives in `graphify-out/`: `graph.json`, `GRAPH_REPORT.md` and `graph.html`. `graphify update .` refreshes it without
an LLM. The graph also indexes the `.agent/` and `.kiro/` BMAD skill copies, so ignore those communities when you
read the report. Standing caveat: before running, confirm the skill's own instructions don't silently self-install
or say "don't ask the user". If they do, override that and install manually as described here.
