//! Offline acceptance tests for the NC engine. They drive the exported `df_*` C functions in 480-sample blocks,
//! the same path Swift uses.
//!
//! Run: `cd DeepFilter && cargo test --release --locked -- --test-threads=1 --nocapture`
//! Speech: two unmodified CMU ARCTIC utterances (tests/fixtures/README.md). Noise: generated from fixed seeds.
//! Listening copies of the pink 0 dB SNR mix are written to `target/tmp/`.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::ffi::CString;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use deepfilter::*;

// Per-thread allocation counter. It documents that df_process allocates, so it must never run on an IO thread.
struct Counting;
thread_local! { static ALLOCS: Cell<u64> = const { Cell::new(0) }; }
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        ALLOCS.with(|c| c.set(c.get() + 1));
        System.alloc(l)
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        System.dealloc(p, l)
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        ALLOCS.with(|c| c.set(c.get() + 1));
        System.realloc(p, l, n)
    }
}
#[global_allocator]
static A: Counting = Counting;

const SR: usize = 48_000;
const WARM: usize = SR / 2;
const LAT: usize = LATENCY_SAMPLES;
const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures");
const BUNDLE_MODEL_DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../Sotto/Resources/DeepFilterNet3"
);

// ---------- signals ----------

fn white(n: usize, seed: u64) -> Vec<f32> {
    let mut s = seed;
    (0..n)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            (s >> 40) as f32 / (1u64 << 24) as f32 * 2.0 - 1.0
        })
        .collect()
}

/// Paul Kellet's economy pink filter.
fn pink(n: usize, seed: u64) -> Vec<f32> {
    let (mut b0, mut b1, mut b2) = (0f32, 0f32, 0f32);
    white(n, seed)
        .into_iter()
        .map(|w| {
            b0 = 0.99765 * b0 + w * 0.0990460;
            b1 = 0.96300 * b1 + w * 0.2965164;
            b2 = 0.57000 * b2 + w * 1.0526913;
            b0 + b1 + b2 + w * 0.1848
        })
        .collect()
}

/// White noise through two one-pole low-passes at 80 Hz: noise with almost no sample-to-sample curvature, so any
/// step introduced by a mode switch stands out in the second difference.
fn rumble(n: usize, seed: u64) -> Vec<f32> {
    let k = 1.0 - (-2.0 * std::f32::consts::PI * 80.0 / SR as f32).exp();
    let (mut y1, mut y2) = (0f32, 0f32);
    white(n, seed)
        .into_iter()
        .map(|w| {
            y1 += k * (w - y1);
            y2 += k * (y1 - y2);
            y2
        })
        .collect()
}

/// 16 kHz -> 48 kHz with a Hann-windowed sinc (24 input taps per side).
fn upsample3(x: &[f32]) -> Vec<f32> {
    use std::f64::consts::PI;
    const TAPS: isize = 24;
    (0..x.len() * 3)
        .map(|m| {
            let t = m as f64 / 3.0;
            let c = t.floor() as isize;
            let mut acc = 0.0;
            for k in (c - TAPS + 1).max(0)..=(c + TAPS).min(x.len() as isize - 1) {
                let d = t - k as f64;
                let sinc = if d == 0.0 {
                    1.0
                } else {
                    (PI * d).sin() / (PI * d)
                };
                acc += x[k as usize] as f64 * sinc * (0.5 + 0.5 * (PI * d / TAPS as f64).cos());
            }
            acc as f32
        })
        .collect()
}

/// Female + male ARCTIC utterance, about 6.6 s at 48 kHz.
fn speech() -> Vec<f32> {
    ["cmu_us_slt_arctic_a0003.wav", "cmu_us_bdl_arctic_a0003.wav"]
        .iter()
        .flat_map(|f| {
            let mut r = hound::WavReader::open(format!("{FIXTURES}/{f}")).expect("speech fixture");
            assert_eq!((r.spec().sample_rate, r.spec().channels), (16_000, 1));
            let x: Vec<f32> = r
                .samples::<i16>()
                .map(|s| s.unwrap() as f32 / 32768.0)
                .collect();
            upsample3(&x)
        })
        .collect()
}

