import AVFoundation
import Observation

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// Settings of the master bus: a compressor, then a limiter. Both take their level from the loudest channel
/// and apply one gain to every channel, so a hit in one speaker never moves the image.
struct BusDynamics: Codable, Equatable {
    var compressor = false
    var threshold = -18.0       // dB
    var ratio = 3.0
    var attack = 10.0           // ms
    var release = 150.0         // ms
    var makeup = 0.0            // dB
    var limiter = true
    var ceiling = -1.0          // dBTP
    var limiterRelease = 120.0  // ms

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compressor = try c.decodeIfPresent(Bool.self, forKey: .compressor) ?? false
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? -18
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 3
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? 10
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? 150
        makeup = try c.decodeIfPresent(Double.self, forKey: .makeup) ?? 0
        limiter = try c.decodeIfPresent(Bool.self, forKey: .limiter) ?? true
        ceiling = try c.decodeIfPresent(Double.self, forKey: .ceiling) ?? -1
        limiterRelease = try c.decodeIfPresent(Double.self, forKey: .limiterRelease) ?? 120
    }
}

/// The DSP. One instance runs on the live output (two channels); the exports run another over every channel
/// of the mix at once. Nothing is allocated after init, so `process` is safe on the audio thread.
final class BusProcessor {
    /// Samples the audio is delayed by so the limiter can turn down before a peak arrives (5 ms).
    static let latency = 240
    private static let half = Downmix.tpHalf            // true-peak interpolation looks this far each way
    private static let ahead = latency - half           // look-ahead left once the peak has been measured
    private static let knee: Float = 6

    let channels: Int
    private let sampleRate: Double
    /// Channel left out of the compressor's detector (the sub), or -1.
    private let lfe: Int

    // Settings, written from the main thread.
    private var compOn = false, limOn = true
    private var threshold: Float = -18, slope: Float = 1 - 1 / 3, makeup: Float = 1
    private var attackCoef: Float = 0, releaseCoef: Float = 0, limReleaseCoef: Float = 0
    private var ceiling: Float = 0.89

    /// Deepest gain reduction since the UI last read it, in dB (0 or negative). The reader resets them to 0.
    var compressorReduction: Float = 0
    var limiterReduction: Float = 0

    private var compGain: Float = 0                     // dB, smoothed
    private var env: Float = 1
    private let delay: UnsafeMutablePointer<Float>      // channels × latency
    private let history: UnsafeMutablePointer<Float>    // channels × 2·half, newest last
    private var delayAt = 0, historyAt = 0
    private let taps: UnsafeMutablePointer<Float>
    // Sliding minimum over ahead+1 gains.
    private let minValue: UnsafeMutablePointer<Float>
    private let minIndex: UnsafeMutablePointer<Int>
    private var minHead = 0, minCount = 0
    private let minCap = BusProcessor.ahead + 2
    // Moving average over `ahead` minima.
    private let box: UnsafeMutablePointer<Float>
    private var boxAt = 0
    private var boxSum = 0.0
    private var clock = 0

    init(channels: Int, sampleRate: Double = AudioCache.sampleRate) {
        self.channels = channels
        self.sampleRate = sampleRate
        lfe = channels > 2 ? 3 : -1
        let h = Self.half * 2
        delay = .allocate(capacity: channels * Self.latency); delay.initialize(repeating: 0, count: channels * Self.latency)
        history = .allocate(capacity: channels * h); history.initialize(repeating: 0, count: channels * h)
        taps = .allocate(capacity: 3 * h)
        for (i, t) in Downmix.tpTaps.enumerated() { taps[i] = Float(t) }
        minValue = .allocate(capacity: minCap); minValue.initialize(repeating: 1, count: minCap)
        minIndex = .allocate(capacity: minCap); minIndex.initialize(repeating: 0, count: minCap)
        box = .allocate(capacity: Self.ahead); box.initialize(repeating: 1, count: Self.ahead)
        boxSum = Double(Self.ahead)
        set(BusDynamics())
    }

    deinit {
        delay.deallocate(); history.deallocate(); taps.deallocate()
        minValue.deallocate(); minIndex.deallocate(); box.deallocate()
    }

