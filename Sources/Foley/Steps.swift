import Foundation

/// Finds the separate hits inside a recording (each footstep in a walk), so they can be placed one by one.
enum Steps {
    struct Slice {
        var start: Double
        var length: Double
        var peak: Double
    }

    static func slices(_ url: URL) -> [Slice] {
        guard let buf = AudioCache.shared.buffer(url), let ch = buf.floatChannelData, buf.frameLength > 4800 else { return [] }
        let n = Int(buf.frameLength), sr = AudioCache.sampleRate, hop = Int(sr * 0.004)
        // Loudness every 4 ms.
        var env: [Double] = []
        var i = 0
        while i + hop <= n {
            var s = 0.0
            for j in i..<(i + hop) { let v = Double(ch[0][j] + ch[1][j]) * 0.5; s += v * v }
            env.append((s / Double(hop)).squareRoot())
            i += hop
        }
        guard let top = env.max(), top > 0.003 else { return [] }
        let floor = env.sorted()[env.count / 5]
        let on = max(top * 0.14, floor * 4), off = max(top * 0.035, floor * 1.5)
        var out: [Slice] = []
        var k = 0
        while k < env.count {
            guard env[k] > on else { k += 1; continue }
            // Walk back to where the hit really begins.
            var a = k
            while a > 0, env[a - 1] > off, k - a < 8 { a -= 1 }
            var b = k, quiet = 0, peak = 0.0
            while b < env.count {
                peak = max(peak, env[b])
                quiet = env[b] < off ? quiet + 1 : 0
                // The hit ends after 60 ms of quiet, when the next one starts, or after 0.7 s.
                if quiet >= 15 || b - a > 175 { break }
                if b - k > 20, env[b] > on, env[b] > env[max(0, b - 6)] * 2.2 { break }
                b += 1
            }
            let start = max(0, Double(a) * 0.004 - 0.004), end = Double(b) * 0.004
            if end - start >= 0.05 { out.append(Slice(start: start, length: end - start, peak: peak)) }
            k = max(b, k + 1)
        }
        // Drop faint blips that are not steps.
        let peaks = out.map(\.peak).sorted()
        guard let median = peaks.isEmpty ? nil : peaks[peaks.count / 2] else { return [] }
        return out.filter { $0.peak >= median * 0.3 }
    }
}
