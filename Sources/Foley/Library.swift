import AVFoundation
import Accelerate
import Observation
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// One sound in the library, with what was measured about it.
struct SoundItem: Codable, Identifiable, Equatable {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case click, hit, rise, swell, steady, pulsing, mixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .click: "Click"
            case .hit: "Hit"
            case .rise: "Rise"
            case .swell: "Swell"
            case .steady: "Steady"
            case .pulsing: "Pulsing"
            case .mixed: "Mixed"
            }
        }
        var about: String {
            switch self {
            case .click: "Very short: taps, ticks, UI sounds"
            case .hit: "Starts loud and dies away: impacts, thuds, slams"
            case .rise: "Builds to its end: risers, whooshes in"
            case .swell: "Builds, then falls: pass-bys, whooshes"
            case .steady: "Holds its level: ambiences, tones, beds"
            case .pulsing: "Repeats: steps, rattles, rhythms"
            case .mixed: "No single shape"
            }
        }
    }
    enum Tone: String, Codable, CaseIterable, Identifiable {
        case low, mid, bright
        var id: String { rawValue }
        var title: String { self == .low ? "Low" : self == .mid ? "Mid" : "Bright" }
    }
    var id: String { path }
    var path: String
    var folder: String          // the folder it sits in, as its category
    var name: String
    var duration: Double
    var peakDB: Double
    var envelope: [Float]       // 48 points of loudness over its length, 0…1
    var shape: Shape
    var tone: Tone
    var centroid: Double        // Hz: where the weight of the sound sits
    var note: String?           // its pitch, when it has a clear one
    var modified: Double
    var size: Int

    var url: URL { URL(fileURLWithPath: path) }
}

/// Your own sounds, indexed so they can be found by what they are like: shape, tone, length, pitch.
@MainActor @Observable
final class Library {
    var items: [SoundItem] = []
    var scanning = false
    var progress = ""
    var folders: [URL] = []
    /// The sound the browser has selected, by path.
    var picked: String?
    /// What the browser is showing, in order, for stepping through with the arrow keys.
    @ObservationIgnored var shown: [SoundItem] = []
    /// The keys go to the browser while it is open and the pointer was last pressed inside it.
    @ObservationIgnored var hovered = false
    @ObservationIgnored var active = false
    /// The sound being dragged out of the browser, so the timeline can draw it at its real length.
    var dragged: SoundItem?

    /// Steps the selection up or down the list. Returns the sound it landed on.
    func step(_ by: Int) -> SoundItem? {
        guard !shown.isEmpty else { return nil }
        let at = shown.firstIndex { $0.id == picked }
        let next = min(shown.count - 1, max(0, (at ?? (by > 0 ? -1 : shown.count)) + by))
        picked = shown[next].id
        return shown[next]
    }
    var pickedItem: SoundItem? { shown.first { $0.id == picked } }

    nonisolated static let kinds: Set<String> = ["wav", "wave", "aif", "aiff", "mp3", "m4a", "caf", "flac", "aac"]

