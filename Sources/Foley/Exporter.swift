import AVFoundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case movie, stereo, stems, groupStems, binaural, bed714, surround51, stereoFold, speakers, mixdowns, adm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .movie: "Movie with mix"
        case .stereo: "Stereo mix"
        case .stems: "Stems, one per track"
        case .groupStems: "Stems, one per group"
        case .binaural: "Binaural (headphones)"
        case .bed714: "7.1.4 immersive"
        case .surround51: "5.1 surround"
        case .stereoFold: "Stereo fold-down (Lo/Ro)"
        case .speakers: "Stereo for laptop and phone speakers"
        case .mixdowns: "Mixdown set"
        case .adm: "ADM BWF for Atmos"
        }
    }
    var detail: String {
        switch self {
        case .movie: "The video with the stereo mix attached. QuickTime .mov"
        case .stereo: "48 kHz, 24-bit WAV"
        case .stems: "A folder with one stereo WAV for every track, each with its space and automation. All start at 0:00 and are the same length, so they line up in any DAW. Muted tracks are left out"
        case .groupStems: "The same, with one WAV per group (SFX, Ambience, Music …) and one for each track outside a group"
        case .binaural: "Spatial mix folded to headphones. 48 kHz, 24-bit WAV"
        case .bed714: "12-channel WAV, objects panned into a 7.1.4 room"
        case .surround51: "6-channel WAV (L R C LFE Ls Rs) folded from the 7.1.4 mix: heights into the front speakers, rear surrounds into the side surrounds"
        case .stereoFold: "The standard Lo/Ro fold-down of that 5.1: what a TV or streaming service does to a surround mix on a stereo set. The LFE is left out, as they do"
        case .speakers: "Folded from the 7.1.4 mix to keep as much of the surround impression as two small speakers can: surrounds widened past the speakers, heights brightened, deep bass carried by its harmonics. Checked to hold up in mono. Aimed at -14 LUFS, peaks held at -1 dBTP"
        case .mixdowns: "A folder with the 7.1.4, the 5.1, the stereo fold-down, the laptop and phone stereo and its mono sum (what one phone speaker plays), all from one render, and a sheet with the loudness of each"
        case .adm: "7.1.2 bed plus one object per spatial track with position data, for Logic Pro, Pro Tools, Resolve or the Dolby Atmos Renderer. Experimental"
        }
    }
    var ext: String { self == .movie ? "mov" : "wav" }
    var isFolder: Bool { self == .stems || self == .groupStems || self == .mixdowns }
    var suffix: String {
        switch self {
        case .movie: "mix"
        case .stereo: "stereo"
        case .stems: "stems"
        case .groupStems: "group stems"
        case .binaural: "binaural"
        case .bed714: "7.1.4"
        case .surround51: "5.1"
        case .stereoFold: "stereo fold-down"
        case .speakers: "laptop and phone"
        case .mixdowns: "mixdowns"
        case .adm: "atmos.adm"
        }
    }
}

struct ExportError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum Exporter {
    static let sr = AudioCache.sampleRate

    /// Renders one pass of the project offline. Returns left and right.
    static func render(_ p: Project, mode: MonitorMode, stem: Stem = .full, tail: Double = 2.5,
                       resolve: (Take) -> URL?) throws -> (l: [Float], r: [Float]) {
        let g = try MixGraph(offline: true)
        g.rebuildIfNeeded(p)
        g.configureSpaces(p)
        g.loadClips(p, resolve: resolve)
        g.apply(p, at: 0, mode: mode, stem: stem, snap: true)
        try g.engine.start()
        g.seek(to: 0, playing: true)
        let total = Int((p.duration + tail) * sr)
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        guard let buf = AVAudioPCMBuffer(pcmFormat: g.engine.manualRenderingFormat, frameCapacity: 512) else {
            throw ExportError(message: "Could not allocate a render buffer.")
        }
        var done = 0
        while done < total {
            let n = min(512, total - done)
            g.apply(p, at: Double(done) / sr, mode: mode, stem: stem)
            let status = try g.engine.renderOffline(AVAudioFrameCount(n), to: buf)
            guard status == .success, let ch = buf.floatChannelData else {
                throw ExportError(message: "Offline render stopped early.")
            }
            let got = Int(buf.frameLength)
            if got == 0 { break }
            l.withUnsafeMutableBufferPointer { memcpy($0.baseAddress! + done, ch[0], got * 4) }
            r.withUnsafeMutableBufferPointer { memcpy($0.baseAddress! + done, ch[1], got * 4) }
            done += got
        }
        g.engine.stop()
        return (l, r)
    }