    func set(_ d: BusDynamics) {
        func coef(_ ms: Double) -> Float { Float(exp(-1 / (max(0.05, ms) / 1000 * sampleRate))) }
        compOn = d.compressor
        limOn = d.limiter
        threshold = Float(min(0, max(-60, d.threshold)))
        slope = 1 - 1 / Float(min(20, max(1, d.ratio)))
        makeup = Float(dbToLinear(min(24, max(-12, d.makeup))))
        attackCoef = coef(d.attack)
        releaseCoef = coef(d.release)
        limReleaseCoef = coef(d.limiterRelease)
        // A little under the ceiling: the gain itself moves, and 4× sampling can miss a peak by a fraction of a dB.
        ceiling = Float(dbToLinear(min(0, max(-12, d.ceiling)) - 0.15))
    }

    /// dB of gain the compressor asks for at a level in dB (0 or negative). Soft knee, 6 dB wide.
    @inline(__always) static func curve(_ level: Float, threshold: Float, slope: Float) -> Float {
        let over = level - threshold
        if over <= -knee / 2 { return 0 }
        if over >= knee / 2 { return -slope * over }
        let k = over + knee / 2
        return -slope * k * k / (2 * knee)
    }

    /// In place, `frames` samples of every channel. The output is the input `latency` samples late.
    func process(_ ch: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        let h2 = Self.half * 2, half = Self.half, ahead = Self.ahead, latency = Self.latency
        var deepestComp: Float = 0, deepestLim: Float = 1
        for n in 0..<frames {
            // Compressor: one detector for all channels.
            var gain = makeup
            if compOn {
                var top: Float = 0
                for c in 0..<channels where c != lfe { top = max(top, abs(ch[c][n])) }
                let target = top > 1e-6 ? Self.curve(20 * log10f(top), threshold: threshold, slope: slope) : 0
                let k = target < compGain ? attackCoef : releaseCoef
                compGain = target + (compGain - target) * k
                if compGain < deepestComp { deepestComp = compGain }
                gain *= powf(10, compGain / 20)
            } else if compGain != 0 {
                compGain = 0
            }

            // Into the true-peak history and the delay line.
            var peak: Float = 0
            let centre = (historyAt + half) % h2        // the sample `half` back: x[i], with x[i-15…i+16] around it
            for c in 0..<channels {
                let x = ch[c][n] * gain
                let hist = history + c * h2
                hist[historyAt] = x
                let line = delay + c * latency
                ch[c][n] = line[delayAt]
                line[delayAt] = x
                if limOn {
                    let here = abs(hist[centre]), next = abs(hist[(centre + 1) % h2])
                    var m = here
                    // Between two quiet samples there is no peak worth the arithmetic.
                    if max(here, next) > ceiling * 0.35 {
                        // Oldest sample is the one after historyAt; it is x[i-15].
                        let first = (historyAt + 1) % h2
                        for p in 0..<3 {
                            var acc: Float = 0
                            let t = taps + p * h2
                            var j = first
                            for k in 0..<h2 {
                                acc += hist[j] * t[k]
                                j += 1
                                if j == h2 { j = 0 }
                            }
                            m = max(m, abs(acc))
                        }
                    }
                    if m > peak { peak = m }
                }
            }
            historyAt = (historyAt + 1) % h2
            delayAt = (delayAt + 1) % latency

            // Limiter: gain needed now, released slowly, held down from `ahead` samples before each peak.
            let need: Float = peak > ceiling ? ceiling / peak : 1
            env = min(need, 1 - (1 - env) * limReleaseCoef)
            while minCount > 0 && minValue[(minHead + minCount - 1) % minCap] >= env { minCount -= 1 }
            let at = (minHead + minCount) % minCap
            minValue[at] = env; minIndex[at] = clock
            minCount += 1
            if minIndex[minHead] < clock - ahead { minHead = (minHead + 1) % minCap; minCount -= 1 }
            let lowest = minValue[minHead]
            boxSum += Double(lowest) - Double(box[boxAt])
            box[boxAt] = lowest
            boxAt = (boxAt + 1) % ahead
            clock += 1
            if clock % 48000 == 0 {
                // Rebuild the running sum now and then so rounding cannot drift.
                var s = 0.0
                for i in 0..<ahead { s += Double(box[i]) }
                boxSum = s
            }
            let g = Float(boxSum / Double(ahead))
            if g < 0.99999 {
                for c in 0..<channels { ch[c][n] *= g }
                if g < deepestLim { deepestLim = g }
            }
        }
        if deepestComp < compressorReduction { compressorReduction = deepestComp }
        if deepestLim < 1 {
            let db = 20 * log10f(deepestLim)
            if db < limiterReduction { limiterReduction = db }
        }
    }

    /// The session's limiter without its compressor, for mixes folded from one that has already been through the bus.
    static func limiterOnly(_ d: BusDynamics?) -> BusDynamics {
        var x = d ?? BusDynamics()
        x.compressor = false
        return x
    }

