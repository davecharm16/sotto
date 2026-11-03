use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::ffi::CString;
use std::time::Instant;
use deepfilter::*;

// Per-thread allocation counter, to prove/disprove allocation inside df_process.
struct Counting;
thread_local! { static ALLOCS: Cell<u64> = const { Cell::new(0) }; }
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 { ALLOCS.with(|c| c.set(c.get() + 1)); System.alloc(l) }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) { System.dealloc(p, l) }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 { ALLOCS.with(|c| c.set(c.get() + 1)); System.realloc(p, l, n) }
}
#[global_allocator]
static A: Counting = Counting;

const FIX: &str = "/private/tmp/claude-1318076561/-Users-davecharm-bulaquena-Documents-personal-sotto/4f8c62c8-ae52-46ff-bfa1-d7bea9efc95b/scratchpad/dsp-spike/fixtures";
const WARM: usize = 24_000; // 0.5 s

fn xorshift(n: usize, seed: u64) -> Vec<f32> {
    let mut s = seed;
    (0..n).map(|_| { s ^= s << 13; s ^= s >> 7; s ^= s << 17; (s >> 40) as f32 / (1u64 << 24) as f32 * 2.0 - 1.0 }).collect()
}
fn pink(n: usize, seed: u64) -> Vec<f32> { // Paul Kellet economy pink filter
    let (mut b0, mut b1, mut b2) = (0f32, 0f32, 0f32);
    xorshift(n, seed).into_iter().map(|w| { b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913; b0 + b1 + b2 + w * 0.1848 }).collect()
}
fn power(x: &[f32]) -> f64 { x.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / x.len() as f64 }
fn db(p: f64) -> f64 { 10.0 * p.log10() }
fn scale_to_dbfs(mut x: Vec<f32>, target: f64) -> Vec<f32> { let g = 10f64.powf((target - db(power(&x))) / 20.0) as f32; x.iter_mut().for_each(|v| *v *= g); x }
fn si_sdr(est: &[f32], s: &[f32]) -> f64 {
    let a = est.iter().zip(s).map(|(e, r)| *e as f64 * *r as f64).sum::<f64>() / s.iter().map(|r| (*r as f64).powi(2)).sum::<f64>();
    let (mut t, mut e) = (0f64, 0f64);
    for (y, r) in est.iter().zip(s) { let tr = a * *r as f64; t += tr * tr; e += (*y as f64 - tr).powi(2); }
    db(t / e)
}
fn speech() -> Vec<f32> { hound::WavReader::open(format!("{FIX}/speech.wav")).unwrap().samples::<f32>().map(|s| s.unwrap()).collect() }

struct Run { out: Vec<f32>, ms: Vec<f64>, allocs: Vec<u64> }
fn run(atten: f32, input: &[f32]) -> Run {
    let h = df_create(std::ptr::null());
    assert!(!h.is_null());
    df_set_attenuation(h, atten);
    let n = input.len() / HOP * HOP;
    let mut out = input[..n].to_vec();
    let (mut ms, mut allocs) = (vec![], vec![]);
    for c in out.chunks_mut(HOP) {
        let a0 = ALLOCS.with(|c| c.get());
        let t = Instant::now();
        df_process(h, c.as_mut_ptr(), HOP as i32);
        ms.push(t.elapsed().as_secs_f64() * 1e3);
        allocs.push(ALLOCS.with(|c| c.get()) - a0);
    }
    df_destroy(h);
    Run { out, ms, allocs }
}
fn sane(label: &str, y: &[f32]) {
    let peak = y.iter().fold(0f32, |m, v| m.max(v.abs()));
    assert!(y.iter().all(|v| v.is_finite()), "{label}: NaN/Inf");
    println!("  {label}: finite=yes peak={peak:.3}");
    assert!(peak <= 1.0);
}
fn lag_of(x: &[f32], y: &[f32]) -> usize {
    (0..4800).max_by(|&a, &b| {
        let c = |l: usize| x[..x.len() - 4800].iter().zip(&y[l..]).map(|(p, q)| *p as f64 * *q as f64).sum::<f64>();
        c(a).partial_cmp(&c(b)).unwrap()
    }).unwrap()
}

#[test]
fn t1_load() {
    let ok = |p: Option<&str>| { let c = p.map(|s| CString::new(s).unwrap()); let h = df_create(c.as_ref().map_or(std::ptr::null(), |c| c.as_ptr())); let r = !h.is_null(); df_destroy(h); r };
    let bundle = "/Users/davecharm.bulaquena/Documents/personal/sotto/Sotto/Resources/DeepFilterNet3";
    let t = Instant::now();
    assert!(ok(None));
    println!("load: NULL->embedded ok ({:.0} ms create+destroy)", t.elapsed().as_secs_f64() * 1e3);
    assert!(ok(Some(bundle))); println!("load: bundle dir (what Swift passes today) -> non-null");
    for bad in ["/nonexistent/x.tar.gz", &format!("{FIX}/garbage.tar.gz"), &format!("{FIX}/no_config.tar.gz")] {
        assert!(!ok(Some(bad))); println!("load: {bad} -> NULL, no abort");
    }
}

