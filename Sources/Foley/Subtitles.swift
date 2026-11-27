import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

// Subtitles: what is said in the film, read on the picture. ElevenLabs writes down the words in the language they were
// spoken in; Claude Sonnet then gives each line in Latin letters and in English. The three can be switched between, or
// the original shown over the English. The words can be dragged anywhere on the picture and restyled.

/// How subtitles are shown.
enum SubtitleMode: String, CaseIterable, Identifiable {
    case native, roman, english, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: "Original"
        case .roman: "Romanised"
        case .english: "English"
        case .both: "Both"
        }
    }
}

/// Turns lines into Latin letters and English with Claude Sonnet: fast and cheap, and good at Indian languages.
enum Translator {
    static let model = "claude-sonnet-5-5"

    static func annotate(_ lines: [String], language: String?) async throws -> [(roman: String, english: String)] {
        guard let key = Secrets.get(.anthropic) else { throw ServiceError(message: "Add your Anthropic API key in Settings to romanise and translate the subtitles.") }
        var out: [(String, String)] = []
        var index = 0
        // In batches, so a long film does not run past what one answer can hold.
        while index < lines.count {
            let batch = Array(lines[index..<min(lines.count, index + 60)])
            index += batch.count
            let numbered = batch.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let prompt = """
            These are subtitle lines from a film\(language.map { ", spoken in the language with code \"\($0)\"" } ?? ""). \
            The lines may mix languages. For each line give two things:
            - "roman": the same words written in Latin letters the way a speaker would type them in a chat, with no \
            diacritics. If the line is already in Latin letters, repeat it unchanged.
            - "english": a natural English translation, short enough to read as a subtitle. Keep names as they are. \
            If the line is already English, repeat it unchanged.
            Answer with only a JSON array of \(batch.count) objects, in the same order, each {"roman": "...", "english": "..."}. \
            No other text.

            \(numbered)
            """
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "max_tokens": 16000,
                "messages": [["role": "user", "content": prompt]],
            ] as [String: Any])
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard status == 200 else {
                if status == 401 { throw ServiceError(message: "Anthropic did not accept the API key. Check it in Settings.") }
                throw ServiceError(message: "Translating the subtitles failed: " + (((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"))
            }
            let text = ((obj["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            // The array, wherever it sits in the answer.
            guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
                  let rows = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [[String: Any]], rows.count == batch.count else {
                throw ServiceError(message: "Claude's translation came back in a shape that could not be read. Try again.")
            }
            out += rows.map { (($0["roman"] as? String) ?? "", ($0["english"] as? String) ?? "") }
        }
        return out.map { (roman: $0.0, english: $0.1) }
    }
}

/// Sarvam: made for Indian languages. Each line is turned into Latin letters and into English, one request for each.
enum Sarvam {
    private static func call(_ path: String, _ body: [String: Any], field: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.sarvam.ai/" + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(key, forHTTPHeaderField: "api-subscription-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<3 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if status == 200 { return (obj[field] as? String) ?? "" }
            let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            if status == 403 { throw ServiceError(message: "Sarvam did not accept the API key. Check it in Settings.") }
            // Busy or rate limited: wait a little and ask again.
            if status == 429 || status >= 500, attempt < 2 { try await Task.sleep(nanoseconds: UInt64(1 + attempt * 2) * 1_000_000_000); continue }
            throw ServiceError(message: "Sarvam: " + message)
        }
        return ""
    }

    static func annotate(_ lines: [String]) async throws -> [(roman: String, english: String)] {
        guard let key = Secrets.get(.sarvam) else { throw ServiceError(message: "Add your Sarvam API key in Settings to use Sarvam for subtitles.") }
        var out: [(roman: String, english: String)] = []
        for line in lines {
            // Lines already in Latin letters need no romanising; anything over the service's limit is cut to fit.
            let text = String(line.prefix(900))
            let latin = text.unicodeScalars.allSatisfy { $0.value < 0x250 }
            async let english = call("translate", ["input": text, "source_language_code": "auto", "target_language_code": "en-IN",
                                                   "model": "mayura:v1", "mode": "modern-colloquial"], field: "translated_text", key: key)
            async let roman = latin ? text : call("transliterate", ["input": text, "source_language_code": "auto", "target_language_code": "en-IN"],
                                                  field: "transliterated_text", key: key)
            out.append((try await roman, try await english))
        }
        return out
    }
}

extension Store {
    /// Listens to the film and writes its subtitles, then adds the romanised and English lines if a Claude key is saved.
    func makeSubtitles() async {
        guard Secrets.has(.elevenLabs) else { say("Add your ElevenLabs API key in Settings to make subtitles.", error: true); return }
        busy = "Writing down what is said"
        defer { busy = nil }
        do {
            let file = try await extractOriginalAudio()
            let heard = try await ElevenLabs.captions(file)
            guard !heard.lines.isEmpty else { say("No speech was found in the film's sound.", error: true); return }
            mutate { p in
                p.subtitles = heard.lines.map { SubtitleLine(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text) }
                p.subtitleLanguage = heard.language
            }
            subtitlesOn = true
            if Secrets.has(.anthropic) || Secrets.has(.sarvam) {
                busy = "Romanising and translating"
                try await translateSubtitles()
                say("Subtitles are ready: \(heard.lines.count) lines, in the original, romanised and English.")
            } else {
                say("Subtitles are ready in the original language. Add an Anthropic or Sarvam key in Settings for romanised and English.")
            }
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    /// Adds the romanised and English version of every subtitle line.
    func translateSubtitles() async throws {
        guard let lines = project.subtitles, !lines.isEmpty else { return }
        // Whichever service was chosen in Settings, falling back to the other if only its key is saved.
        let wantSarvam = (UserDefaults.standard.string(forKey: "subtitleBy") ?? "claude") == "sarvam"
        let useSarvam = Secrets.has(.sarvam) && (wantSarvam || !Secrets.has(.anthropic))
        let done = useSarvam ? try await Sarvam.annotate(lines.map(\.text))
                             : try await Translator.annotate(lines.map(\.text), language: project.subtitleLanguage)
        mutate { p in
            guard var s = p.subtitles, s.count == done.count else { return }
            for i in s.indices {
                s[i].roman = done[i].roman.isEmpty ? nil : done[i].roman
                s[i].english = done[i].english.isEmpty ? nil : done[i].english
            }
            p.subtitles = s
        }
    }

    /// Keeps only the voice in a clip's sound, as a new take. The sound as it was stays as the take before it.
    func isolateVoice(_ id: UUID) async throws {
        guard Secrets.has(.elevenLabs) else { throw ServiceError(message: "Add your ElevenLabs API key in Settings to isolate a voice.") }
        guard let l = project.locate(clip: id), let take = project.tracks[l.track].clips[l.clip].take else { throw ServiceError(message: "That clip has no sound yet.") }
        let name = project.tracks[l.track].clips[l.clip].name
        busy = "Isolating the voice in \(name)"
        defer { busy = nil }
        let data = try await ElevenLabs.isolate(url(for: take))
        let file = subfolder("Audio").appendingPathComponent("voice-" + UUID().uuidString.prefix(8) + ".mp3")
        try data.write(to: file)
        let length = AudioCache.shared.duration(file)
        guard length > 0 else { throw ServiceError(message: "ElevenLabs returned a sound that could not be read.") }
        mutate { p in
            guard let l = p.locate(clip: id) else { return }
            p.tracks[l.track].clips[l.clip].takes.append(Take(file: "Audio/" + file.lastPathComponent, duration: length))
            p.tracks[l.track].clips[l.clip].activeTake = p.tracks[l.track].clips[l.clip].takes.count - 1
        }
        say("\(name) now plays the voice alone. The sound as it was is the take before it.")
    }

    /// The film's own sound with everything but the voices taken out, on a voice track of its own.
    func isolateFilmVoice() async throws {
        guard Secrets.has(.elevenLabs) else { throw ServiceError(message: "Add your ElevenLabs API key in Settings to isolate the voices.") }
        busy = "Isolating the voices in the film"
        defer { busy = nil }
        let source = try await extractOriginalAudio()
        let data = try await ElevenLabs.isolate(source)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Film voices.mp3")
        try? FileManager.default.removeItem(at: file)
        try data.write(to: file)
        let track = addTrack(kind: .dialogue, name: "Film voices")
        guard importAudio(file, track: track, at: 0, name: "Film voices") != nil else { return }
        say("The film's voices are on their own track. Turn the film's own sound down so they are not heard twice.")
    }
}

// MARK: - On the picture

/// The subtitle for this moment, drawn over the picture. Reads the playhead by itself, so nothing else is redrawn with it.
/// It stands in one of four places measured from the picture itself, or wherever it has been dragged to.
struct SubtitleOverlay: View {
    @Environment(Store.self) private var store
    @AppStorage("subtitleMode") private var mode = SubtitleMode.english.rawValue
    @AppStorage("subtitleSize") private var size = 20.0
    @AppStorage("subtitleBack") private var back = 0.55
    @AppStorage("subtitleInk") private var ink = 1.0
    /// "bottom", "top", "left", "right", or "free" (dragged: subtitleX and subtitleY say where its middle is).
    @AppStorage("subtitlePlace") private var place = "bottom"
    @AppStorage("subtitleX") private var x = 0.5
    @AppStorage("subtitleY") private var y = 0.88
    /// Where its middle is while being dragged, in points.
    @State private var held: CGPoint?
    @State private var from: CGPoint = .zero
    /// Where it is drawn just now, so a drag starts from there without a jump.
    @State private var frame: CGRect = .zero
    /// The gap kept between the words and the picture when they stand beside it.
    private let gap: CGFloat = 12

    private func words(_ l: SubtitleLine) -> (top: String?, main: String) {
        switch SubtitleMode(rawValue: mode) ?? .english {
        case .native: (nil, l.text)
        case .roman: (nil, l.roman ?? l.text)
        case .english: (nil, l.english ?? l.text)
        case .both: (l.english == nil ? nil : l.text, l.english ?? l.text)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let t = store.player.time
            let line = store.subtitlesOn ? store.project.subtitles?.first(where: { t >= $0.start && t <= $0.end + 0.15 }) : nil
            // Where the picture itself is inside this space: it keeps its shape, centred.
            let v = store.project.video
            let shape = v.map { CGFloat(max(1, $0.width)) / CGFloat(max(1, $0.height)) } ?? 16 / 9
            let pw = min(geo.size.width, geo.size.height * shape), ph = pw / shape
            let picture = CGRect(x: (geo.size.width - pw) / 2, y: (geo.size.height - ph) / 2, width: pw, height: ph)
            let where_ = held != nil ? "free" : place
            let beside = where_ == "left" || where_ == "right"
            if let line {
                let w = words(line)
                let plate = VStack(spacing: 2) {
                    if let top = w.top {
                        Text(top).font(.system(size: size * 0.72, weight: .medium)).opacity(0.82)
                    }
                    Text(w.main).font(.system(size: size, weight: .semibold))
                }
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .foregroundStyle(Color.white.opacity(ink))
                // A soft dark edge, so the words hold over a bright picture even with the plate turned right down.
                .shadow(color: .black.opacity(0.85), radius: 1.2, y: 0.6)
                .shadow(color: .black.opacity(0.5), radius: 5, y: 1)
                .padding(.horizontal, size * 0.6).padding(.vertical, size * 0.3)
                .background(Color.black.opacity(back), in: RoundedRectangle(cornerRadius: max(6, size * 0.4), style: .continuous))
                // Beside the picture the words get the width of the empty side; over it, most of the space.
                .frame(maxWidth: beside ? max(90, picture.minX - gap * 2) : geo.size.width * 0.9)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("subtitles")) } action: { frame = $0 }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("subtitles"))
                    .onChanged { g in
                        if held == nil { from = CGPoint(x: frame.midX, y: frame.midY) }
                        held = CGPoint(x: min(geo.size.width - 20, max(20, from.x + g.translation.width)),
                                       y: min(geo.size.height - 10, max(10, from.y + g.translation.height)))
                    }
                    .onEnded { _ in
                        if let h = held { x = h.x / max(1, geo.size.width); y = h.y / max(1, geo.size.height); place = "free" }
                        held = nil
                    })
                .simultaneousGesture(TapGesture(count: 2).onEnded { place = "bottom" })
                .hint("Drag the subtitle anywhere on or beside the picture. Double-click to put it back at the bottom.")
                .accessibilityLabel("Subtitle: \(w.main)")
                Group {
                    switch where_ {
                    case "top":
                        // Its top edge on the picture's top edge.
                        plate.frame(width: geo.size.width, height: geo.size.height, alignment: .top).offset(y: picture.minY)
                    case "left":
                        // Its right edge a small gap short of the picture's left edge.
                        plate.frame(width: max(90, picture.minX - gap), height: geo.size.height, alignment: .trailing)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    case "right":
                        plate.frame(width: max(90, geo.size.width - picture.maxX - gap), height: geo.size.height, alignment: .leading)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
                    case "free":
                        plate.position(held ?? CGPoint(x: x * geo.size.width, y: y * geo.size.height))
                    default:
                        // Its bottom edge on the bottom of the picture's space: the same gap above the transport bar as
                        // the transport bar has to the timeline under it.
                        plate.frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                    }
                }
            }
        }
        .coordinateSpace(name: "subtitles")
    }
}

/// The button on the picture that opens the subtitle settings.
struct SubtitleButton: View {
    @Environment(Store.self) private var store
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: store.subtitlesOn ? "captions.bubble.fill" : "captions.bubble").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(store.subtitlesOn ? Theme.accent : .white)
                .frame(width: 28, height: 24)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .hint("Subtitles: what is said in the film, in its own language, romanised or in English")
        .popover(isPresented: $open, arrowEdge: .bottom) { SubtitlePanel().environment(store) }
    }
}

