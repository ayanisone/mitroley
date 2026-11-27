import AVFoundation
import simd

/// Decodes audio files once into 48 kHz stereo float buffers and keeps waveform peaks for drawing.
final class AudioCache {
    static let shared = AudioCache()
    static let sampleRate = 48000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    /// How many points a second a waveform is measured at. More shows finer shape when zoomed far in. Chosen in Settings.
    static var peaksPerSecond: Double {
        let v = UserDefaults.standard.double(forKey: "waveDetail")
        return [200, 400, 800, 1600, 3200].contains(v) ? v : 800
    }
    /// Forgets every measured waveform, so they are measured again at the detail now chosen.
    func resetPeaks() { lock.lock(); peakCache = [:]; bandCache = [:]; extremeCache = [:]; lock.unlock() }
    private var bandCache: [String: [SIMD3<Float>]] = [:]
    private var extremeCache: [String: [SIMD2<Float>]] = [:]

    /// The lowest and highest the sound reaches in every step (see peaksPerSecond), mono-summed, signs kept: what a
    /// zoomed-out waveform is drawn from.
    func extremes(_ url: URL) -> [SIMD2<Float>] {
        let rate = Self.peaksPerSecond
        let key = url.path + "@\(Int(rate))"
        lock.lock()
        if let e = extremeCache[key] { lock.unlock(); return e }
        lock.unlock()
        guard let b = buffer(url), let ch = b.floatChannelData else { return [] }
        let n = Int(b.frameLength), step = max(4, Int(Self.sampleRate / rate))
        var out = [SIMD2<Float>](repeating: .zero, count: max(1, n / step))
        let l = ch[0], r = ch[1]
        for i in 0..<out.count {
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            let base = i * step
            for j in 0..<step {
                let v = (l[base + j] + r[base + j]) * 0.5
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            out[i] = SIMD2(lo, hi)
        }
        lock.lock()
        extremeCache[key] = out
        lock.unlock()
        return out
    }

    /// How much of the sound is low (under about 200 Hz), middle, and high (over about 2.5 kHz) in every step of the
    /// waveform, for colouring it by what it is made of. Two gentle filters split the sound; cheap, and measured once.
    func bands(_ url: URL) -> [SIMD3<Float>] {
        let rate = Self.peaksPerSecond
        let key = url.path + "@\(Int(rate))"
        lock.lock()
        if let b = bandCache[key] { lock.unlock(); return b }
        lock.unlock()
        guard let b = buffer(url), let ch = b.floatChannelData else { return [] }
        let n = Int(b.frameLength), step = max(4, Int(Self.sampleRate / rate))
        var out = [SIMD3<Float>](repeating: .zero, count: max(1, n / step))
        let l = ch[0], r = ch[1]
        let a1 = Float(1 - exp(-2 * Double.pi * 200 / Self.sampleRate)), a2 = Float(1 - exp(-2 * Double.pi * 2500 / Self.sampleRate))
        var lp1: Float = 0, lp2: Float = 0
        for i in 0..<out.count {
            var m = SIMD3<Float>.zero
            let base = i * step
            for j in 0..<step {
                let x = (l[base + j] + r[base + j]) * 0.5
                lp1 += a1 * (x - lp1)
                lp2 += a2 * (x - lp2)
                m = simd_max(m, SIMD3(abs(lp1), abs(lp2 - lp1), abs(x - lp2)))
            }
            out[i] = m
        }
        lock.lock()
        bandCache[key] = out
        lock.unlock()
        return out
    }

    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var peakCache: [String: [Float]] = [:]
    private let lock = NSLock()

    func buffer(_ url: URL) -> AVAudioPCMBuffer? {
        let key = url.path
        lock.lock()
        if let b = buffers[key] { lock.unlock(); return b }
        lock.unlock()
        guard let decoded = Self.decode(url) else { return nil }
        lock.lock()
        buffers[key] = decoded
        lock.unlock()
        return decoded
    }

    func duration(_ url: URL) -> Double {
        guard let b = buffer(url) else { return 0 }
        return Double(b.frameLength) / Self.sampleRate
    }

    /// Absolute peak per step (see peaksPerSecond), mono-summed. Cheap enough to compute on first draw.
    func peaks(_ url: URL) -> [Float] {
        let rate = Self.peaksPerSecond
        let key = url.path + "@\(Int(rate))"
        lock.lock()
        if let p = peakCache[key] { lock.unlock(); return p }
        lock.unlock()
        guard let b = buffer(url), let ch = b.floatChannelData else { return [] }
        let n = Int(b.frameLength), step = max(4, Int(Self.sampleRate / rate))
        var out = [Float](repeating: 0, count: max(1, n / step))
        let l = ch[0], r = ch[1]
        for i in 0..<out.count {
            var m: Float = 0
            let base = i * step
            var j = 0
            while j < step {
                let v = abs(l[base + j] + r[base + j]) * 0.5
                if v > m { m = v }
                j += step >= 64 ? 4 : 1
            }
            out[i] = m
        }
        lock.lock()
        peakCache[key] = out
        lock.unlock()
        return out
    }

    func forget(_ url: URL) {
        lock.lock()
        buffers[url.path] = nil
        peakCache[url.path] = nil
        lock.unlock()
    }

    private static func decode(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        do { try file.read(into: inBuf) } catch { return nil }

        // 1. Resample (keeping the channel count) if the file is not 48 kHz.
        var src = inBuf
        if inFormat.sampleRate != sampleRate {
            guard let mid = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: inFormat.channelCount),
                  let conv = AVAudioConverter(from: inFormat, to: mid) else { return nil }
            let cap = AVAudioFrameCount(Double(frames) * sampleRate / inFormat.sampleRate) + 4096
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: mid, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if fed { outStatus.pointee = .endOfStream; return nil }
                fed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            guard status != .error, outBuf.frameLength > 0 else { return nil }
            src = outBuf
        }

        // 2. Map to stereo by hand: mono is doubled, anything wider keeps its first two channels.
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: src.frameLength),
              let s = src.floatChannelData, let d = out.floatChannelData else { return nil }
        out.frameLength = src.frameLength
        let bytes = Int(src.frameLength) * MemoryLayout<Float>.size
        memcpy(d[0], s[0], bytes)
        memcpy(d[1], src.format.channelCount > 1 ? s[1] : s[0], bytes)
        return out
    }
}
