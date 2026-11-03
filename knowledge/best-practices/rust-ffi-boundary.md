# Rust ↔ Swift FFI boundary (DeepFilter staticlib)

Backfilled on 2026-10-03. Rewritten on 2026-10-04 for the libDF wrap (Phase 1, D1, D2 and D7), from
`DeepFilter/src/lib.rs`, `DeepFilter/tests/nc_offline.rs` and `Sotto/DeepFilter-Bridging-Header.h`. Background is in
ADR-0003 and ADR-0004 in `ADR-Sotto.md`, and in §4 (C2, C3, C5, C9) of
[`0001-rearchitecture-assessment.md`](../architecture/0001-rearchitecture-assessment.md).

## Contract
- **Engine.** `DeepFilter/` is Sotto's own thin layer over upstream libDF `DfTract` (DeepFilterNet git rev
  `d375b2d8`, features `tract` + `default-model`). We never enable libDF's `capi` feature: its `df_create` clashes
  with ours and it panics across FFI.
- **Opaque handle.** Rust owns `DeepFilterState`. Swift only holds `OpaquePointer?`. `df_create` returns
  `Box::into_raw`, or NULL on any failure. `df_destroy` reclaims it.
- **Model location.** `df_create(NULL)` uses the model **embedded** in the `.a` (v0.5.6 DeepFilterNet3, about
  7.9 MB). A directory path, which is what Swift passes today, also gets the embedded model. Any other path is loaded
  as a DeepFilterNet3 `*.tar.gz`. libDF can't load an extracted directory. Once Swift passes NULL,
  `Resources/DeepFilterNet3` is dead weight (C10). Creating an engine takes about 170 ms, so call it off the main
  thread.
- **Frames.** `df_process(state, buffer, 480)` processes 48 kHz mono float in place. Any other `frame_count`, or a
  NULL pointer, leaves the buffer untouched.
- **Latency is constant: 1440 samples (30 ms)** = 480 (STFT) + 2 × 480 (model lookahead). This holds in every mode:
  NC, bypass, every slider value, and failure passthrough.
- **Threading.**
  - `df_process` runs on **one** non-real-time thread. libDF allocates about 2,100 times per frame and may log, so it
    must never run on a CoreAudio IO thread.
  - `df_set_attenuation` is safe from any thread. It's a relaxed atomic store that the next `df_process` frame applies.
    Swift needs no lock for attenuation or bypass.
  - `df_destroy` runs only after the `df_process` thread has been joined.
  - Inside Rust, the per-frame state sits in an `UnsafeCell` that only the `df_process` thread touches. That is
    sound only under this contract.
- **Attenuation.** `0` is bypass. `(0, 1)` maps linearly onto libDF `atten_lim_db` 0–40 dB, and `1` means no limit.
  Values are clamped to [0, 1], and NaN is ignored. Non-zero values never go below 0.01 dB, because libDF turns a
  limit under 0.01 dB into an *undelayed* copy that skips the model, which would break the constant latency.
- **Bypass lives in Rust (C5).** The output is the input delayed by 1440 samples, bit-exact. The model keeps running
  so its GRU and normalisation state stay warm. Entering or leaving bypass crossfades over one 480-sample hop with a
  raised cosine. Changing the slider between non-zero values needs no crossfade, because libDF mixes the limit
  per frame in the STFT domain and overlap-add smooths it.
- **Gating** uses the upstream CLI thresholds: LSNR −15 dB (zero mask), 35 dB (skip ERB stage) and 35 dB (skip the
  deep-filter stage).

## No panic crosses the boundary
- Every export body runs inside `catch_unwind`. Since Rust 1.81, a panic that escapes an `extern "C"` fn aborts the
  whole app. libDF `unwrap`s freely: a tarball without `config.ini` panics inside `DfTract::new`, for example.
- `df_create` turns an error or a panic into NULL, with one `eprintln`.
- In `df_process`:
  - A model error gives delayed passthrough for that frame, and is logged once.
  - A model panic **poisons** the engine. The model is never run again, and the output stays as delayed passthrough
    until the engine is recreated.
- `[profile.release]` must stay `panic = "unwind"` (the default), or `catch_unwind` does nothing.
- Don't add `if let Ok` that discards an error silently. Log once, or return a status.

## Build
- **Exact pins.** Use `tract-* = "=0.21.4"` and `kstring = "=2.0.2"`, as the spike proved (see
  [`../lessons/pin-transitive-deps-proven-in-spike.md`](../lessons/pin-transitive-deps-proven-in-spike.md)).
  `DeepFilter/Cargo.lock` is committed, so the root `.gitignore` must not ignore it. Build with `--locked`. The first
  build needs the network to fetch the libDF git rev; after that it builds from `~/.cargo/git`.
- **Crate types.** `crate-type = ["staticlib", "rlib"]`. The `rlib` exists so `tests/nc_offline.rs` can call the
  exports. Build arm64 only (user decision D2).
- **No LTO.** Cargo can't LTO a lib whose crate types include `rlib`. `lto = true` only LTO'd the test binaries and
  padded the `.a` with embedded LLVM bitcode, 123.6 MB against 47.5 MB now. Xcode's `nm` can't read that bitcode.
  Measured through the C ABI, an LTO'd staticlib-only build is no faster (about 0.68 ms/frame either way); it only
  links about 5 MB smaller. That difference isn't worth a workspace split.
- **Deployment target.** `DeepFilter/.cargo/config.toml` sets `MACOSX_DEPLOYMENT_TARGET=13.0` for every cargo run.
  Without it, tract-linalg's `cc`-built SIMD kernels are stamped with the host SDK version (macOS 26.0), and ld warns
  once per object. tract-linalg tracks the variable, so callers must not pass a different value. A different value
  forces a multi-minute rebuild.
- **Header.** The header is hand-written. Change it in the same commit as any `#[no_mangle] pub extern "C"`
  signature. Comments in it document the contract above.
- **Timings.** A clean `cargo build --release --locked` takes about 1 m 45 s, and a no-op one about 0.5 s. Before
  Phase 1 S0, Xcode only ran cargo when `libdeepfilter.a` was missing, and silently linked a stale library.

## Proof
Run `cd DeepFilter && cargo test --release --locked -- --test-threads=1 --nocapture`. It drives the exported
functions in 480-sample blocks, using two CMU ARCTIC utterances (`tests/fixtures/`, about 210 KB, free-use licence)
and seeded noise. It covers:
- load and NULL safety;
- bit-exact delayed bypass;
- noise-only reduction (white ≤ −40 dB, pink ≤ −20 dB);
- SI-SDR ≥ +6 dB at 0 and 5 dB SNR;
- clean level within ±1 dB, and latency 1440 by cross-correlation;
- p99 < 2 ms/frame;
- a monotonic slider curve;
- a toggle with a warm model and no step above −40 dB;
- a concurrent `df_set_attenuation` stress test.

TSan wasn't run, because no nightly toolchain is installed. The concurrency claim rests on the design (one atomic,
plus an `UnsafeCell` with a single owner) and on the stress test.

## Principles check
- **DIP/ISP:** Swift depends on a 4-call C surface, not on tract, ndarray or libDF. That's why the engine could be
  swapped without touching Swift.
- **YAGNI:** Swift still never calls `df_get_sample_rate` or `df_get_frame_size`. They stay because removing them
  changes the header. Either use them to assert the frame contract at startup, or drop them in a header change. Don't
  add more unused exports.
