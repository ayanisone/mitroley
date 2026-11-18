import Foundation

// MARK: - Primitives

/// Room-centric position, the same convention Dolby Atmos uses.
/// x: -1 left … +1 right · y: -1 back … +1 front · z: 0 ear level … 1 ceiling
struct Vec3: Codable, Equatable {
    var x = 0.0
    var y = 1.0
    var z = 0.0
}

struct Keyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var value: Double
    /// How the value travels to the next keyframe: nil = straight line, "hold" = stay then jump (cuts), "smooth" = ease in and out.
    var curve: String?
}

enum TrackKind: String, Codable, CaseIterable, Identifiable {
    case ambience, foley, fx, music, dialogue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ambience: "Ambience"
        case .foley: "Foley"
        case .fx: "FX"
        case .music: "Music"
        case .dialogue: "Dialogue"
        }
    }
    var symbol: String {
        switch self {
        case .ambience: "wind"
        case .foley: "shoeprints.fill"
        case .fx: "sparkles"
        case .music: "music.note"
        case .dialogue: "waveform"
        }
    }
}

/// How a track relates to the scene lane.
enum SpaceMode: String, Codable, CaseIterable, Identifiable {
    case follow   // takes on the acoustics of whichever scene the playhead is in
    case fixed    // always lives in one space
    case dry      // ignores spaces (music, voice-over)
    var id: String { rawValue }
    var title: String {
        switch self {
        case .follow: "Follows scene"
        case .fixed: "Fixed space"
        case .dry: "Dry"
        }
    }
}

enum AutoParam: String, Codable, CaseIterable, Identifiable {
    case volume, highCut, lowCut, send, x, y, z
    var id: String { rawValue }
    var title: String {
        switch self {
        case .volume: "Volume"
        case .highCut: "Muffle"
        case .lowCut: "Low cut"
        case .send: "Space amount"
        case .x: "Left–Right"
        case .y: "Back–Front"
        case .z: "Height"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .volume: -36...12
        case .highCut: 200...20000
        case .lowCut: 20...2000
        case .send: 0...1
        case .x, .y: -1...1
        case .z: 0...1
        }
    }
    var isLog: Bool { self == .highCut || self == .lowCut }
    func format(_ v: Double) -> String {
        switch self {
        case .volume: String(format: "%+.1f dB", v)
        case .highCut: v >= 19000 ? "Open" : (v >= 1000 ? String(format: "%.1f kHz", v / 1000) : String(format: "%.0f Hz", v))
        case .lowCut: v <= 25 ? "Off" : String(format: "%.0f Hz", v)
        case .send: String(format: "%.0f%%", v * 100)
        case .x, .y, .z: String(format: "%.2f", v)
        }
    }
    /// 0…1 position of a value inside the range (log-aware).
    func unit(_ v: Double) -> Double {
        let r = range
        if isLog { return (log(v) - log(r.lowerBound)) / (log(r.upperBound) - log(r.lowerBound)) }
        return (v - r.lowerBound) / (r.upperBound - r.lowerBound)
    }
    func value(unit u: Double) -> Double {
        let r = range, c = min(1, max(0, u))
        if isLog { return exp(log(r.lowerBound) + c * (log(r.upperBound) - log(r.lowerBound))) }
        return r.lowerBound + c * (r.upperBound - r.lowerBound)
    }
}

// MARK: - Spaces (acoustic environments)

enum ReverbKind: String, Codable, CaseIterable, Identifiable {
    case smallRoom, mediumRoom, largeRoom, mediumChamber, largeChamber, mediumHall, largeHall, plate, cathedral
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smallRoom: "Small room"
        case .mediumRoom: "Medium room"
        case .largeRoom: "Large room"
        case .mediumChamber: "Chamber"
        case .largeChamber: "Large chamber"
        case .mediumHall: "Hall"
        case .largeHall: "Large hall"
        case .plate: "Plate"
        case .cathedral: "Cathedral"
        }
    }
}