#[test]
fn t2_bypass_exact() {
    let x = scale_to_dbfs(pink(48_000 * 3, 7), -30.0);
    let r = run(0.0, &x);
    let diff = r.out.iter().zip(&x).filter(|(a, b)| a.to_bits() != b.to_bits()).count();
    println!("bypass atten=0: {diff} of {} samples differ (bit-exact={}) ; mean {:.4} ms/frame", r.out.len(), diff == 0, r.ms.iter().sum::<f64>() / r.ms.len() as f64);
    assert_eq!(diff, 0);
}

#[test]
fn t3_noise_only() {
    for (name, n) in [("white", xorshift(48_000 * 3, 0x5eed)), ("pink", pink(48_000 * 3, 0x5eed))] {
        let x = scale_to_dbfs(n, -30.0);
        let r = run(1.0, &x);
        let red = db(power(&r.out[WARM..])) - db(power(&x[WARM..r.out.len()]));
        println!("noise-only {name} @-30 dBFS: in {:.2} dBFS, out {:.2} dBFS, change {red:+.2} dB (after 0.5 s warm-up)", db(power(&x[WARM..])), db(power(&r.out[WARM..])));
        sane(name, &r.out);
        assert!(red <= -15.0);
    }
}

#[test]
fn t4_speech_and_perf() {
    let s = scale_to_dbfs(speech(), -23.0);
    let clean = run(1.0, &s);
    let lag = lag_of(&s, &clean.out);
    println!("latency (xcorr clean in vs out): {lag} samples = {:.1} ms (constant {LATENCY_SAMPLES})", lag as f64 / 48.0);
    let n = clean.out.len() - LATENCY_SAMPLES;
    let lvl = db(power(&clean.out[WARM + LATENCY_SAMPLES..])) - db(power(&s[WARM..n]));
    println!("clean speech level change: {lvl:+.2} dB ; SI-SDR(out vs clean) {:.1} dB", si_sdr(&clean.out[WARM + LATENCY_SAMPLES..], &s[WARM..n]));
    sane("clean", &clean.out);
    let mut all_ms = vec![]; let mut all_allocs = vec![];
    for (nname, noise) in [("white", xorshift(s.len(), 11)), ("pink", pink(s.len(), 11))] {
        for snr in [0.0, 5.0] {
            let nz = scale_to_dbfs(noise.clone(), -23.0 - snr);
            let x: Vec<f32> = s.iter().zip(&nz).map(|(a, b)| a + b).collect();
            let r = run(1.0, &x);
            let n = r.out.len() - LATENCY_SAMPLES;
            let before = si_sdr(&x[WARM..n], &s[WARM..n]);
            let after = si_sdr(&r.out[WARM + LATENCY_SAMPLES..], &s[WARM..n]);
            println!("speech+{nname} @ {snr} dB SNR: SI-SDR {before:.2} -> {after:.2} dB ({:+.2} dB)", after - before);
            sane("mix", &r.out);
            assert!(after - before >= 6.0);
            if nname == "pink" && snr == 0.0 {
                let w = |p: &str, d: &[f32]| { let mut wr = hound::WavWriter::create(format!("{FIX}/{p}"), hound::WavSpec { channels: 1, sample_rate: 48000, bits_per_sample: 32, sample_format: hound::SampleFormat::Float }).unwrap(); d.iter().for_each(|v| wr.write_sample(*v).unwrap()); wr.finalize().unwrap(); };
                w("noisy_pink_0db.wav", &x); w("spike_enh_pink_0db.wav", &r.out);
            }
            all_ms.extend(r.ms); all_allocs.extend(r.allocs);
        }
    }
    let mut ms = all_ms.clone(); ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mean = ms.iter().sum::<f64>() / ms.len() as f64;
    println!("perf over {} frames: mean {mean:.3} ms, p50 {:.3}, p99 {:.3}, max {:.3} ms/frame; RTF {:.3}", ms.len(), ms[ms.len() / 2], ms[ms.len() * 99 / 100], ms[ms.len() - 1], mean / 10.0);
    let zero = all_allocs.iter().filter(|&&a| a == 0).count();
    println!("allocations in df_process: mean {:.1}/frame, min {}, max {}, zero-alloc frames {zero}/{}", all_allocs.iter().sum::<u64>() as f64 / all_allocs.len() as f64, all_allocs.iter().min().unwrap(), all_allocs.iter().max().unwrap(), all_allocs.len());
    assert!(mean < 2.0);
}

#[test]
fn t5_slider_mapping() {
    let x = scale_to_dbfs(pink(48_000 * 3, 0x5eed), -30.0);
    for a in [0.05f32, 0.1, 0.2, 0.3, 0.5, 0.99, 1.0] {
        let r = run(a, &x);
        println!("slider {a:.2} -> atten_lim {:.0} dB: pink noise change {:+.2} dB", a * 100.0, db(power(&r.out[WARM..])) - db(power(&x[WARM..r.out.len()])));
    }
}
