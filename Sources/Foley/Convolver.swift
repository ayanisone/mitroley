import AVFoundation
import Accelerate

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// An impulse response cut into blocks and transformed, ready for the convolver.
final class IRData {
    let parts: Int
    let re: [UnsafeMutablePointer<Float>]   // per channel, parts × Convolver.size
    let im: [UnsafeMutablePointer<Float>]
    let seconds: Double

    /// `left` and `right` are the response at 48 kHz. Silence at the end is dropped, anything past six seconds is cut,
    /// and the level is set so a steady sound comes back about as loud as it went in.
    init?(left: [Float], right: [Float]) {
        let block = Convolver.block, size = Convolver.size
        var n = min(left.count, right.count, Convolver.maxParts * block)
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(left[i]), abs(right[i])) }
        guard peak > 0 else { return nil }
        while n > 1 && abs(left[n - 1]) < peak * 0.0001 && abs(right[n - 1]) < peak * 0.0001 { n -= 1 }
        var energy = 0.0
        for i in 0..<n { energy += Double(left[i] * left[i]) + Double(right[i] * right[i]) }
        let k = Float(1 / (energy / 2).squareRoot())
        parts = (n + block - 1) / block
        seconds = Double(n) / AudioCache.sampleRate
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else { return nil }
        defer { vDSP_DFT_DestroySetup(setup) }
        var re: [UnsafeMutablePointer<Float>] = [], im: [UnsafeMutablePointer<Float>] = []
        var tr = [Float](repeating: 0, count: size)
        let ti = [Float](repeating: 0, count: size)
        for src in [left, right] {
            let r = UnsafeMutablePointer<Float>.allocate(capacity: parts * size)
            let m = UnsafeMutablePointer<Float>.allocate(capacity: parts * size)
            for p in 0..<parts {
                for i in 0..<size { tr[i] = 0 }
                for i in 0..<block where p * block + i < n { tr[i] = src[p * block + i] * k }
                vDSP_DFT_Execute(setup, tr, ti, r + p * size, m + p * size)
            }
            re.append(r); im.append(m)
        }
        self.re = re; self.im = im
    }

    convenience init?(url: URL) {
        guard let buf = AudioCache.shared.buffer(url), let ch = buf.floatChannelData, buf.frameLength > 0 else { return nil }
        let n = Int(buf.frameLength)
        self.init(left: Array(UnsafeBufferPointer(start: ch[0], count: n)), right: Array(UnsafeBufferPointer(start: ch[1], count: n)))
    }

    deinit { for p in re + im { p.deallocate() } }
}

/// Stereo convolution reverb: left through the response's left channel, right through its right.
/// Works in blocks of 512 samples, so what comes out is 512 samples (about 11 ms) behind what went in.
/// Nothing is allocated while it runs.
final class Convolver {
    static let block = 512, size = 1024
    static let maxParts = 563       // six seconds

    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var ir: IRData?
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let input: [UnsafeMutablePointer<Float>]     // per channel: the last block and the one being filled
    private let output: [UnsafeMutablePointer<Float>]    // per channel: the block being played out
    private let lineRe: [UnsafeMutablePointer<Float>]    // per channel: spectra of the last maxParts blocks
    private let lineIm: [UnsafeMutablePointer<Float>]
    private let zero, accRe, accIm, outRe, outIm: UnsafeMutablePointer<Float>
    private var fill = 0, slot = 0

    init() {
        lock.initialize(to: os_unfair_lock())
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .INVERSE)!
        func buffer(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        input = [buffer(Self.size), buffer(Self.size)]
        output = [buffer(Self.block), buffer(Self.block)]
        lineRe = [buffer(Self.maxParts * Self.size), buffer(Self.maxParts * Self.size)]
        lineIm = [buffer(Self.maxParts * Self.size), buffer(Self.maxParts * Self.size)]
        zero = buffer(Self.size); accRe = buffer(Self.size); accIm = buffer(Self.size); outRe = buffer(Self.size); outIm = buffer(Self.size)
    }

    deinit {
        for p in input + output + lineRe + lineIm + [zero, accRe, accIm, outRe, outIm] { p.deallocate() }
        vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse)
        lock.deallocate()
    }

    /// Swaps in a new response (nil = silence). Call from any thread but the audio thread.
    func set(_ new: IRData?) {
        os_unfair_lock_lock(lock)
        let old = ir
        ir = new
        os_unfair_lock_unlock(lock)
        _ = old
    }

    /// In place.
    func process(_ ch: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        let block = Self.block, size = Self.size
        guard os_unfair_lock_trylock(lock) else {
            for c in 0..<2 { memset(ch[c], 0, frames * 4) }
            return
        }
        defer { os_unfair_lock_unlock(lock) }
        for n in 0..<frames {
            for c in 0..<2 {
                input[c][block + fill] = ch[c][n]
                ch[c][n] = output[c][fill]
            }
            fill += 1
            if fill == block {
                fill = 0
                for c in 0..<2 {
                    vDSP_DFT_Execute(forward, input[c], zero, lineRe[c] + slot * size, lineIm[c] + slot * size)
                    memset(accRe, 0, size * 4); memset(accIm, 0, size * 4)
                    if let ir {
                        var acc = DSPSplitComplex(realp: accRe, imagp: accIm)
                        for k in 0..<ir.parts {
                            let s = (slot - k + Self.maxParts) % Self.maxParts
                            var x = DSPSplitComplex(realp: lineRe[c] + s * size, imagp: lineIm[c] + s * size)
                            var h = DSPSplitComplex(realp: ir.re[c] + k * size, imagp: ir.im[c] + k * size)
                            vDSP_zvma(&x, 1, &h, 1, &acc, 1, &acc, 1, vDSP_Length(size))
                        }
                    }
                    vDSP_DFT_Execute(inverse, accRe, accIm, outRe, outIm)
                    var scale = 1 / Float(size)
                    vDSP_vsmul(outRe + block, 1, &scale, output[c], 1, vDSP_Length(block))
                    memcpy(input[c], input[c] + block, block * 4)
                }
                slot = (slot + 1) % Self.maxParts
            }
        }
    }
}

/// The convolver as an audio unit, used in place of the built-in reverb for a space that has an impulse response.
final class ConvolverAU: AUAudioUnit {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6d636e76 /* mcnv */,
                                                componentManufacturer: 0x4d747279 /* Mtry */, componentFlags: 0, componentFlagsMask: 0)
    static let registered: Bool = {
        AUAudioUnit.registerSubclass(ConvolverAU.self, as: desc, name: "mitroley: IR reverb", version: 1)
        return true
    }()

    let dsp = Convolver()
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

    override var internalRenderBlock: AUInternalRenderBlock {
        let dsp = self.dsp
        let scratchList = scratch.mutableAudioBufferList
        let capacity = Int(scratch.frameCapacity)
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