    /// Runs the export and returns a short human summary.
    static func export(_ p: Project, format: ExportFormat, to url: URL, videoURL: URL?,
                       resolve: (Take) -> URL?) async throws -> String {
        switch format {
        case .stereo, .binaural:
            let mix = try render(p, mode: format == .binaural ? .spatial : .stereo, resolve: resolve)
            var ch = [mix.l, mix.r]
            let bus = BusProcessor.run(&ch, p.bus)
            let trim = protect(&ch)
            try WAV.write(url, channels: ch)
            return summary(ch, trim: trim) + busNote(bus)
        case .stems, .groupStems:
            // Each stem is the full mix with everything else silenced, so the stems add up to the mix.
            var units: [(name: String, ids: Set<UUID>)] = []
            let anySolo = p.anySolo
            for t in p.tracks {
                let g = p.group(t.groupID)
                let audible = !t.mute && g?.mute != true && (!anySolo || t.solo || g?.solo == true)
                guard audible, t.clips.contains(where: { $0.take != nil }) else { continue }
                if format == .groupStems, let g {
                    if let i = units.firstIndex(where: { $0.name == g.name }) { units[i].ids.insert(t.id) } else { units.append((g.name, [t.id])) }
                } else {
                    units.append((t.name, [t.id]))
                }
            }
            guard !units.isEmpty else { throw ExportError(message: "There is nothing audible to export.") }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var rendered: [(name: String, ch: [[Float]])] = []
            var peak: Float = 0
            for u in units {
                var q = p
                for i in q.tracks.indices { q.tracks[i].solo = false; q.tracks[i].mute = !u.ids.contains(q.tracks[i].id) }
                q.groups = q.groups?.map { var g = $0; g.solo = false; g.mute = false; return g }
                let mix = try render(q, mode: .stereo, resolve: resolve)
                for c in [mix.l, mix.r] { for v in c { peak = max(peak, abs(v)) } }
                rendered.append((u.name, [mix.l, mix.r]))
            }
            // One shared trim if anything would clip, so the balance between stems is kept.
            let trim: Float = peak > 0.98 ? 0.98 / peak : 1
            var used = Set<String>()
            for (i, r) in rendered.enumerated() {
                var name = r.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                while !used.insert(name).inserted { name += " 2" }
                let ch = trim < 1 ? r.ch.map { $0.map { $0 * trim } } : r.ch
                try WAV.write(url.appendingPathComponent(String(format: "%02d %@.wav", i + 1, name)), channels: ch)
            }
            return "\(rendered.count) stems, 48 kHz 24-bit" + (trim < 1 ? String(format: ", all lowered %.1f dB to avoid clipping", -20 * log10(trim)) : "") + "."
        case .movie:
            guard let videoURL else { throw ExportError(message: "There is no video in this project to attach the mix to.") }
            let mix = try render(p, mode: .stereo, tail: 0, resolve: resolve)
            var ch = [mix.l, mix.r]
            BusProcessor.run(&ch, p.bus)
            let trim = protect(&ch)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try WAV.write(tmp, channels: ch)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await mux(video: videoURL, audio: tmp, to: url)
            return summary(ch, trim: trim)
        case .bed714:
            var ch = try immersive(p, layout: .bed714, resolve: resolve).channels
            let bus = BusProcessor.run(&ch, p.bus)
            let trim = protect(&ch)
            try WAV.write(url, channels: ch, channelMask: 0x2D63F)
            return "12 channels (L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr). " + summary(ch, trim: trim) + busNote(bus)
        case .surround51, .stereoFold, .speakers, .mixdowns:
            return try exportFolds(p, format: format, to: url, resolve: resolve)   // Downmix.swift
        case .adm:
            let out = try immersive(p, layout: .adm, resolve: resolve)
            var ch = out.channels
            BusProcessor.run(&ch, p.bus)
            let trim = protect(&ch)
            let frames = ch.first?.count ?? 0
            let adm = ADM.build(project: p, objects: out.objects, frames: frames)
            try WAV.write(url, channels: ch, extra: [("chna", adm.chna), ("axml", adm.axml)])
            return "7.1.2 bed + \(out.objects.count) object\(out.objects.count == 1 ? "" : "s"). " + summary(ch, trim: trim)
        }
    }

