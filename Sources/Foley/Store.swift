import AppKit
import AVFoundation
import Observation

enum Selection: Equatable {
    case none, clip(UUID), track(UUID), scene(UUID), space(UUID), group(UUID)
}

/// How clips behave when dragged, as in Pro Tools: free, pulled to nearby edges, or locked to the time grid.
enum EditMode: String, CaseIterable { case slip, snap, grid }

enum GridUnit: String, CaseIterable, Identifiable {
    case frame, frames5, tenth, quarter, half, second, beat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .frame: "1 frame"
        case .frames5: "5 frames"
        case .tenth: "0.1 second"
        case .quarter: "¼ second"
        case .half: "½ second"
        case .second: "1 second"
        case .beat: "1 beat"
        }
    }
}

struct Toast: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var isError = false
}

/// The open project and everything the UI edits. All changes go through `mutate` (undoable) or `live` (mid-gesture).
@MainActor @Observable
final class Store {
    var project = Project.starter()
    var folder: URL
    var selection: Selection = .none {
        didSet { if selection != oldValue { stopAudition() } }
    }
    var zoom = 1.0
    /// The pinch in progress. Its own object, so stretching the timeline does not touch anything that follows the store.
    @ObservationIgnored let zoomLive = ZoomLive()
    /// Set by the timeline: scrolls it to an x offset. Used by the hidden scroll benchmark.
    @ObservationIgnored var scrollTimeline: ((CGPoint) -> Void)?
    /// Set by the timeline: re-measures its scrolling area after row heights change.
    @ObservationIgnored var relayoutTimeline: (() -> Void)?
    var vzoom = 1.0
    var editMode = EditMode(rawValue: UserDefaults.standard.string(forKey: "editMode") ?? "") ?? .snap {
        didSet { UserDefaults.standard.set(editMode.rawValue, forKey: "editMode") }
    }
    var gridUnit = GridUnit(rawValue: UserDefaults.standard.string(forKey: "gridUnit") ?? "") ?? .quarter {
        didSet { UserDefaults.standard.set(gridUnit.rawValue, forKey: "gridUnit") }
    }
    var showSceneGrid = UserDefaults.standard.object(forKey: "sceneGrid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSceneGrid, forKey: "sceneGrid") }
    }
    var showTimeGrid = UserDefaults.standard.object(forKey: "timeGrid") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showTimeGrid, forKey: "timeGrid") }
    }
    /// Seconds between time-grid lines.
    var gridStep: Double {
        switch gridUnit {
        case .frame: 1 / max(1, project.fps)
        case .frames5: 5 / max(1, project.fps)
        case .tenth: 0.1
        case .quarter: 0.25
        case .half: 0.5
        case .second: 1
        case .beat: 60 / Double(project.music?.tempo ?? 120)
        }
    }
    func rowHeight(_ t: Track) -> CGFloat { min(320, max(46, CGFloat(t.height ?? Double(Metrics.track)) * CGFloat(vzoom))) }
    var filmstrip: [NSImage] = []
    var toast: Toast?
    var busy: String?
    var showExport = false
    var showSettings = false
    var showClaude = false
    var canUndo = false
    var canRedo = false
    let player = Player()
    let agent = AgentState()
    /// The take playing on its own in the inspector, if any.
    var auditioning: UUID?
    /// A loop start marked with ⌘-click on the ruler, waiting for the second ⌘-click. Not saved.
    var loopPending: Double?

    @ObservationIgnored private var undoStack: [Project] = []
    @ObservationIgnored private var redoStack: [Project] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var audition: AVAudioPlayer?
    @ObservationIgnored private var auditionEnd: Task<Void, Never>?
    @ObservationIgnored lazy var commands = Commands(store: self)
    @ObservationIgnored var server: ControlServer?

    static var library: URL { AppPaths.library }

    init() {
        folder = Store.library.appendingPathComponent("Untitled." + AppPaths.sessionExtension, isDirectory: true)
        if let last = UserDefaults.standard.string(forKey: "lastProject"),
           FileManager.default.fileExists(atPath: last + "/project.json") {
            open(URL(fileURLWithPath: last))
        } else {
            create(named: "Untitled")
        }
        server = ControlServer(store: self)
        player.onPlay = { [weak self] in self?.stopAudition() }
    }

    // MARK: Editing

    func mutate(_ change: (inout Project) -> Void) {
        pushUndo()
        change(&project)
        changed()
    }

    /// Call once when a drag starts, then use `live` for every movement.
    func beginGesture() { pushUndo() }

    func live(_ change: (inout Project) -> Void) {
        change(&project)
        changed()
    }

    private func pushUndo() {
        undoStack.append(project)
        if undoStack.count > 120 { undoStack.removeFirst() }
        redoStack = []
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let p = undoStack.popLast() else { return }
        redoStack.append(project)
        project = p
        canUndo = !undoStack.isEmpty
        canRedo = true
        changed()
    }

    func redo() {
        guard let p = redoStack.popLast() else { return }
        undoStack.append(project)
        project = p
        canUndo = true
        canRedo = !redoStack.isEmpty
        changed()
    }

    private func changed() {
        player.sync(project, resolve: { [folder] in Store.url(for: $0, in: folder) })
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func say(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 6 : 3)) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    // MARK: Files

    nonisolated static func url(for take: Take, in folder: URL) -> URL {
        take.file.hasPrefix("/") ? URL(fileURLWithPath: take.file) : folder.appendingPathComponent(take.file)
    }
    func url(for take: Take) -> URL { Store.url(for: take, in: folder) }
    var videoURL: URL? {
        guard let v = project.video else { return nil }
        return v.path.hasPrefix("/") ? URL(fileURLWithPath: v.path) : folder.appendingPathComponent(v.path)
    }
    func subfolder(_ name: String) -> URL {
        let u = folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func save() {
        saveWork?.cancel()
        guard ready else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(project) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("project.json"), options: .atomic)
    }

    func create(named name: String) {
        save()
        var url = Store.library.appendingPathComponent(name + "." + AppPaths.sessionExtension, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Store.library.appendingPathComponent("\(name) \(n)." + AppPaths.sessionExtension, isDirectory: true)
            n += 1
        }
        folder = url
        project = Project.starter()
        project.name = url.deletingPathExtension().lastPathComponent
        ready = true
        reset()
        save()
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("project.json")),
              var p = try? JSONDecoder().decode(Project.self, from: data) else {
            say("That project could not be opened.", error: true)
            return false
        }
        save()
        for t in p.tracks.indices { for c in p.tracks[t].clips.indices { p.tracks[t].clips[c].pending = 0 } }
        folder = url
        project = p
        ready = true
        reset()
        return true
    }

    private func reset() {
        undoStack = []; redoStack = []
        canUndo = false; canRedo = false
        selection = .none
        filmstrip = []
        UserDefaults.standard.set(folder.path, forKey: "lastProject")
        player.pause()
        player.time = 0
        player.loadVideo(videoURL)
        player.sync(project, resolve: { [folder] in Store.url(for: $0, in: folder) })
        player.seek(0)
        loadFilmstrip()
        refreshVersions()
        taps = []; tapTrack = nil
    }

    private func loadFilmstrip() {
        guard let url = videoURL, let v = project.video else { return }
        let target = folder
        Task {
            let frames = await VideoAnalysis.filmstrip(url, duration: v.duration, count: 28)
            if self.folder == target { self.filmstrip = frames }
        }
    }

    // MARK: Video

    func importVideo(_ source: URL) async throws {
        busy = "Reading video"
        defer { busy = nil }
        let dest = subfolder("Video").appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL != dest.standardizedFileURL {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
        }
        var info = try await VideoAnalysis.info(dest)
        info.path = "Video/" + dest.lastPathComponent
        busy = "Finding shots"
        let cuts = await VideoAnalysis.detectCuts(dest)
        mutate { p in
            p.video = info
            p.duration = info.duration
            p.fps = info.fps
            if p.name.hasPrefix("Untitled") { p.name = source.deletingPathExtension().lastPathComponent }
            if p.scenes.isEmpty { p.scenes = Store.scenes(from: cuts, duration: info.duration) }
        }
        player.loadVideo(videoURL)
        player.seek(0)
        loadFilmstrip()
    }

    static func scenes(from cuts: [Double], duration: Double) -> [SceneRegion] {
        let edges = [0.0] + cuts.filter { $0 > 0.05 && $0 < duration - 0.05 } + [duration]
        return (0..<(edges.count - 1)).map { SceneRegion(start: edges[$0], end: edges[$0 + 1], name: "Shot \($0 + 1)") }
    }

    /// Saves stills at the given times into the project's Frames folder and returns their paths.
    func writeFrames(at times: [Double], maxSize: CGFloat = 768) async -> [(time: Double, path: String)] {
        guard let url = videoURL else { return [] }
        let dir = subfolder("Frames")
        var out: [(Double, String)] = []
        for t in times {
            guard let img = await VideoAnalysis.frame(url, at: t, maxSize: maxSize) else { continue }
            let file = dir.appendingPathComponent(String(format: "frame_%07.2fs.jpg", t))
            if VideoAnalysis.writeJPEG(img, to: file) { out.append((t, file.path)) }
        }
        return out
    }

    // MARK: Scenes and spaces

    func splitScene(at t: Double) {
        guard let i = project.scenes.firstIndex(where: { t > $0.start + 0.05 && t < $0.end - 0.05 }) else {
            if project.scenes.isEmpty {
                mutate { $0.scenes = [SceneRegion(start: 0, end: t, name: "Scene 1"), SceneRegion(start: t, end: $0.duration, name: "Scene 2")] }
            }
            return
        }
        mutate { p in
            var second = p.scenes[i]
            second.id = UUID()
            second.start = t
            second.name = p.scenes[i].name + " b"
            p.scenes[i].end = t
            p.scenes.insert(second, at: i + 1)
        }
    }

    func deleteScene(_ id: UUID) {
        mutate { p in
            let sorted = p.scenes.sorted { $0.start < $1.start }
            guard let i = sorted.firstIndex(where: { $0.id == id }) else { return }
            var s = sorted
            if i > 0 { s[i - 1].end = s[i].end } else if s.count > 1 { s[1].start = s[0].start }
            s.remove(at: i)
            p.scenes = s
        }
        selection = .none
    }

    @discardableResult
    func addSpace(from template: SpaceTemplate) -> UUID {
        if let existing = project.space(named: template.name) { return existing.id }
        var s = template.space
        s.id = UUID()
        mutate { $0.spaces.append(s) }
        return s.id
    }

    // MARK: Loop region

    func setLoop(_ start: Double, _ end: Double) {
        live { $0.loopStart = max(0, start); $0.loopEnd = min($0.duration, end) }
        if end - start > 0.05 { player.loop = true }
    }

    func clearLoop() {
        live { $0.loopStart = nil; $0.loopEnd = nil }
        player.loop = false
    }

    /// Loops the selected clip or scene; with nothing selected, the scene under the playhead.
    func loopSelection() {
        switch selection {
        case .clip(let id):
            if let l = project.locate(clip: id) { let c = project.tracks[l.track].clips[l.clip]; setLoop(c.start, c.end) }
        case .scene(let id):
            if let s = project.scenes.first(where: { $0.id == id }) { setLoop(s.start, s.end) }
        default:
            if let s = project.scene(at: player.time) { setLoop(s.start, s.end) }
        }
    }

    // MARK: Tracks and clips

    @discardableResult
    func addTrack(kind: TrackKind, name: String? = nil) -> UUID {
        var t = Track(name: name ?? kind.title, kind: kind)
        t.spatial = kind == .foley || kind == .fx
        if kind == .music || kind == .dialogue { t.spaceMode = .dry }
        mutate { $0.tracks.append(t) }
        return t.id
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id):
            mutate { p in if let l = p.locate(clip: id) { p.tracks[l.track].clips.remove(at: l.clip) } }
        case .track(let id):
            mutate { p in p.tracks.removeAll { $0.id == id }; p.tidyGroups() }
        case .scene(let id):
            deleteScene(id)
            return
        case .space(let id):
            mutate { p in
                p.spaces.removeAll { $0.id == id }
                for i in p.scenes.indices where p.scenes[i].spaceID == id { p.scenes[i].spaceID = nil }
                for i in p.tracks.indices where p.tracks[i].fixedSpace == id { p.tracks[i].fixedSpace = nil }
            }
        case .group(let id):
            ungroup(id)
            return
        case .none: return
        }
        selection = .none
    }

    /// Copies an audio file into the project and places it on a track.
    @discardableResult
    func importAudio(_ source: URL, track: UUID, at start: Double, name: String? = nil) -> UUID? {
        let dest = subfolder("Audio").appendingPathComponent(UUID().uuidString.prefix(8) + "-" + source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: dest) } catch {
            say("Could not copy \(source.lastPathComponent).", error: true)
            return nil
        }
        let dur = AudioCache.shared.duration(dest)
        guard dur > 0 else {
            say("\(source.lastPathComponent) is not a readable audio file.", error: true)
            return nil
        }
        let clip = Clip(name: name ?? source.deletingPathExtension().lastPathComponent, start: start, duration: dur,
                        takes: [Take(file: "Audio/" + dest.lastPathComponent, duration: dur)])
        mutate { p in if let i = p.trackIndex(track) { p.tracks[i].clips.append(clip) } }
        return clip.id
    }

    /// Creates a clip and asks ElevenLabs for `takes` versions of it. Returns when every take has arrived or failed.
    @discardableResult
    func generate(prompt: String, track: UUID, start: Double, duration: Double, takes: Int, loop: Bool,
                  influence: Double, name: String? = nil, fadeIn: Double = 0.01, fadeOut: Double = 0.05, gain: Double = 0) async -> UUID {
        var clip = Clip(name: name ?? String(prompt.prefix(40)), start: start, duration: duration)
        clip.prompt = prompt
        clip.loop = loop
        clip.fadeIn = fadeIn
        clip.fadeOut = fadeOut
        clip.gain = gain
        clip.pending = takes
        mutate { p in if let i = p.trackIndex(track) { p.tracks[i].clips.append(clip) } }
        await fetchTakes(for: clip.id, count: takes, influence: influence, marked: true)
        return clip.id
    }

    /// Places a cue with a prompt and timing but no audio yet. `generateMissing` fills it in later.
    @discardableResult
    func addCue(prompt: String, track: UUID, start: Double, duration: Double, loop: Bool, name: String? = nil,
                fadeIn: Double = 0.01, fadeOut: Double = 0.05, gain: Double = 0) -> UUID {
        var clip = Clip(name: name ?? String(prompt.prefix(40)), start: start, duration: duration)
        clip.prompt = prompt
        clip.loop = loop
        clip.fadeIn = fadeIn
        clip.fadeOut = fadeOut
        clip.gain = gain
        mutate { p in if let i = p.trackIndex(track) { p.tracks[i].clips.append(clip) } }
        return clip.id
    }

    /// Clips that have a prompt but no sound yet.
    var missingCues: [UUID] {
        // Spoken lines wait until a voice is chosen; they are never made as sound effects.
        var out: [Clip] = []
        for t in project.tracks {
            for c in t.clips where c.takes.isEmpty && c.pending == 0 && !c.prompt.isEmpty {
                if t.kind == .dialogue && c.voiceID == nil { continue }
                out.append(c)
            }
        }
        return out.sorted { $0.start < $1.start }.map(\.id)
    }

    var generatingAll = false
    /// Every cut of this film that has a session, oldest first.
    var versionList: [URL] = []
    /// Footfalls tapped in by hand (T while playing), waiting to be placed on `tapTrack`.
    var voices: [Voice] = []
    /// The track a dragged clip is hovering over.
    var dropTrack: UUID?
    var taps: [Double] = []
    var tapTrack: UUID?

    /// Generates sound for every cue that has none. Cues with the same prompt share one generation.
    @discardableResult
    func generateMissing(takes: Int = 2) async -> (done: Int, failed: Int) {
        guard Secrets.has(.elevenLabs) else {
            say("Add your ElevenLabs API key in Settings to generate sounds.", error: true)
            showSettings = true
            return (0, 0)
        }
        guard !generatingAll else { return (0, 0) }
        generatingAll = true
        defer { generatingAll = false }
        var done = 0, failed = 0
        var made: [String: [Take]] = [:]
        for id in missingCues {
            guard let l = project.locate(clip: id) else { continue }
            let clip = project.tracks[l.track].clips[l.clip]
            let key = clip.prompt + (clip.loop ? "|loop" : "")
            // A shared take must be long enough for this cue, unless it loops.
            if let shared = made[key], clip.loop || (shared.first?.duration ?? 0) >= clip.duration - 0.05 {
                // Same sound asked for twice (a second footstep, the closing clap): reuse the takes, start on a different one.
                live { p in
                    guard let x = p.locate(clip: id) else { return }
                    p.tracks[x.track].clips[x.clip].takes = shared
                    p.tracks[x.track].clips[x.clip].activeTake = min(shared.count - 1, 1)
                }
                done += 1
                continue
            }
            await moreTakes(for: id, count: takes)
            if let x = project.locate(clip: id), !project.tracks[x.track].clips[x.clip].takes.isEmpty {
                made[key] = project.tracks[x.track].clips[x.clip].takes
                done += 1
            } else {
                failed += 1
            }
        }
        if done > 0 || failed > 0 {
            say(failed == 0 ? "Generated \(done) sound\(done == 1 ? "" : "s")." : "Generated \(done), \(failed) failed. Select a red clip to see why.", error: failed > 0)
        }
        return (done, failed)
    }

    /// Adds more takes to an existing clip from its prompt.
    func moreTakes(for clipID: UUID, count: Int, influence: Double = 0.3) async {
        await fetchTakes(for: clipID, count: count, influence: influence, marked: false)
    }

    private func fetchTakes(for clipID: UUID, count: Int, influence: Double, marked: Bool) async {
        guard let loc = project.locate(clip: clipID) else { return }
        let clip = project.tracks[loc.track].clips[loc.clip]
        if !marked { live { p in if let l = p.locate(clip: clipID) { p.tracks[l.track].clips[l.clip].pending += count; p.tracks[l.track].clips[l.clip].error = nil } } }
        // ElevenLabs makes 0.5–30 s. Longer beds are generated as loops and tiled.
        let genDuration = min(30, max(0.5, clip.duration))
        let loop = clip.loop
        let audio = subfolder("Audio")
        await withTaskGroup(of: Result<Take, Error>.self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        let r = try await (clip.voiceID.map { v in { try await ElevenLabs.speech(clip.prompt, voice: v) } }
                            ?? { try await ElevenLabs.soundEffect(prompt: clip.prompt, duration: genDuration, influence: influence, loop: loop) })()
                        let file = audio.appendingPathComponent((clip.voiceID == nil ? "gen-" : "voice-") + UUID().uuidString.prefix(8) + "." + r.ext)
                        try r.data.write(to: file)
                        let d = AudioCache.shared.duration(file)
                        guard d > 0 else { throw ServiceError(message: "ElevenLabs returned audio that could not be read.") }
                        return .success(Take(file: "Audio/" + file.lastPathComponent, duration: d))
                    } catch { return .failure(error) }
                }
            }
            for await result in group {
                live { p in
                    guard let l = p.locate(clip: clipID) else { return }
                    p.tracks[l.track].clips[l.clip].pending = max(0, p.tracks[l.track].clips[l.clip].pending - 1)
                    switch result {
                    case .success(let take): p.tracks[l.track].clips[l.clip].takes.append(take)
                    case .failure(let e): p.tracks[l.track].clips[l.clip].error = e.localizedDescription
                    }
                }
            }
        }
        if clip.voiceID != nil { fitVoice(clipID) }
        if let l = project.locate(clip: clipID), let e = project.tracks[l.track].clips[l.clip].error,
           project.tracks[l.track].clips[l.clip].takes.isEmpty {
            say(e, error: true)
        }
    }

    /// Generates a looping bed for every run of scenes that uses a space, overlapping neighbours by the scene transition.
    func fillAmbience(space id: UUID) async {
        guard let sp = project.space(id), !sp.ambiencePrompt.isEmpty else { return }
        guard Secrets.has(.elevenLabs) else {
            say("Add your ElevenLabs API key in Settings to generate sounds.", error: true)
            return
        }
        let scenes = project.scenes.sorted { $0.start < $1.start }
        var ranges: [(start: Double, end: Double, fadeIn: Double, fadeOut: Double)] = []
        for (i, s) in scenes.enumerated() where s.spaceID == id {
            let lead = i > 0 ? s.transition : 0.3
            let tail = i + 1 < scenes.count ? scenes[i + 1].transition : 0.5
            let start = max(0, s.start - (i > 0 ? lead / 2 : 0))
            let end = min(project.duration, s.end + (i + 1 < scenes.count ? tail / 2 : 0))
            if let last = ranges.last, last.end >= start - 0.02 {
                ranges[ranges.count - 1].end = end
                ranges[ranges.count - 1].fadeOut = tail
            } else {
                ranges.append((start, end, lead, tail))
            }
        }
        guard !ranges.isEmpty else { return }
        let track = project.tracks.first { $0.kind == .ambience }?.id ?? addTrack(kind: .ambience)
        await withTaskGroup(of: Void.self) { group in
            for r in ranges {
                group.addTask {
                    await self.generate(prompt: sp.ambiencePrompt, track: track, start: r.start, duration: r.end - r.start, takes: 2,
                                        loop: true, influence: 0.3, name: sp.name, fadeIn: r.fadeIn, fadeOut: r.fadeOut, gain: -6)
                }
            }
        }
    }

    // MARK: Music

    /// Composes a score that follows the film section by section and places it on a music track.
    /// With no sections given, the scene lane is used: one section per scene.
    @discardableResult
    func composeMusic(style: String, sections given: [MusicSection]? = nil, track: UUID? = nil, options: MusicOptions? = nil) async throws -> UUID {
        let o = options ?? MusicOptions()
        func terms(_ text: String) -> [String] {
            text.split(whereSeparator: { ",;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var overall = terms(o.genre) + terms(o.mood) + terms(o.instruments) + terms(style)
        if let bpm = o.tempo { overall.append("\(bpm) BPM") }
        overall = overall.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let range: ClosedRange<Double> = o.loopOnly ? (project.loopRange ?? 0...project.duration) : 0...project.duration
        var sections = given ?? (o.followScenes ? project.scenes.sorted { $0.start < $1.start }.map {
            MusicSection(start: $0.start, end: $0.end, cue: $0.name, styles: [])
        } : [])
        if given == nil { sections = sections.filter { $0.end > range.lowerBound && $0.start < range.upperBound } }
        if sections.isEmpty {
            // One continuous piece, cut only where the two-minute limit forces it.
            var t = range.lowerBound
            while t < range.upperBound - 0.01 {
                let e = min(range.upperBound, t + 120)
                sections.append(MusicSection(start: t, end: e, cue: project.name, styles: []))
                t = e
            }
        }
        sections.sort { $0.start < $1.start }
        // The music model needs sections of 3 s to 2 min and at most 30 of them: fold short ones into their neighbour.
        var merged: [MusicSection] = []
        for var s in sections {
            s.start = max(range.lowerBound, s.start); s.end = min(range.upperBound, s.end)
            guard s.end > s.start else { continue }
            if var last = merged.last, (last.end - last.start < 3) || (s.end - s.start < 3 && last.end - last.start + s.end - s.start <= 120) {
                last.end = s.end
                last.styles += s.styles.filter { !last.styles.contains($0) }
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        while merged.count > 30, let i = merged.indices.dropLast().min(by: { merged[$0].end - merged[$0].start < merged[$1].end - merged[$1].start }) {
            merged[i].end = merged[i + 1].end
            merged.remove(at: i + 1)
        }
        guard let first = merged.first, let last = merged.last else { throw ServiceError(message: "There is nothing to score yet.") }
        let start = first.start, length = last.end - start
        guard length >= 3 else { throw ServiceError(message: "That stretch is too short to score (under 3 seconds).") }
        // Lyrics are sung in order, shared out across the sections by length.
        let lines = o.vocals ? o.lyrics.split(separator: "\n").map { String($0.prefix(200)) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } : []
        var nextLine = 0
        var avoid = terms(o.avoid)
        if !o.vocals { avoid += ["vocals", "singing", "lyrics", "spoken word", "choir"].filter { !avoid.contains($0) } }
        var chunks: [[String: Any]] = []
        for (i, s) in merged.enumerated() {
            var styles = s.styles
            if i == 0 || styles.isEmpty { styles = overall + styles.filter { !overall.contains($0) } }
            if !o.vocals, !styles.contains(where: { $0.lowercased().contains("instrumental") }) { styles.append("instrumental") }
            if styles.isEmpty { styles = ["cinematic"] }
            // The text is a section label, then lyric lines. Anything else written here would be sung.
            let label = s.cue.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
            var text = "[" + (o.vocals ? String(label.prefix(40)) : "Instrumental") + "]"
            if !lines.isEmpty {
                let share = i == merged.count - 1 ? lines.count - nextLine
                    : Int((Double(lines.count) * (s.end - s.start) / length).rounded())
                let take = lines[nextLine..<min(lines.count, nextLine + max(0, share))]
                nextLine += take.count
                if !take.isEmpty { text += "\n" + take.prefix(28).joined(separator: "\n") }
            }
            chunks.append(["text": text,
                           "duration_ms": min(120_000, max(3000, Int(((s.end - s.start) * 1000).rounded()))),
                           "positive_styles": Array(styles.prefix(50)), "negative_styles": Array(avoid.prefix(50)),
                           "context_adherence": o.strict ? "high" : "medium"])
        }
        let trackID: UUID
        if let track, project.trackIndex(track) != nil { trackID = track }
        else if let existing = project.tracks.first(where: { $0.kind == .music }) { trackID = existing.id }
        else { trackID = addTrack(kind: .music, name: "Music") }

        var clip = Clip(name: "Score", start: start, duration: length)
        clip.prompt = overall.joined(separator: ", ")
        clip.fadeIn = 0.05
        clip.fadeOut = 0.8
        clip.gain = -6
        clip.pending = 1
        mutate { p in if let i = p.trackIndex(trackID) { p.tracks[i].clips.append(clip) } }
        let audio = subfolder("Audio")
        do {
            let r = try await ElevenLabs.music(chunks: chunks)
            let file = audio.appendingPathComponent("music-" + UUID().uuidString.prefix(8) + "." + r.ext)
            try r.data.write(to: file)
            let d = AudioCache.shared.duration(file)
            guard d > 0 else { throw ServiceError(message: "ElevenLabs returned music that could not be read.") }
            live { p in
                guard let l = p.locate(clip: clip.id) else { return }
                p.tracks[l.track].clips[l.clip].pending = 0
                p.tracks[l.track].clips[l.clip].takes.append(Take(file: "Audio/" + file.lastPathComponent, duration: d))
                p.tracks[l.track].clips[l.clip].duration = min(length, d)
            }
        } catch {
            live { p in
                guard let l = p.locate(clip: clip.id) else { return }
                p.tracks[l.track].clips[l.clip].pending = 0
                p.tracks[l.track].clips[l.clip].error = error.localizedDescription
            }
            throw error
        }
        return clip.id
    }

    /// Plays a take on its own; the same take again stops it.
    func playTake(_ take: Take) {
        let same = auditioning == take.id
        stopAudition()
        guard !same, let a = try? AVAudioPlayer(contentsOf: url(for: take)), a.play() else { return }
        audition = a
        auditioning = take.id
        let id = take.id, length = a.duration
        auditionEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 0.05))
            guard !Task.isCancelled, let self, self.auditioning == id else { return }
            self.stopAudition()
        }
    }

    func stopAudition() {
        auditionEnd?.cancel()
        auditionEnd = nil
        audition?.stop()
        audition = nil
        if auditioning != nil { auditioning = nil }
    }

    // MARK: Export

    func export(_ format: ExportFormat, to url: URL? = nil) async throws -> (url: URL, summary: String) {
        let out = url ?? subfolder("Exports").appendingPathComponent(format.isFolder ? "\(project.name) \(format.suffix)" : "\(project.name).\(format.suffix).\(format.ext)")
        let p = project, folder = self.folder, video = videoURL
        busy = "Exporting \(format.title.lowercased())"
        defer { busy = nil }
        let summary = try await Task.detached(priority: .userInitiated) {
            try await Exporter.export(p, format: format, to: out, videoURL: video, resolve: { Store.url(for: $0, in: folder) })
        }.value
        return (out, summary)
    }
}