fn power(x: &[f32]) -> f64 {
    x.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / x.len() as f64
}
fn db(p: f64) -> f64 {
    10.0 * p.log10()
}
fn scale_to_dbfs(mut x: Vec<f32>, target: f64) -> Vec<f32> {
    let g = 10f64.powf((target - db(power(&x))) / 20.0) as f32;
    x.iter_mut().for_each(|v| *v *= g);
    x
}
fn si_sdr(est: &[f32], reference: &[f32]) -> f64 {
    let dot = est
        .iter()
        .zip(reference)
        .map(|(e, r)| *e as f64 * *r as f64)
        .sum::<f64>();
    let a = dot / reference.iter().map(|r| (*r as f64).powi(2)).sum::<f64>();
    let (mut t, mut e) = (0f64, 0f64);
    for (y, r) in est.iter().zip(reference) {
        let target = a * *r as f64;
        t += target * target;
        e += (*y as f64 - target).powi(2);
    }
    db(t / e)
}
/// Level change of `out` vs `input`, both after the warm-up (stationary noise, so latency doesn't matter).
fn change_db(out: &[f32], input: &[f32]) -> f64 {
    db(power(&out[WARM..])) - db(power(&input[WARM..out.len()]))
}
/// `x` delayed by the engine latency, truncated to `n` samples.
fn delayed(x: &[f32], n: usize) -> Vec<f32> {
    let mut d = vec![0.0; LAT];
    d.extend_from_slice(&x[..n - LAT]);
    d
}
fn lag_of(x: &[f32], y: &[f32]) -> usize {
    let xcorr = |l: usize| {
        x[..x.len() - 3000]
            .iter()
            .zip(&y[l..])
            .map(|(p, q)| *p as f64 * *q as f64)
            .sum::<f64>()
    };
    (0..3000)
        .max_by(|&a, &b| xcorr(a).total_cmp(&xcorr(b)))
        .unwrap()
}
fn peak(y: &[f32]) -> f32 {
    y.iter().fold(0f32, |m, v| m.max(v.abs()))
}
fn assert_sane(label: &str, y: &[f32]) {
    assert!(
        y.iter().all(|v| v.is_finite()),
        "{label}: NaN/Inf in output"
    );
    assert!(peak(y) <= 1.0, "{label}: peak {} > 1.0", peak(y));
}
/// Largest |second difference| in `y[range]` re `reference_peak`, in dB. A step of size s shows up as s.
fn curvature_db(y: &[f32], range: std::ops::Range<usize>, reference_peak: f32) -> f64 {
    let m = range
        .map(|n| (y[n] - 2.0 * y[n - 1] + y[n - 2]).abs())
        .fold(0f32, f32::max);
    20.0 * (m as f64 / reference_peak as f64).log10()
}

// ---------- harness ----------

struct Run {
    out: Vec<f32>,
    ms: Vec<f64>,
    allocs: Vec<u64>,
}

/// Fresh engine (embedded model); `schedule(frame)` may set the attenuation before that frame is processed.
fn run_scheduled(input: &[f32], mut schedule: impl FnMut(usize) -> Option<f32>) -> Run {
    let h = df_create(std::ptr::null());
    assert!(!h.is_null(), "embedded model must load");
    let n = input.len() / HOP * HOP;
    let mut out = input[..n].to_vec();
    let (mut ms, mut allocs) = (vec![], vec![]);
    for (i, frame) in out.chunks_mut(HOP).enumerate() {
        if let Some(a) = schedule(i) {
            df_set_attenuation(h, a);
        }
        let a0 = ALLOCS.with(|c| c.get());
        let t = Instant::now();
        df_process(h, frame.as_mut_ptr(), HOP as i32);
        ms.push(t.elapsed().as_secs_f64() * 1e3);
        allocs.push(ALLOCS.with(|c| c.get()) - a0);
    }
    df_destroy(h);
    Run { out, ms, allocs }
}

fn run(atten: f32, input: &[f32]) -> Run {
    run_scheduled(input, |i| (i == 0).then_some(atten))
}

fn write_wav(name: &str, x: &[f32]) {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: SR as u32,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut w =
        hound::WavWriter::create(format!("{}/{name}", env!("CARGO_TARGET_TMPDIR")), spec).unwrap();
    x.iter().for_each(|v| w.write_sample(*v).unwrap());
    w.finalize().unwrap();
}

// ---------- tests ----------

