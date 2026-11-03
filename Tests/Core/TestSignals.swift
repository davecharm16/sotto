import Foundation

/// Deterministic signal helpers shared by the headless pipeline tests.
enum TestSignals {
    static func sine(frames: Int, rate: Double, hz: Double, amplitude: Float) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// Xorshift white noise in [-1, 1).
    static func white(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Float(s >> 40) / Float(1 << 24) * 2 - 1
        }
    }

    /// Paul Kellet's economy pink filter (same as DeepFilter/tests/nc_offline.rs).
    static func pink(_ n: Int, seed: UInt64) -> [Float] {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        return white(n, seed: seed).map { w in
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            return b0 + b1 + b2 + w * 0.1848
        }
    }

    static func meanSquare(_ x: ArraySlice<Float>) -> Double {
        x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))
    }

    static func db(_ power: Double) -> Double { 10 * log10(max(power, 1e-20)) }

    static func scaled(_ x: [Float], toDBFS target: Double) -> [Float] {
        let g = Float(pow(10, (target - db(meanSquare(x[...]))) / 20))
        return x.map { $0 * g }
    }

    /// Least-squares fit of a*sin + b*cos at `hz`. Returns amplitude and the residual power relative to the signal.
    static func sineFit(_ x: ArraySlice<Float>, rate: Double, hz: Double) -> (amplitude: Double, residualDB: Double) {
        let w = 2 * Double.pi * hz / rate
        var ss = 0.0, cc = 0.0, sc = 0.0, xs = 0.0, xc = 0.0
        for (k, v) in x.enumerated() {
            let s = sin(w * Double(k)), c = cos(w * Double(k)), d = Double(v)
            ss += s * s; cc += c * c; sc += s * c; xs += d * s; xc += d * c
        }
        let det = ss * cc - sc * sc
        let a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det
        var res = 0.0, sig = 0.0
        for (k, v) in x.enumerated() {
            let fit = a * sin(w * Double(k)) + b * cos(w * Double(k))
            res += (Double(v) - fit) * (Double(v) - fit)
            sig += fit * fit
        }
        return ((a * a + b * b).squareRoot(), db(res / max(sig, 1e-20)))
    }

    /// Largest |x[n] - 2x[n-1] + x[n-2]|: a smooth band-limited tone keeps this tiny, a click or step does not.
    static func maxSecondDifference(_ x: ArraySlice<Float>) -> Float {
        var m: Float = 0
        var i = x.startIndex + 2
        while i < x.endIndex {
            m = max(m, abs(x[i] - 2 * x[i - 1] + x[i - 2]))
            i += 1
        }
        return m
    }
}