    // MARK: Immersive

    enum Layout { case bed714, adm }

    /// Prints stems (dry bed, reverb, each object) and lays them out for 7.1.4 or for an ADM bed + objects.
    static func immersive(_ p: Project, layout: Layout, resolve: (Take) -> URL?) throws -> (channels: [[Float]], objects: [Track]) {
        let bed = try render(p, mode: .stereo, stem: .bedDry, resolve: resolve)
        let verb = try render(p, mode: .stereo, stem: .reverb, resolve: resolve)
        let n = bed.l.count
        let objects = p.tracks.filter { $0.spatial && !$0.clips.isEmpty }
        let bedCount = layout == .bed714 ? 12 : 10
        var ch = [[Float]](repeating: [Float](repeating: 0, count: n), count: bedCount)

        // Channel indexes for the two layouts.
        // 7.1.4 (WAV mask order): L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr
        // ADM 7.1.2 bed:          L R C LFE Lss Rss Lrs Rrs Lts Rts
        let side = layout == .bed714 ? (6, 7) : (4, 5)
        let rear = layout == .bed714 ? (4, 5) : (6, 7)
        func add(_ src: [Float], to c: Int, gain: Float) {
            ch[c].withUnsafeMutableBufferPointer { d in
                for i in 0..<n { d[i] += src[i] * gain }
            }
        }
        add(bed.l, to: 0, gain: 1); add(bed.r, to: 1, gain: 1)
        // Reverb wraps around the listener so rooms feel like rooms.
        add(verb.l, to: 0, gain: 0.8); add(verb.r, to: 1, gain: 0.8)
        // With the Surround reverb effect, each speaker pair away from the front gets its own decorrelated copy, so the
        // room surrounds the listener instead of being one reverb played from five places. Without it they share the front's.
        let spread = Float(min(1, max(0, p.surroundSpread)))
        func wide(_ x: [Float], _ seed: UInt64) -> [Float] {
            guard spread > 0 else { return x }
            var d = decorrelate(x, seed: seed)
            if spread < 1 { for i in d.indices { d[i] = d[i] * spread + x[i] * (1 - spread) } }
            return d
        }
        add(wide(verb.l, 11), to: side.0, gain: 0.45); add(wide(verb.r, 12), to: side.1, gain: 0.45)
        add(wide(verb.l, 21), to: rear.0, gain: 0.3); add(wide(verb.r, 22), to: rear.1, gain: 0.3)
        add(wide(verb.l, 31), to: 8, gain: 0.3); add(wide(verb.r, 32), to: 9, gain: 0.3)
        if layout == .bed714 { add(wide(verb.l, 41), to: 10, gain: 0.2); add(wide(verb.r, 42), to: 11, gain: 0.2) }

        // The sub: the low end of every track that sends to it, below 120 Hz.
        if p.tracks.contains(where: { $0.lfeSend > 0 && !$0.clips.isEmpty }) {
            var q = p
            for i in q.tracks.indices {
                let send = q.tracks[i].lfeSend
                q.tracks[i].spatial = false
                q.tracks[i].pan = 0
                q.tracks[i].automation[AutoParam.x.rawValue] = nil
                q.tracks[i].spaceMode = .dry
                if send > 0 { q.tracks[i].volume += linearToDb(send) } else { q.tracks[i].mute = true; q.tracks[i].solo = false }
            }
            let low = try render(q, mode: .stereo, resolve: resolve)
            var sub = [Float](repeating: 0, count: n)
            // −10 dB: playback systems reproduce the LFE channel 10 dB hotter than the others.
            for i in 0..<min(n, low.l.count) { sub[i] = (low.l[i] + low.r[i]) * 0.5 * 0.316 }
            lowpass(&sub, hz: 120); lowpass(&sub, hz: 120)
            add(sub, to: 3, gain: 1)
        }

        for tr in objects {
            let s = try render(p, mode: .stereo, stem: .object(tr.id), resolve: resolve)
            var monoSum = [Float](repeating: 0, count: n)
            for i in 0..<n { monoSum[i] = (s.l[i] + s.r[i]) * 0.5 }
            if layout == .adm {
                ch.append(monoSum)
            } else {
                // Pan into the room, updating the position every 256 samples.
                var gains = pan714(position(of: tr, in: p, at: 0))
                var i = 0
                while i < n {
                    let target = pan714(position(of: tr, in: p, at: Double(i) / sr))
                    let end = min(n, i + 256)
                    for c in 0..<12 {
                        let g0 = gains[c], g1 = target[c]
                        if g0 == 0 && g1 == 0 { continue }
                        let step = (g1 - g0) / Float(end - i)
                        var g = g0
                        for j in i..<end { ch[c][j] += monoSum[j] * g; g += step }
                    }
                    gains = target
                    i = end
                }
            }
        }
        return (ch, objects)
    }

