//! Spike: Sotto's C surface (same signatures as DeepFilter-Bridging-Header.h) over upstream libDF `DfTract`.
use std::ffi::CStr;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;

use df::tract::{DfParams, DfTract, RuntimeParams};
use ndarray::{ArrayView2, ArrayViewMut2};

pub const SR: i32 = 48_000;
pub const HOP: usize = 480;
/// STFT (fft 960 - hop 480) + model lookahead (2 hops), same as upstream enhance_wav delay compensation.
pub const LATENCY_SAMPLES: usize = 1440;

pub struct DeepFilterState {
    model: DfTract,
    noisy: Vec<f32>,
    bypass: bool,
    poisoned: bool,
    warned: bool,
}

fn load(model_path: *const c_char) -> Result<DfTract, String> {
    // NULL or a directory (what Swift passes today) -> embedded DFN3; otherwise a DFN3 *.tar.gz.
    let params = if model_path.is_null() {
        DfParams::default()
    } else {
        let s = unsafe { CStr::from_ptr(model_path) }.to_str().map_err(|e| e.to_string())?;
        let p = PathBuf::from(s);
        if p.is_dir() { DfParams::default() } else { DfParams::new(p).map_err(|e| format!("{e:#}"))? }
    };
    DfTract::new(params, &RuntimeParams::default_with_ch(1).with_atten_lim(100.).with_thresholds(-15., 35., 35.)).map_err(|e| format!("{e:#}"))
}

#[no_mangle]
pub extern "C" fn df_create(model_path: *const c_char) -> *mut DeepFilterState {
    match catch_unwind(|| load(model_path)) {
        Ok(Ok(model)) => Box::into_raw(Box::new(DeepFilterState {
            model,
            noisy: vec![0.0; HOP],
            bypass: false,
            poisoned: false,
            warned: false,
        })),
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

#[no_mangle]
pub extern "C" fn df_process(state: *mut DeepFilterState, buffer: *mut f32, frame_count: i32) {
    if state.is_null() || buffer.is_null() || frame_count != HOP as i32 {
        return;
    }
    let st = unsafe { &mut *state };
    let buf = unsafe { std::slice::from_raw_parts_mut(buffer, HOP) };
    if st.bypass || st.poisoned {
        return; // in place: untouched buffer is an exact copy-through
    }
    st.noisy.copy_from_slice(buf);
    let res = catch_unwind(AssertUnwindSafe(|| {
        let noisy = ArrayView2::from_shape((1, HOP), &st.noisy[..]).expect("fixed shape");
        let enh = ArrayViewMut2::from_shape((1, HOP), &mut buf[..]).expect("fixed shape");
        st.model.process(noisy, enh)
    }));
    match res {
        Ok(Ok(_lsnr)) => {}
        Ok(Err(e)) => {
            buf.copy_from_slice(&st.noisy);
            if !st.warned {
                st.warned = true;
                eprintln!("DeepFilter: process failed, passing through: {e:#}");
            }
        }
        Err(_) => {
            buf.copy_from_slice(&st.noisy);
            st.poisoned = true;
            eprintln!("DeepFilter: process panicked; passthrough until recreated");
        }
    }
}

/// 0 => exact bypass (model not run); (0,1] => atten_lim_db = a*100 (1.0 => unlimited).
#[no_mangle]
pub extern "C" fn df_set_attenuation(state: *mut DeepFilterState, attenuation: f32) {
    if state.is_null() || attenuation.is_nan() {
        return;
    }
    let st = unsafe { &mut *state };
    let a = attenuation.clamp(0.0, 1.0);
    st.bypass = a == 0.0;
    let _ = catch_unwind(AssertUnwindSafe(|| st.model.set_atten_lim(a * 100.0)));
}

#[no_mangle]
pub extern "C" fn df_get_sample_rate(_state: *const DeepFilterState) -> i32 {
    SR
}

#[no_mangle]
pub extern "C" fn df_get_frame_size(_state: *const DeepFilterState) -> i32 {
    HOP as i32
}

#[no_mangle]
pub extern "C" fn df_destroy(state: *mut DeepFilterState) {
    if !state.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(state) })));
    }
}
