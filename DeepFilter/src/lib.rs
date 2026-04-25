use std::ffi::CStr;
use std::os::raw::c_char;
use std::ptr;

struct DeepFilterState {
    sr: usize,
    frame_size: usize,
}

#[no_mangle]
pub extern "C" fn df_create(model_path: *const c_char) -> *mut DeepFilterState {
    if model_path.is_null() {
        return ptr::null_mut();
    }

    let path = match unsafe { CStr::from_ptr(model_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };

    eprintln!("DeepFilter: Loading model from {}", path);

    let state = Box::new(DeepFilterState {
        sr: 48000,
        frame_size: 480,
    });

    Box::into_raw(state)
}

#[no_mangle]
pub extern "C" fn df_process(
    state: *mut DeepFilterState,
    _buffer: *mut f32,
    _frame_count: i32,
) {
    if state.is_null() {
        return;
    }
    // TODO: Implement DeepFilterNet3 inference
    // Currently passthrough - audio is unchanged
}

#[no_mangle]
pub extern "C" fn df_get_sample_rate(state: *const DeepFilterState) -> i32 {
    if state.is_null() {
        return 0;
    }
    let state = unsafe { &*state };
    state.sr as i32
}

#[no_mangle]
pub extern "C" fn df_get_frame_size(state: *const DeepFilterState) -> i32 {
    if state.is_null() {
        return 0;
    }
    let state = unsafe { &*state };
    state.frame_size as i32
}

#[no_mangle]
pub extern "C" fn df_destroy(state: *mut DeepFilterState) {
    if state.is_null() {
        return;
    }
    unsafe {
        let _ = Box::from_raw(state);
    }
}
