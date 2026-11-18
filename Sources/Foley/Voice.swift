import SwiftUI
import AVFoundation

struct Voice: Identifiable, Equatable {
    var id: String
    var name: String
    var accent = ""
    var gender = ""
    var age = ""
    var about = ""
    var owner: String?          // set for voices from the shared library that are not in the account yet
    var detail: String { [gender, age, accent].filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct SpokenLine {
    var speaker: String
    var text: String
    var start: Double
    var end: Double
}

extension Store {
    /// Listens to the film's own sound and writes down who says what, when.
    func transcribe() async throws -> [SpokenLine] {
        guard Secrets.has(.elevenLabs) else { throw ServiceError(message: "Add your ElevenLabs API key in Settings to transcribe the film.") }
        busy = "Listening for voices"
        defer { busy = nil }
        let file = try await extractOriginalAudio()
        return try await ElevenLabs.transcribe(file)
    }

    /// Transcribes the film and lays every spoken line on a voice track as a cue waiting for a voice.
    @discardableResult
    func transcribeToTrack(_ track: UUID? = nil) async throws -> [SpokenLine] {
        let lines = try await transcribe()
        guard !lines.isEmpty else { throw ServiceError(message: "No speech was found in the film's sound.") }
        let id = track ?? project.tracks.first { $0.kind == .dialogue }?.id ?? addTrack(kind: .dialogue, name: "Voice-over")
        mutate { p in
            guard let i = p.trackIndex(id) else { return }
            for l in lines where !p.tracks[i].clips.contains(where: { abs($0.start - l.start) < 0.05 && $0.prompt == l.text }) {
                var c = Clip(name: l.speaker + ": " + String(l.text.prefix(30)), start: l.start, duration: max(0.3, l.end - l.start))
                c.prompt = l.text
                c.fadeIn = 0.005; c.fadeOut = 0.03
                p.tracks[i].clips.append(c)
            }
        }
        say("Found \(lines.count) spoken line\(lines.count == 1 ? "" : "s"). Choose a voice for each, then generate.")
        return lines
    }

    func loadVoices() async {
        guard voices.isEmpty, Secrets.has(.elevenLabs) else { return }
        voices = (try? await ElevenLabs.voices()) ?? []
    }

    /// Places a line of speech and has a voice say it.
    @discardableResult
    func speak(_ text: String, voice: Voice, track: UUID, start: Double, takes: Int = 2, name: String? = nil, gain: Double = 0) async throws -> UUID {
        var v = voice
        if let owner = v.owner {
            // A shared-library voice has to be in the account before it can speak.
            v.id = try await ElevenLabs.addShared(owner: owner, voice: v.id, name: v.name)
            v.owner = nil
            voices = []
        }
        var clip = Clip(name: name ?? v.name + ": " + String(text.prefix(30)), start: max(0, start), duration: max(0.5, Double(text.count) / 14))
        clip.prompt = text
        clip.voiceID = v.id; clip.voiceName = v.name
        clip.gain = gain
        clip.fadeIn = 0.005; clip.fadeOut = 0.03
        mutate { p in if let i = p.trackIndex(track) { p.tracks[i].clips.append(clip) } }
        await moreTakes(for: clip.id, count: takes)
        guard let l = project.locate(clip: clip.id) else { throw ServiceError(message: "The clip disappeared.") }
        if project.tracks[l.track].clips[l.clip].takes.isEmpty {
            throw ServiceError(message: project.tracks[l.track].clips[l.clip].error ?? "ElevenLabs returned no voice.")
        }
        return clip.id
    }

    /// A spoken take starts after a breath of silence: start the clip on the first sound and make it as long as the line.
    func fitVoice(_ id: UUID) {
        guard let l = project.locate(clip: id), let take = project.tracks[l.track].clips[l.clip].take,
              let m = Commands.measure(url(for: take)) else { return }
        let onset = max(0, (m["onset"] ?? 0) - 0.02)
        live { p in
            guard let x = p.locate(clip: id) else { return }
            p.tracks[x.track].clips[x.clip].offset = onset
            p.tracks[x.track].clips[x.clip].duration = max(0.2, take.duration - onset)
        }
    }
}

/// Voice controls for a spoken line: who says it, and the button that makes them say it.
struct VoicePicker: View {
    @Environment(Store.self) private var store
    let current: String?
    let pick: (Voice) -> Void

    var body: some View {
        Menu {
            if store.voices.isEmpty { Text("Loading voices…") }
            let indian = store.voices.filter { $0.accent.lowercased().contains("indian") }
            if !indian.isEmpty {
                Section("Indian") { ForEach(indian) { v in item(v) } }
            }
            Section("All voices") { ForEach(store.voices.filter { !$0.accent.lowercased().contains("indian") }) { v in item(v) } }
        } label: {
            Text(current ?? "Choose a voice")
        }
        .task { await store.loadVoices() }
    }

    private func item(_ v: Voice) -> some View {
        Button(v.detail.isEmpty ? v.name : "\(v.name) — \(v.detail)") { pick(v) }
    }
}

/// How spoken lines are made. Saved with the session.
struct VoiceSettings: Codable, Equatable {
    var id = ""                             // the voice's ID, copied from ElevenLabs
    var model = "eleven_multilingual_v2"
    var stability = 0.5                     // 0…1: lower is more expressive, higher more even
    var similarity = 0.75                   // 0…1: how closely it sticks to the original voice
    var style = 0.0                         // 0…1: exaggerates the voice's style
    var speed = 1.0                         // 0.7…1.2
    var boost = true                        // speaker boost

    static let models = [("eleven_v3", "Eleven v3 (most expressive)"), ("eleven_multilingual_v2", "Multilingual v2"),
                         ("eleven_turbo_v2_5", "Turbo v2.5 (fast)"), ("eleven_flash_v2_5", "Flash v2.5 (fastest)")]
}

struct VoiceOverSection: View {
    @Environment(Store.self) private var store
    let track: Track
    @State private var text = ""
    @State private var working = false

    private var settings: VoiceSettings { store.project.voice ?? VoiceSettings() }
    private func set(_ change: @escaping (inout VoiceSettings) -> Void) {
        store.live { p in var v = p.voice ?? VoiceSettings(); change(&v); p.voice = v }
    }
    private func slide(_ kp: WritableKeyPath<VoiceSettings, Double>, _ range: ClosedRange<Double>, reset: Double) -> Slide {
        Slide(value: settings[keyPath: kp], range: range, tint: track.kind.color, reset: reset, begin: { store.beginGesture() }) { v in
            set { $0[keyPath: kp] = (v * 100).rounded() / 100 }
        }
    }

    var body: some View {
        let s = settings
        let id = s.id.trimmingCharacters(in: .whitespacesAndNewlines)
        SectionTitle("Voice-over")
        QuietEditor(placeholder: "A line to say", text: $text, height: 58)
        QuietField(placeholder: "Voice ID from ElevenLabs", text: Binding(get: { s.id }, set: { v in set { $0.id = v } }))
        Caption("In ElevenLabs, open the voice's menu and choose Copy voice ID, then paste it here. Any voice in your account or the voice library works.")
        Picker("Model", selection: Binding(get: { s.model }, set: { v in set { $0.model = v } })) {
            ForEach(VoiceSettings.models, id: \.0) { m in Text(m.1).tag(m.0) }
        }
        .font(.system(size: 12))
        Field(title: "Stability", value: String(format: "%.0f%%", s.stability * 100)) { slide(\.stability, 0...1, reset: 0.5) }
        Field(title: "Similarity", value: String(format: "%.0f%%", s.similarity * 100)) { slide(\.similarity, 0...1, reset: 0.75) }
        Field(title: "Style", value: String(format: "%.0f%%", s.style * 100)) { slide(\.style, 0...1, reset: 0) }
        Field(title: "Speed", value: String(format: "%.2f×", s.speed)) { slide(\.speed, 0.7...1.2, reset: 1) }
        Toggle("Speaker boost", isOn: Binding(get: { s.boost }, set: { v in set { $0.boost = v } }))
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        HStack(spacing: 8) {
            Button(working ? "Speaking…" : "Speak at Playhead") {
                let line = text, at = store.player.time
                working = true
                Task {
                    do { store.selection = .clip(try await store.speak(line, voice: Voice(id: id, name: "Voice"), track: track.id, start: at)) }
                    catch { store.say(error.localizedDescription, error: true) }
                    working = false
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(working || id.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Import…") { Panels.importAudio(store, track: track.id) }.buttonStyle(PillButtonStyle())
        }
        if store.project.video != nil {
            Button("Transcribe the Film's Voices") {
                Task {
                    do { try await store.transcribeToTrack(track.id) } catch { store.say(error.localizedDescription, error: true) }
                }
            }
            .buttonStyle(PillButtonStyle())
            Caption("Writes down what is said in the video and places each line here at its time. Choose a voice for a line to have it spoken again, cleanly.")
        }
    }
}
