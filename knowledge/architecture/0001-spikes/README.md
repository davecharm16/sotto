# 0001 spikes: snapshot of the experiments behind the re-architecture assessment

These are throwaway experiments from 2026-10-03, copied out of a temporary scratchpad so the evidence survives. They
are **reference, not buildable as-is**. Paths are absolute to the old scratchpad, and the audio fixtures were not
kept. The implementation slices in [`../0001-rearchitecture-assessment.md`](../0001-rearchitecture-assessment.md)
should start from them.

| Path | What it proved |
|---|---|
| `dsp/current/tests/smell1.rs` | The current `lib.rs` fails all 600 frames with `Expected 5 got 1`, and output = input −2.26 dB. The window ripple is 6.02 dB. |
| `dsp/wrap/` (`Cargo.toml`, `src/lib.rs`, `tests/nc_offline.rs`) | A libDF `DfTract` wrap behind the existing `df_*` exports, with `catch_unwind` and exact tract pins. It passes 5 acceptance tests. |
| `coreaudio/probe13.swift` | The input and output nodes share one AUHAL unit. The device pinning in the WIP loses the mic. |
| `coreaudio/spike/{main,rt}.swift` | Two engines (capture sink on the mic, render source on another output) running at the same time. 0 allocations inside the blocks. |
| `coreaudio/ring.swift`, `spsc.h` | An SPSC ring on C atomics: 0 continuity errors across about 4 M samples, and chunking to 480 from any delivery size. |
| `coreaudio/offline/main.swift` | 44.1 kHz stereo in random chunks to exactly 480-frame, 48 kHz mono out, with 0 writes rejected. |
| `coreaudio/rtguard.c`, `hal.swift` | An `DYLD_INSERT_LIBRARIES` allocation guard, and HAL device helpers. |
| `app/unhosted/` | An unhosted XCTest target (no `TEST_HOST`) that links `-ldeepfilter` and runs ring and NC tests headless. |
