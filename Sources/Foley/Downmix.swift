import Foundation

/// Fold-downs of one 7.1.4 render, and the meters they are checked with.
/// Input channel order is the 7.1.4 export's: L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr.
enum Downmix {
    static let sr = AudioCache.sampleRate
    static let minus3: Float = 0.70710678

    /// ITU-R BS.1770-4 channel weights: LFE left out, surrounds between 60° and 120° at +1.5 dB.
    static let weights714: [Double] = [1, 1, 1, 0, 1, 1, 1.41, 1.41, 1, 1, 1, 1]
    static let weights51: [Double] = [1, 1, 1, 0, 1.41, 1.41]

    // MARK: 5.1 and Lo/Ro

    /// 7.1.4 → 5.1 in the ITU side-surround layout: L R C LFE Ls Rs.
    /// The 7.1.4 mix with the session's fold-down trims on its surrounds and heights. Used for every fold; the 7.1.4 itself is never trimmed.
    static func trimmed(_ c: [[Float]], _ p: Project) -> [[Float]] {
        let t = p.foldTrims
        let s = Float(dbToLinear(t.surround)), h = Float(dbToLinear(t.height))
        guard c.count == 12, s != 1 || h != 1 else { return c }
        var o = c
        for i in 4..<8 where s != 1 { scale(&o[i], s) }
        for i in 8..<12 where h != 1 { scale(&o[i], h) }
        return o
    }

    static func fold51(_ c: [[Float]]) -> [[Float]] {
        var l = c[0], r = c[1], ls = c[6], rs = c[7]
        // Top fronts into L/R at −3 dB, Dolby's default height fold.
        add(c[8], to: &l, gain: minus3); add(c[9], to: &r, gain: minus3)
        // Sides at 0 dB, rears and top rears at −3 dB (not 0 dB): a deliberate choice so the surrounds do not build up.
        add(c[4], to: &ls, gain: minus3); add(c[5], to: &rs, gain: minus3)
        add(c[10], to: &ls, gain: minus3); add(c[11], to: &rs, gain: minus3)
        return [l, r, c[2], c[3], ls, rs]
    }

    /// 5.1 → Lo/Ro (ITU-R BS.775): centre and surrounds at −3 dB, LFE left out as TVs and streaming services do.
    static func loRo(_ s: [[Float]]) -> [[Float]] {
        var lo = s[0], ro = s[1]
        add(s[2], to: &lo, gain: minus3); add(s[2], to: &ro, gain: minus3)
        add(s[4], to: &lo, gain: minus3); add(s[5], to: &ro, gain: minus3)
        return [lo, ro]
    }

    // MARK: Stereo for laptop and phone speakers

    /// Every number of the small-speaker stereo in one place.
    enum Tune {
        /// Side surrounds into their own side at 0 dB, rears at −1.5 dB with a gentle high cut so they sit behind.
        static let side: Float = 1
        static let rear: Float = 0.84
        static let rearShelf = (hz: 4000.0, db: -3.0)
        /// Heights at −3 dB with a high shelf: the lift above ~7 kHz is the cue the ear reads as "above".
        static let height: Float = 0.71
        static let heightShelf = (hz: 5000.0, db: 4.0)
        /// Each surround also goes to the opposite side inverted, a little late and band-limited: a first-order
        /// crosstalk cancel, so it sounds outside two close speakers. At −9 dB it does not vanish in mono.
        /// 4 samples (0.083 ms) plus the band-pass's own ~0.04 ms lag matches the far-ear delay of laptop and
        /// phone speakers (about ±10–15°, 0.1–0.13 ms); 0.2–0.3 ms would suit a ±30° desk pair and barely widens here.
        static let cross: Float = 0.355
        static let crossDelay = 4 / 48000.0
        static let crossBand = (low: 300.0, high: 6000.0)
        /// LFE: +10 dB playback gain, then −6 dB into each channel (in mono they add back to the LFE's level).
        static let lfe: Float = 1.58
        /// Bass harmonics: made from the mix below 120 Hz, kept to 120–400 Hz, and mixed so that a 50 Hz
        /// tone's harmonics sit about 15 dB under it: as loud as the tone itself by the equal-loudness
        /// contours, so small speakers keep the thump and full-range playback does not get muddy.
        static let bassSplit = 120.0
        static let harmonicBand = (low: 120.0, high: 400.0)
        static let harmonics: Float = 1.2
        static let target = -14.0       // LUFS integrated
        static let ceiling = -1.0       // dBTP
        static let maxLimiting = 12.0   // dB of gain reduction allowed to reach the target
        static let maxMonoLoss = 3.0    // dB, at the 0.1 dB it is reported to (hard-panned sound alone loses 3.01)
    }

