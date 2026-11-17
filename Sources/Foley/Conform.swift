import AVFoundation
import Foundation

/// Fits a session to a revised cut of its film: finds which picture in the new cut is the same as in the
/// old one, moves every sound with its picture, and reports the stretches that are new and still need sound.
enum Conform {
    struct Frame {
        var t: Double
        var diff: Double        // change from the frame before, 0…1 (used to find cuts)
        var print: [Float]      // 16×9 brightness pattern with its average removed
    }

    struct Report {
        var kept = 0, moved = 0, longer = 0, shorter = 0, new = 0, removed = 0
        var clipsKept = 0, clipsRemoved = 0
        var summary: String {
            var parts: [String] = []
            func add(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") } }
            add(kept + moved, "shot unchanged", "shots unchanged")
            add(shorter, "shot shortened", "shots shortened")
            add(longer, "shot extended", "shots extended")
            add(new, "new shot", "new shots")
            add(removed, "shot removed", "shots removed")
            var s = parts.joined(separator: ", ") + "."
            s += " \(clipsKept) sound\(clipsKept == 1 ? "" : "s") carried over"
            if clipsRemoved > 0 { s += ", \(clipsRemoved) dropped with removed picture" }
            return s + "."
        }
    }

    // MARK: Reading the picture

    static func frames(_ url: URL) async -> [Frame] {
        await Task.detached(priority: .userInitiated) { () -> [Frame] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let w = 64, h = 36, n = w * h * 3
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return [] }
            var prev = [UInt8](repeating: 0, count: n), cur = [UInt8](repeating: 0, count: n)
            var hasPrev = false
            var out: [Frame] = []
            while let sb = output.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                if let basePtr = CVPixelBufferGetBaseAddress(pb) {
                    let rowBytes = CVPixelBufferGetBytesPerRow(pb)
                    let pw = min(w, CVPixelBufferGetWidth(pb)), ph = min(h, CVPixelBufferGetHeight(pb))
                    let p = basePtr.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<ph {
                        for x in 0..<pw {
                            let o = y * rowBytes + x * 4, q = (y * w + x) * 3
                            cur[q] = p[o]; cur[q + 1] = p[o + 1]; cur[q + 2] = p[o + 2]
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                var d = 0.0
                if hasPrev {
                    var sum = 0
                    for i in 0..<n { sum += abs(Int(cur[i]) - Int(prev[i])) }
                    d = Double(sum) / Double(n) / 255
                }
                // 16×9 blocks of 4×4 pixels, brightness only, average removed so a small grade change still matches.
                var fp = [Float](repeating: 0, count: 144)
                var mean: Float = 0
                for by in 0..<9 {
                    for bx in 0..<16 {
                        var s = 0
                        for y in (by * 4)..<(by * 4 + 4) {
                            for x in (bx * 4)..<(bx * 4 + 4) {
                                let q = (y * w + x) * 3
                                s += Int(cur[q]) + 2 * Int(cur[q + 1]) + Int(cur[q + 2])
                            }
                        }
                        let v = Float(s) / (16 * 4 * 255)
                        fp[by * 16 + bx] = v
                        mean += v
                    }
                }
                mean /= 144
                for i in 0..<144 { fp[i] -= mean }
                out.append(Frame(t: CMSampleBufferGetPresentationTimeStamp(sb).seconds, diff: d, print: fp))
                swap(&prev, &cur)
                hasPrev = true
            }
            return out.sorted { $0.t < $1.t }
        }.value
    }

    private static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<144 { s += abs(a[i] - b[i]) }
        return s / 144
    }

    static func shots(_ f: [Frame], duration: Double) -> [(start: Double, end: Double)] {
        let cuts = VideoAnalysis.cuts(from: f.dropFirst().map { ($0.t, $0.diff) })
        let edges = [0.0] + cuts.filter { $0 > 0.05 && $0 < duration - 0.05 } + [duration]
        return (0..<(edges.count - 1)).map { (edges[$0], edges[$0 + 1]) }
    }

    // MARK: Matching

