import AVFoundation

/// Decodes audio files once into 48 kHz stereo float buffers and keeps waveform peaks for drawing.
final class AudioCache {
    static let shared = AudioCache()
    static let sampleRate = 48000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    static let peaksPerSecond = 200.0

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

    /// Absolute peak per 1/200 s, mono-summed. Cheap enough to compute on first draw.
    func peaks(_ url: URL) -> [Float] {
        let key = url.path
        lock.lock()
        if let p = peakCache[key] { lock.unlock(); return p }
        lock.unlock()
        guard let b = buffer(url), let ch = b.floatChannelData else { return [] }
        let n = Int(b.frameLength), step = Int(Self.sampleRate / Self.peaksPerSecond)
        var out = [Float](repeating: 0, count: max(1, n / step))
        let l = ch[0], r = ch[1]
        for i in 0..<out.count {
            var m: Float = 0
            let base = i * step
            var j = 0
            while j < step {
                let v = abs(l[base + j] + r[base + j]) * 0.5
                if v > m { m = v }
                j += 4
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