#[test]
fn t1_load_and_boundary_safety() {
    let tmp = env!("CARGO_TARGET_TMPDIR");
    let loads = |path: Option<&[u8]>| {
        let c = path.map(|p| CString::new(p).unwrap());
        let h = df_create(c.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()));
        let ok = !h.is_null();
        df_destroy(h);
        ok
    };

    let t = Instant::now();
    assert!(loads(None));
    println!(
        "load: NULL -> embedded model ({:.0} ms create+destroy)",
        t.elapsed().as_secs_f64() * 1e3
    );
    assert!(loads(Some(FIXTURES.as_bytes())));
    println!("load: any directory -> embedded model");

    if std::path::Path::new(BUNDLE_MODEL_DIR)
        .join("config.ini")
        .exists()
    {
        assert!(loads(Some(BUNDLE_MODEL_DIR.as_bytes())));
        println!("load: bundle DeepFilterNet3/ dir (what Swift passes today) -> non-null");
        let tgz = format!("{tmp}/bundle_model.tar.gz");
        let mut tar = tar::Builder::new(flate2::write::GzEncoder::new(
            std::fs::File::create(&tgz).unwrap(),
            Default::default(),
        ));
        for f in ["config.ini", "enc.onnx", "erb_dec.onnx", "df_dec.onnx"] {
            tar.append_path_with_name(format!("{BUNDLE_MODEL_DIR}/{f}"), f)
                .unwrap();
        }
        tar.into_inner().unwrap().finish().unwrap();
        assert!(loads(Some(tgz.as_bytes())));
        println!("load: DFN3 tar.gz built from the bundle files -> non-null");
    } else {
        println!("load: bundle DeepFilterNet3/ assets not present; skipped the bundle-dir and tar.gz checks");
    }

    let garbage = format!("{tmp}/garbage.tar.gz");
    std::fs::write(&garbage, b"not gzip").unwrap();
    let no_config = format!("{tmp}/no_config.tar.gz");
    let mut gz = flate2::write::GzEncoder::new(
        std::fs::File::create(&no_config).unwrap(),
        Default::default(),
    );
    std::io::Write::write_all(&mut gz, &[0u8; 1024]).unwrap(); // an empty tar archive: libDF panics on the missing config
    gz.finish().unwrap();
    for bad in [
        "/nonexistent/model.tar.gz",
        garbage.as_str(),
        no_config.as_str(),
    ] {
        assert!(!loads(Some(bad.as_bytes())), "{bad} must fail");
        println!("load: {bad} -> NULL, no abort");
    }
    assert!(!loads(Some(b"/tmp/\xff\xfe.tar.gz")));
    println!("load: non-UTF-8 path -> NULL");

    let h = df_create(std::ptr::null());
    let mut buf = [0.25f32; HOP];
    df_process(std::ptr::null_mut(), buf.as_mut_ptr(), HOP as i32);
    df_process(h, std::ptr::null_mut(), HOP as i32);
    df_process(h, buf.as_mut_ptr(), HOP as i32 - 1);
    assert!(
        buf.iter().all(|v| *v == 0.25),
        "bad calls must leave the buffer untouched"
    );
    df_set_attenuation(std::ptr::null_mut(), 1.0);
    df_set_attenuation(h, f32::NAN);
    assert_eq!((df_get_sample_rate(h), df_get_frame_size(h)), (48_000, 480));
    assert_eq!(
        (
            df_get_sample_rate(std::ptr::null()),
            df_get_frame_size(std::ptr::null())
        ),
        (48_000, 480)
    );
    df_destroy(h);
    df_destroy(std::ptr::null_mut());
    println!(
        "boundary: NULL handle/buffer, frame_count 479, NaN attenuation, destroy(NULL) -> no-ops"
    );
}

#[test]
fn t2_bypass_is_input_delayed_by_latency() {
    let x = scale_to_dbfs(pink(SR * 3, 7), -30.0);
    let r = run(0.0, &x);
    let want = delayed(&x, r.out.len());
    let diff = r
        .out
        .iter()
        .zip(&want)
        .filter(|(a, b)| a.to_bits() != b.to_bits())
        .count();
    println!("bypass (atten 0): {diff} of {} samples differ from input delayed by {LAT} (bit-exact = {})", r.out.len(), diff == 0);
    assert_eq!(diff, 0);
}