/// An acoustic environment. Scenes point at spaces; tracks that follow the scene
/// are sent into the space's reverb and take on its muffle and trim.
struct Space: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var hue: Double                 // 0…1, the scene colour
    var reverb: ReverbKind = .mediumRoom
    var wet: Double = 0.2           // 0…1 how much of the sound goes into the room
    var tone: Double = 9000         // Hz low-pass on the reverb return (darker rooms = lower)
    var echo: Double = 0            // 0…1 discrete echo before the reverb (caves, canyons, tunnels)
    var echoTime: Double = 0.18     // seconds
    var echoFeedback: Double = 0.3  // 0…0.9
    var muffle: Double = 20000      // Hz low-pass on the dry sound (next room, underwater, inside a car)
    var dryTrim: Double = 0         // dB applied to the dry sound while in this space
    var ambiencePrompt: String = "" // what this place sounds like when nothing happens
    var size: Double?               // 0…1 small → large room, overriding the reverb type's own size
    var ir: String?                 // impulse response file used instead of the built-in reverb (path inside the session)
}

struct SpaceTemplate: Identifiable {
    var id: String { name }
    let name: String
    let space: Space
    static func make(_ name: String, _ hue: Double, _ reverb: ReverbKind, wet: Double, tone: Double = 9000,
                     echo: Double = 0, echoTime: Double = 0.18, echoFeedback: Double = 0.3,
                     muffle: Double = 20000, dryTrim: Double = 0, ambience: String) -> SpaceTemplate {
        SpaceTemplate(name: name, space: Space(name: name, hue: hue, reverb: reverb, wet: wet, tone: tone, echo: echo,
                                               echoTime: echoTime, echoFeedback: echoFeedback, muffle: muffle,
                                               dryTrim: dryTrim, ambiencePrompt: ambience))
    }
    static let all: [SpaceTemplate] = [
        make("Open Air", 0.33, .plate, wet: 0.03, tone: 6000, ambience: "quiet outdoor air, faint distant birds, light breeze"),
        make("Street", 0.58, .largeRoom, wet: 0.08, tone: 5000, echo: 0.06, echoTime: 0.11, echoFeedback: 0.1, ambience: "city street ambience, distant traffic, occasional passers-by"),
        make("Forest", 0.38, .mediumHall, wet: 0.10, tone: 4500, echo: 0.05, echoTime: 0.14, echoFeedback: 0.15, ambience: "forest ambience, birdsong, leaves rustling in a soft wind"),
        make("Small Room", 0.08, .smallRoom, wet: 0.14, tone: 8000, ambience: "quiet small room tone, faint electrical hum"),
        make("Living Room", 0.10, .mediumRoom, wet: 0.16, tone: 6500, ambience: "soft furnished living room tone, a clock ticking, muffled outside world"),
        make("Dining Room", 0.05, .mediumRoom, wet: 0.24, tone: 9500, ambience: "dining room tone, hard floors and walls, faint fridge hum from the kitchen"),
        make("Kitchen", 0.14, .smallRoom, wet: 0.26, tone: 12000, ambience: "kitchen room tone, refrigerator hum, hard tiled surfaces"),
        make("Bathroom", 0.52, .smallRoom, wet: 0.42, tone: 14000, ambience: "tiled bathroom tone, a tap dripping, extractor fan hum"),
        make("Hallway", 0.62, .mediumChamber, wet: 0.30, tone: 8000, ambience: "empty corridor tone, faint air conditioning"),
        make("Large Hall", 0.70, .largeHall, wet: 0.36, tone: 8500, ambience: "large empty hall room tone, vast quiet air"),
        make("Cathedral", 0.76, .cathedral, wet: 0.48, tone: 7000, ambience: "cathedral interior, huge reverberant silence, distant footsteps"),
        make("Cave", 0.80, .cathedral, wet: 0.45, tone: 4200, echo: 0.28, echoTime: 0.19, echoFeedback: 0.38, ambience: "deep cave ambience, water dripping with long echoes, low rumbling air"),
        make("Tunnel", 0.66, .largeChamber, wet: 0.40, tone: 5200, echo: 0.22, echoTime: 0.12, echoFeedback: 0.45, ambience: "concrete tunnel ambience, low air movement, distant resonant drone"),
        make("Car Interior", 0.92, .smallRoom, wet: 0.07, tone: 3500, muffle: 9000, ambience: "car interior, steady engine and road noise, muffled outside"),
        make("Next Room", 0.97, .mediumRoom, wet: 0.12, tone: 2500, muffle: 1100, dryTrim: -7, ambience: "muffled sounds through a wall"),
        make("Underwater", 0.55, .largeChamber, wet: 0.30, tone: 1500, muffle: 650, dryTrim: -3, ambience: "underwater ambience, deep muffled rumble, bubbles"),
    ]
    static func named(_ name: String) -> SpaceTemplate? {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        return all.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == key }
    }
}

