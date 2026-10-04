# Rust ↔ Swift FFI boundary (DeepFilter staticlib)

Backfilled on 2026-10-03 from `DeepFilter/src/lib.rs`, `Sotto/DeepFilter-Bridging-Header.h`,
`Sotto/Audio/NCProcessor.swift` and `project.yml`. Background is in ADR-0003 and ADR-0004 in `ADR-Sotto.md`.

## Contract
- **Opaque handle.** Rust owns `DeepFilterState`. Swift only ever holds `OpaquePointer?` and never sees the layout.
  `df_create` returns `Box::into_raw` (or null on failure), and `df_destroy` reclaims it with `Box::from_raw`.
- **One Swift owner.** `NCProcessor` is the only Swift type that calls `df_*`. Everything else goes through
  `NCProcessor` (`process`, `setAttenuation`, `shutdown`). Each method takes the `NSLock` and checks `isDestroyed`
  before it uses the handle.
- **The header is hand-written.** `Sotto/DeepFilter-Bridging-Header.h` is not generated (no cbindgen). Any change to
  a `#[no_mangle] pub extern "C"` signature in `lib.rs` must update the header in the same change.
- **Rust is defensive at the edge.** Every `extern "C"` function null-checks its pointers and returns quietly when
  the input is bad (null, `frame_count != 480`, non-UTF-8 path). Do not let a panic cross the boundary. The one
  `unwrap()` in `process_frame` sits on a fixed shape and is safe, but keep it that way.
- **Audio is processed in place.** `df_process(state, buffer, 480)` overwrites `buffer` with the processed frame.
- **Model location.** Swift finds `DeepFilterNet3/config.ini` in the bundle and passes that directory. Rust loads
  `enc.onnx`, `erb_dec.onnx` and `df_dec.onnx` from it. If the model is missing, `AudioEngine` runs NC-less in
  passthrough.

## Build gotchas
- The Xcode pre-build script (`project.yml`) runs `cargo build --release` **only if
  `DeepFilter/target/release/libdeepfilter.a` does not exist**. After you edit `lib.rs`, run
  `cd DeepFilter && cargo build --release` yourself, or Xcode will link the stale library without any warning.
- The crate is `crate-type = ["staticlib"]` with `lto = true` and `strip = true`. It is linked with `-ldeepfilter`
  from `$(PROJECT_DIR)/DeepFilter/target/release`.

## Principles check
- **DIP/ISP:** the Swift side depends on a 4-call C surface, not on tract or ndarray. That makes it possible to swap
  in another engine, for example the RNNoise fallback from ADR-0004, behind the same header.
- **YAGNI:** nothing calls `df_get_sample_rate` or `df_get_frame_size`. Either use them to assert the frame contract
  at startup or remove them. Do not add more unused exports.
