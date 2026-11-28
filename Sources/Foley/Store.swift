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
        didSet {
            guard selection != oldValue else { return }
            stopAudition()
            // Clicking a clip, track, scene or space shows its settings, even while the assistant is open
            // (but not while Claude is working and selecting things itself).
            if selection != .none, showClaude, !anyAgentRunning { showClaude = false }
        }
    }
    /// Never anything but a real number in range: a bad value here becomes a timeline with no width, which AppKit will not survive.
    var zoom = 1.0 { didSet { if !zoom.isFinite || zoom < 1 || zoom > zoomCap { zoom = oldValue.isFinite ? min(zoomCap, max(1, zoom.isFinite ? zoom : oldValue)) : 1 } } }
    /// How far in the timeline can be zoomed, as a multiple of fitting the film in the window. Set by the timeline: far
    /// enough to see single samples of the sound on a short film, less on a long one so the timeline never becomes
    /// wider than the drawing system can place things exactly.
    @ObservationIgnored var zoomCap = 40.0
    /// What a click or drag on the timeline does.
    var tool = Tool.pointer {
        didSet { if tool != .marquee { marquee = nil } }
    }
    var marquee: Marquee?
    /// The pinch in progress. Its own object, so stretching the timeline does not touch anything that follows the store.
    @ObservationIgnored let zoomLive = ZoomLive()
    /// Set by the timeline: scrolls it to an x offset. Used by the hidden scroll benchmark.
    @ObservationIgnored var scrollTimeline: ((CGPoint) -> Void)?
    /// Set by the timeline: re-measures its scrolling area after row heights change.
    @ObservationIgnored var relayoutTimeline: (() -> Void)?
    /// The timeline's own pinch handler, so a test can drive exactly what the trackpad drives.
    @ObservationIgnored var debugPinch: ((CGFloat, CGPoint, Bool, Bool) -> Void)?
    var vzoom = 1.0 { didSet { if !vzoom.isFinite || vzoom < 0.75 || vzoom > 3 { vzoom = oldValue.isFinite ? min(3, max(0.75, vzoom.isFinite ? vzoom : oldValue)) : 1 } } }
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
    /// The resource monitor pinned in a corner of the picture. Held here so the menu's tick, Settings and the card agree at once.
    var vitalsOn: Bool = UserDefaults.standard.bool(forKey: "vitalsOn") { didSet { UserDefaults.standard.set(vitalsOn, forKey: "vitalsOn") } }
    /// Subtitles drawn over the picture.
    var subtitlesOn: Bool = UserDefaults.standard.bool(forKey: "subtitlesOn") { didSet { UserDefaults.standard.set(subtitlesOn, forKey: "subtitlesOn") } }
    /// The panel down the right side put away, to give the picture, timeline and mixer the whole width.
    var sideHidden: Bool = UserDefaults.standard.bool(forKey: "sideHidden") { didSet { UserDefaults.standard.set(sideHidden, forKey: "sideHidden") } }
    /// The right side is showing: the inspector unless put away, and always while Claude is open.
    var sideOpen: Bool { showClaude || !sideHidden }
    func toggleSide() {
        if sideOpen { showClaude = false; sideHidden = true } else { sideHidden = false }
    }
    var canUndo = false
    var canRedo = false
    let player = Player()
    var showDub = false
    var showCutCheck = false
    /// The look: a palette's id. Remembered between launches.
    var theme: String = Theme.current.id { didSet { Theme.current = Palette.named(theme); UserDefaults.standard.set(theme, forKey: "theme") } }
    /// The picture is in a window of its own (for a second screen).
    var pictureOut = false
    /// Asks a small panel to open itself: "presets" or "duck", for the selected track. Set by the voice helper.
    var peek: String?
    /// What is open under the timeline: "mixer", "library" or nothing. Remembered between launches.
    /// What is docked under the timeline: the mixer, or nothing. (A library used to be an option here; a saved choice of it opens the mixer.)
    var dock: String? = UserDefaults.standard.string(forKey: "dock").map { _ in "mixer" } { didSet { UserDefaults.standard.set(dock, forKey: "dock") } }
    /// The library as a browser down the left side of the window.
    var browser: Bool = UserDefaults.standard.bool(forKey: "browser") { didSet { UserDefaults.standard.set(browser, forKey: "browser") } }
    func toggleDock(_ which: String) { dock = dock == which ? nil : which }
    /// Languages being dubbed right now, and how each is getting on.
    var dubJobs: [DubJob] = []
    /// Your own sounds, indexed.
    @ObservationIgnored let library = Library()
    /// Claude, up to four at once: each has its own conversation and sees a note of what the others are doing.
    var agents: [AgentState] = [AgentState(name: "Agent 1")]
    var agentIndex = 0
    var agent: AgentState { agents[min(max(0, agentIndex), agents.count - 1)] }
    var anyAgentRunning: Bool { agents.contains { $0.running } }
    func addAgent() {
        guard agents.count < 4 else { return }
        let n = (1...4).first { i in !agents.contains { $0.name == "Agent \(i)" } } ?? agents.count + 1
        agents.append(AgentState(name: "Agent \(n)"))
        agentIndex = agents.count - 1
    }
    func closeAgent(_ a: AgentState) {
        guard agents.count > 1, let i = agents.firstIndex(where: { $0 === a }) else { return }
        a.stop()
        agents.remove(at: i)
        agentIndex = min(agentIndex, agents.count - 1)
    }
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

    static var library: URL { Places.sessions }
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var filmstrips: [String: [NSImage]] = [:]
    @ObservationIgnored private var saveTimer: Timer?

    init() {
        folder = Store.library.appendingPathComponent("Untitled." + AppPaths.sessionExtension, isDirectory: true)
        // Whatever the autosave interval, nothing is lost on quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        applyHoverHelp()
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
        // The engine is about to be rebuilt (a track, space or plug-in came or went): keep what the open plug-ins are set to.
        if MixGraph.signature(project) != player.graph.signature {
            capturePluginStates()
            PluginWindows.closeAll()
        }
        player.sync(project, resolve: { [folder] in Store.url(for: $0, in: folder) })
        saveWork?.cancel()
        dirty = true
        let every = Places.autosave
        if every <= 0 {
            // Save shortly after every change.
            let work = DispatchWorkItem { [weak self] in self?.save() }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else if saveTimer == nil || saveTimer?.timeInterval != every {
            // Save on a timer, and only when something has changed since the last save.
            saveTimer?.invalidate()
            let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in
                Task { @MainActor in if self?.dirty == true { self?.save() } }
            }
            RunLoop.main.add(t, forMode: .common)
            saveTimer = t
        }
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
        capturePluginStates()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(project) else { return }
        dirty = false
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
        create(at: url)
    }

    /// Makes an empty session in the folder `url` (which ends in .mitroley).
    func create(at url: URL) {
        save()
        try? FileManager.default.removeItem(at: url)
        folder = url
        project = Project.starter()
        project.name = url.deletingPathExtension().lastPathComponent
        ready = true
        reset()
        save()
    }

    // MARK: Tabs

    /// The sessions kept open as tabs along the top of the window. One is shown at a time; the others are saved on disk
    /// and opened again when their tab is picked.
    var tabs: [URL] = (UserDefaults.standard.stringArray(forKey: "openTabs") ?? [])
        .filter { FileManager.default.fileExists(atPath: $0 + "/project.json") }.map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(tabs.map(\.path), forKey: "openTabs") }
    }

    func isCurrent(_ tab: URL) -> Bool { tab.standardizedFileURL == folder.standardizedFileURL }

    /// Shows another tab's session. The one being left is saved first.
    func showTab(_ tab: URL) {
        guard !isCurrent(tab) else { return }
        if !open(tab) { tabs.removeAll { $0 == tab } }
    }

    /// Closes a tab. The session stays on disk. The last tab cannot be closed: there is always a session open.
    func closeTab(_ tab: URL) {
        guard tabs.count > 1, let i = tabs.firstIndex(of: tab) else { return }
        if isCurrent(tab) {
            let next = tabs[i == tabs.count - 1 ? i - 1 : i + 1]
            guard open(next) else { return }
        }
        tabs.removeAll { $0 == tab }
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("project.json")) else {
            say(url.pathExtension == "zip" ? "Unzip the session first: double-click the .zip in Finder, then open the .mitroley it makes."
                : "\(url.lastPathComponent) is not a mitroley session, or it arrived incomplete. Ask for it again as a .zip made with File › Share Session.", error: true)
            return false
        }
        var p: Project
        do { p = try JSONDecoder().decode(Project.self, from: data) } catch {
            // Say what was wrong, so a session from a newer version is not mistaken for a broken one.
            var why = "\(error.localizedDescription)"
            if case DecodingError.dataCorrupted(let c) = error { why = c.debugDescription + " (" + c.codingPath.map(\.stringValue).joined(separator: " › ") + ")" }
            if case DecodingError.keyNotFound(let k, _) = error { why = "it has no \"\(k.stringValue)\"" }
            if case DecodingError.typeMismatch(_, let c) = error { why = c.debugDescription + " (" + c.codingPath.map(\.stringValue).joined(separator: " › ") + ")" }
            say("That session could not be opened: \(why). It was probably saved by a newer mitroley than this one: update this copy and try again.", error: true)
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
        if !tabs.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) { tabs.append(folder) }
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
        // Kept per video: switching back to a cut shows its filmstrip at once.
        if let have = filmstrips[url.path] { filmstrip = have; return }
        Task {
            let frames = await VideoAnalysis.filmstrip(url, duration: v.duration, count: 28)
            self.filmstrips[url.path] = frames
            if self.filmstrips.count > 6, let extra = self.filmstrips.keys.first(where: { $0 != url.path }) { self.filmstrips[extra] = nil }
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

    /// One strip per shot: six moments of it side by side (fewer for a very short shot).
    func writeStrips(shots: [(start: Double, end: Double)]) async -> [(shot: Int, times: [Double], path: String)] {
        guard let url = videoURL else { return [] }
        let dir = subfolder("Frames")
        var out: [(Int, [Double], String)] = []
        for (i, s) in shots.enumerated() {
            let length = s.end - s.start
            let n = length < 0.4 ? 2 : length < 0.9 ? 4 : 6
            // Evenly through the shot, a little in from each cut so no frame shows the neighbouring shot.
            let inset = min(0.06, length / 8)
            let times = (0..<n).map { k in s.start + inset + (length - 2 * inset) * Double(k) / Double(max(1, n - 1)) }
            guard let img = await VideoAnalysis.strip(url, times: times, columns: 3, cell: 448) else { continue }
            let file = dir.appendingPathComponent(String(format: "shot_%03d.jpg", i + 1))
            if VideoAnalysis.writeJPEG(img, to: file) { out.append((i + 1, times, file.path)) }
        }
        return out
    }

    /// Stills of one part of the picture, enlarged.
    func writeFrames(at times: [Double], region: CGRect, maxSize: CGFloat = 768) async -> [(time: Double, path: String)] {
        guard let url = videoURL else { return [] }
        let dir = subfolder("Frames")
        var out: [(Double, String)] = []
        for t in times {
            guard let img = await VideoAnalysis.frame(url, at: t, region: region, maxSize: maxSize) else { continue }
            let file = dir.appendingPathComponent(String(format: "zoom_%07.2fs.jpg", t))
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
    /// The helper you talk to.
    @ObservationIgnored let voiceAgent = VoiceAgent()
    /// Set by the toolbar: opens the Room window.
    @ObservationIgnored var openRoom: (() -> Void)?
    /// Whether the master effects rack is showing.
    var showMaster = false
    /// Speech models the ElevenLabs account offers: (id, name). Empty until asked for.
    var voiceModels: [(id: String, name: String)] = []
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
    /// `duration`: how long the new takes should be. nil = as long as the clip is now.
    func moreTakes(for clipID: UUID, count: Int, influence: Double = 0.3, duration: Double? = nil) async {
        if let duration {
            // The clip takes the new length, so the new takes are heard in full.
            mutate { p in if let l = p.locate(clip: clipID) { p.tracks[l.track].clips[l.clip].duration = min(30, max(0.5, duration)) } }
        }
        await fetchTakes(for: clipID, count: count, influence: influence, marked: false)
    }

    /// Composes another version of a music clip from its description. `length` nil = the whole film from its start;
    /// otherwise that many seconds from where the clip starts.
    func recompose(_ clipID: UUID, length: Double?) async {
        guard let l = project.locate(clip: clipID) else { return }
        let clip = project.tracks[l.track].clips[l.clip]
        // The clip's own description is the style; how it is sung and what to leave out come from the session's music settings.
        var o = project.music ?? MusicOptions()
        o.genre = clip.prompt; o.mood = ""; o.instruments = ""; o.tempo = nil
        o.loopOnly = false
        o.length = length
        do {
            try await composeMusic(style: "", track: project.tracks[l.track].id, options: o, into: clipID, from: length == nil ? nil : clip.start)
        } catch { say(error.localizedDescription, error: true) }
    }

    private func fetchTakes(for clipID: UUID, count: Int, influence: Double, marked: Bool) async {
        guard let loc = project.locate(clip: clipID) else { return }
        let clip = project.tracks[loc.track].clips[loc.clip]
        if !marked { live { p in if let l = p.locate(clip: clipID) { p.tracks[l.track].clips[l.clip].pending += count; p.tracks[l.track].clips[l.clip].error = nil } } }
        // ElevenLabs makes 0.5–30 s. Longer beds are generated as loops and tiled.
        let voiceSettings = project.voice
        let genDuration = min(30, max(0.5, clip.duration))
        let loop = clip.loop
        let audio = subfolder("Audio")
        await withTaskGroup(of: Result<Take, Error>.self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        let r = try await (clip.voiceID.map { v in { try await ElevenLabs.speech(clip.prompt, voice: v, settings: voiceSettings) } }
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
    /// `into`: an existing music clip that gets the new piece as another take, instead of a new clip being made.
    /// `from`: where a piece of a hand-set length starts; the playhead when not given.
    func composeMusic(style: String, sections given: [MusicSection]? = nil, track: UUID? = nil, options: MusicOptions? = nil,
                      into existing: UUID? = nil, from: Double? = nil) async throws -> UUID {
        let o = options ?? MusicOptions()
        func terms(_ text: String) -> [String] {
            text.split(whereSeparator: { ",;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var overall = terms(o.genre) + terms(o.mood) + terms(o.instruments) + terms(style)
        if let bpm = o.tempo { overall.append("\(bpm) BPM") }
        overall = overall.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        var range: ClosedRange<Double> = o.loopOnly ? (project.loopRange ?? 0...project.duration) : 0...project.duration
        // A length set by hand: that much music from the playhead (from the loop's start when only the loop is scored),
        // even past the end of the picture.
        if given == nil, let manual = o.length {
            let from = from ?? (o.loopOnly && project.loopRange != nil ? range.lowerBound : max(0, player.time))
            range = from...(from + min(600, max(3, manual)))
        }
        var sections = given ?? (o.followScenes ? project.scenes.sorted { $0.start < $1.start }.map {
            MusicSection(start: $0.start, end: $0.end, cue: $0.name, styles: [])
        } : [])
        if given == nil { sections = sections.filter { $0.end > range.lowerBound && $0.start < range.upperBound } }
        // Scenes stop where the picture does. Music asked to run longer carries on in the last scene's mood.
        if given == nil, o.length != nil, var t = sections.map(\.end).max(), t < range.upperBound - 0.01 {
            let cue = sections.last?.cue ?? project.name
            while t < range.upperBound - 0.01 {
                let e = min(range.upperBound, t + 120)
                sections.append(MusicSection(start: t, end: e, cue: cue, styles: []))
                t = e
            }
        }
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
        if let existing, let l = project.locate(clip: existing) {
            // Another take of a piece that is already there.
            clip = project.tracks[l.track].clips[l.clip]
            live { p in
                guard let l = p.locate(clip: existing) else { return }
                p.tracks[l.track].clips[l.clip].pending += 1
                p.tracks[l.track].clips[l.clip].error = nil
            }
        } else {
            clip.prompt = overall.joined(separator: ", ")
            clip.fadeIn = 0.05
            clip.fadeOut = 0.8
            clip.gain = -6
            clip.pending = 1
            mutate { p in if let i = p.trackIndex(trackID) { p.tracks[i].clips.append(clip) } }
        }
        let another = existing != nil
        let audio = subfolder("Audio")
        do {
            let r = try await ElevenLabs.music(chunks: chunks)
            let file = audio.appendingPathComponent("music-" + UUID().uuidString.prefix(8) + "." + r.ext)
            try r.data.write(to: file)
            let d = AudioCache.shared.duration(file)
            guard d > 0 else { throw ServiceError(message: "ElevenLabs returned music that could not be read.") }
            live { p in
                guard let l = p.locate(clip: clip.id) else { return }
                p.tracks[l.track].clips[l.clip].pending = max(0, p.tracks[l.track].clips[l.clip].pending - 1)
                p.tracks[l.track].clips[l.clip].takes.append(Take(file: "Audio/" + file.lastPathComponent, duration: d))
                p.tracks[l.track].clips[l.clip].duration = min(length, d)
                if another {
                    // The new piece becomes the one that plays, placed where it was asked for.
                    p.tracks[l.track].clips[l.clip].activeTake = p.tracks[l.track].clips[l.clip].takes.count - 1
                    p.tracks[l.track].clips[l.clip].start = start
                    p.tracks[l.track].clips[l.clip].loop = false
                }
            }
        } catch {
            live { p in
                guard let l = p.locate(clip: clip.id) else { return }
                p.tracks[l.track].clips[l.clip].pending = max(0, p.tracks[l.track].clips[l.clip].pending - 1)
                p.tracks[l.track].clips[l.clip].error = error.localizedDescription
            }
            throw error
        }
        return clip.id
    }

    /// The library sound being listened to, by its path.
    var auditionPath: String?

    /// Plays a file on its own (a library sound); the same file again stops it.
    func audition(path: String, again: Bool = false) {
        let same = auditionPath == path && !again
        stopAudition()
        guard !same, let a = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)), a.play() else { return }
        audition = a
        auditionPath = path
        let length = a.duration
        auditionEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 0.05))
            guard !Task.isCancelled, let self, self.auditionPath == path else { return }
            self.stopAudition()
        }
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
        if auditionPath != nil { auditionPath = nil }
    }

    // MARK: Export

    func export(_ format: ExportFormat, to url: URL? = nil) async throws -> (url: URL, summary: String) {
        let out = url ?? exportsFolder.appendingPathComponent(format.isFolder ? "\(project.name) \(format.suffix)" : "\(project.name).\(format.suffix).\(format.ext)")
        capturePluginStates()
        let p = project, folder = self.folder, video = videoURL
        busy = "Exporting \(format.title.lowercased())"
        defer { busy = nil }
        let summary = try await Task.detached(priority: .userInitiated) {
            try await Exporter.export(p, format: format, to: out, videoURL: video, resolve: { Store.url(for: $0, in: folder) })
        }.value
        return (out, summary)
    }
}
