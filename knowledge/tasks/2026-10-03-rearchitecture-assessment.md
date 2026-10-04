# Task — Assessment: patch vs. restructure vs. redesign (before "make NC work")

## Goal
Decide, backed by evidence, how much of Sotto to keep, restructure or redesign before implementation starts. The
output is one decision doc, `knowledge/architecture/0001-rearchitecture-assessment.md`, with a recommendation per
lane, the cross-lane contracts, and ordered build slices that each have acceptance criteria. **No product code
changes in this task.**

## Plan
- [x] `dsp-engineer`, read-only plus a scratchpad experiment: assess `DeepFilter/`. Confirm smell 1 at runtime, then
      run a test build of the libDF `DfTract` wrap: does it build, how many dB of noise reduction, how many ms per
      frame, what is the size cost.
- [x] `coreaudio-engineer`, read-only plus a scratchpad experiment: assess `Sotto/Audio/`. Prove or disprove smell
      13, and test whether two engines (capture on the mic, render on BlackHole or another output) are feasible.
- [x] `macos-app-engineer`, read-only plus a build: assess the project structure, including XcodeGen targets,
      testability (whether to split out a core package), app lifecycle and state ownership (`AudioManager`),
      permissions and signing.
- [x] Orchestrator: combine the three into the decision doc. Resolve cross-lane contracts, order the slices, and
      list the decisions only the user can make.

## Verification
- Every claim in the decision doc cites a file or line, or experiment output that an agent actually ran.
- Each recommended option names its effort, its risk and its first verifiable slice.

## Outcome / Review
Done on 2026-10-03. The decision doc is
[`knowledge/architecture/0001-rearchitecture-assessment.md`](../architecture/0001-rearchitecture-assessment.md).

**Verdict:** not a rewrite.
- DSP: wrap libDF (S–M).
- Audio: redesign around two engines (M).
- App: light restructure (M).

The orchestrator re-ran these spikes and reproduced them: smell 1 (`Expected 5 got 1`, −2.26 dB), the window
ripple (6.02 dB), the libDF wrap (5/5 tests; SI-SDR +10.0 to +14.6 dB; bit-exact bypass; 1440 samples; p99
0.77 ms), and smell 13 (mic lost).

**Deviations:**
- The DSP agent stalled once, during a long cargo run, after about 10 minutes without progress. It was resumed
  with SendMessage, and the `/sotto-team` dispatch template now requires timeouts.
- The assumption "libDF matches our tract 0.21.15" was false. See the lesson
  [`pin-transitive-deps-proven-in-spike`](../lessons/pin-transitive-deps-proven-in-spike.md).

**Next:** the user answers D1–D3 and D10, then `/sotto-team` runs Phase 1.
