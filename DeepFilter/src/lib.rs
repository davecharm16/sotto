use std::ffi::CStr;
use std::os::raw::c_char;
use std::path::Path;
use std::ptr;
use std::sync::Arc;

use ndarray::{Array1, Array3};
use num_complex::Complex32;
use realfft::{RealFftPlanner, RealToComplex, ComplexToReal};
use tract_onnx::prelude::*;

const SR: usize = 48000;
const FFT_SIZE: usize = 960;
const HOP_SIZE: usize = 480;
const FREQ_SIZE: usize = FFT_SIZE / 2 + 1;
const NB_ERB: usize = 32;
const NB_DF: usize = 96;
const DF_ORDER: usize = 5;

type TractModel = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

struct DeepFilterState {
    encoder: TractModel,
    erb_decoder: TractModel,
    df_decoder: TractModel,

    fft_forward: Arc<dyn RealToComplex<f32>>,
    fft_inverse: Arc<dyn ComplexToReal<f32>>,
    window: Vec<f32>,

    analysis_mem: Vec<f32>,
    synthesis_mem: Vec<f32>,

    erb_indices: Vec<usize>,
    erb_widths: Vec<usize>,

    enc_hidden: Array3<f32>,
    erb_hidden: Array3<f32>,
    df_hidden: Array3<f32>,
    df_coefs: Array3<Complex32>,

    attenuation: f32,
}

fn hann_window(size: usize) -> Vec<f32> {
    (0..size)
        .map(|i| {
            let x = std::f32::consts::PI * i as f32 / size as f32;
            x.sin().powi(2)
        })
        .collect()
}

fn erb_fb() -> (Vec<usize>, Vec<usize>) {
    let freq2erb = |f: f32| 9.265 * (f / (24.7 * 9.265)).ln_1p();
    let erb2freq = |e: f32| 24.7 * 9.265 * ((e / 9.265).exp() - 1.0);

    let nyq = SR as f32 / 2.0;
    let freq_width = SR as f32 / FFT_SIZE as f32;
    let erb_low = freq2erb(0.0);
    let erb_high = freq2erb(nyq);
    let step = (erb_high - erb_low) / NB_ERB as f32;

    let mut widths = vec![0usize; NB_ERB];
    let mut indices = vec![0usize; NB_ERB + 1];
    let mut prev_freq = 0usize;
    let mut freq_over = 0i32;
    let min_nb_freqs = 2i32;

    for i in 1..=NB_ERB {
        let f = erb2freq(erb_low + i as f32 * step);
        let fb = (f / freq_width).round() as usize;
        let mut nb_freqs = fb as i32 - prev_freq as i32 - freq_over;
        if nb_freqs < min_nb_freqs {
            freq_over = min_nb_freqs - nb_freqs;
            nb_freqs = min_nb_freqs;
        } else {
            freq_over = 0;
        }
        widths[i - 1] = nb_freqs as usize;
        indices[i] = indices[i - 1] + widths[i - 1];
        prev_freq = fb;
    }

    let total: usize = widths.iter().sum();
    if total < FREQ_SIZE {
        widths[NB_ERB - 1] += FREQ_SIZE - total;
    } else if total > FREQ_SIZE {
        widths[NB_ERB - 1] -= total - FREQ_SIZE;
    }

    indices[NB_ERB] = FREQ_SIZE;

    (indices, widths)
}

fn load_model(path: &Path) -> TractResult<TractModel> {
    tract_onnx::onnx()
        .model_for_path(path)?
        .into_optimized()?
        .into_runnable()
}

impl DeepFilterState {
    fn new(model_dir: &str) -> Option<Self> {
        let model_path = Path::new(model_dir);

        let encoder = load_model(&model_path.join("enc.onnx")).ok()?;
        let erb_decoder = load_model(&model_path.join("erb_dec.onnx")).ok()?;
        let df_decoder = load_model(&model_path.join("df_dec.onnx")).ok()?;

        let mut planner = RealFftPlanner::new();
        let fft_forward = planner.plan_fft_forward(FFT_SIZE);
        let fft_inverse = planner.plan_fft_inverse(FFT_SIZE);

        let window = hann_window(FFT_SIZE);
        let (erb_indices, erb_widths) = erb_fb();

        Some(Self {
            encoder,
            erb_decoder,
            df_decoder,
            fft_forward,
            fft_inverse,
            window,
            analysis_mem: vec![0.0; FFT_SIZE - HOP_SIZE],
            synthesis_mem: vec![0.0; FFT_SIZE - HOP_SIZE],
            erb_indices,
            erb_widths,
            enc_hidden: Array3::zeros((2, 1, 256)),
            erb_hidden: Array3::zeros((2, 1, 256)),
            df_hidden: Array3::zeros((2, 1, 256)),
            df_coefs: Array3::from_elem((DF_ORDER, 1, NB_DF), Complex32::new(0.0, 0.0)),
            attenuation: 1.0,
        })
    }