// MARK: - Timeline content

struct Take: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String       // relative to the project folder, or absolute
    var duration: Double
}

struct Clip: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var start: Double
    var duration: Double
    var offset: Double = 0      // seconds into the source
    var gain: Double = 0        // dB
    var fadeIn: Double = 0.01
    var fadeOut: Double = 0.05
    var loop: Bool = false
    var takes: [Take] = []
    var activeTake: Int = 0
    var prompt: String = ""
    var pending: Int = 0        // takes still being generated
    var error: String?
    var voiceID: String?        // set on spoken lines: the ElevenLabs voice that says `prompt`
    var voiceName: String?
    var rate: Double?           // playback speed: 0.5 = half speed and an octave down, 2 = double. nil = 1
    var fadeInShape: FadeShape?     // nil = equal power
    var fadeOutShape: FadeShape?
    var speed: Double { min(4, max(0.25, rate ?? 1)) }
    var inShape: FadeShape { fadeInShape ?? .equalPower }
    var outShape: FadeShape { fadeOutShape ?? .equalPower }

    var end: Double { start + duration }
    var take: Take? { takes.indices.contains(activeTake) ? takes[activeTake] : takes.first }

    /// Seconds the clip's end could move later before its source runs out.
    var spareAfter: Double {
        if loop { return .infinity }
        guard let d = take?.duration else { return 0 }
        return max(0, (d - offset) / speed - duration)
    }
    /// Seconds the clip's start could move earlier before reaching the start of its source.
    var spareBefore: Double { loop ? .infinity : max(0, offset / speed) }

    /// Moves the start and keeps the end and the audio under it where they are.
    mutating func setStart(_ s: Double) {
        let delta = s - start
        start = s
        duration -= delta
        var off = offset + delta * speed
        if loop, let d = take?.duration, d > 0 { off = off.truncatingRemainder(dividingBy: d); if off < 0 { off += d } }
        offset = max(0, off)
    }
}

/// The curve of a fade. `gain` rises from 0 to 1; a fade-out reads it backwards. The renderer and the drawing both use it.
enum FadeShape: String, Codable, CaseIterable, Identifiable {
    case equalPower, linear, sCurve, slow, fast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .equalPower: "Equal power"
        case .linear: "Linear"
        case .sCurve: "S-curve"
        case .slow: "Slow start"
        case .fast: "Fast start"
        }
    }
    /// A small number for the render thread.
    var code: UInt8 {
        switch self {
        case .equalPower: 0
        case .linear: 1
        case .sCurve: 2
        case .slow: 3
        case .fast: 4
        }
    }
    init(code: UInt8) {
        switch code {
        case 1: self = .linear
        case 2: self = .sCurve
        case 3: self = .slow
        case 4: self = .fast
        default: self = .equalPower
        }
    }
    /// t = 0…1 through the fade, rising.
    @inline(__always)
    func gain(_ t: Float) -> Float {
        let t = min(1, max(0, t))
        switch self {
        case .equalPower: return sinf(t * .pi / 2)
        case .linear: return t
        case .sCurve: return (1 - cosf(.pi * t)) / 2
        case .slow: return t * t
        case .fast: return 1 - (1 - t) * (1 - t)
        }
    }
}

/// Two clips on one track that overlap: A fades out while B fades in, over [b.start, a.end].
/// Also used for two clips that only touch, before they are crossfaded.
struct Crossfade: Identifiable {
    var a: Clip
    var b: Clip
    var id: String { a.id.uuidString + b.id.uuidString }
    var start: Double { b.start }
    var end: Double { a.end }
    var length: Double { end - start }
    var centre: Double { (start + end) / 2 }
    /// How late A can end: until its source runs out, and always before B ends.
    var latestEnd: Double { min(a.end + a.spareAfter, b.end - 0.01) }
    /// How early B can start: until its source runs out, and always after A starts.
    var earliestStart: Double { max(0, a.start + 0.01, b.start - b.spareBefore) }