#[test]
fn t3_noise_only() {
    for (name, noise, need_db) in [
        ("white", white(SR * 3, 0x5eed), 40.0),
        ("pink", pink(SR * 3, 0x5eed), 20.0),
    ] {
        let x = scale_to_dbfs(noise, -30.0);
        let r = run(1.0, &x);
        let red = change_db(&r.out, &x);
        println!("noise-only {name} @ -30 dBFS: out {:.2} dBFS, change {red:+.2} dB after 0.5 s (need <= -{need_db})", db(power(&r.out[WARM..])));
        assert_sane(name, &r.out);
        assert!(red <= -need_db);
    }
}

#[test]
fn t4_speech_quality_latency_and_perf() {
    let s = scale_to_dbfs(speech(), -23.0);
    println!(
        "speech: {:.2} s (CMU ARCTIC slt + bdl, upsampled to 48 kHz)",
        s.len() as f64 / SR as f64
    );

    let clean = run(1.0, &s);
    let lag = lag_of(&s, &clean.out);
    println!(
        "latency: xcorr(clean in, out) peaks at {lag} samples = {:.1} ms (LATENCY_SAMPLES = {LAT})",
        lag as f64 / 48.0
    );
    assert_eq!(lag, LAT);
    let n = clean.out.len() - LAT;
    let level = db(power(&clean.out[WARM + LAT..])) - db(power(&s[WARM..n]));
    println!(
        "clean speech: level change {level:+.2} dB (need within +-1), SI-SDR(out, clean) {:.1} dB",
        si_sdr(&clean.out[WARM + LAT..], &s[WARM..n])
    );
    assert_sane("clean", &clean.out);
    assert!(level.abs() <= 1.0);

    let (mut ms, mut allocs) = (clean.ms, clean.allocs);
    for (name, noise) in [("white", white(s.len(), 11)), ("pink", pink(s.len(), 11))] {
        for snr in [0.0, 5.0] {
            let nz = scale_to_dbfs(noise.clone(), -23.0 - snr);
            let x: Vec<f32> = s.iter().zip(&nz).map(|(a, b)| a + b).collect();
            let r = run(1.0, &x);
            let n = r.out.len() - LAT;
            let before = si_sdr(&x[WARM..n], &s[WARM..n]);
            let after = si_sdr(&r.out[WARM + LAT..], &s[WARM..n]);
            println!("speech + {name} @ {snr} dB SNR: SI-SDR {before:.2} -> {after:.2} dB ({:+.2} dB, need >= +6)", after - before);
            assert_sane("mix", &r.out);
            assert!(after - before >= 6.0);
            if name == "pink" && snr == 0.0 {
                write_wav("noisy_pink_0db.wav", &x);
                write_wav("enhanced_pink_0db.wav", &r.out);
            }
            ms.extend(r.ms);
            allocs.extend(r.allocs);
        }
    }

    ms.sort_by(f64::total_cmp);
    let mean = ms.iter().sum::<f64>() / ms.len() as f64;
    let p99 = ms[ms.len() * 99 / 100];
    println!(
        "perf over {} frames: mean {mean:.3} ms, p50 {:.3}, p99 {p99:.3}, max {:.3} ms/frame; RTF {:.3} (need p99 < 2 ms)",
        ms.len(), ms[ms.len() / 2], ms[ms.len() - 1], mean / 10.0
    );
    println!(
        "allocations per df_process: mean {:.0}, min {}, max {} -> never call it on an IO thread",
        allocs.iter().sum::<u64>() as f64 / allocs.len() as f64,
        allocs.iter().min().unwrap(),
        allocs.iter().max().unwrap()
    );
    assert!(p99 < 2.0);
}

#[test]
fn t5_slider_curve() {
    let x = scale_to_dbfs(pink(SR * 3, 0x5eed), -30.0);
    let mut reds: Vec<f64> = vec![];
    for a in [0.1f32, 0.25, 0.5, 0.75, 1.0] {
        let red = change_db(&run(a, &x).out, &x);
        println!(
            "slider {a:.2} -> atten_lim {:>5.1} dB: pink noise change {red:+.2} dB",
            atten_lim_db(a)
        );
        assert!(
            reds.last().is_none_or(|prev| red < *prev),
            "reduction must grow monotonically with the slider"
        );
        reds.push(red);
    }
    println!(
        "slider 0.5 vs 1.0: {:.2} dB apart (need >= 3)",
        reds[2] - reds[4]
    );
    assert!(reds[2] - reds[4] >= 3.0);

    // A tiny non-zero slider must still go through the model (libDF would otherwise switch to an undelayed copy).
    let r = run(1e-6, &x);
    let want = delayed(&x, r.out.len());
    let residual: Vec<f32> = r.out.iter().zip(&want).map(|(a, b)| a - b).collect();
    let res_db = db(power(&residual[WARM..])) - db(power(&want[WARM..]));
    println!("slider 1e-6 -> atten_lim {} dB: residual vs input delayed by {LAT} = {res_db:.1} dB (need <= -40)", atten_lim_db(1e-6));
    assert!(res_db <= -40.0);
}

