import AppKit
import AVFoundation

extension Store {
    // MARK: Clips

    /// Copies the selected clip and places the copy right after it.
    func duplicateClip() {
        guard case .clip(let id) = selection, let l = project.locate(clip: id) else { return }
        var copy = project.tracks[l.track].clips[l.clip]
        copy.id = UUID()
        copy.start = min(max(0, project.duration - 0.05), copy.end)
        copy.pending = 0
        mutate { $0.tracks[l.track].clips.append(copy) }
        selection = .clip(copy.id)
    }

    /// Cuts a clip in two at a time: the given clip, or the selected one at the playhead.
    func splitClip(_ target: UUID? = nil, at time: Double? = nil) {
        let t = time ?? player.time
        var id = target
        if id == nil, case .clip(let sel) = selection { id = sel }
        guard let id, let l = project.locate(clip: id) else { return }
        let c = project.tracks[l.track].clips[l.clip]
        guard t > c.start + 0.02, t < c.end - 0.02 else { say("Put the playhead inside the clip to split it."); return }
        var first = c, second = c
        first.duration = t - c.start
        first.fadeOut = min(c.fadeOut, 0.01)
        second.id = UUID()
        second.start = t
        second.duration = c.end - t
        second.offset = c.offset + (t - c.start) * c.speed
        if c.loop, let d = c.take?.duration, d > 0 { second.offset = second.offset.truncatingRemainder(dividingBy: d) }
        second.fadeIn = min(c.fadeIn, 0.01)
        mutate { p in
            p.tracks[l.track].clips[l.clip] = first
            p.tracks[l.track].clips.append(second)
        }
        selection = .clip(second.id)
    }

    /// Moves the selected clip earlier or later by one grid step (one frame in Slip mode).
    func nudge(_ direction: Double) {
        guard case .clip(let id) = selection, project.locate(clip: id) != nil else { return }
        let step = editMode == .slip ? 1 / max(1, project.fps) : gridStep
        mutate { p in
            guard let l = p.locate(clip: id) else { return }
            p.tracks[l.track].clips[l.clip].start = max(0, p.tracks[l.track].clips[l.clip].start + direction * step)
        }
    }

    // MARK: Crossfades

    /// Overlaps a clip (or the selected one) with its neighbour on the track and fades one into the other.
    /// Length: `length`, else the existing overlap, else 0.1 s, centred on the join and limited by the audio each clip has spare.
    @discardableResult
    func crossfade(_ clip: UUID? = nil, length: Double? = nil, shape: FadeShape? = nil) -> Bool {
        var id = clip
        if id == nil, case .clip(let sel) = selection { id = sel }
        guard let id, let l = project.locate(clip: id), let x = project.tracks[l.track].crossfadePartner(of: id) else {
            say("Select a clip that touches or overlaps another clip on its track, then crossfade.")
            return false
        }
        let target = length ?? (x.length > 0.01 ? x.length : 0.1)
        guard let fit = x.fitted(target, around: x.centre) else {
            say("Neither clip has spare audio to overlap. Trim one back, then crossfade.")
            return false
        }
        let pair = x.applied(bStart: fit.bStart, aEnd: fit.aEnd, shape: shape ?? .equalPower)
        mutate { p in Store.put(pair, in: &p) }
        return true
    }

    /// Changes a crossfade's length about its centre. `live` = inside a gesture that already called `beginGesture`.
    @discardableResult
    func setCrossfade(a: UUID, b: UUID, length: Double, live inGesture: Bool = false) -> Bool {
        guard let x = crossfadePair(a: a, b: b), let fit = x.fitted(length, around: x.centre) else { return false }
        let pair = x.applied(bStart: fit.bStart, aEnd: fit.aEnd)
        if inGesture { live { p in Store.put(pair, in: &p) } } else { mutate { p in Store.put(pair, in: &p) } }
        return true
    }