    /// B's start and A's end for an overlap of `target` seconds centred on `m`, within the audio both clips have.
    /// If one side runs out the other takes the rest; if both do the overlap gets shorter. Nil when under 5 ms fits.
    func fitted(_ target: Double, around m: Double) -> (bStart: Double, aEnd: Double)? {
        let hi = latestEnd, lo = earliestStart
        let o = min(max(0, target), hi - lo)
        guard o >= 0.005 else { return nil }
        var s = m - o / 2, e = m + o / 2
        if e > hi { e = hi; s = hi - o }
        if s < lo { s = lo; e = lo + o }
        return (s, e)
    }

    /// Both clips with B starting at `bStart`, A ending at `aEnd` and their fades matching the overlap.
    /// `shape` replaces both curves; nil keeps them.
    func applied(bStart: Double, aEnd: Double, shape: FadeShape? = nil) -> (a: Clip, b: Clip) {
        var a = self.a, b = self.b
        let o = max(0, aEnd - bStart)
        a.duration = aEnd - a.start
        b.setStart(bStart)
        a.fadeOut = o
        b.fadeIn = o
        a.fadeIn = min(a.fadeIn, max(0, a.duration - o))
        b.fadeOut = min(b.fadeOut, max(0, b.duration - o))
        if let shape { a.fadeOutShape = shape; b.fadeInShape = shape }
        return (a, b)
    }
}

struct Track: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var kind: TrackKind
    var volume: Double = 0          // dB
    var pan: Double = 0             // -1…1, used when the track is not an object
    var mute = false
    var solo = false
    var spaceMode: SpaceMode = .follow
    var fixedSpace: UUID?
    var send: Double = 1            // 0…1 how strongly the space applies
    var lowCut: Double = 20         // Hz high-pass
    var highCut: Double = 20000     // Hz low-pass
    var spatial = false             // true = Atmos-style object with a 3D position
    var position = Vec3()
    var clips: [Clip] = []
    var automation: [String: [Keyframe]] = [:]
    var lane: AutoParam?            // automation lane shown under the track
    var groupID: UUID?              // the group this track belongs to, if any
    var height: Double?             // lane height in points, nil = standard
    var duck: Duck?                 // music only: dips under voice; nil = off
    var lfe: Double?                // 0…1 how much of the track's low end also goes to the sub (immersive exports)

    func keys(_ p: AutoParam) -> [Keyframe] { automation[p.rawValue] ?? [] }

    /// Every crossfade on the track, in time order: B starts inside A (after A starts) and ends after A ends.
    func crossfades() -> [Crossfade] {
        let sorted = clips.sorted { $0.start < $1.start }
        var out: [Crossfade] = []
        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] {
                if b.start >= a.end - 1e-6 { break }
                if b.start > a.start, a.end < b.end { out.append(Crossfade(a: a, b: b)) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The crossfade this clip is part of, preferring the one into the following clip.
    func crossfade(involving id: UUID) -> Crossfade? {
        let all = crossfades()
        return all.first { $0.a.id == id } ?? all.first { $0.b.id == id }
    }

    /// The clip to crossfade with: the one it already overlaps, else the nearest clip whose edge is
    /// within 0.05 s of one of its edges, the following clip first.
    func crossfadePartner(of id: UUID) -> Crossfade? {
        if let x = crossfade(involving: id) { return x }
        guard let c = clips.first(where: { $0.id == id }) else { return nil }
        let reach = 0.05
        let next = clips.filter { $0.id != id && $0.start > c.start && $0.end > c.end && abs($0.start - c.end) <= reach }
            .min { abs($0.start - c.end) < abs($1.start - c.end) }
        if let next { return Crossfade(a: c, b: next) }
        let previous = clips.filter { $0.id != id && $0.start < c.start && $0.end < c.end && abs(c.start - $0.end) <= reach }
            .min { abs(c.start - $0.end) < abs(c.start - $1.end) }
        if let previous { return Crossfade(a: previous, b: c) }
        return nil
    }

    var lfeSend: Double {
        get { lfe ?? 0 }
        set { lfe = newValue < 0.005 ? nil : min(1, newValue) }
    }
}

struct SceneRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var name: String
    var spaceID: UUID?
    var transition: Double = 0.12   // seconds of crossfade into this scene (0.1 = hard cut, 1–3 = walking through a door)
    var note: String = ""
    var status: String?             // set by a revised cut: "new" = picture not in the previous version, "longer" = shot extended
}