    fn stft(&mut self, input: &[f32]) -> Vec<Complex32> {
        let mut frame = vec![0.0f32; FFT_SIZE];

        // Overlap: previous samples + new samples
        frame[..FFT_SIZE - HOP_SIZE].copy_from_slice(&self.analysis_mem);
        frame[FFT_SIZE - HOP_SIZE..].copy_from_slice(input);

        // Store new samples for next frame
        self.analysis_mem.copy_from_slice(&frame[HOP_SIZE..]);

        // Apply window
        for (s, w) in frame.iter_mut().zip(self.window.iter()) {
            *s *= w;
        }

        let mut spectrum = vec![Complex32::new(0.0, 0.0); FREQ_SIZE];
        self.fft_forward.process(&mut frame, &mut spectrum).ok();

        spectrum
    }

    fn istft(&mut self, spectrum: &mut [Complex32]) -> Vec<f32> {
        let mut frame = vec![0.0f32; FFT_SIZE];
        self.fft_inverse.process(spectrum, &mut frame).ok();

        let norm = 1.0 / FFT_SIZE as f32;
        for (s, w) in frame.iter_mut().zip(self.window.iter()) {
            *s *= w * norm;
        }

        for i in 0..FFT_SIZE - HOP_SIZE {
            frame[i] += self.synthesis_mem[i];
        }
        self.synthesis_mem.copy_from_slice(&frame[HOP_SIZE..]);

        frame[..HOP_SIZE].to_vec()
    }

    fn compute_erb(&self, spectrum: &[Complex32]) -> Array1<f32> {
        let mut erb = Array1::zeros(NB_ERB);
        for (band, &width) in self.erb_widths.iter().enumerate() {
            let start = self.erb_indices[band];
            let end = start + width;
            let mut sum = 0.0f32;
            for i in start..end.min(FREQ_SIZE) {
                sum += spectrum[i].norm_sqr();
            }
            erb[band] = (sum / width as f32 + 1e-10).sqrt();
        }
        erb
    }

    fn apply_erb_mask(&self, spectrum: &mut [Complex32], mask: &Array1<f32>) {
        for (band, &width) in self.erb_widths.iter().enumerate() {
            let start = self.erb_indices[band];
            let end = start + width;
            let gain = mask[band].max(0.0).min(1.0);
            let gain = 1.0 - self.attenuation * (1.0 - gain);
            for i in start..end.min(FREQ_SIZE) {
                spectrum[i] *= gain;
            }
        }
    }

    fn process_frame(&mut self, input: &[f32]) -> Vec<f32> {
        let mut spectrum = self.stft(input);
        let erb = self.compute_erb(&spectrum);

        let erb_input: Tensor = tract_ndarray::Array3::from_shape_vec(
            (1, 1, NB_ERB),
            erb.to_vec()
        ).unwrap().into();

        if let Ok(result) = self.erb_decoder.run(tvec!(erb_input.into())) {
            if let Ok(mask_arr) = result[0].to_array_view::<f32>() {
                let mask = Array1::from_iter(mask_arr.iter().take(NB_ERB).cloned());
                self.apply_erb_mask(&mut spectrum, &mask);
            }
        }

        self.istft(&mut spectrum)
    }
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

    eprintln!("DeepFilter: Loading models from {}", path);

    match DeepFilterState::new(path) {
        Some(state) => Box::into_raw(Box::new(state)),
        None => {
            eprintln!("DeepFilter: Failed to load models");
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn df_process(
    state: *mut DeepFilterState,
    buffer: *mut f32,
    frame_count: i32,
) {
    if state.is_null() || buffer.is_null() || frame_count <= 0 {
        return;
    }

    let state = unsafe { &mut *state };
    let frame_count = frame_count as usize;

    if frame_count != HOP_SIZE {
        return;
    }

    let input = unsafe { std::slice::from_raw_parts(buffer, frame_count) };
    let output = state.process_frame(input);

    let out_slice = unsafe { std::slice::from_raw_parts_mut(buffer, frame_count) };
    out_slice.copy_from_slice(&output);
}

#[no_mangle]
pub extern "C" fn df_set_attenuation(state: *mut DeepFilterState, attenuation: f32) {
    if state.is_null() {
        return;
    }
    let state = unsafe { &mut *state };
    state.attenuation = attenuation.max(0.0).min(1.0);
}

#[no_mangle]
pub extern "C" fn df_get_sample_rate(_state: *const DeepFilterState) -> i32 {
    SR as i32
}

#[no_mangle]
pub extern "C" fn df_get_frame_size(_state: *const DeepFilterState) -> i32 {
    HOP_SIZE as i32
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
