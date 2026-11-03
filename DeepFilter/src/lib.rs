//! Sotto's noise-cancellation engine: a thin C boundary over upstream libDF `DfTract` (DeepFilterNet3).
//!
//! Contract (mirrored in `Sotto/DeepFilter-Bridging-Header.h`):
//! - 48 kHz mono f32, `HOP` (480) samples per `df_process` call, processed in place.
//! - Output is the input delayed by `LATENCY_SAMPLES` (1440 = 480 STFT + 2 x 480 model lookahead), in every mode.
//! - `df_process` runs on ONE non-real-time thread: libDF allocates (~2,100 times per frame) and may log.
//! - `df_set_attenuation` may be called from any thread; it is an atomic store applied at the next frame.
//! - `df_destroy` only after the `df_process` thread has stopped.
//! - No panic crosses the boundary: every export body runs inside `catch_unwind` (since Rust 1.81 a panic escaping an
//!   `extern "C"` fn aborts the host app).

// The exports are a C ABI: their callers are C/Swift, which cannot see Rust's `unsafe`. Each one null-checks its
// pointers and documents the rest of its contract (live handle from df_create, HOP-sample buffer).
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::cell::UnsafeCell;
use std::f32::consts::PI;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicU32, Ordering};

use df::tract::{DfParams, DfTract, RuntimeParams};
use ndarray::{ArrayView2, ArrayViewMut2};

pub const SAMPLE_RATE: i32 = 48_000;
pub const HOP: usize = 480;
/// STFT (fft 960 - hop 480) + model lookahead (2 hops); same as upstream `enhance_wav` delay compensation.
pub const LATENCY_SAMPLES: usize = 1440;

/// Slider (0, 1) spans 0..40 dB of attenuation limit; the top of the slider means "no limit".
const MAX_LIMITED_DB: f32 = 40.0;
/// libDF treats >= 100 dB as "no limit".
const UNLIMITED_DB: f32 = 100.0;
/// libDF turns limits below 0.01 dB into an undelayed copy that skips the model, which would break the constant
/// latency. Never go below it.
const MIN_LIMIT_DB: f32 = 0.01;

/// Maps the UI slider `a` in (0, 1] to libDF's `atten_lim_db`: linear 0..40 dB, and 1.0 => unlimited.
/// `a <= 0` is bypass and never reaches the model.
pub fn atten_lim_db(a: f32) -> f32 {
    if a >= 1.0 {
        UNLIMITED_DB
    } else {
        (a * MAX_LIMITED_DB).max(MIN_LIMIT_DB)
    }
}

pub struct DeepFilterState {
    /// Requested slider value in [0, 1] as f32 bits. Written by `df_set_attenuation` from any thread, read once per
    /// frame by `df_process`.
    requested: AtomicU32,
    /// Only ever touched by the single `df_process` thread, and by `df_destroy` after that thread has stopped.
    engine: UnsafeCell<Engine>,
}

// SAFETY: `requested` is atomic. `engine` is only accessed from the one `df_process` thread and from `df_destroy`
// after it has been joined (the documented C contract), so there is never concurrent access to it.
unsafe impl Sync for DeepFilterState {}

struct Engine {
    model: DfTract,
    /// Raw input; the newest HOP samples are the current frame (the model's input), and `history[..HOP]` is that
    /// frame delayed by `LATENCY_SAMPLES` (the bypass signal).
    history: [f32; LATENCY_SAMPLES + HOP],
    wet: [f32; HOP],
    /// Raised cosine 0 -> 1 over one hop; the outgoing signal gets `1 - fade_in[i]`, so the gains sum to 1.
    fade_in: [f32; HOP],
    /// Slider value applied to the current mode, `None` until the first frame.
    applied: Option<f32>,
    bypass: bool,
    /// The model panicked; it may be inconsistent, so it is never run again (delayed passthrough until recreated).
    poisoned: bool,
    warned: bool,
}

impl Engine {
    fn new(model: DfTract) -> Self {
        let mut fade_in = [0.0; HOP];
        for (i, g) in fade_in.iter_mut().enumerate() {
            *g = 0.5 - 0.5 * (PI * (i as f32 + 0.5) / HOP as f32).cos();
        }
        Self {
            model,
            history: [0.0; LATENCY_SAMPLES + HOP],
            wet: [0.0; HOP],
            fade_in,
            applied: None,
            bypass: false,
            poisoned: false,
            warned: false,
        }
    }

    fn process(&mut self, buf: &mut [f32], requested: f32) {
        self.history[LATENCY_SAMPLES..].copy_from_slice(buf);

        let was_bypass = self.apply(requested);
        // The model runs in every mode so its GRU and normalisation state stay warm for an instant switch back.
        let wet_ok = self.run_model();

        let dry = &self.history[..HOP];
        let wet = &self.wet[..];
        if !wet_ok {
            buf.copy_from_slice(dry);
        } else if was_bypass == self.bypass {
            buf.copy_from_slice(if self.bypass { dry } else { wet });
        } else {
            let (from, to) = if self.bypass { (wet, dry) } else { (dry, wet) };
            for (i, out) in buf.iter_mut().enumerate() {
                let g = self.fade_in[i];
                *out = from[i] * (1.0 - g) + to[i] * g;
            }
        }
        self.history.copy_within(HOP.., 0);
    }

    /// Applies a changed slider value at this frame boundary. Returns the mode of the previous frame (on the very
    /// first frame, the requested mode, so there is nothing to crossfade from).
    fn apply(&mut self, requested: f32) -> bool {
        let was_bypass = if self.applied.is_some() {
            self.bypass
        } else {
            requested <= 0.0
        };
        if self.applied != Some(requested) {
            self.bypass = requested <= 0.0;
            // In bypass the model keeps its last limit; its output only matters during the crossfade out of it.
            if !self.bypass {
                self.model.set_atten_lim(atten_lim_db(requested));
            }
            self.applied = Some(requested);
        }
        was_bypass
    }