/// A set of tracks mixed together: one fader, one mute and one solo for all of them.
struct TrackGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var volume: Double = 0          // dB added to every track in the group
    var mute = false
    var solo = false
    var collapsed = false
}

/// How the score should sound. Remembered with the session.
struct MusicOptions: Codable, Equatable {
    var genre = ""
    var mood = ""
    var instruments = ""
    var avoid = ""
    var tempo: Int?                 // BPM, nil = let the music decide
    var vocals = false
    var lyrics = ""
    var followScenes = true         // false = one continuous piece
    var loopOnly = false            // score only the loop region
    var strict = true               // true = follow the description closely

    var summary: String {
        [genre, mood, instruments, tempo.map { "\($0) BPM" } ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// What changed between the previous cut of the film and this one.
struct RevisionRange: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var kind: String                // "new" or "longer"
}

/// A stretch of this cut that is the same picture as the previous cut, `delta` seconds apart (old time = new time + delta).
struct RevisionSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var delta: Double
}

struct Revision: Codable, Equatable {
    var from: String                // name of the session this was made from
    var ranges: [RevisionRange]     // picture that needs sound
    var segments: [RevisionSegment]
    var summary: String
}

/// One stretch of the score: where it sits, what happens there, and how it should sound.
struct MusicSection {
    var start: Double
    var end: Double
    var cue: String
    var styles: [String]
}

struct VideoRef: Codable, Equatable {
    var path: String
    var duration: Double
    var fps: Double
    var width: Int
    var height: Int
}

struct Project: Codable, Equatable {
    var name = "Untitled"
    var fps = 30.0
    var duration = 30.0
    var video: VideoRef?
    var videoVolume = 0.0           // 0…1, the video's own soundtrack
    var tracks: [Track] = []
    var scenes: [SceneRegion] = []
    var spaces: [Space] = []
    var storyboard = ""
    var storyboardFiles: [String] = []
    var loopStart: Double?
    var loopEnd: Double?
    var groups: [TrackGroup]?
    var masterVolume: Double?       // dB on everything
    var surroundTrim: Double?       // dB on the surrounds when the mix is folded to fewer speakers
    var heightTrim: Double?         // dB on the height speakers when folded
    var dynamics: BusDynamics?      // before the rack: master compressor and limiter. Read once, then cleared
    var voice: VoiceSettings?       // how spoken lines are made: voice, model, stability and so on
    var rack: [Effect]?             // master effects; nil = a session from before the rack
    var mixFormat: MixFormat?       // what the session is mixed for; nil = 7.1.4
    var format: MixFormat { mixFormat ?? .atmos714 }
    var music: MusicOptions?
    var revision: Revision?
    var previousVersion: String?    // folder of the cut this session was made from
    var nextVersion: String?        // folder of the cut made from this one
    var loopRange: ClosedRange<Double>? {
        guard let a = loopStart, let b = loopEnd, b - a > 0.05 else { return nil }
        return a...b
    }

    static func starter() -> Project {
        var p = Project()
        p.mixFormat = MixFormat.forNewSessions
        p.tracks = [
            Track(name: "Ambience", kind: .ambience),
            Track(name: "Foley", kind: .foley, spatial: true),
            Track(name: "FX", kind: .fx, spatial: true),
        ]
        return p
    }

    func space(_ id: UUID?) -> Space? { id.flatMap { i in spaces.first { $0.id == i } } }
    func space(named n: String) -> Space? { spaces.first { $0.name.caseInsensitiveCompare(n) == .orderedSame } }
    func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }
    func locate(clip id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }
    func scene(at t: Double) -> SceneRegion? { scenes.first { t >= $0.start && t < $0.end } }
    func group(_ id: UUID?) -> TrackGroup? { id.flatMap { i in groups?.first { $0.id == i } } }
    var anySolo: Bool { tracks.contains { $0.solo } || (groups ?? []).contains { g in g.solo && tracks.contains { $0.groupID == g.id } } }

    /// Timeline rows top to bottom: a header for every group, then its tracks unless the group is folded.
    var rows: [TimelineRow] {
        var out: [TimelineRow] = []
        var last: UUID?
        for t in tracks {
            let g = group(t.groupID)
            if let g, g.id != last { out.append(.group(g, first: t.id)) }
            last = g?.id
            if g?.collapsed != true { out.append(.track(t)) }
        }
        return out
    }

