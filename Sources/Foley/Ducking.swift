import AVFoundation

// mitroley. Copyright © 2026 Ayan Mitra.

/// Music dipping under voice. Off unless switched on for a music track.
struct Duck: Codable, Equatable {
    var depth = 9.0     // dB the music drops by while someone is speaking
    var source: UUID?   // the track it listens to; nil = every voice
}

enum VoiceActivity {
    /// Stretches of a recording where someone is speaking, in seconds. Looks at the level in the band speech
    /// lives in (300 Hz to 3.4 kHz), so music or rumble under a voice does not count as voice on its own.
    static func regions(left: [Float], right: [Float], sampleRate: Double = AudioCache.sampleRate, speech: Bool = true) -> [ClosedRange<Double>] {
        let n = min(left.count, right.count)
        guard n > Int(sampleRate / 4) else { return [] }
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { mono[i] = (left[i] + right[i]) * 0.5 }
        if speech { Downmix.bandpass(&mono, low: 300, high: 3400) }
        let hop = Int(sampleRate / 50)      // 20 ms
        let frames = n / hop
        var level = [Float](repeating: 0, count: frames)
        var top: Float = 0
        for f in 0..<frames {
            var acc: Float = 0
            for i in f * hop..<(f + 1) * hop { acc += mono[i] * mono[i] }
            level[f] = (acc / Float(hop)).squareRoot()
            top = max(top, level[f])
        }
        // Speaking = within 26 dB of the loudest moment, and never below -45 dBFS.
        let threshold = max(top * 0.05, 0.0056)
        guard top > threshold else { return [] }
        var out: [ClosedRange<Double>] = []
        var start: Int?
        for f in 0...frames {
            let on = f < frames && level[f] > threshold
            if on, start == nil { start = f }
            if !on, let s = start {
                out.append(Double(s) * 0.02...Double(f) * 0.02)
                start = nil
            }
        }
        return merge(out, gap: 0.4).filter { $0.upperBound - $0.lowerBound >= 0.15 }
    }

    /// Joins stretches that are closer together than `gap` seconds.
    static func merge(_ r: [ClosedRange<Double>], gap: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for x in r.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, x.lowerBound - last.upperBound < gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, x.upperBound)
            } else {
                out.append(x)
            }
        }
        return out
    }

    /// Volume keyframes that take the music down by `depth` dB under each stretch: down over 0.3 s just before
    /// the voice starts, back up over 0.6 s after it ends. Stretches close enough to pump are treated as one.
    static func keys(for regions: [ClosedRange<Double>], depth: Double, duration: Double) -> [Keyframe] {
        let down = 0.3, up = 0.6
        var keys: [Keyframe] = []
        for r in merge(regions, gap: down + up + 0.2) {
            let a = max(0, r.lowerBound - down), b = min(duration, r.upperBound + up)
            if a > 0.01 { keys.append(Keyframe(time: a, value: 0, curve: "smooth")) }
            keys.append(Keyframe(time: max(a, r.lowerBound), value: -depth))
            keys.append(Keyframe(time: min(b, r.upperBound), value: -depth, curve: "smooth"))
            if b < duration - 0.01 { keys.append(Keyframe(time: b, value: 0)) }
        }
        return keys
    }
}