    /// Gives both sides of a crossfade the same curve.
    func setCrossfadeShape(a: UUID, b: UUID, shape: FadeShape) {
        mutate { p in
            if let l = p.locate(clip: a) { p.tracks[l.track].clips[l.clip].fadeOutShape = shape }
            if let l = p.locate(clip: b) { p.tracks[l.track].clips[l.clip].fadeInShape = shape }
        }
    }

    /// Takes the overlap away: both clips meet at the crossfade's centre, with short fades.
    func removeCrossfade(a: UUID, b: UUID) {
        guard let x = crossfadePair(a: a, b: b) else { return }
        var first = x.a, second = x.b
        let m = x.centre
        first.duration = m - first.start
        second.setStart(m)
        first.fadeOut = 0.01
        second.fadeIn = 0.01
        mutate { p in Store.put((first, second), in: &p) }
    }

    /// The two clips as a crossfade, when they are on one track and B starts inside A.
    private func crossfadePair(a: UUID, b: UUID) -> Crossfade? {
        guard let la = project.locate(clip: a), let lb = project.locate(clip: b), la.track == lb.track else { return nil }
        let x = Crossfade(a: project.tracks[la.track].clips[la.clip], b: project.tracks[lb.track].clips[lb.clip])
        return x.b.start > x.a.start && x.b.start < x.a.end && x.a.end < x.b.end ? x : nil
    }

    /// Writes both clips of a crossfade back into the session.
    static func put(_ pair: (a: Clip, b: Clip), in p: inout Project) {
        if let l = p.locate(clip: pair.a.id) { p.tracks[l.track].clips[l.clip] = pair.a }
        if let l = p.locate(clip: pair.b.id) { p.tracks[l.track].clips[l.clip] = pair.b }
    }

    // MARK: Groups