    /// Keeps the tracks of each group next to each other, in the order the groups first appear.
    mutating func tidyGroups() {
        let known = Set((groups ?? []).map(\.id))
        for i in tracks.indices { if let g = tracks[i].groupID, !known.contains(g) { tracks[i].groupID = nil } }
        var out: [Track] = [], done = Set<UUID>()
        for t in tracks {
            guard let g = t.groupID else { out.append(t); continue }
            if done.insert(g).inserted { out += tracks.filter { $0.groupID == g } }
        }
        tracks = out
        groups = (groups ?? []).filter { g in tracks.contains { $0.groupID == g.id } }
        if groups?.isEmpty == true { groups = nil }
    }
}

enum TimelineRow: Identifiable {
    case group(TrackGroup, first: UUID)
    case track(Track)
    var id: String {
        switch self {
        case .group(let g, let first): "g-\(g.id)-\(first)"
        case .track(let t): t.id.uuidString
        }
    }
}

// MARK: - Mix maths (shared by live playback and offline export)

func dbToLinear(_ db: Double) -> Double { db <= -80 ? 0 : pow(10, db / 20) }
func linearToDb(_ g: Double) -> Double { g <= 0.0001 ? -80 : 20 * log10(g) }

private func smooth(_ x: Double) -> Double {
    let c = min(1, max(0, x))
    return c * c * (3 - 2 * c)
}

func interpolate(_ keys: [Keyframe], at t: Double, log isLog: Bool = false) -> Double? {
    guard let first = keys.first else { return nil }
    if keys.count == 1 || t <= first.time { return first.value }
    guard let last = keys.last else { return nil }
    if t >= last.time { return last.value }
    for i in 1..<keys.count where t <= keys[i].time {
        let a = keys[i - 1], b = keys[i]
        if a.curve == "hold" { return a.value }
        var f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 1
        if a.curve == "smooth" { f = f * f * (3 - 2 * f) }
        if isLog, a.value > 0, b.value > 0 { return exp(log(a.value) + f * (log(b.value) - log(a.value))) }
        return a.value + f * (b.value - a.value)
    }
    return last.value
}

/// Everything the engine needs to know about one track at one instant.
struct TrackMix {
    var gain = 0.0              // linear, includes mute/solo, automation and the space's dry trim
    var pan = 0.0
    var position = Vec3()
    var lowCut = 20.0
    var highCut = 20000.0
    var sends: [UUID: Double] = [:]
}

extension Project {
    /// Scenes audible at `t` with crossfade weights. Adjacent scenes crossfade across their boundary.
    func sceneWeights(at t: Double) -> [(scene: SceneRegion, weight: Double)] {
        let s = scenes.sorted { $0.start < $1.start }
        var out: [(SceneRegion, Double)] = []
        for (i, sc) in s.enumerated() {
            let hasPrev = i > 0 && abs(s[i - 1].end - sc.start) < 0.05
            let hasNext = i < s.count - 1 && abs(s[i + 1].start - sc.end) < 0.05
            var w = 1.0
            if hasPrev {
                let d = max(0.02, sc.transition)
                w *= smooth((t - (sc.start - d / 2)) / d)
            } else if t < sc.start { w = 0 }
            if hasNext {
                let d = max(0.02, s[i + 1].transition)
                w *= 1 - smooth((t - (sc.end - d / 2)) / d)
            } else if t > sc.end { w = 0 }
            if w > 0.0005 { out.append((sc, w)) }
        }
        return out
    }

