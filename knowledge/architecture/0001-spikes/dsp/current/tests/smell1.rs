use std::ffi::CString;
use std::sync::atomic::Ordering;
use deepfilter::*;

const MODEL: &str = "/Users/davecharm.bulaquena/Documents/personal/sotto/Sotto/Resources/DeepFilterNet3";

fn noise(n: usize, seed: u64, amp: f32) -> Vec<f32> {
    let mut s = seed;
    (0..n).map(|_| { s ^= s << 13; s ^= s >> 7; s ^= s << 17; ((s >> 40) as f32 / (1u64 << 24) as f32 * 2.0 - 1.0) * amp }).collect()
}
fn rms_db(x: &[f32]) -> f64 { 10.0 * (x.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / x.len() as f64).log10() }

#[test]
fn smell1_runtime() {
    use tract_onnx::prelude::*;
    for f in ["enc.onnx", "erb_dec.onnx", "df_dec.onnx"] {
        let m = tract_onnx::onnx().model_for_path(format!("{MODEL}/{f}")).unwrap();
        let ins: Vec<String> = m.input_outlets().unwrap().iter().map(|o| format!("{}:{:?}", m.node(o.node).name, m.outlet_fact(*o).unwrap().shape)).collect();
        let outs: Vec<String> = m.output_outlets().unwrap().iter().map(|o| format!("{}:{:?}", m.node(o.node).name, m.outlet_fact(*o).unwrap().shape)).collect();
        println!("{f}: inputs {ins:?}\n          outputs {outs:?}");
    }
    let p = CString::new(MODEL).unwrap();
    let h = df_create(p.as_ptr());
    assert!(!h.is_null());
    for (atten, label) in [(1.0f32, "atten=1.0"), (0.0, "atten=0.0 (bypass)")] {
        let st = df_create(p.as_ptr());
        df_set_attenuation(st, atten);
        let x = noise(48000 * 3, 0x5eed, 0.1);
        let mut y = x.clone();
        for c in y.chunks_mut(480) { df_process(st, c.as_mut_ptr(), 480); }
        let (xi, yi) = (&x[24000..x.len() - 960], &y[24000 + 480..x.len() - 480]);
        let null: Vec<f32> = xi.iter().zip(yi).map(|(a, b)| b - a).collect();
        println!("{label}: in {:.2} dBFS, out {:.2} dBFS, out-in {:+.2} dB, null residual (480-delay) {:+.2} dB rel. input, peak-to-trough of per-sample gain envelope seen in resynth",
            rms_db(xi), rms_db(yi), rms_db(yi) - rms_db(xi), rms_db(&null) - rms_db(xi));
        df_destroy(st);
    }
    println!("erb_decoder.run: ok={} err={}", ERB_OK.load(Ordering::Relaxed), ERB_ERR.load(Ordering::Relaxed));
    // WOLA gain of sin^2 analysis * sin^2 synthesis at 50% overlap, per sample position in hop
    let w: Vec<f64> = (0..960).map(|i| (std::f64::consts::PI * i as f64 / 960.0).sin().powi(2)).collect();
    let g: Vec<f64> = (0..480).map(|i| w[i] * w[i] + w[i + 480] * w[i + 480]).collect();
    println!("WOLA sum w^2: min {:.3} max {:.3} -> ripple {:.2} dB", g.iter().cloned().fold(9.0, f64::min), g.iter().cloned().fold(0.0, f64::max),
        20.0 * (g.iter().cloned().fold(0.0, f64::max) / g.iter().cloned().fold(9.0, f64::min)).log10());
    df_destroy(h);
}