    /// Every sound file under the folders, with when it last changed and its size.
    nonisolated static func files(in roots: [URL]) -> [(URL, Double, Int)] {
        var out: [(URL, Double, Int)] = []
        for root in roots {
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            while let u = walk.nextObject() as? URL {
                guard kinds.contains(u.pathExtension.lowercased()) else { continue }
                let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                out.append((u, v?.contentModificationDate?.timeIntervalSince1970 ?? 0, v?.fileSize ?? 0))
                if out.count >= 20000 { return out }
            }
        }
        return out
    }
    private static var indexURL: URL { AppPaths.support.appendingPathComponent("library.json") }
    /// Where sounds go when nothing else is chosen.
    static var home: URL {
        let u = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("mitroley Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "libraryFolders") ?? []
        folders = saved.isEmpty ? [Self.home] : saved.map { URL(fileURLWithPath: $0) }
        if let data = try? Data(contentsOf: Self.indexURL), let old = try? JSONDecoder().decode([SoundItem].self, from: data) { items = old }
    }

    func add(folder: URL) {
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        UserDefaults.standard.set(folders.map(\.path), forKey: "libraryFolders")
        Task { await scan() }
    }

    func remove(folder: URL) {
        folders.removeAll { $0 == folder }
        if folders.isEmpty { folders = [Self.home] }
        UserDefaults.standard.set(folders.map(\.path), forKey: "libraryFolders")
        Task { await scan() }
    }

    /// Looks through the folders. Sounds measured before, and unchanged since, are not measured again.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        progress = "Looking for sounds"
        defer { scanning = false; progress = "" }
        let roots = folders
        let known = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let found = await Task.detached(priority: .utility) { Library.files(in: roots) }.value
        var fresh: [SoundItem] = []
        var todo: [(URL, Double, Int)] = []
        for f in found {
            if let k = known[f.0.path], k.modified == f.1, k.size == f.2 { fresh.append(k) } else { todo.append(f) }
        }
        var done = 0
        let total = todo.count
        // A few at a time: decoding is the slow part.
        var index = 0
        while index < todo.count {
            let batch = Array(todo[index..<min(todo.count, index + 8)])
            index += batch.count
            let measured = await withTaskGroup(of: SoundItem?.self) { group -> [SoundItem] in
                for f in batch { group.addTask { Library.measure(f.0, modified: f.1, size: f.2) } }
                var out: [SoundItem] = []
                for await m in group { if let m { out.append(m) } }
                return out
            }
            fresh += measured
            done += batch.count
            progress = "Measuring \(done) of \(total)"
            if done % 64 == 0 { items = fresh.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        }
        items = fresh.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.indexURL, options: .atomic) }
    }

    // MARK: Measuring

    /// Decodes up to a minute of a file to mono and measures it. nil if it cannot be read.
    nonisolated static func measure(_ url: URL, modified: Double, size: Int) -> SoundItem? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let total = Double(file.length) / rate
        let frames = AVAudioFrameCount(min(Double(file.length), rate * 60))
        guard frames > 64, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf, frameCount: frames)) != nil, let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), chans = Int(file.processingFormat.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chans { vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(n)) }
        var scale = 1 / Float(chans)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
        return measure(mono, rate: rate, duration: total, url: url, modified: modified, size: size)
    }

    nonisolated static func measure(_ mono: [Float], rate: Double, duration: Double, url: URL, modified: Double = 0, size: Int = 0) -> SoundItem {
        let n = mono.count
        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(n))
        // Loudness over the length, in 48 steps, then scaled so the loudest step is 1.
        let points = 48
        var env = [Float](repeating: 0, count: points)
        mono.withUnsafeBufferPointer { p in
            for i in 0..<points {
                let a = i * n / points, b = max(a + 1, (i + 1) * n / points)
                var r: Float = 0
                vDSP_rmsqv(p.baseAddress! + a, 1, &r, vDSP_Length(min(n, b) - a))
                env[i] = r
            }
        }
        let top = env.max() ?? 0
        if top > 0 { env = env.map { $0 / top } }
        let spectrum = Self.spectrum(mono, rate: rate, env: env)
        return SoundItem(path: url.path, folder: url.deletingLastPathComponent().lastPathComponent,
                         name: url.deletingPathExtension().lastPathComponent, duration: duration,
                         peakDB: peak > 0 ? Double(20 * log10(peak)) : -120, envelope: env,
                         shape: shape(env, duration: duration), tone: spectrum.centroid < 600 ? .low : spectrum.centroid < 3000 ? .mid : .bright,
                         centroid: spectrum.centroid, note: pitch(mono, rate: rate, env: env), modified: modified, size: size)
    }

    /// What the loudness does over time.
    nonisolated static func shape(_ e: [Float], duration: Double) -> SoundItem.Shape {
        let n = e.count
        guard n >= 8 else { return .mixed }
        if duration < 0.18 { return .click }
        let peakAt = Double(e.firstIndex(of: e.max() ?? 1) ?? 0) / Double(n - 1)
        func mean(_ a: Double, _ b: Double) -> Float {
            let s = Int(a * Double(n)), t = max(s + 1, Int(b * Double(n)))
            return e[s..<min(n, t)].reduce(0, +) / Float(min(n, t) - s)
        }
        let first = mean(0, 0.25), middle = mean(0.35, 0.65), last = mean(0.75, 1)
        // Dips and returns: how many times it falls well below its surroundings and comes back.
        var bumps = 0
        var up = e[0] > 0.5
        for v in e {
            if up, v < 0.25 { up = false } else if !up, v > 0.6 { up = true; bumps += 1 }
        }
        if bumps >= 3 { return .pulsing }
        let body = e[(n / 10)..<(n * 9 / 10)]
        if (body.min() ?? 0) > 0.42 { return .steady }
        if peakAt < 0.2, middle < 0.45, last < 0.25 { return .hit }
        if peakAt > 0.72, first < 0.4 { return .rise }
        if peakAt >= 0.2, peakAt <= 0.8, first < 0.5, last < 0.5 { return .swell }
        if peakAt < 0.3, last < 0.35 { return .hit }
        return .mixed
    }

    /// Where the weight of the sound sits, from the louder parts of it.
    nonisolated static func spectrum(_ x: [Float], rate: Double, env: [Float]) -> (centroid: Double, flatness: Double) {
        let size = 4096, log2n = vDSP_Length(12)
        guard x.count >= 256, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (1000, 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var sum = [Float](repeating: 0, count: size / 2)
        // Frames taken where the sound is loud, so silence at the ends does not count.
        let loud = env.indices.filter { env[$0] > 0.35 }
        let picks = loud.isEmpty ? [0] : stride(from: 0, to: loud.count, by: max(1, loud.count / 8)).map { loud[$0] }
        for step in picks {
            let start = min(max(0, x.count - size), step * x.count / max(1, env.count))
            var frame = [Float](repeating: 0, count: size)
            let take = min(size, x.count - start)
            for i in 0..<take { frame[i] = x[start + i] * window[i] }
            var real = [Float](repeating: 0, count: size / 2), imag = [Float](repeating: 0, count: size / 2)
            var mags = [Float](repeating: 0, count: size / 2)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(size / 2))
                }
            }
            vDSP_vadd(sum, 1, mags, 1, &sum, 1, vDSP_Length(size / 2))
        }
        var weighted = 0.0, total = 0.0
        for k in 1..<(size / 2) {
            let m = Double(sum[k])     // by power: a low thump with a little hiss on top still reads as low
            weighted += m * Double(k) * rate / Double(size)
            total += m
        }
        return (total > 0 ? weighted / total : 1000, 0)
    }

    /// The pitch, if the sound has a clear one: a tone, a beep, a note. Noise and impacts give nil.
    nonisolated static func pitch(_ x: [Float], rate: Double, env: [Float]) -> String? {
        let size = 4096
        guard x.count >= size else { return nil }
        // Just after the loudest moment, past the attack.
        let at = (env.firstIndex(of: env.max() ?? 1) ?? 0) * x.count / max(1, env.count)
        let start = min(x.count - size, at + Int(rate * 0.02))
        let seg = Array(x[start..<(start + size)])
        var energy: Float = 0
        vDSP_dotpr(seg, 1, seg, 1, &energy, vDSP_Length(size))
        guard energy > 1e-4 else { return nil }
        let minLag = Int(rate / 2000), maxLag = min(size / 2, Int(rate / 55))
        var r = [Float](repeating: 0, count: maxLag + 1)
        seg.withUnsafeBufferPointer { p in
            for lag in max(1, minLag - 1)...maxLag {
                var dot: Float = 0, e1: Float = 0, e2: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(size - lag))
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress!, 1, &e1, vDSP_Length(size - lag))
                vDSP_dotpr(p.baseAddress! + lag, 1, p.baseAddress! + lag, 1, &e2, vDSP_Length(size - lag))
                r[lag] = dot / max(1e-9, (e1 * e2).squareRoot())
            }
        }
        // Any smooth sound is like itself a moment later. A note is one that stops being so and then comes back:
        // only repeats after the likeness has first fallen away count.
        guard let from = (minLag..<maxLag).first(where: { r[$0] < 0.4 }) else { return nil }
        let bestR = r[from..<maxLag].max() ?? 0
        guard bestR > 0.88 else { return nil }
        // The shortest repeat that is as good as the best one: the note itself, not an octave below it.
        var best = 0
        for lag in from..<maxLag where r[lag] >= bestR - 0.04 && r[lag] > r[lag - 1] && r[lag] >= r[lag + 1] { best = lag; break }
        guard best > 0 else { return nil }
        // Between whole samples, by the curve through the peak and its neighbours.
        let a = Double(r[best - 1]), b = Double(r[best]), c = Double(r[best + 1])
        let bend = a - 2 * b + c
        let exact = Double(best) + (abs(bend) > 1e-9 ? 0.5 * (a - c) / bend : 0)
        let hz = rate / exact
        let midi = Int((69 + 12 * log2(hz / 440)).rounded())
        guard (24...108).contains(midi) else { return nil }
        return ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][midi % 12] + "\(midi / 12 - 1)"
    }

    /// How alike two sounds are in the way their loudness moves, 0…1.
    nonisolated static func likeness(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &aa, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &bb, vDSP_Length(a.count))
        return dot / max(1e-9, (aa * bb).squareRoot())
    }

    /// Search used by the window and by Claude.
    func find(text: String = "", shape: SoundItem.Shape? = nil, tone: SoundItem.Tone? = nil, minLength: Double = 0, maxLength: Double = .infinity,
              folder: String? = nil, like: SoundItem? = nil) -> [SoundItem] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        var out = items.filter { i in
            (shape == nil || i.shape == shape) && (tone == nil || i.tone == tone) && i.duration >= minLength && i.duration <= maxLength
                && (folder == nil || i.folder == folder)
                && words.allSatisfy { w in i.name.lowercased().contains(w) || i.folder.lowercased().contains(w) || (i.note ?? "").lowercased() == w }
        }
        if let like { out = out.filter { $0.id != like.id }.sorted { Library.likeness($0.envelope, like.envelope) > Library.likeness($1.envelope, like.envelope) } }
        return out
    }
}