    struct Speakers {
        var left: [Float], right: [Float]
        var lufs: Double?
        var truePeak: Double
        var monoLoss: Double
        var correlation: Double
        var widening: Double     // 1 = full
        var limiting: Double     // deepest gain reduction, dB
        var short: Double        // LU below the target (0 when reached)
        var trimmed: Double      // extra dB taken off after limiting to hold the ceiling

        var summary: String {
            var s = (lufs.map { String(format: "%.1f LUFS, ", $0) } ?? "")
                + String(format: "%.1f dBTP, mono loses %.1f dB, correlation %.2f", truePeak, monoLoss, correlation)
            if widening < 1 {
                s += String(format: ". Widening cut to %.0f%% to keep the mono loss within 3 dB", widening * 100)
            }
            if widening == 0 && monoLoss >= Tune.maxMonoLoss + 0.05 { s += "; the mix itself is wider than that" }
            if short > 0.3 {
                s += String(format: ". %.1f LU short of -14 LUFS: louder would need more than 12 dB of limiting", short)
            }
            return s + "."
        }
    }

    /// The stereo for laptop and phone speakers: keeps as much of the surround, height and weight as two small
    /// speakers can, stays safe in mono, normalised to −14 LUFS with peaks held at −1 dBTP.
    static func speakers(_ c: [[Float]]) -> Speakers {
        let n = c[0].count
        // Front and centre, as Lo/Ro.
        var l = c[0], r = c[1]
        add(c[2], to: &l, gain: minus3); add(c[2], to: &r, gain: minus3)
        // Surrounds into their own side; rears duller first.
        var sl = [Float](repeating: 0, count: n), sR = sl
        do {
            var rl = c[4], rr = c[5]
            highShelf(&rl, hz: Tune.rearShelf.hz, db: Tune.rearShelf.db)
            highShelf(&rr, hz: Tune.rearShelf.hz, db: Tune.rearShelf.db)
            add(c[6], to: &sl, gain: Tune.side); add(rl, to: &sl, gain: Tune.rear)
            add(c[7], to: &sR, gain: Tune.side); add(rr, to: &sR, gain: Tune.rear)
        }
        add(sl, to: &l, gain: 1); add(sR, to: &r, gain: 1)
        // Heights into their own side, brighter.
        do {
            var hl = c[8], hr = c[9]
            add(c[10], to: &hl, gain: 1); add(c[11], to: &hr, gain: 1)
            highShelf(&hl, hz: Tune.heightShelf.hz, db: Tune.heightShelf.db)
            highShelf(&hr, hz: Tune.heightShelf.hz, db: Tune.heightShelf.db)
            add(hl, to: &l, gain: Tune.height); add(hr, to: &r, gain: Tune.height)
        }
        add(c[3], to: &l, gain: Tune.lfe); add(c[3], to: &r, gain: Tune.lfe)
        // Bass small speakers cannot play, heard through its harmonics. The original lows stay for headphones and TVs.
        do {
            var mid = l
            add(r, to: &mid, gain: 1)
            let h = bassHarmonics(mid, scale: 0.5)
            add(h, to: &l, gain: Tune.harmonics); add(h, to: &r, gain: Tune.harmonics)
        }
        // Widening: the right surrounds go into the left inverted, and the other way round.
        let d = Int((Tune.crossDelay * sr).rounded())
        var wl = sR, wr = sl
        delay(&wl, samples: d); bandpass(&wl, low: Tune.crossBand.low, high: Tune.crossBand.high)
        delay(&wr, samples: d); bandpass(&wr, low: Tune.crossBand.low, high: Tune.crossBand.high)
        sl = []; sR = []

        // Mono safety: less widening until the mono sum loses at most 3 dB.
        var out: [[Float]] = [l, r], widening = 0.0
        for w in [1.0, 0.7, 0.5, 0.35, 0.2, 0] {
            var a = l, b = r
            add(wl, to: &a, gain: -Tune.cross * Float(w)); add(wr, to: &b, gain: -Tune.cross * Float(w))
            out = [a, b]
            widening = w
            if monoLoss(a, b) < Tune.maxMonoLoss + 0.05 { break }
        }
        l = []; r = []; wl = []; wr = []

        let fin = normalise(&out)
        // The limiter works from 4× oversampled peaks; a last check catches what its smoothing let past.
        var tp = truePeak(out), trimmed = 0.0
        if tp > Tune.ceiling {
            trimmed = tp - Tune.ceiling + 0.02
            let k = Float(pow(10, -trimmed / 20))
            for i in out.indices { scale(&out[i], k) }
            tp = truePeak(out)
        }
        let lufs = trimmed > 0 ? loudness(out) : fin.lufs
        return Speakers(left: out[0], right: out[1], lufs: lufs, truePeak: tp,
                        monoLoss: monoLoss(out[0], out[1]), correlation: correlation(out[0], out[1]),
                        widening: widening, limiting: fin.limiting,
                        short: max(0, Tune.target - (lufs ?? Tune.target)), trimmed: trimmed)
    }