    /// Runs whole channels through the bus and lines them back up, so the result is sample-aligned with the input.
    /// Returns the deepest reduction of the compressor and of the limiter, in dB.
    @discardableResult
    static func run(_ ch: inout [[Float]], _ d: BusDynamics) -> (compressor: Double, limiter: Double) {
        guard d.compressor || d.limiter, let n = ch.first?.count, n > 0 else { return (0, 0) }
        let bus = BusProcessor(channels: ch.count)
        bus.set(d)
        let total = n + latency
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: ch.count)
        for c in ch.indices {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: total)
            p.initialize(repeating: 0, count: total)
            ch[c].withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: n) }
            ptrs[c] = p
        }
        bus.process(UnsafePointer(ptrs), frames: total)
        for c in ch.indices {
            ch[c] = Array(UnsafeBufferPointer(start: ptrs[c] + latency, count: n))
            ptrs[c].deallocate()
        }
        ptrs.deallocate()
        return (Double(bus.compressorReduction), Double(bus.limiterReduction))
    }
}

/// The bus as an audio unit, so it can sit on the live engine's output.
final class BusAU: AUAudioUnit {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6d627573 /* mbus */,
                                                componentManufacturer: 0x4d747279 /* Mtry */, componentFlags: 0, componentFlagsMask: 0)
    static let registered: Bool = {
        AUAudioUnit.registerSubclass(BusAU.self, as: desc, name: "mitroley: Master bus", version: 1)
        return true
    }()

    let dsp = BusProcessor(channels: 2)
    private let scratch: AVAudioPCMBuffer
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AudioCache.format
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var latency: TimeInterval { Double(BusProcessor.latency) / AudioCache.sampleRate }

    override var internalRenderBlock: AUInternalRenderBlock {
        let dsp = self.dsp
        let scratchList = scratch.mutableAudioBufferList
        let capacity = Int(scratch.frameCapacity)
        // The scratch buffer's own storage, to put back before every pull (upstream may swap in its own pointers).
        let own = UnsafeMutableAudioBufferListPointer(scratchList).map { $0.mData }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        return { _, timestamp, frames, _, output, _, pull in
            guard let pull, Int(frames) <= capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let input = UnsafeMutableAudioBufferListPointer(scratchList)
            for i in 0..<input.count {
                input[i].mData = own[i]
                input[i].mDataByteSize = frames * 4
            }
            var flags = AudioUnitRenderActionFlags()
            let status = pull(&flags, timestamp, frames, 0, scratchList)
            if status != noErr { return status }
            let out = UnsafeMutableAudioBufferListPointer(output)
            guard input.count >= 2, out.count >= 2, let a = input[0].mData, let b = input[1].mData else { return noErr }
            for (i, src) in [a, b].enumerated() {
                if let dst = out[i].mData {
                    if dst != src { memcpy(dst, src, Int(frames) * 4) }
                } else {
                    out[i].mData = src
                }
                out[i].mDataByteSize = frames * 4
                ptrs[i] = out[i].mData!.assumingMemoryBound(to: Float.self)
            }
            dsp.process(UnsafePointer(ptrs), frames: Int(frames))
            return noErr
        }
    }
}

// MARK: - Loudness

/// What the loudness meter shows. Its own observable object, so only the views that show loudness follow it.
@MainActor @Observable
final class LoudnessMeter {
    var momentary: Double?      // LUFS, last 400 ms
    var shortTerm: Double?      // LUFS, last 3 s
    var integrated: Double?     // LUFS, gated, since the last reset
    var truePeak: Double?       // dBTP, highest since the last reset
    var compressor = 0.0        // dB of gain reduction right now (0 or negative)
    var limiter = 0.0
    @ObservationIgnored let analyzer = LoudnessAnalyzer()

    init() {
        analyzer.publish = { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.momentary != r.momentary { self.momentary = r.momentary }
                if self.shortTerm != r.shortTerm { self.shortTerm = r.shortTerm }
                if self.integrated != r.integrated { self.integrated = r.integrated }
                if self.truePeak != r.truePeak { self.truePeak = r.truePeak }
            }
        }
    }

    func reset() {
        analyzer.resetRequested = true
        integrated = nil
        truePeak = nil
    }
}

/// ITU-R BS.1770-4 on a stream: K-weighting, 100 ms steps, 400 ms blocks, the two gates, and 4× true peak.
/// Fed from the output tap, which runs on its own queue, never on the audio thread.
final class LoudnessAnalyzer {
    struct Reading { var momentary, shortTerm, integrated, truePeak: Double? }
    var publish: ((Reading) -> Void)?
    var resetRequested = false