    /// A copy of `x` that sounds the same but no longer lines up with it: a short burst of sparse, decaying
    /// impulses (velvet noise, 30 ms), different for every seed, with the same overall level.
    static func decorrelate(_ x: [Float], seed: UInt64) -> [Float] {
        let length = Int(0.03 * sr), count = 24
        var s = seed &* 0x9E3779B97F4A7C15 | 1
        func next() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s % 1_000_000) / 1_000_000
        }
        var taps: [(at: Int, gain: Float)] = []
        var energy = 0.0
        for k in 0..<count {
            // One impulse somewhere in each of `count` equal slots, random sign, fading over the burst.
            let at = Int((Double(k) + next()) * Double(length) / Double(count))
            let g = (next() < 0.5 ? -1.0 : 1.0) * exp(-3.0 * Double(at) / Double(length))
            taps.append((at, Float(g)))
            energy += g * g
        }
        let norm = Float(1 / energy.squareRoot())
        var out = [Float](repeating: 0, count: x.count)
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for t in taps {
                    let g = t.gain * norm
                    if t.at >= src.count { continue }
                    for i in t.at..<src.count { dst[i] += src[i - t.at] * g }
                }
            }
        }
        return out
    }

    /// Second-order Butterworth low-pass, in place.
    static func lowpass(_ x: inout [Float], hz: Double) {
        let w = 2 * Double.pi * hz / sr, cosw = cos(w), alpha = sin(w) / (2 * 0.7071)
        let a0 = 1 + alpha
        let b0 = Float((1 - cosw) / 2 / a0), b1 = Float((1 - cosw) / a0), b2 = b0
        let a1 = Float(-2 * cosw / a0), a2 = Float((1 - alpha) / a0)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in x.indices {
            let v = x[i]
            let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = y
            x[i] = y
        }
    }

    static func position(of tr: Track, in p: Project, at t: Double) -> Vec3 {
        p.mix(for: tr, at: t, anySolo: false).position
    }

    /// Room-centric amplitude panner. Output order: L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr.
    static func pan714(_ p: Vec3) -> [Float] {
        let x = min(1, max(-1, p.x)), y = min(1, max(-1, p.y)), z = min(1, max(0, p.z))
        let h = Double.pi / 2
        let bottom = cos(z * h), top = sin(z * h)
        let xr = (x + 1) / 2
        let left = cos(xr * h), right = sin(xr * h)
        var g = [Double](repeating: 0, count: 12)
        var front = 0.0, side = 0.0, rear = 0.0
        if y >= 0 { front = sin(y * h); side = cos(y * h) } else { side = cos(-y * h); rear = sin(-y * h) }
        // Front row uses the centre speaker.
        if x < 0 { g[0] = sin(-x * h) * front; g[2] = cos(-x * h) * front } else { g[1] = sin(x * h) * front; g[2] = cos(x * h) * front }
        g[6] = left * side; g[7] = right * side
        g[4] = left * rear; g[5] = right * rear
        for i in 0..<8 { g[i] *= bottom }
        let fy = (y + 1) / 2
        g[8] = left * sin(fy * h) * top; g[9] = right * sin(fy * h) * top
        g[10] = left * cos(fy * h) * top; g[11] = right * cos(fy * h) * top
        return g.map { Float($0) }
    }

    // MARK: Helpers

    /// Scales the whole mix down if it would clip. Returns the trim in dB (0 if untouched).
    static func protect(_ ch: inout [[Float]]) -> Double {
        var peak: Float = 0
        for c in ch { for v in c where abs(v) > peak { peak = abs(v) } }
        guard peak > 0.985 else { return 0 }
        let k = 0.985 / peak
        for c in ch.indices { for i in ch[c].indices { ch[c][i] *= k } }
        return Double(20 * log10(k))
    }

    /// What the master bus did to an export, for its summary line.
    static func busNote(_ r: (compressor: Double, limiter: Double)) -> String {
        var parts: [String] = []
        if r.compressor < -0.1 { parts.append(String(format: "compressor up to %.1f dB", -r.compressor)) }
        if r.limiter < -0.1 { parts.append(String(format: "limiter up to %.1f dB", -r.limiter)) }
        return parts.isEmpty ? "" : ". Master bus: " + parts.joined(separator: ", ")
    }

    static func summary(_ ch: [[Float]], trim: Double) -> String {
        var peak: Float = 0
        for c in ch { for v in c where abs(v) > peak { peak = abs(v) } }
        let pk = String(format: "Peak %.1f dBFS", linearToDb(Double(peak)))
        return trim < 0 ? pk + String(format: ", lowered %.1f dB to avoid clipping", -trim) : pk
    }

    static func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        let vDur = try await v.load(.duration)
        guard let vTrack = try await v.loadTracks(withMediaType: .video).first,
              let aTrack = try await a.loadTracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError(message: "Could not read the video or the rendered mix.")
        }
        let aDur = try await a.load(.duration)
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vTrack, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: min(aDur, vDur)), of: aTrack, at: .zero)
        cv.preferredTransform = try await vTrack.load(.preferredTransform)
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError(message: "Could not start the movie export.")
        }
        session.outputURL = out
        session.outputFileType = .mov
        await session.export()
        if session.status != .completed {
            throw ExportError(message: session.error?.localizedDescription ?? "The movie export failed.")
        }
    }
}