    /// Harmonics of everything below 120 Hz, kept to 120–400 Hz. Odd ones from a soft clip scaled to the
    /// envelope, even ones from the rectified wave; both follow the level of the bass, so nothing is compressed.
    static func bassHarmonics(_ x: [Float], scale s: Float = 1) -> [Float] {
        var low = x
        lowpass(&low, hz: Tune.bassSplit); lowpass(&low, hz: Tune.bassSplit)
        let fall = exp(-1 / (0.03 * sr)), k = 4.0, norm = tanh(4.0)
        var env = 0.0
        var h = [Float](repeating: 0, count: low.count)
        low.withUnsafeBufferPointer { p in
            h.withUnsafeMutableBufferPointer { o in
                for i in 0..<p.count {
                    let v = Double(p[i] * s)
                    env = max(abs(v), env * fall)
                    guard env > 1e-7 else { continue }
                    // The rectified wave minus its average (2/π of the peak), so the envelope itself adds little.
                    o[i] = Float(env * tanh(k * v / env) / norm + 0.6 * (abs(v) - 0.6366 * env))
                }
            }
        }
        highpass(&h, hz: Tune.harmonicBand.low); highpass(&h, hz: Tune.harmonicBand.low)
        lowpass(&h, hz: Tune.harmonicBand.high); lowpass(&h, hz: Tune.harmonicBand.high)
        return h
    }

    /// Gain to the loudness target, then a look-ahead limiter at the true-peak ceiling. The gain stops where
    /// the limiter would have to take off more than 12 dB.
    static func normalise(_ ch: inout [[Float]]) -> (lufs: Double?, limiting: Double) {
        guard let start = loudness(ch) else { return (nil, 0) }
        let peaks = peakEnvelope(ch)
        let top = Double(peaks.max() ?? 0)
        guard top > 0 else { return (start, 0) }
        let ceiling = Tune.ceiling - 0.1                       // margin for the gain smoothing between oversampled points
        let cap = ceiling + Tune.maxLimiting - 20 * log10(top)
        var gain = min(Tune.target - start, cap)
        var result = ch, limiting = 0.0, lufs: Double? = start
        for _ in 0..<5 {
            var y = ch
            limiting = limit(&y, peaks: peaks, gain: gain, ceiling: ceiling)
            result = y
            lufs = loudness(y)
            guard let got = lufs else { break }
            let next = min(gain + (Tune.target - got), cap)
            if abs(Tune.target - got) < 0.05 || abs(next - gain) < 0.01 { break }
            gain = next
        }
        ch = result
        return (lufs, limiting)
    }