    /// Runs one hop through the model into `self.wet`. Returns false if `wet` must not be used.
    fn run_model(&mut self) -> bool {
        if self.poisoned {
            return false;
        }
        let (model, noisy, wet) = (
            &mut self.model,
            &self.history[LATENCY_SAMPLES..],
            &mut self.wet,
        );
        let run = || {
            let noisy =
                ArrayView2::from_shape((1, HOP), noisy).expect("1 x HOP view of a HOP buffer");
            let wet = ArrayViewMut2::from_shape((1, HOP), &mut wet[..])
                .expect("1 x HOP view of a HOP buffer");
            model.process(noisy, wet)
        };
        match catch_unwind(AssertUnwindSafe(run)) {
            Ok(Ok(_lsnr)) => true,
            Ok(Err(e)) => {
                if !self.warned {
                    self.warned = true;
                    eprintln!("DeepFilter: process failed, passing through (logged once): {e:#}");
                }
                false
            }
            Err(_) => {
                self.poisoned = true;
                eprintln!("DeepFilter: process panicked; delayed passthrough until the engine is recreated");
                false
            }
        }
    }
}

/// Runs an export body so that no panic can unwind into C.
fn ffi_guard<R>(fallback: R, body: impl FnOnce() -> R) -> R {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

fn load(model_path: *const c_char) -> Result<DfTract, String> {
    let params = if model_path.is_null() {
        DfParams::default()
    } else {
        let path = unsafe { CStr::from_ptr(model_path) }
            .to_str()
            .map_err(|_| "model path is not valid UTF-8".to_string())?;
        let path = Path::new(path);
        if path.is_dir() {
            // Legacy: Swift passes the bundled `DeepFilterNet3/` directory, which holds the same v0.5.6 model that is
            // embedded. libDF cannot load an extracted directory, so use the embedded copy.
            DfParams::default()
        } else {
            DfParams::new(path.to_path_buf()).map_err(|e| format!("{}: {e:#}", path.display()))?
        }
    };
    let runtime = RuntimeParams::default_with_ch(1)
        .with_atten_lim(UNLIMITED_DB)
        // Upstream `deep-filter` CLI defaults: zero mask below -15 dB LSNR, skip both stages above 35 dB.
        .with_thresholds(-15.0, 35.0, 35.0);
    DfTract::new(params, &runtime).map_err(|e| format!("{e:#}"))
}

/// Creates an engine. `model_path`: NULL or a directory => the embedded DeepFilterNet3 model; otherwise a
/// DeepFilterNet3 `*.tar.gz`. Returns NULL (never aborts) if loading fails. Takes ~170 ms: call it off the main thread.
#[no_mangle]
pub extern "C" fn df_create(model_path: *const c_char) -> *mut DeepFilterState {
    let create = || {
        load(model_path).map(|model| {
            Box::into_raw(Box::new(DeepFilterState {
                requested: AtomicU32::new(1.0f32.to_bits()),
                engine: UnsafeCell::new(Engine::new(model)),
            }))
        })
    };
    match catch_unwind(create) {
        Ok(Ok(state)) => state,
        Ok(Err(e)) => {
            eprintln!("DeepFilter: model load failed: {e}");
            ptr::null_mut()
        }
        Err(_) => {
            eprintln!("DeepFilter: model load panicked");
            ptr::null_mut()
        }
    }
}

/// Processes exactly `HOP` samples in place. Any other `frame_count`, or a NULL pointer, leaves `buffer` untouched.
#[no_mangle]
pub extern "C" fn df_process(state: *mut DeepFilterState, buffer: *mut f32, frame_count: i32) {
    if state.is_null() || buffer.is_null() || frame_count != HOP as i32 {
        return;
    }
    ffi_guard((), || {
        // SAFETY: non-null handle from df_create; the C contract gives this thread exclusive use of `engine`.
        let state = unsafe { &*state };
        let engine = unsafe { &mut *state.engine.get() };
        let buf = unsafe { std::slice::from_raw_parts_mut(buffer, HOP) };
        engine.process(buf, f32::from_bits(state.requested.load(Ordering::Relaxed)));
    })
}

/// 0 => bypass (input delayed by `LATENCY_SAMPLES`, model kept warm); (0, 1) => 0..40 dB attenuation limit;
/// 1 => unlimited. Clamped to [0, 1]; NaN is ignored. Safe from any thread; applied at the next `df_process` frame,
/// with a one-hop crossfade when entering or leaving bypass.
#[no_mangle]
pub extern "C" fn df_set_attenuation(state: *mut DeepFilterState, attenuation: f32) {
    if state.is_null() || attenuation.is_nan() {
        return;
    }
    ffi_guard((), || {
        // SAFETY: shared access only; `requested` is atomic.
        let state = unsafe { &*state };
        state
            .requested
            .store(attenuation.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    })
}

#[no_mangle]
pub extern "C" fn df_get_sample_rate(_state: *const DeepFilterState) -> i32 {
    ffi_guard(SAMPLE_RATE, || SAMPLE_RATE)
}

#[no_mangle]
pub extern "C" fn df_get_frame_size(_state: *const DeepFilterState) -> i32 {
    ffi_guard(HOP as i32, || HOP as i32)
}

#[no_mangle]
pub extern "C" fn df_destroy(state: *mut DeepFilterState) {
    if state.is_null() {
        return;
    }
    // SAFETY: pointer came from Box::into_raw in df_create; caller guarantees df_process has stopped.
    ffi_guard((), || drop(unsafe { Box::from_raw(state) }))
}