// MARK: - WAV

enum WAV {
    /// 24-bit PCM WAV. `channelMask` switches to WAVE_FORMAT_EXTENSIBLE; `extra` chunks go before the data.
    static func write(_ url: URL, channels: [[Float]], channelMask: UInt32? = nil, extra: [(String, Data)] = []) throws {
        let nch = channels.count, frames = channels.first?.count ?? 0
        let bytesPerFrame = nch * 3
        var fmt = Data()
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        fmt += u16(channelMask == nil ? 1 : 0xFFFE)
        fmt += u16(nch)
        fmt += u32(Int(AudioCache.sampleRate))
        fmt += u32(Int(AudioCache.sampleRate) * bytesPerFrame)
        fmt += u16(bytesPerFrame)
        fmt += u16(24)
        if let mask = channelMask {
            fmt += u16(22) + u16(24) + u32(Int(mask))
            fmt += Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        var pcm = Data(count: frames * bytesPerFrame)
        pcm.withUnsafeMutableBytes { raw in
            let d = raw.bindMemory(to: UInt8.self).baseAddress!
            for c in 0..<nch {
                channels[c].withUnsafeBufferPointer { src in
                    var o = c * 3
                    for i in 0..<frames {
                        let v = Int32((max(-1, min(1, src[i])) * 8388607).rounded())
                        d[o] = UInt8(truncatingIfNeeded: v)
                        d[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                        d[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
                        o += bytesPerFrame
                    }
                }
            }
        }
        func chunk(_ id: String, _ body: Data) -> Data {
            var d = Data(id.utf8) + u32(body.count) + body
            if body.count % 2 == 1 { d.append(0) }
            return d
        }
        var body = Data("WAVE".utf8) + chunk("fmt ", fmt)
        for (id, data) in extra { body += chunk(id, data) }
        body += chunk("data", pcm)
        guard body.count < 0xFFFF_FFF0 else { throw ExportError(message: "The export is larger than a WAV file allows (4 GB).") }
        try (Data("RIFF".utf8) + u32(body.count) + body).write(to: url, options: .atomic)
    }
}

// MARK: - ADM (ITU-R BS.2076) metadata in the Dolby Atmos master layout

enum ADM {
    static let bed: [(name: String, label: String, x: Double, y: Double, z: Double)] = [
        ("RoomCentricLeft", "RC_L", -1, 1, 0), ("RoomCentricRight", "RC_R", 1, 1, 0),
        ("RoomCentricCenter", "RC_C", 0, 1, 0), ("RoomCentricLFE", "RC_LFE", -1, 1, -1),
        ("RoomCentricLeftSideSurround", "RC_Lss", -1, 0, 0), ("RoomCentricRightSideSurround", "RC_Rss", 1, 0, 0),
        ("RoomCentricLeftRearSurround", "RC_Lrs", -1, -1, 0), ("RoomCentricRightRearSurround", "RC_Rrs", 1, -1, 0),
        ("RoomCentricLeftTopSurround", "RC_Lts", -1, 0, 1), ("RoomCentricRightTopSurround", "RC_Rts", 1, 0, 1),
    ]

    static func time(_ frames: Int) -> String {
        let sr = Int(AudioCache.sampleRate)
        let s = frames / sr, f = frames % sr
        return String(format: "%02d:%02d:%02d.%05dS%d", s / 3600, (s / 60) % 60, s % 60, f, sr)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func build(project p: Project, objects: [Track], frames: Int) -> (axml: Data, chna: Data) {
        let dur = time(frames)
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ebuCoreMain xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="urn:ebu:metadata-schema:ebuCore_2016" xml:lang="en">
        <coreMetadata><format>
        <audioFormatExtended version="ITU-R_BS.2076-2">
        <audioProgramme audioProgrammeID="APR_1001" audioProgrammeName="\(esc(p.name))" start="\(time(0))" end="\(dur)">
        <audioContentIDRef>ACO_1001</audioContentIDRef>

        """
        for i in objects.indices { x += "<audioContentIDRef>ACO_\(String(format: "%04X", 0x1002 + i))</audioContentIDRef>\n" }
        x += "</audioProgramme>\n"

        // Contents and objects
        x += "<audioContent audioContentID=\"ACO_1001\" audioContentName=\"Bed\"><audioObjectIDRef>AO_1001</audioObjectIDRef><dialogue mixedContentKind=\"0\">2</dialogue></audioContent>\n"
        for (i, t) in objects.enumerated() {
            let id = String(format: "%04X", 0x1002 + i)
            x += "<audioContent audioContentID=\"ACO_\(id)\" audioContentName=\"\(esc(t.name))\"><audioObjectIDRef>AO_\(id)</audioObjectIDRef><dialogue mixedContentKind=\"0\">2</dialogue></audioContent>\n"
        }
        x += "<audioObject audioObjectID=\"AO_1001\" audioObjectName=\"Bed\" start=\"\(time(0))\" duration=\"\(dur)\">\n<audioPackFormatIDRef>AP_00011001</audioPackFormatIDRef>\n"
        for c in 1...bed.count { x += "<audioTrackUIDRef>ATU_\(String(format: "%08X", c))</audioTrackUIDRef>\n" }
        x += "</audioObject>\n"
        for (i, t) in objects.enumerated() {
            let id = String(format: "%04X", 0x1002 + i)
            x += "<audioObject audioObjectID=\"AO_\(id)\" audioObjectName=\"\(esc(t.name))\" start=\"\(time(0))\" duration=\"\(dur)\">\n"
            x += "<audioPackFormatIDRef>AP_0003\(id)</audioPackFormatIDRef>\n<audioTrackUIDRef>ATU_\(String(format: "%08X", bed.count + 1 + i))</audioTrackUIDRef>\n</audioObject>\n"
        }

        // Pack formats
        x += "<audioPackFormat audioPackFormatID=\"AP_00011001\" audioPackFormatName=\"AtmosCustomPackFormat1\" typeLabel=\"0001\" typeDefinition=\"DirectSpeakers\">\n"
        for c in 1...bed.count { x += "<audioChannelFormatIDRef>AC_0001\(String(format: "%04X", 0x1000 + c))</audioChannelFormatIDRef>\n" }
        x += "</audioPackFormat>\n"
        for (i, t) in objects.enumerated() {
            let id = String(format: "%04X", 0x1002 + i)
            x += "<audioPackFormat audioPackFormatID=\"AP_0003\(id)\" audioPackFormatName=\"\(esc(t.name))\" typeLabel=\"0003\" typeDefinition=\"Objects\"><audioChannelFormatIDRef>AC_0003\(id)</audioChannelFormatIDRef></audioPackFormat>\n"
        }

        // Channel formats
        for (c, b) in bed.enumerated() {
            let id = String(format: "%04X", 0x1001 + c)
            x += "<audioChannelFormat audioChannelFormatID=\"AC_0001\(id)\" audioChannelFormatName=\"\(b.name)\" typeLabel=\"0001\" typeDefinition=\"DirectSpeakers\">\n"
            x += "<audioBlockFormat audioBlockFormatID=\"AB_0001\(id)_00000001\"><speakerLabel>\(b.label)</speakerLabel><cartesian>1</cartesian>"
            x += "<position coordinate=\"X\">\(b.x)</position><position coordinate=\"Y\">\(b.y)</position><position coordinate=\"Z\">\(b.z)</position></audioBlockFormat>\n</audioChannelFormat>\n"
        }
        let step = Int(AudioCache.sampleRate / 20)   // position resolution: 50 ms
        for (i, t) in objects.enumerated() {
            let id = String(format: "%04X", 0x1002 + i)
            x += "<audioChannelFormat audioChannelFormatID=\"AC_0003\(id)\" audioChannelFormatName=\"\(esc(t.name))\" typeLabel=\"0003\" typeDefinition=\"Objects\">\n"
            let moving = [AutoParam.x, .y, .z].contains { t.keys($0).count > 1 }
            var blocks: [(start: Int, length: Int, pos: Vec3)] = []
            if moving {
                var f = 0
                while f < frames {
                    let pos = Exporter.position(of: t, in: p, at: Double(f) / AudioCache.sampleRate)
                    let len = min(step, frames - f)
                    if let last = blocks.last, last.pos == pos {
                        blocks[blocks.count - 1].length += len
                    } else {
                        blocks.append((f, len, pos))
                    }
                    f += len
                }
            } else {
                blocks = [(0, frames, Exporter.position(of: t, in: p, at: 0))]
            }
            for (n, b) in blocks.enumerated() {
                x += "<audioBlockFormat audioBlockFormatID=\"AB_0003\(id)_\(String(format: "%08X", n + 1))\" rtime=\"\(time(b.start))\" duration=\"\(time(b.length))\">"
                x += "<cartesian>1</cartesian><position coordinate=\"X\">\(String(format: "%.4f", b.pos.x))</position>"
                x += "<position coordinate=\"Y\">\(String(format: "%.4f", b.pos.y))</position><position coordinate=\"Z\">\(String(format: "%.4f", b.pos.z))</position>"
                x += "<jumpPosition interpolationLength=\"\(n == 0 ? "0" : "0.05")\">1</jumpPosition></audioBlockFormat>\n"
            }
            x += "</audioChannelFormat>\n"
        }

        // Stream formats, track formats, track UIDs
        struct Row { var type: String; var id: String; var name: String; var pack: String }
        var rows: [Row] = bed.enumerated().map { c, b in
            Row(type: "0001", id: String(format: "%04X", 0x1001 + c), name: b.name, pack: "AP_00011001")
        }
        for (i, t) in objects.enumerated() {
            let id = String(format: "%04X", 0x1002 + i)
            rows.append(Row(type: "0003", id: id, name: esc(t.name), pack: "AP_0003\(id)"))
        }
        for r in rows {
            x += "<audioStreamFormat audioStreamFormatID=\"AS_\(r.type)\(r.id)\" audioStreamFormatName=\"PCM_\(r.name)\" formatLabel=\"0001\" formatDefinition=\"PCM\">"
            x += "<audioChannelFormatIDRef>AC_\(r.type)\(r.id)</audioChannelFormatIDRef><audioTrackFormatIDRef>AT_\(r.type)\(r.id)_01</audioTrackFormatIDRef></audioStreamFormat>\n"
        }
        for r in rows {
            x += "<audioTrackFormat audioTrackFormatID=\"AT_\(r.type)\(r.id)_01\" audioTrackFormatName=\"PCM_\(r.name)\" formatLabel=\"0001\" formatDefinition=\"PCM\">"
            x += "<audioStreamFormatIDRef>AS_\(r.type)\(r.id)</audioStreamFormatIDRef></audioTrackFormat>\n"
        }
        var chna = Data()
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        chna += u16(rows.count) + u16(rows.count)
        for (n, r) in rows.enumerated() {
            let uid = "ATU_\(String(format: "%08X", n + 1))"
            let trackRef = "AT_\(r.type)\(r.id)_01"
            x += "<audioTrackUID UID=\"\(uid)\" sampleRate=\"48000\" bitDepth=\"24\"><audioTrackFormatIDRef>\(trackRef)</audioTrackFormatIDRef><audioPackFormatIDRef>\(r.pack)</audioPackFormatIDRef></audioTrackUID>\n"
            chna += u16(n + 1) + Data(uid.utf8) + Data(trackRef.utf8) + Data(r.pack.utf8) + Data([0])
        }
        x += "</audioFormatExtended>\n</format></coreMetadata>\n</ebuCoreMain>\n"
        return (Data(x.utf8), chna)
    }
}