    /// Look-ahead peak limiter, linked across channels: `gain` dB, then nothing over `ceiling` dBTP.
    /// `peaks` is `peakEnvelope` of the input. Returns the deepest gain reduction in dB.
    static func limit(_ ch: inout [[Float]], peaks: [Float], gain: Double, ceiling: Double) -> Double {
        let n = peaks.count, g = pow(10, gain / 20), c = pow(10, ceiling / 20)
        var need = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let p = Double(peaks[i]) * g
            if p > c { need[i] = Float(c / p) }
        }
        let look = Int(0.002 * sr)
        // 1. Each sample takes the lowest gain any of the next 2 ms needs.
        var gr = aheadMin(need, look)
        // 2. Drop at once, recover over ~80 ms.
        let rel = Float(1 - exp(-1 / (0.08 * sr)))
        var cur: Float = 1
        for i in 0..<n {
            let t = gr[i]
            cur = t < cur ? t : cur + (t - cur) * rel
            gr[i] = cur
        }
        // 3. Spread each drop over the 2 ms before it, so the full reduction is there when the peak arrives.
        var smooth = [Float](repeating: 1, count: n), sum = 0.0, deepest: Float = 1
        for i in 0..<n {
            sum += Double(gr[i])
            if i >= look { sum -= Double(gr[i - look]) }
            smooth[i] = Float(sum / Double(min(i + 1, look)))
            deepest = min(deepest, smooth[i])
        }
        let gf = Float(g)
        for k in ch.indices {
            ch[k].withUnsafeMutableBufferPointer { x in
                smooth.withUnsafeBufferPointer { s in
                    for i in 0..<min(x.count, n) { x[i] *= gf * s[i] }
                }
            }
        }
        return deepest < 1 ? -20 * log10(Double(deepest)) : 0
    }

    /// out[i] = the smallest of x[i ..< i + w].
    static func aheadMin(_ x: [Float], _ w: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 1, count: n), dq = [Int](repeating: 0, count: n)
        var head = 0, tail = 0
        for j in 0..<(n + w - 1) {
            if j < n {
                while tail > head && x[dq[tail - 1]] >= x[j] { tail -= 1 }
                dq[tail] = j; tail += 1
            }
            let i = j - w + 1
            if i >= 0 {
                while dq[head] < i { head += 1 }
                out[i] = x[dq[head]]
            }
        }
        return out
    }

    // MARK: Meters

    /// ITU-R BS.1770-4 integrated loudness: K-weighted, 400 ms blocks every 100 ms, gated at −70 LUFS and
    /// 10 LU under the ungated level. nil when nothing passes the gate.
    static func loudness(_ ch: [[Float]], weights: [Double]? = nil) -> Double? {
        let hop = Int(sr / 10), n = ch.first?.count ?? 0, subs = n / hop
        guard subs >= 4 else { return nil }
        var ms = [Double](repeating: 0, count: subs)
        let (shelf, rlb) = kWeighting
        for (c, x) in ch.enumerated() {
            let w = weights?[c] ?? 1
            guard w > 0 else { continue }
            var f1 = shelf, f2 = rlb
            x.withUnsafeBufferPointer { p in
                for s in 0..<subs {
                    var acc = 0.0
                    for i in s * hop..<(s + 1) * hop {
                        let y = f2.step(f1.step(Double(p[i])))
                        acc += y * y
                    }
                    ms[s] += w * acc / Double(hop)
                }
            }
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        var blocks: [Double] = []
        for s in 0..<(subs - 3) { blocks.append((ms[s] + ms[s + 1] + ms[s + 2] + ms[s + 3]) / 4) }
        let loud = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !loud.isEmpty else { return nil }
        let relative = lufs(loud.reduce(0, +) / Double(loud.count)) - 10
        let gated = loud.filter { lufs($0) > relative }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// BS.1770 K-weighting for any sample rate; at 48 kHz these give the coefficients published in the standard.
    static var kWeighting: (Biquad, Biquad) {
        let f0 = 1681.974450955533, gdb = 3.999843853973347, q = 0.7071752369554196
        var k = tan(.pi * f0 / sr)
        let vh = pow(10, gdb / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        let f1 = 38.13547087602444, q1 = 0.5003270373238773
        k = tan(.pi * f1 / sr)
        a0 = 1 + k / q1 + k * k
        return (shelf, Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0))
    }

    /// Loss of the mono sum (L+R)/2 against the stereo, by loudness: 0 dB for centred sound, 3 dB for hard-panned
    /// or uncorrelated sound, more when the channels work against each other.
    static func monoLoss(_ l: [Float], _ r: [Float]) -> Double {
        guard let stereo = loudness([l, r]) else { return 0 }
        var m = l
        add(r, to: &m, gain: 1)
        scale(&m, 0.5)
        // Weight 2 = the mono sum on both speakers.
        guard let mono = loudness([m], weights: [2]) else { return 99 }
        return stereo - mono
    }

    static func correlation(_ l: [Float], _ r: [Float]) -> Double {
        var lr = 0.0, ll = 0.0, rr = 0.0
        l.withUnsafeBufferPointer { a in
            r.withUnsafeBufferPointer { b in
                for i in 0..<min(a.count, b.count) {
                    let x = Double(a[i]), y = Double(b[i])
                    lr += x * y; ll += x * x; rr += y * y
                }
            }
        }
        return ll > 0 && rr > 0 ? lr / (ll * rr).squareRoot() : 0
    }

    /// True peak in dBTP: the largest of every sample and three points between each pair (4× oversampling).
    static func truePeak(_ ch: [[Float]]) -> Double {
        var top: Float = 0
        for x in ch { top = max(top, interSample(x).max() ?? 0) }
        return top > 0 ? 20 * log10(Double(top)) : -120
    }

    /// Per sample, the highest 4× oversampled peak of any channel next to it (on either side).
    static func peakEnvelope(_ ch: [[Float]]) -> [Float] {
        let n = ch.first?.count ?? 0
        var env = [Float](repeating: 0, count: n)
        for x in ch {
            let seg = interSample(x)
            for i in 0..<n { env[i] = max(env[i], seg[i], i > 0 ? seg[i - 1] : 0) }
        }
        return env
    }

    /// seg[i] = the largest of |x| at i, i+¼, i+½ and i+¾, interpolated with a windowed sinc.
    static func interSample(_ x: [Float]) -> [Float] {
        let n = x.count, half = tpHalf
        var seg = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            tpTaps.withUnsafeBufferPointer { h in
                seg.withUnsafeMutableBufferPointer { o in
                    for i in 0..<n {
                        var m = abs(p[i])
                        let lo = max(0, i - (half - 1)), hi = min(n - 1, i + half)
                        for k in 0..<3 {
                            var acc = 0.0
                            let base = k * 2 * half + half - 1 - i
                            for j in lo...hi { acc += Double(p[j]) * h[base + j] }
                            m = max(m, Float(abs(acc)))
                        }
                        o[i] = m
                    }
                }
            }
        }
        return seg
    }

    /// Half the taps per phase. Measured on faded sines: the interpolation is within 0.01 dB of the exact
    /// waveform up to 20 kHz; what remains is 4× sampling itself, which can miss a peak by up to 0.2 dB near 16 kHz.
    static let tpHalf = 16

    /// Three phases (¼, ½, ¾) of a Kaiser-windowed sinc (β 7), for x[i-15 ... i+16]; each sums to 1.
    static let tpTaps: [Double] = {
        func i0(_ x: Double) -> Double {
            var s = 1.0, term = 1.0
            for k in 1...30 { term *= (x / 2 / Double(k)) * (x / 2 / Double(k)); s += term }
            return s
        }
        let beta = 7.0, half = Double(tpHalf)
        var t: [Double] = []
        for k in 1...3 {
            let f = Double(k) / 4
            var h = (-(tpHalf - 1)...tpHalf).map { m -> Double in
                let d = f - Double(m), r = d / half
                return sin(.pi * d) / (.pi * d) * i0(beta * max(0, 1 - r * r).squareRoot()) / i0(beta)
            }
            let sum = h.reduce(0, +)
            h = h.map { $0 / sum }
            t += h
        }
        return t
    }()

    // MARK: Filters and helpers

    /// Direct-form-I biquad, normalised (a0 = 1), Double state.
    struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func step(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }

        func run(_ x: inout [Float]) {
            var f = self
            x.withUnsafeMutableBufferPointer { p in
                for i in 0..<p.count { p[i] = Float(f.step(Double(p[i]))) }
            }
        }
    }

    /// Second-order Butterworth low-pass, in place (RBJ cookbook, Q 0.707).
    static func lowpass(_ x: inout [Float], hz: Double) {
        let w = 2 * Double.pi * hz / sr, cosw = cos(w), alpha = sin(w) / (2 * 0.7071), a0 = 1 + alpha
        Biquad(b0: (1 - cosw) / 2 / a0, b1: (1 - cosw) / a0, b2: (1 - cosw) / 2 / a0,
               a1: -2 * cosw / a0, a2: (1 - alpha) / a0).run(&x)
    }

    /// Second-order Butterworth high-pass, in place.
    static func highpass(_ x: inout [Float], hz: Double) {
        let w = 2 * Double.pi * hz / sr, cosw = cos(w), alpha = sin(w) / (2 * 0.7071), a0 = 1 + alpha
        Biquad(b0: (1 + cosw) / 2 / a0, b1: -(1 + cosw) / a0, b2: (1 + cosw) / 2 / a0,
               a1: -2 * cosw / a0, a2: (1 - alpha) / a0).run(&x)
    }

    /// Band-pass as a second-order high-pass then a second-order low-pass.
    static func bandpass(_ x: inout [Float], low: Double, high: Double) {
        highpass(&x, hz: low); lowpass(&x, hz: high)
    }

    /// High shelf (RBJ cookbook, slope 1): `db` above `hz`, half of it at `hz`.
    static func highShelf(_ x: inout [Float], hz: Double, db: Double) {
        let a = pow(10, db / 40), w = 2 * Double.pi * hz / sr, cosw = cos(w)
        let beta = 2 * a.squareRoot() * sin(w) / 2 * 2.0.squareRoot()
        let a0 = (a + 1) - (a - 1) * cosw + beta
        Biquad(b0: a * ((a + 1) + (a - 1) * cosw + beta) / a0, b1: -2 * a * ((a - 1) + (a + 1) * cosw) / a0,
               b2: a * ((a + 1) + (a - 1) * cosw - beta) / a0,
               a1: 2 * ((a - 1) - (a + 1) * cosw) / a0, a2: ((a + 1) - (a - 1) * cosw - beta) / a0).run(&x)
    }

    /// Whole-sample delay, in place (the length stays the same).
    static func delay(_ x: inout [Float], samples d: Int) {
        guard d > 0, d < x.count else { return }
        x = [Float](repeating: 0, count: d) + x[0..<(x.count - d)]
    }

    static func add(_ src: [Float], to dst: inout [Float], gain: Float) {
        guard gain != 0 else { return }
        dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                for i in 0..<min(d.count, s.count) { d[i] += s[i] * gain }
            }
        }
    }

    static func scale(_ x: inout [Float], _ k: Float) {
        x.withUnsafeMutableBufferPointer { p in for i in 0..<p.count { p[i] *= k } }
    }

    /// "-17.2 LUFS, -3.1 dBTP" for a summary line.
    static func levels(_ ch: [[Float]], weights: [Double]? = nil) -> String {
        (loudness(ch, weights: weights).map { String(format: "%.1f LUFS, ", $0) } ?? "")
            + String(format: "%.1f dBTP", truePeak(ch))
    }
}