    /// Puts tracks into a group, creating it by name if needed. Pass nil to take them out of their group.
    @discardableResult
    func setGroup(_ name: String?, for ids: [UUID]) -> UUID? {
        var gid: UUID?
        mutate { p in
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                var groups = p.groups ?? []
                if let g = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { gid = g.id }
                else { let g = TrackGroup(name: name); groups.append(g); gid = g.id }
                p.groups = groups
            }
            for i in p.tracks.indices where ids.contains(p.tracks[i].id) { p.tracks[i].groupID = gid }
            p.tidyGroups()
        }
        return gid
    }

    /// One group per kind of sound: effects (foley and FX), ambience, music, voice.
    func groupByKind() {
        mutate { p in
            var groups = p.groups ?? []
            func id(_ name: String) -> UUID {
                if let g = groups.first(where: { $0.name == name }) { return g.id }
                let g = TrackGroup(name: name); groups.append(g); return g.id
            }
            for i in p.tracks.indices where p.tracks[i].groupID == nil {
                switch p.tracks[i].kind {
                case .foley, .fx: p.tracks[i].groupID = id("SFX")
                case .ambience: p.tracks[i].groupID = id("Ambience")
                case .music: p.tracks[i].groupID = id("Music")
                case .dialogue: p.tracks[i].groupID = id("Voice")
                }
            }
            p.groups = groups
            p.tidyGroups()
        }
    }

    func editGroup(_ id: UUID, undoable: Bool = true, _ change: @escaping (inout TrackGroup) -> Void) {
        let work: (inout Project) -> Void = { p in
            guard var groups = p.groups, let i = groups.firstIndex(where: { $0.id == id }) else { return }
            change(&groups[i]); p.groups = groups
        }
        if undoable { mutate(work) } else { live(work) }
    }

    func ungroup(_ id: UUID) {
        mutate { p in
            for i in p.tracks.indices where p.tracks[i].groupID == id { p.tracks[i].groupID = nil }
            p.tidyGroups()
        }
        selection = .none
    }

    // MARK: Versions (revised cuts)

    /// Works out the chain of cuts this session belongs to, oldest first.
    func refreshVersions() {
        func load(_ u: URL) -> Project? {
            (try? Data(contentsOf: u.appendingPathComponent("project.json"))).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
        }
        var list = [folder], steps = 0
        var cur = project
        while let prev = cur.previousVersion, steps < 20, let p = load(URL(fileURLWithPath: prev)) {
            list.insert(URL(fileURLWithPath: prev), at: 0); cur = p; steps += 1
        }
        cur = project
        while let next = cur.nextVersion, steps < 40, let p = load(URL(fileURLWithPath: next)) {
            list.append(URL(fileURLWithPath: next)); cur = p; steps += 1
        }
        versionList = list
    }

    /// Opens another cut of the same film at the matching moment.
    func switchVersion(to url: URL) {
        guard url != folder else { return }
        let t = player.time, from = folder, old = project
        guard open(url) else { return }
        var target = t
        if project.previousVersion == from.path, let segs = project.revision?.segments {
            // Going forward: old time → new time.
            if let s = segs.first(where: { t >= $0.start + $0.delta && t < $0.end + $0.delta }) { target = t - s.delta }
        } else if old.previousVersion == url.path, let segs = old.revision?.segments {
            if let s = segs.first(where: { t >= $0.start && t < $0.end }) { target = t + s.delta }
        }
        player.seek(min(max(0, target), project.duration))
    }

    /// Makes a new session for a revised cut of this film. Sounds stay with their picture; only new picture is left silent.
    @discardableResult
    func importRevision(_ source: URL) async throws -> Conform.Report {
        guard let oldURL = videoURL, project.video != nil else {
            try await importVideo(source)
            return Conform.Report()
        }
        busy = "Comparing the two cuts"
        defer { busy = nil }
        save()
        let fm = FileManager.default
        var info = try await VideoAnalysis.info(source)
        async let a = Conform.frames(oldURL)
        async let b = Conform.frames(source)
        let (oldFrames, newFrames) = await (a, b)
        guard !oldFrames.isEmpty, !newFrames.isEmpty else { throw ServiceError(message: "One of the two videos could not be read.") }
        let oldShots = Conform.shots(oldFrames, duration: project.duration)
        let newShots = Conform.shots(newFrames, duration: info.duration)
        let m = Conform.match(old: oldFrames, new: newFrames, oldShots: oldShots, newShots: newShots)

        // The new cut gets its own session next to this one; audio files are shared, not copied.
        let base = folder.deletingPathExtension().lastPathComponent
        var stem = base, n = 2
        if let r = base.range(of: #" v(\d+)$"#, options: .regularExpression), let k = Int(base[r].dropFirst(2)) {
            stem = String(base[..<r.lowerBound]); n = k + 1
        }
        var dest = Store.library.appendingPathComponent("\(stem) v\(n)." + AppPaths.sessionExtension, isDirectory: true)
        while fm.fileExists(atPath: dest.path) { n += 1; dest = Store.library.appendingPathComponent("\(stem) v\(n)." + AppPaths.sessionExtension, isDirectory: true) }
        try fm.createDirectory(at: dest.appendingPathComponent("Video"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dest.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        for file in (try? fm.contentsOfDirectory(at: folder.appendingPathComponent("Audio"), includingPropertiesForKeys: nil)) ?? [] {
            let to = dest.appendingPathComponent("Audio").appendingPathComponent(file.lastPathComponent)
            if (try? fm.linkItem(at: file, to: to)) == nil { try? fm.copyItem(at: file, to: to) }
        }
        let video = dest.appendingPathComponent("Video").appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: video)
        info.path = "Video/" + video.lastPathComponent

        var (p, report) = Conform.apply(project, video: info, segments: m.segments, ranges: m.ranges, report: m.report)
        p.name = "\(stem) v\(n)"
        p.previousVersion = folder.path
        p.nextVersion = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: dest.appendingPathComponent("project.json"), options: .atomic)
        live { $0.nextVersion = dest.path }
        save()
        open(dest)
        report.clipsKept = p.tracks.reduce(0) { $0 + $1.clips.count }
        say(p.revision?.summary ?? "Revised cut loaded.")
        return report
    }

    // MARK: Footsteps

    /// Places one footstep on every given time. The steps come from a walk that is cut into its single
    /// footfalls, so no two neighbours are the same recording, and each lands on its frame.
    @discardableResult
    func placeSteps(track: UUID, times: [Double], prompt: String, source: UUID? = nil, gain: Double = 0,
                    variation: Double = 0.5, replace: ClosedRange<Double>? = nil) async throws -> Int {
        let times = times.filter { $0 >= 0 && $0 < project.duration }.sorted()
        guard !times.isEmpty else { throw ServiceError(message: "There are no step times to place.") }
        guard project.trackIndex(track) != nil else { throw ServiceError(message: "That track no longer exists.") }
        var bank: [(take: Take, slice: Steps.Slice)] = []
        func add(_ take: Take) {
            let found = Steps.slices(url(for: take))
            if found.isEmpty, let m = Commands.measure(url(for: take)) {
                bank.append((take, Steps.Slice(start: max(0, (m["onset"] ?? 0) - 0.004), length: min(0.6, take.duration), peak: 0.1)))
            }
            for s in found { bank.append((take, s)) }
        }
        if let source, let l = project.locate(clip: source), let take = project.tracks[l.track].clips[l.clip].take {
            add(take)
        } else {
            guard Secrets.has(.elevenLabs) else { throw ServiceError(message: "Add your ElevenLabs API key in Settings to generate footsteps.") }
            busy = "Recording footsteps"
            defer { busy = nil }
            let audio = subfolder("Audio")
            let text = prompt.lowercased().contains("step") || prompt.lowercased().contains("walk") ? prompt
                : "footsteps walking at a slow steady pace, " + prompt + ", single person, close, dry, clear separate steps, no other sound"
            // Two walks give a dozen or more different steps to draw from.
            try await withThrowingTaskGroup(of: Take.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        let r = try await ElevenLabs.soundEffect(prompt: text, duration: 7, influence: 0.5, loop: false)
                        let file = audio.appendingPathComponent("steps-" + UUID().uuidString.prefix(8) + "." + r.ext)
                        try r.data.write(to: file)
                        return Take(file: "Audio/" + file.lastPathComponent, duration: AudioCache.shared.duration(file))
                    }
                }
                for try await take in group where take.duration > 0 { add(take) }
            }
        }
        guard !bank.isEmpty else { throw ServiceError(message: "No separate steps could be found in that sound.") }
        let peaks = bank.map(\.slice.peak).sorted(), median = peaks[peaks.count / 2]
        var clips: [Clip] = []
        var last = -1, order = Array(bank.indices).shuffled()
        for (i, t) in times.enumerated() {
            if order.isEmpty { order = Array(bank.indices).shuffled() }
            var pick = order.removeLast()
            if pick == last, !order.isEmpty { order.insert(pick, at: 0); pick = order.removeLast() }
            last = pick
            let b = bank[pick]
            // Never let a step run into the next one.
            let room = i + 1 < times.count ? max(0.08, times[i + 1] - t - 0.01) : 1
            var c = Clip(name: "Step \(i + 1)", start: max(0, t - 0.004), duration: min(b.slice.length + 0.04, room))
            c.offset = b.slice.start
            c.takes = [b.take]
            c.fadeIn = 0.002
            c.fadeOut = min(0.05, c.duration / 3)
            let level = max(-6, min(6, linearToDb(median / max(0.0001, b.slice.peak))))
            c.gain = gain + level + Double.random(in: -1.5...1.5) * variation * 2
            let rate = 1 + Double.random(in: -0.05...0.05) * variation * 2
            c.rate = abs(rate - 1) < 0.005 ? nil : rate
            clips.append(c)
        }
        mutate { p in
            guard let ti = p.trackIndex(track) else { return }
            if let replace { p.tracks[ti].clips.removeAll { $0.start >= replace.lowerBound - 0.01 && $0.start < replace.upperBound } }
            p.tracks[ti].clips += clips
        }
        return clips.count
    }

    // MARK: The film's own sound

    /// Writes the video's soundtrack to an audio file in the session.
    func extractOriginalAudio() async throws -> URL {
        guard let video = videoURL else { throw ServiceError(message: "There is no video in the session yet.") }
        let out = subfolder("Audio").appendingPathComponent("original-" + video.deletingPathExtension().lastPathComponent + ".m4a")
        if FileManager.default.fileExists(atPath: out.path), AudioCache.shared.duration(out) > 0 { return out }
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw ServiceError(message: "This video has no sound of its own.") }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ServiceError(message: "The video's sound could not be read.")
        }
        try await export.export(to: out, as: .m4a)
        return out
    }

    /// Puts the film's own soundtrack on a track, so any part of it can be cut out and kept.
    @discardableResult
    func addOriginalSound() async throws -> UUID {
        busy = "Reading the film's sound"
        defer { busy = nil }
        let file = try await extractOriginalAudio()
        let dur = AudioCache.shared.duration(file)
        let id = addTrack(kind: .fx, name: "Original sound")
        mutate { p in
            guard let i = p.trackIndex(id) else { return }
            p.tracks[i].spaceMode = .dry; p.tracks[i].spatial = false; p.tracks[i].mute = true
            p.tracks[i].clips = [Clip(name: "Original sound", start: 0, duration: dur, fadeIn: 0, fadeOut: 0, takes: [Take(file: "Audio/" + file.lastPathComponent, duration: dur)])]
        }
        return id
    }

    /// Splits the film's own soundtrack into stems with ElevenLabs and lays them out as a muted group.
    @discardableResult
    func splitOriginalSound() async throws -> [String] {
        guard Secrets.has(.elevenLabs) else { throw ServiceError(message: "Add your ElevenLabs API key in Settings to split the film's sound.") }
        busy = "Splitting the film's sound"
        defer { busy = nil }
        let file = try await extractOriginalAudio()
        let zip = try await ElevenLabs.stems(of: file)
        let work = subfolder("Audio").appendingPathComponent("stems-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("stems.zip")
        try zip.write(to: archive)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: archive)
        let found = (FileManager.default.enumerator(at: work, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["mp3", "wav", "m4a", "flac", "opus"].contains($0.pathExtension.lowercased()) && AudioCache.shared.duration($0) > 0 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !found.isEmpty else { throw ServiceError(message: "ElevenLabs returned no stems.") }
        var names: [String] = [], ids: [UUID] = []
        let rel = "Audio/" + work.lastPathComponent + "/"
        mutate { p in
            for f in found {
                let stem = f.deletingPathExtension().lastPathComponent.lowercased()
                let kind: TrackKind = stem.contains("vocal") ? .dialogue : stem.contains("other") ? .fx : .music
                let title = stem.contains("vocal") ? "Voice" : stem.contains("other") ? "Other (effects, pads)" : stem.capitalized
                var t = Track(name: "Original · " + title, kind: kind)
                t.spaceMode = .dry
                let d = AudioCache.shared.duration(f)
                let path = rel + f.path.replacingOccurrences(of: work.path + "/", with: "")
                t.clips = [Clip(name: title, start: 0, duration: d, fadeIn: 0, fadeOut: 0, takes: [Take(file: path, duration: d)])]
                p.tracks.append(t)
                names.append(title); ids.append(t.id)
            }
            var g = TrackGroup(name: "Original sound")
            g.mute = true
            p.groups = (p.groups ?? []) + [g]
            for i in p.tracks.indices where ids.contains(p.tracks[i].id) { p.tracks[i].groupID = g.id }
            p.tidyGroups()
        }
        say("The film's sound is split into \(names.count) stems, muted. Solo one to hear it.")
        return names
    }
}