extension Store {
    /// Puts a library sound on the timeline: on the given track, else the selected one, else an FX track.
    @discardableResult
    func place(_ item: SoundItem, track: UUID? = nil, at time: Double? = nil) -> UUID? {
        var target = track
        if target == nil, case .track(let id) = selection { target = id }
        if target == nil, case .clip(let id) = selection, let l = project.locate(clip: id) { target = project.tracks[l.track].id }
        if target == nil { target = project.tracks.first { $0.kind == .fx }?.id ?? addTrack(kind: .fx) }
        guard let target, let id = importAudio(item.url, track: target, at: time ?? player.time, name: item.name) else { return nil }
        selection = .clip(id)
        return id
    }
}

// MARK: - Window

struct LibraryView: View {
    @Environment(Store.self) private var store
    @State private var text = ""
    @State private var shape: SoundItem.Shape?
    @State private var tone: SoundItem.Tone?
    @State private var length = 0          // 0 any, 1 under half a second, 2 up to three seconds, 3 longer
    @State private var folder: String?
    @State private var like: SoundItem?
    @AppStorage("libraryAutoplay") private var autoplay = true
    /// Inside the main window, under the timeline.
    var docked = false

    private var lengths: (Double, Double) { length == 1 ? (0, 0.5) : length == 2 ? (0.5, 3) : length == 3 ? (3, .infinity) : (0, .infinity) }