struct SubtitlePanel: View {
    @Environment(Store.self) private var store
    @AppStorage("subtitleMode") private var mode = SubtitleMode.english.rawValue
    @AppStorage("subtitleSize") private var size = 20.0
    @AppStorage("subtitleBack") private var back = 0.55
    @AppStorage("subtitleInk") private var ink = 1.0
    @AppStorage("subtitlePlace") private var place = "bottom"
    @State private var working = false

    var body: some View {
        @Bindable var store = store
        let lines = store.project.subtitles ?? []
        let translated = lines.contains { $0.english != nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("Subtitles").font(.system(size: 13, weight: .semibold))
            if lines.isEmpty {
                Caption("mitroley listens to the film's own sound and writes down what is said, in the language it is spoken in. Claude then gives every line in Latin letters and in English.")
            } else {
                Toggle("Show on the picture", isOn: $store.subtitlesOn).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s")\(store.project.subtitleLanguage.map { " · spoken in " + (Locale.current.localizedString(forLanguageCode: $0) ?? $0) } ?? "")")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                SegmentedPill(options: SubtitleMode.allCases.map { (value: $0.rawValue, label: $0.title) }, selection: mode, segmentWidth: 70, height: 24, size: 11.5) { mode = $0 }
                if !translated {
                    Caption("Only the original is here so far. Romanised and English are made by Claude or Sarvam and need one of their keys in Settings.")
                }
                Field(title: "Size", value: String(format: "%.0f pt", size)) {
                    Slide(value: size, range: 12...44, reset: 20, begin: {}) { size = $0.rounded() }
                }
                Field(title: "Plate behind", value: String(format: "%.0f%%", back * 100)) {
                    Slide(value: back, range: 0...0.9, reset: 0.55, begin: {}) { back = $0 }
                }
                Field(title: "Words", value: String(format: "%.0f%%", ink * 100)) {
                    Slide(value: ink, range: 0.35...1, reset: 1, begin: {}) { ink = $0 }
                }
                // Ready-made places, for when the words sit on something that matters in the picture. On a tall film the
                // sides are empty, so the words can stand beside the picture and cover nothing.
                HStack(spacing: 6) {
                    Text("Place").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                    ForEach(["bottom", "top", "left", "right"], id: \.self) { name in
                        let here = place == name
                        Button(name.capitalized) { place = name }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: here ? .semibold : .medium))
                            .foregroundStyle(here ? Color.white : Theme.secondary)
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(here ? Theme.accent.opacity(0.32) : Color.white.opacity(0.07), in: Capsule())
                    }
                }
                Caption(place == "free" ? "Dragged to a place of its own. Choose one above to put it back." : "Bottom and Top sit on the picture's own edges; Left and Right stand just beside it. Or drag the words anywhere.")
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            HStack(spacing: 8) {
                Button(lines.isEmpty ? "Make Subtitles" : "Make Again") {
                    working = true
                    Task { await store.makeSubtitles(); working = false }
                }
                .buttonStyle(PillButtonStyle(prominent: lines.isEmpty))
                if !lines.isEmpty, !translated {
                    Button("Add English") {
                        working = true
                        Task {
                            do { try await store.translateSubtitles() } catch { store.say(error.localizedDescription, error: true) }
                            working = false
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                }
                if working { ProgressView().controlSize(.small) }
            }
            .disabled(working || store.project.video == nil)
            Caption("Making subtitles uses ElevenLabs credits for the listening, and a small amount of Claude Sonnet or Sarvam for the romanised and English lines. Choose which in Settings.")
        }
        .padding(16)
        .frame(width: 320)
    }
}