extension Store {
    /// Where voice is heard on the timeline: every clip on a voice track, and the film's own sound when it is turned up.
    /// With `source`, it listens to that one track instead, whatever is on it.
    nonisolated static func voiceRegions(_ p: Project, folder: URL, video: URL?, source: UUID? = nil) -> (regions: [ClosedRange<Double>], filmUnreadable: Bool) {
        var all: [ClosedRange<Double>] = []
        let speech = source == nil || p.tracks.first { $0.id == source }?.kind == .dialogue
        func regions(of url: URL) -> [ClosedRange<Double>]? {
            guard let buf = AudioCache.shared.buffer(url), let ch = buf.floatChannelData, buf.frameLength > 0 else { return nil }
            let n = Int(buf.frameLength)
            return VoiceActivity.regions(left: Array(UnsafeBufferPointer(start: ch[0], count: n)), right: Array(UnsafeBufferPointer(start: ch[1], count: n)), speech: speech)
        }
        let anySolo = p.anySolo
        for t in p.tracks where (source == nil ? t.kind == .dialogue && !t.mute && (!anySolo || t.solo) : t.id == source) {
            for c in t.clips where c.muted != true {
                guard let take = c.take, let found = regions(of: Store.url(for: take, in: folder)) else { continue }
                let speed = max(0.01, c.speed)
                for r in found {
                    // File time → timeline time, kept inside the clip.
                    let a = c.start + (r.lowerBound - c.offset) / speed, b = c.start + (r.upperBound - c.offset) / speed
                    let lo = max(c.start, a), hi = min(c.end, b)
                    if hi - lo > 0.1 { all.append(lo...hi) }
                }
            }
        }
        var unreadable = false
        if source == nil, p.videoVolume > 0.001, let video {
            if let found = regions(of: video) { all += found.filter { $0.lowerBound < p.duration } } else { unreadable = true }
        }
        return (VoiceActivity.merge(all, gap: 0.4), unreadable)
    }

    /// Switches ducking on a music track on (writing its volume lane) or off (clearing it).
    func setDucking(_ id: UUID, on: Bool, depth: Double? = nil, source: UUID?? = nil) async {
        guard let track = project.tracks.first(where: { $0.id == id }) else { return }
        if !on {
            guard track.duck != nil else { return }
            mutate { p in
                guard let i = p.trackIndex(id) else { return }
                p.tracks[i].duck = nil
                p.tracks[i].automation[AutoParam.volume.rawValue] = nil
            }
            return
        }
        let d = min(24, max(2, depth ?? track.duck?.depth ?? Duck().depth))
        // The track it listens to: the one asked for, else the one it already had, else every voice. Never itself.
        var from = source ?? track.duck?.source
        if from == id || !project.tracks.contains(where: { $0.id == from }) { from = nil }
        let p = project, folder = self.folder, video = videoURL
        busy = from == nil ? "Listening for voice" : "Listening to the other track"
        let found = await Task.detached(priority: .userInitiated) { Store.voiceRegions(p, folder: folder, video: video, source: from) }.value
        busy = nil
        guard !found.regions.isEmpty else {
            if let from, let name = project.tracks.first(where: { $0.id == from })?.name {
                say("Nothing is heard on \(name) to duck under.", error: true)
                return
            }
            say(found.filmUnreadable ? "Could not read the film's own sound to find the voice. Put the voice on a Voice-over track, or use File › Use the Film's Own Sound first."
                                     : "No voice found to duck under. It looks on Voice-over tracks, and in the film's own sound when that is turned up.", error: true)
            return
        }
        let keys = VoiceActivity.keys(for: found.regions, depth: d, duration: p.duration)
        let replaced = track.duck == nil && !(track.automation[AutoParam.volume.rawValue] ?? []).isEmpty
        mutate { p in
            guard let i = p.trackIndex(id) else { return }
            p.tracks[i].duck = Duck(depth: d, source: from)
            p.tracks[i].automation[AutoParam.volume.rawValue] = keys
            p.tracks[i].lane = .volume
        }
        let count = VoiceActivity.merge(found.regions, gap: 1.1).count
        say("\(track.name) dips \(String(format: "%.0f", d)) dB under \(count) \(from == nil ? "voice " : "")passage\(count == 1 ? "" : "s")\(from.flatMap { f in project.tracks.first { $0.id == f }?.name }.map { " of " + $0 } ?? ""). The points are in its Volume lane."
            + (replaced ? " This replaced the volume automation that was there; Undo brings it back." : ""))
    }
}