    var body: some View {
        let library = store.library
        let results = Array(library.find(text: text, shape: shape, tone: tone, minLength: lengths.0, maxLength: lengths.1, folder: folder, like: like).prefix(600))
        VStack(spacing: 0) {
            if docked {
                // Under the timeline: what to look for on the left, the sounds beside it, so the list keeps its height.
                HStack(spacing: 0) {
                    ScrollView { filters(library).padding(14) }.frame(width: 400)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    list(results, library)
                }
            } else {
                filters(library).padding(16)
                Rectangle().fill(Theme.line).frame(height: 1)
                list(results, library)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 8) {
                if library.scanning { ProgressView().controlSize(.small) }
                Text(library.scanning ? library.progress : "\(results.count) of \(library.items.count) sounds\(results.count >= 600 ? ", first 600 shown" : "")")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                if store.auditionPath != nil {
                    Button { store.stopAudition() } label: {
                        Label("Stop", systemImage: "stop.fill").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(PillButtonStyle())
                    .controlSize(.small)
                }
                Spacer()
                Text("↑ ↓ move · Space plays or stops · Return places · drag onto a track").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 16).frame(height: 34)
        }
        .background(Theme.panel)
        .task { await library.scan() }
        // The arrow keys, Space and Return belong to the library while the pointer was last pressed inside it.
        .onHover { library.hovered = $0 }
        .onAppear { library.active = true }
        .onDisappear { library.active = false; library.hovered = false; store.stopAudition() }
    }

    @ViewBuilder private func filters(_ library: Library) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    TextField("Search by name, folder or note", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Menu {
                    Button("Add a Folder of Sounds…") {
                        if let u = Places.chooseFolder("Choose a folder of sounds to add to the library.", start: Library.home) { library.add(folder: u) }
                    }
                    Button("Look Again for New Sounds") { Task { await library.scan() } }
                    Toggle("Play Sounds as I Move Through Them", isOn: $autoplay)
                    Divider()
                    ForEach(library.folders, id: \.self) { f in
                        Menu(f.lastPathComponent) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                            Button("Remove from the Library") { library.remove(folder: f) }
                        }
                    }
                } label: {
                    Label("Folders", systemImage: "folder").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                chips("Shape", [("Any", shape == nil, { shape = nil })] + SoundItem.Shape.allCases.map { s in (s.title, shape == s, { shape = s }) })
            }
            if docked {
                chips("Tone", [("Any", tone == nil, { tone = nil })] + SoundItem.Tone.allCases.map { t in (t.title, tone == t, { tone = t }) })
                chips("Length", [("Any", length == 0, { length = 0 }), ("Under ½ s", length == 1, { length = 1 }), ("½ to 3 s", length == 2, { length = 2 }), ("Over 3 s", length == 3, { length = 3 })])
            } else {
                HStack(spacing: 18) {
                    chips("Tone", [("Any", tone == nil, { tone = nil })] + SoundItem.Tone.allCases.map { t in (t.title, tone == t, { tone = t }) })
                    chips("Length", [("Any", length == 0, { length = 0 }), ("Under ½ s", length == 1, { length = 1 }), ("½ to 3 s", length == 2, { length = 2 }), ("Over 3 s", length == 3, { length = 3 })])
                    Spacer(minLength: 0)
                }
            }
            let folders = Array(Set(library.items.map(\.folder))).sorted()
            if folders.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    chips("Folder", [("All", folder == nil, { folder = nil })] + folders.map { f in (f, folder == f, { folder = f }) })
                }
            }
            if let like {
                HStack(spacing: 6) {
                    Text("Sounds shaped like \(like.name), closest first").font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                    Button("Clear") { self.like = nil }.buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    @ViewBuilder private func list(_ results: [SoundItem], _ library: Library) -> some View {
        if library.items.isEmpty && !library.scanning {
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
                Text("No sounds yet").font(.system(size: 15, weight: .semibold))
                Text("Put sound files in the folder below, or add a folder you already have. Each sound is measured once, so you can find it by its shape, tone, length and pitch.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack {
                    Button("Open the Sounds Folder") { NSWorkspace.shared.open(Library.home) }.buttonStyle(PillButtonStyle(prominent: true))
                    Button("Add a Folder…") {
                        if let u = Places.chooseFolder("Choose a folder of sounds to add to the library.", start: Library.home) { library.add(folder: u) }
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty && !library.scanning {
            VStack(spacing: 6) {
                Text("Nothing matches").font(.system(size: 14, weight: .semibold))
                Text("Loosen the shape, tone or length, or clear the search.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { item in
                            LibraryRow(item: item, picked: library.picked == item.id, like: { like = item }) { library.picked = item.id }
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .onChange(of: library.picked) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: results.map(\.id), initial: true) { _, _ in library.shown = results }
            }
        }
    }

    private func chips(_ title: String, _ options: [(String, Bool, () -> Void)]) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary).frame(width: 44, alignment: .leading)
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Text(o.0).font(.system(size: 11.5, weight: o.1 ? .semibold : .medium)).lineLimit(1)
                    .foregroundStyle(o.1 ? Color.white : Theme.secondary)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(o.1 ? Theme.accent.opacity(0.32) : Color.white.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture(perform: o.2)
            }
        }
    }
}

private struct LibraryRow: View {
    @Environment(Store.self) private var store
    let item: SoundItem
    let picked: Bool
    let like: () -> Void
    let pick: () -> Void
    private var take: Take { Take(file: item.path, duration: item.duration) }

    var body: some View {
        let playing = store.auditionPath == item.path
        HStack(spacing: 10) {
            Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 9))
                .frame(width: 24, height: 24)
                .background(playing ? Theme.accent.opacity(0.4) : Color.white.opacity(0.09), in: Circle())
            // The sound's loudness over its length.
            Canvas { ctx, size in
                let n = item.envelope.count
                guard n > 1 else { return }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in item.envelope.enumerated() {
                    path.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(n - 1) * size.width, y: size.height - CGFloat(v) * (size.height - 2)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(Theme.accent.opacity(picked ? 0.9 : 0.55)))
            }
            .frame(width: 84, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.folder).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let note = item.note { tag(note) }
            tag(item.shape.title).hint(item.shape.about)
            tag(item.tone.title)
            Text(shortTime(item.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 52, alignment: .trailing)
            Button { store.place(item) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 22).background(Color.white.opacity(0.08), in: Circle()).contentShape(Circle())
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .hint("Place at the playhead, on the selected track")
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(picked ? Theme.accent.opacity(0.14) : Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.place(item) }
        .onTapGesture { pick(); store.audition(path: item.path) }
        .onDrag {
            store.library.dragged = item
            return NSItemProvider(object: item.url as NSURL)
        } preview: {
            // A small tag under the pointer, so it does not hide the place it is being dropped on.
            Text(item.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Theme.accent.opacity(0.9), in: Capsule())
        }
        .contextMenu {
            Button("Place at the Playhead") { store.place(item) }
            Button("Find Sounds Shaped Like This") { like() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 7).frame(height: 19)
            .background(Color.white.opacity(0.07), in: Capsule())
    }
}