    private let hop = Int(AudioCache.sampleRate / 10)
    private var filters: [(Downmix.Biquad, Downmix.Biquad)] = [Downmix.kWeighting, Downmix.kWeighting]
    private var acc = 0.0
    private var filled = 0
    private var steps: [Double] = []        // mean square of the last 30 steps (3 s)
    private var blocks: [Double] = []       // every 400 ms block above the absolute gate
    private var peak: Float = 0
    private var carry: [[Float]] = [[], []] // tail of the last buffer, so peaks on the seam are seen

    private func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }

    func reset() {
        blocks = []
        peak = 0
    }

    func feed(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int) {
        if resetRequested { resetRequested = false; reset() }
        var published = false
        for i in 0..<frames {
            let l = filters[0].1.step(filters[0].0.step(Double(left[i])))
            let r = filters[1].1.step(filters[1].0.step(Double(right[i])))
            acc += l * l + r * r
            filled += 1
            if filled == hop {
                steps.append(acc / Double(hop))
                if steps.count > 30 { steps.removeFirst() }
                acc = 0; filled = 0
                if steps.count >= 4 {
                    let block = steps.suffix(4).reduce(0, +) / 4
                    if block > 0, lufs(block) > -70 { blocks.append(block) }
                }
                published = true
            }
        }
        // True peak, only where the signal is loud enough to matter.
        for (c, p) in [left, right].enumerated() {
            var x = carry[c]
            x.append(contentsOf: UnsafeBufferPointer(start: p, count: frames))
            if (x.max() ?? 0) > 0.05 || (x.min() ?? 0) < -0.05 {
                let seg = Downmix.interSample(x)
                // Only where the interpolation has its full context on both sides; the rest is seen with the next buffer.
                let first = carry[c].isEmpty ? 0 : Downmix.tpHalf, usable = seg.count - Downmix.tpHalf
                if usable > first { for i in first..<usable where seg[i] > peak { peak = seg[i] } }
            }
            carry[c] = Array(x.suffix(Downmix.tpHalf * 2))
        }
        guard published else { return }
        var r = Reading()
        if steps.count >= 4 {
            let m = steps.suffix(4).reduce(0, +) / 4
            if m > 1e-10 { r.momentary = lufs(m) }
        }
        if !steps.isEmpty {
            let s = steps.reduce(0, +) / Double(steps.count)
            if s > 1e-10 { r.shortTerm = lufs(s) }
        }
        r.integrated = integrated()
        if peak > 0 { r.truePeak = 20 * log10(Double(peak)) }
        publish?(r)
    }

    func integrated() -> Double? {
        guard !blocks.isEmpty else { return nil }
        let relative = lufs(blocks.reduce(0, +) / Double(blocks.count)) - 10
        let gated = blocks.filter { lufs($0) > relative }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

/// One row of "Measure full mix".
struct MixMeasure: Identifiable {
    var id: String { name }
    var name: String
    var lufs: Double?
    var truePeak: Double
}

extension Exporter {
    /// Renders the session once and measures every format it folds to.
    static func measure(_ p: Project, resolve: (Take) -> URL?) throws -> [MixMeasure] {
        var bed = try immersive(p, layout: .bed714, resolve: resolve).channels
        BusProcessor.run(&bed, p.dynamics ?? BusDynamics())
        let folding = Downmix.trimmed(bed, p)
        var s51 = Downmix.fold51(folding)
        var lr = Downmix.loRo(s51)
        // Folding adds channels together, so the folds get the limiter again, linked across their own channels.
        BusProcessor.run(&s51, BusProcessor.limiterOnly(p.dynamics))
        BusProcessor.run(&lr, BusProcessor.limiterOnly(p.dynamics))
        let sp = Downmix.speakers(folding)
        return [
            MixMeasure(name: "7.1.4", lufs: Downmix.loudness(bed, weights: Downmix.weights714), truePeak: Downmix.truePeak(bed)),
            MixMeasure(name: "5.1", lufs: Downmix.loudness(s51, weights: Downmix.weights51), truePeak: Downmix.truePeak(s51)),
            MixMeasure(name: "Stereo fold-down", lufs: Downmix.loudness(lr), truePeak: Downmix.truePeak(lr)),
            MixMeasure(name: "Laptop and phone", lufs: Downmix.loudness([sp.left, sp.right]), truePeak: Downmix.truePeak([sp.left, sp.right])),
        ]
    }
}