// MARK: - Export

extension Exporter {
    /// 5.1, Lo/Ro, the laptop-and-phone stereo and the mixdown set: each folded from the same 7.1.4 render.
    static func exportFolds(_ p: Project, format: ExportFormat, to url: URL, resolve: (Take) -> URL?) throws -> String {
        var bed = try immersive(p, layout: .bed714, resolve: resolve).channels
        // The master bus works on all twelve channels at once, before anything is folded.
        BusProcessor.run(&bed, p.bus)
        let folding = Downmix.trimmed(bed, p)
        switch format {
        case .surround51:
            var ch = Downmix.fold51(folding)
            BusProcessor.run(&ch, BusProcessor.limiterOnly(p.bus))
            let trim = protect(&ch)
            try WAV.write(url, channels: ch, channelMask: 0x60F)
            return "6 channels (L R C LFE Ls Rs) folded from the 7.1.4 mix. "
                + Downmix.levels(ch, weights: Downmix.weights51) + lowered(trim)
        case .stereoFold:
            var ch = Downmix.loRo(Downmix.fold51(folding))
            BusProcessor.run(&ch, BusProcessor.limiterOnly(p.bus))
            let trim = protect(&ch)
            try WAV.write(url, channels: ch)
            return "Lo/Ro of the 5.1 fold, LFE left out. " + Downmix.levels(ch)
                + String(format: ", mono loses %.1f dB", Downmix.monoLoss(ch[0], ch[1])) + lowered(trim)
        case .speakers:
            let s = Downmix.speakers(folding)
            try WAV.write(url, channels: [s.left, s.right])
            return s.summary
        case .mixdowns:
            let name = p.name.isEmpty ? "Mix" : p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Everything is folded from the render before anything is trimmed, so all five are the same mix.
            var s51 = Downmix.fold51(folding)
            var lr = Downmix.loRo(s51)
            let sp = Downmix.speakers(folding)
            var mono = sp.left
            Downmix.add(sp.right, to: &mono, gain: 1)
            Downmix.scale(&mono, 0.5)
            // Folding adds channels together: the folds get the limiter again, linked across their own channels.
            BusProcessor.run(&s51, BusProcessor.limiterOnly(p.bus))
            BusProcessor.run(&lr, BusProcessor.limiterOnly(p.bus))
            let trims = [protect(&bed), protect(&s51), protect(&lr)]

            var rows: [String] = []
            func row(_ file: String, _ ch: [[Float]], _ weights: [Double]?, _ what: String) -> String {
                let lufs = Downmix.loudness(ch, weights: weights).map { String(format: "%6.1f LUFS", $0) } ?? "   silent  "
                var s = "\(file)\n    \(ch.count) ch  \(lufs)  " + String(format: "%5.1f dBTP", Downmix.truePeak(ch))
                if ch.count == 2 {
                    s += String(format: "  correlation %.2f  mono loss %.1f dB", Downmix.correlation(ch[0], ch[1]), Downmix.monoLoss(ch[0], ch[1]))
                }
                return s + "\n    " + what
            }
            let files: [(String, [[Float]], UInt32?, [Double]?, String)] = [
                ("\(name) 7.1.4.wav", bed, 0x2D63F, Downmix.weights714,
                 "The master for a 7.1.4 room (L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr)."),
                ("\(name) 5.1.wav", s51, 0x60F, Downmix.weights51,
                 "Heights folded into the front at -3 dB, rear surrounds and top rears into the side surrounds at -3 dB."),
                ("\(name) stereo fold-down.wav", lr, nil, nil,
                 "Lo/Ro of the 5.1, LFE left out: what a TV or streaming service plays on a stereo set."),
                ("\(name) laptop and phone.wav", [sp.left, sp.right], nil, nil,
                 "Surrounds widened past the speakers, heights brightened, bass carried by its harmonics. Aimed at -14 LUFS, peaks held at -1 dBTP."
                    + (sp.widening < 1 ? String(format: " Widening cut to %.0f%% to keep mono safe.", sp.widening * 100) : "")
                    + (sp.short > 0.3 ? String(format: " %.1f LU short of -14: louder would need more than 12 dB of limiting.", sp.short) : "")),
                ("\(name) mono.wav", [mono], nil, nil,
                 "(L+R)/2 of the laptop and phone file: what one phone speaker plays. Measured as one channel, it reads 3 LU plus the mono loss under the stereo."),
            ]
            for (file, ch, mask, weights, what) in files {
                try WAV.write(url.appendingPathComponent(file), channels: ch, channelMask: mask)
                rows.append(row(file, ch, weights, what))
            }
            let trimNotes = zip(["7.1.4", "5.1", "stereo fold-down"], trims).filter { $0.1 < 0 }
                .map { String(format: "%@ lowered %.1f dB to avoid clipping", $0.0, -$0.1) }
            let text = """
            How these translate: \(name)

            All five files are folded from one 7.1.4 render, so they are the same mix.
            Loudness is ITU-R BS.1770-4 integrated (LUFS), true peak is 4x oversampled (dBTP).
            Mono loss: how much quieter (L+R)/2 is than the stereo. 0 dB for centred sound, 3 dB for hard-panned or uncorrelated sound.
            The laptop and phone file keeps as much of the surround impression as two small speakers can. It is not a decode of the immersive mix.

            \(rows.joined(separator: "\n\n"))
            \(trimNotes.isEmpty ? "" : "\n" + trimNotes.joined(separator: "; ") + ".\n")
            """
            try Data(text.utf8).write(to: url.appendingPathComponent("How these translate.txt"), options: .atomic)
            return "7.1.4, 5.1, stereo fold-down, laptop and phone, mono, from one render. Laptop and phone: " + sp.summary
        default:
            throw ExportError(message: "\(format.title) is not a fold-down of the 7.1.4 mix.")
        }
    }

    private static func lowered(_ trim: Double) -> String {
        trim < 0 ? String(format: ", lowered %.1f dB to avoid clipping.", -trim) : "."
    }
}