    func mix(for track: Track, at t: Double, anySolo: Bool) -> TrackMix {
        var m = TrackMix()
        let group = self.group(track.groupID)
        var db = track.volume + (group?.volume ?? 0) + (masterVolume ?? 0) + (interpolate(track.keys(.volume), at: t) ?? 0)
        let sendAmount = min(1, max(0, interpolate(track.keys(.send), at: t) ?? track.send))
        var cut = interpolate(track.keys(.highCut), at: t, log: true) ?? track.highCut
        m.lowCut = interpolate(track.keys(.lowCut), at: t, log: true) ?? track.lowCut
        // On stereo-bed tracks the Left–Right lane drives the pan.
        m.pan = track.spatial ? track.pan : (interpolate(track.keys(.x), at: t) ?? track.pan)
        m.position = Vec3(x: interpolate(track.keys(.x), at: t) ?? track.position.x,
                          y: interpolate(track.keys(.y), at: t) ?? track.position.y,
                          z: interpolate(track.keys(.z), at: t) ?? track.position.z)

        var active: [(Space, Double)] = []
        switch track.spaceMode {
        case .dry: break
        case .fixed:
            if let sp = space(track.fixedSpace) { active = [(sp, 1)] }
        case .follow:
            for (sc, w) in sceneWeights(at: t) {
                if let sp = space(sc.spaceID) { active.append((sp, w)) }
            }
        }
        var logMuffle = 0.0, trim = 0.0, total = 0.0
        for (sp, w) in active {
            m.sends[sp.id, default: 0] += w * sp.wet * sendAmount
            logMuffle += w * log(sp.muffle)
            trim += w * sp.dryTrim
            total += w
        }
        if total > 0 {
            // The space's muffle and trim scale with how strongly the track sits in the space.
            let rest = max(0, 1 - total)
            let muffle = exp(logMuffle + rest * log(20000))
            let applied = exp(log(20000) + sendAmount * (log(muffle) - log(20000)))
            cut = min(cut, applied)
            db += trim * sendAmount
        }
        m.highCut = min(20000, max(120, cut))
        let audible = !track.mute && group?.mute != true && (!anySolo || track.solo || group?.solo == true)
        m.gain = audible ? dbToLinear(db) : 0
        for k in m.sends.keys { m.sends[k] = audible ? min(1, m.sends[k]! ) : 0 }
        return m
    }
}

// MARK: - Formatting

func timecode(_ t: Double, fps: Double) -> String {
    let f = max(1, fps.rounded())
    let total = Int((max(0, t) * f).rounded(.down))
    let frames = total % Int(f)
    let secs = (total / Int(f)) % 60
    let mins = total / Int(f) / 60
    return String(format: "%02d:%02d:%02d", mins, secs, frames)
}

func shortTime(_ t: Double) -> String {
    t < 60 ? String(format: "%.2fs", t) : String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

/// What a session is mixed for. Every other format can still be exported from it.
enum MixFormat: String, Codable, CaseIterable, Identifiable {
    case atmos714 = "7.1.4", surround51 = "5.1", binaural, stereo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .atmos714: "7.1.4"
        case .surround51: "5.1"
        case .binaural: "Binaural"
        case .stereo: "Stereo"
        }
    }
    var detail: String {
        switch self {
        case .atmos714: "Twelve speakers with height. The master every other format is folded from"
        case .surround51: "Six speakers, no height"
        case .binaural: "Headphones, with sounds placed around the head"
        case .stereo: "Two speakers, left and right only"
        }
    }
    /// Channels of the 7.1.4 order (L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr) this format has. In 5.1 the side pair are its surrounds.
    var channels: [Int] {
        switch self {
        case .atmos714: Array(0..<12)
        case .surround51: [0, 1, 2, 3, 6, 7]
        case .binaural, .stereo: [0, 1]
        }
    }
    var export: ExportFormat {
        switch self {
        case .atmos714: .bed714
        case .surround51: .surround51
        case .binaural: .binaural
        case .stereo: .stereo
        }
    }
    static var forNewSessions: MixFormat? {
        UserDefaults.standard.string(forKey: "defaultMixFormat").flatMap(MixFormat.init(rawValue:))
    }
    /// Folds 7.1.4 speaker power into this format's speakers, the way the exports fold the signal.
    func fold(power p: [Double]) -> [Double] {
        var o = p
        switch self {
        case .atmos714: break
        case .surround51:
            o[0] += p[8] / 2; o[1] += p[9] / 2
            o[6] += (p[4] + p[10]) / 2; o[7] += (p[5] + p[11]) / 2
            for c in [4, 5, 8, 9, 10, 11] { o[c] = 0 }
        case .binaural, .stereo:
            o[0] += p[2] / 2 + (p[6] + p[4] / 2 + p[10] / 2) / 2 + p[8] / 2
            o[1] += p[2] / 2 + (p[7] + p[5] / 2 + p[11] / 2) / 2 + p[9] / 2
            for c in 2..<12 { o[c] = 0 }
        }
        return o
    }
}