#[test]
fn t6_toggle_crossfade_warm_model() {
    const OFF: usize = 150; // frame where bypass starts (1.5 s)
    const ON: usize = 300; // frame where NC resumes (3.0 s)
    let x = scale_to_dbfs(rumble(SR * 4, 3), -20.0);
    let toggled = run_scheduled(&x, |i| match i {
        0 | ON => Some(1.0),
        OFF => Some(0.0),
        _ => None,
    });
    let nc = run(1.0, &x).out;
    let dry = delayed(&x, toggled.out.len());
    let y = &toggled.out;
    let frames = |a: usize, b: usize| a * HOP..b * HOP;
    let differ = |r: std::ops::Range<usize>, want: &[f32]| {
        r.filter(|&i| y[i].to_bits() != want[i].to_bits()).count()
    };

    let before = differ(frames(0, OFF), &nc);
    let bypass = differ(frames(OFF + 1, ON), &dry);
    let after = differ(frames(ON + 1, y.len() / HOP), &nc);
    println!("toggle: before OFF {before} samples differ from always-on NC; bypass after crossfade {bypass} differ from input delayed by {LAT}; after ON+crossfade {after} differ from always-on NC (model kept warm)");
    assert_eq!((before, bypass, after), (0, 0, 0));

    let pk = peak(&x);
    let steady_nc = curvature_db(y, frames(100, 140), pk);
    let steady_dry = curvature_db(y, frames(200, 240), pk);
    for (label, f) in [("NC -> bypass", OFF), ("bypass -> NC", ON)] {
        let click = curvature_db(y, f * HOP - 2..(f + 1) * HOP + 2, pk);
        let hard = (f * HOP..(f + 1) * HOP)
            .map(|i| (dry[i] - nc[i]).abs())
            .fold(0f32, f32::max);
        let hard_db = 20.0 * (hard as f64 / pk as f64).log10();
        println!(
            "toggle {label}: max step {click:.1} dB re peak (steady NC {steady_nc:.1}, steady bypass {steady_dry:.1}); a hard switch in that frame could step by up to {hard_db:.1} dB (need crossfade < -40)"
        );
        assert!(
            hard_db > -20.0,
            "test signal must make NC and bypass differ, or the check proves nothing"
        );
        assert!(click < -40.0);
    }
    assert_sane("toggle", y);
}

#[test]
fn t7_concurrent_set_attenuation_stress() {
    let h = df_create(std::ptr::null());
    assert!(!h.is_null());
    let addr = h as usize;
    let stop = Arc::new(AtomicBool::new(false));
    let stores = Arc::new(AtomicU64::new(0));
    let setter = {
        let (stop, stores) = (stop.clone(), stores.clone());
        std::thread::spawn(move || {
            let values = [0.0f32, 0.3, 1.0, 0.75, 1e-6, f32::NAN, -1.0, 2.0, 0.5];
            let mut i = 0;
            while !stop.load(Ordering::Relaxed) {
                df_set_attenuation(addr as *mut DeepFilterState, values[i % values.len()]);
                i += 1;
                if i % 64 == 0 {
                    std::thread::yield_now();
                }
            }
            stores.store(i as u64, Ordering::Relaxed);
        })
    };
    let mut x = scale_to_dbfs(pink(SR * 3, 99), -20.0);
    x.truncate(x.len() / HOP * HOP);
    for frame in x.chunks_mut(HOP) {
        df_process(h, frame.as_mut_ptr(), HOP as i32);
    }
    stop.store(true, Ordering::Relaxed);
    setter.join().unwrap();
    df_destroy(h);
    println!("stress: {} set_attenuation calls from another thread during {} frames; output finite, peak {:.3}", stores.load(Ordering::Relaxed), x.len() / HOP, peak(&x));
    assert_sane("stress", &x);
}