    /// Index of the frame showing at time `t`.
    private static func index(_ f: [Frame], at t: Double) -> Int? {
        guard let first = f.first, let last = f.last, t >= first.t - 0.02, t <= last.t + 0.06 else { return nil }
        var lo = 0, hi = f.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if f[mid].t <= t + 0.004 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Same-picture stretches of the new cut, and the stretches with no match.
    static func match(old: [Frame], new: [Frame], oldShots: [(start: Double, end: Double)], newShots: [(start: Double, end: Double)],
                      threshold: Float = 0.022) -> (segments: [RevisionSegment], ranges: [RevisionRange], report: Report) {
        var segments: [RevisionSegment] = [], ranges: [RevisionRange] = []
        var report = Report()
        var usedOld = Set<Int>()
        let frameTime = new.count > 1 ? (new.last!.t - new.first!.t) / Double(new.count - 1) : 1.0 / 24
        func oldShot(at t: Double) -> Int? { oldShots.firstIndex { t >= $0.start - 0.001 && t < $0.end } }

        for shot in newShots {
            let idx = new.indices.filter { new[$0].t >= shot.start - 0.004 && new[$0].t < shot.end - 0.004 }
            guard idx.count >= 2 else {
                ranges.append(RevisionRange(start: shot.start, end: shot.end, kind: "new")); report.new += 1
                continue
            }
            // Candidate shifts: where a few frames of this shot look most like a frame of the old cut,
            // plus lining the shot up with the start and the end of each old shot those frames fall in.
            var aligned: [Double] = [], probed: [Double] = []
            let probes = stride(from: 0, to: idx.count, by: max(1, idx.count / 7)).map { idx[min(idx.count - 1, $0 + min(1, idx.count - 1))] }
            for i in Set(probes) {
                var best = Float.greatestFiniteMagnitude, bestJ = -1
                for j in old.indices {
                    let d = distance(new[i].print, old[j].print)
                    if d < best { best = d; bestJ = j }
                }
                guard bestJ >= 0, best < threshold * 1.5 else { continue }
                probed.append(old[bestJ].t - new[i].t)
                if let s = oldShot(at: old[bestJ].t) {
                    aligned.append(oldShots[s].start - shot.start)
                    aligned.append(oldShots[s].end - shot.end)
                }
            }
            var candidates: [Double] = []
            for d in aligned + probed where !candidates.contains(where: { abs($0 - d) < frameTime * 0.4 }) { candidates.append(d) }

            var bestRun: (a: Int, b: Int, delta: Double, cost: Float)?
            for delta in candidates {
                // Longest run of frames that match at this shift, staying inside one old shot.
                var runStart: Int?, misses = 0, sum: Float = 0, lastGood = 0, runShot: Int?
                func close(_ end: Int) {
                    guard let a = runStart else { return }
                    let len = end - a + 1, cost = sum / Float(max(1, len))
                    if bestRun == nil || len > (bestRun!.b - bestRun!.a + 1) + 1 { bestRun = (a, end, delta, cost) }
                    runStart = nil; sum = 0; misses = 0; runShot = nil
                }
                for (k, i) in idx.enumerated() {
                    let told = new[i].t + delta
                    var ok = false
                    if let j = index(old, at: told) {
                        let s = oldShot(at: old[j].t)
                        let d = distance(new[i].print, old[j].print)
                        if d < threshold, runShot == nil || s == runShot {
                            ok = true
                            if runStart == nil { runStart = k; runShot = s }
                            sum += d; lastGood = k; misses = 0
                        }
                    }
                    if !ok, runStart != nil {
                        misses += 1
                        if misses > 2 { close(lastGood) }
                    }
                }
                if runStart != nil { close(lastGood) }
            }

            let need = min(idx.count, max(6, Int(0.25 / frameTime)))
            guard let run = bestRun, run.b - run.a + 1 >= need else {
                ranges.append(RevisionRange(start: shot.start, end: shot.end, kind: "new")); report.new += 1
                continue
            }
            // Snap a run that reaches the shot's first or last frame to the shot's edge.
            let a = run.a <= 1 ? shot.start : new[idx[run.a]].t
            let b = run.b >= idx.count - 2 ? shot.end : new[idx[run.b]].t + frameTime
            segments.append(RevisionSegment(start: a, end: b, delta: run.delta))
            var grew = false
            if a - shot.start > frameTime * 1.5 { ranges.append(RevisionRange(start: shot.start, end: a, kind: "longer")); grew = true }
            if shot.end - b > frameTime * 1.5 { ranges.append(RevisionRange(start: b, end: shot.end, kind: "longer")); grew = true }
            if let s = oldShot(at: (a + b) / 2 + run.delta) {
                usedOld.insert(s)
                let oldLen = oldShots[s].end - oldShots[s].start
                if grew { report.longer += 1 }
                else if (b - a) < oldLen - frameTime * 1.5 { report.shorter += 1 }
                else if abs(run.delta) > frameTime * 0.5 { report.moved += 1 }
                else { report.kept += 1 }
            } else { report.kept += 1 }
        }
        report.removed = oldShots.indices.filter { !usedOld.contains($0) }.count
        return (segments, ranges, report)
    }

    // MARK: Moving the session

    /// Rebuilds a project on the new cut's timeline.
    static func apply(_ old: Project, video: VideoRef, segments: [RevisionSegment], ranges: [RevisionRange], report r: Report) -> (Project, Report) {
        var p = old, report = r
        let segs = segments.sorted { $0.start < $1.start }
        /// New-cut time of an old-cut time, if that picture survived.
        func map(_ t: Double) -> Double? {
            for s in segs where t >= s.start + s.delta - 0.0005 && t < s.end + s.delta { return max(s.start, t - s.delta) }
            return nil
        }
        func segment(_ t: Double) -> Int? { segs.firstIndex { t >= $0.start + $0.delta - 0.0005 && t < $0.end + $0.delta } }
        func nextMapped(after t: Double, before limit: Double) -> Double? {
            var x = t
            while x < limit { if let m = map(x) { return m }; x += 0.04 }
            return nil
        }
        func lastMapped(before t: Double, after limit: Double) -> Double? {
            var x = t
            while x > limit { if let m = map(x) { return m + 0.04 }; x -= 0.04 }
            return nil
        }

        p.video = video
        p.duration = video.duration
        p.fps = video.fps
        p.loopStart = nil; p.loopEnd = nil

        for ti in p.tracks.indices {
            var kept: [Clip] = []
            let bedTrack = p.tracks[ti].kind == .ambience || p.tracks[ti].kind == .music
            for var c in p.tracks[ti].clips {
                let within = segment(c.start) != nil && segment(c.start) == segment(max(c.start, c.end - 0.02))
                if within, let s = map(c.start) {
                    c.start = s
                } else if c.loop || bedTrack || c.duration > 6 {
                    // A bed that runs across cuts: keep it from the first surviving moment to the last.
                    guard let s = map(c.start) ?? nextMapped(after: c.start, before: c.end) else { report.clipsRemoved += 1; continue }
                    let e = min(video.duration, lastMapped(before: c.end, after: c.start) ?? (s + c.duration))
                    if c.loop { c.duration = max(0.2, e - s) }
                    c.start = s
                    if !c.loop { c.duration = min(c.duration, max(0.2, video.duration - s)) }
                } else if let s = map(c.start) {
                    c.start = s     // a hit whose tail runs past the cut
                } else {
                    report.clipsRemoved += 1
                    continue
                }
                if c.start >= video.duration - 0.02 { report.clipsRemoved += 1; continue }
                report.clipsKept += 1
                kept.append(c)
            }
            p.tracks[ti].clips = kept
            for (param, keys) in p.tracks[ti].automation {
                var moved: [Keyframe] = []
                for var k in keys { if let t = map(k.time) { k.time = t; moved.append(k) } }
                moved.sort { $0.time < $1.time }
                p.tracks[ti].automation[param] = moved.isEmpty ? nil : moved
            }
        }

        // Scenes: carry every old scene with its picture, then add scenes for what is new.
        var scenes: [SceneRegion] = []
        var seen = Set<UUID>()
        for s in segs {
            let a = s.start + s.delta, b = s.end + s.delta
            for sc in old.scenes.sorted(by: { $0.start < $1.start }) where sc.end > a + 0.02 && sc.start < b - 0.02 {
                var piece = sc
                if !seen.insert(sc.id).inserted { piece.id = UUID() }
                piece.start = max(a, sc.start) - s.delta
                piece.end = min(b, sc.end) - s.delta
                piece.status = nil
                scenes.append(piece)
            }
        }
        scenes.sort { $0.start < $1.start }
        var count = 0
        for g in ranges.sorted(by: { $0.start < $1.start }) {
            if g.kind == "longer" {
                // The same shot, running longer: the neighbouring scene grows to cover it.
                if let i = scenes.firstIndex(where: { abs($0.start - g.end) < 0.05 }) { scenes[i].start = g.start; scenes[i].status = "longer"; continue }
                if let i = scenes.lastIndex(where: { abs($0.end - g.start) < 0.05 }) { scenes[i].end = g.end; scenes[i].status = "longer"; continue }
            }
            count += 1
            var sc = SceneRegion(start: g.start, end: g.end, name: "New shot \(count)")
            sc.status = "new"
            sc.note = "New in this cut. Needs a space and sound."
            scenes.append(sc)
        }
        scenes.sort { $0.start < $1.start }
        for i in scenes.indices {
            if i == 0 { scenes[i].start = 0 }
            if i + 1 < scenes.count { scenes[i].end = scenes[i + 1].start } else { scenes[i].end = video.duration }
        }
        p.scenes = scenes.filter { $0.end - $0.start > 0.02 }
        p.revision = Revision(from: old.name, ranges: ranges.sorted { $0.start < $1.start }, segments: segs, summary: "")
        p.revision?.summary = report.summary
        return (p, report)
    }
}
