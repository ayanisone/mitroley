import AVFoundation
import Observation
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// Dubbing with ElevenLabs: a voice track, or the film's own sound, re-voiced in other languages. Each language
/// comes back on its own Voice-over track, in step with the original, so you can switch between them.
enum Dubbing {
    /// Languages ElevenLabs dubs into, as it lists them. The code is what the service is sent.
    static let languages: [(code: String, name: String)] = [
        ("hi", "Hindi"), ("bn", "Bengali"), ("ta", "Tamil"), ("te", "Telugu"), ("mr", "Marathi"), ("gu", "Gujarati"), ("kn", "Kannada"),
        ("ml", "Malayalam"), ("pa", "Punjabi"), ("ur", "Urdu"), ("as", "Assamese"), ("ne", "Nepali"), ("sd", "Sindhi"),
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"), ("he", "Hebrew"), ("fa", "Persian"),
        ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese (Mandarin)"), ("yue", "Cantonese"), ("id", "Indonesian"), ("ms", "Malay"),
        ("fil", "Filipino"), ("vi", "Vietnamese"), ("th", "Thai"), ("my", "Burmese"),
        ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"), ("is", "Icelandic"), ("cs", "Czech"), ("sk", "Slovak"),
        ("hu", "Hungarian"), ("ro", "Romanian"), ("bg", "Bulgarian"), ("el", "Greek"), ("hr", "Croatian"), ("bs", "Bosnian"), ("sl", "Slovenian"),
        ("mk", "Macedonian"), ("sq", "Albanian"), ("lt", "Lithuanian"), ("lv", "Latvian"), ("et", "Estonian"), ("ca", "Catalan"), ("gl", "Galician"),
        ("eu", "Basque"), ("cy", "Welsh"), ("af", "Afrikaans"), ("sw", "Swahili"), ("am", "Amharic"), ("ha", "Hausa"), ("yo", "Yoruba"),
        ("zu", "Zulu"), ("hy", "Armenian"), ("ka", "Georgian"), ("az", "Azerbaijani"), ("kk", "Kazakh"), ("uz", "Uzbek"), ("mn", "Mongolian"),
    ]
    static func name(_ code: String) -> String { languages.first { $0.code == code }?.name ?? code }

    /// Starts one dub: uploads the sound and asks for one language. Returns the job's id.
    static func start(file: URL, language: String, name: String) async throws -> String {
        let boundary = "mitroley-" + UUID().uuidString
        var req = try ElevenLabs.request("https://api.elevenlabs.io/v1/dubbing", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 900
        var body = Data()
        func field(_ k: String, _ v: String) { body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
        field("name", name)
        field("target_lang", language)
        field("source_lang", "auto")
        field("num_speakers", "0")              // 0 = work out how many people speak
        field("watermark", "false")
        field("drop_background_audio", "true")  // only the voices come back: the sound design here is the background
        let type = file.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/mp4"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(type)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ServiceError(message: "ElevenLabs dubbing: " + ElevenLabs.describe(data, status: status)) }
        guard let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["dubbing_id"] as? String else {
            throw ServiceError(message: "ElevenLabs did not return a dubbing job.")
        }
        return id
    }

    /// "dubbing" while it works, "dubbed" when done, or a failure.
    static func status(_ id: String) async throws -> (state: String, error: String?) {
        let req = try ElevenLabs.request("https://api.elevenlabs.io/v1/dubbing/\(id)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ServiceError(message: "ElevenLabs dubbing: " + ElevenLabs.describe(data, status: code))
        }
        return ((obj["status"] as? String) ?? "", obj["error"] as? String)
    }

    /// The dubbed sound for a language.
    static func audio(_ id: String, language: String) async throws -> Data {
        let req = try ElevenLabs.request("https://api.elevenlabs.io/v1/dubbing/\(id)/audio/\(language)")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, data.count > 1000 else { throw ServiceError(message: "ElevenLabs dubbing: " + ElevenLabs.describe(data, status: code)) }
        return data
    }
}

/// One language being dubbed.
struct DubJob: Identifiable, Equatable {
    var id = UUID()
    var language: String
    var state: String           // what to show: Uploading, Dubbing, Done, or the failure
    var failed = false
    var done = false
}

extension Store {
    /// What can be dubbed: the film's own sound, and every Voice-over track that has something on it.
    var dubSources: [(id: UUID?, name: String)] {
        var out: [(UUID?, String)] = []
        if project.video != nil { out.append((nil, "The film's own sound")) }
        for t in project.tracks where t.kind == .dialogue && t.clips.contains(where: { $0.take != nil }) && !t.name.hasPrefix("Dub · ") { out.append((t.id, t.name)) }
        return out
    }

    /// The sound to send: the film's soundtrack, or one track as it stands, dry.
    private func dubSource(_ track: UUID?) async throws -> (file: URL, start: Double) {
        guard let track else { return (try await extractOriginalAudio(), 0) }
        guard let t = project.tracks.first(where: { $0.id == track }) else { throw ServiceError(message: "That track is gone.") }
        var q = project
        q.tracks = [t]
        q.tracks[0].mute = false; q.tracks[0].solo = false; q.tracks[0].spaceMode = .dry; q.tracks[0].plugins = nil
        q.tracks[0].automation = [:]; q.tracks[0].volume = 0; q.tracks[0].pan = 0; q.tracks[0].spatial = false; q.tracks[0].groupID = nil
        q.rack = []; q.masterVolume = nil; q.videoVolume = 0
        let folder = self.folder
        let out = subfolder("Audio").appendingPathComponent("dub-source-" + UUID().uuidString.prefix(8) + ".wav")
        try await Task.detached(priority: .userInitiated) {
            let mix = try Exporter.render(q, mode: .stereo, tail: 0.5, resolve: { Store.url(for: $0, in: folder) })
            try WAV.write(out, channels: [mix.l, mix.r])
        }.value
        return (out, 0)
    }

    /// Dubs a source into each language. Every language is its own job at ElevenLabs and its own track here.
    func dub(source: UUID?, into languages: [String]) async {
        guard Secrets.has(.elevenLabs) else { say("Add your ElevenLabs API key in Settings to dub.", error: true); return }
        dubJobs = languages.map { DubJob(language: $0, state: "Getting the sound ready") }
        let sourceName = source.flatMap { id in project.tracks.first { $0.id == id }?.name } ?? "Film"
        let prepared: (file: URL, start: Double)
        do { prepared = try await dubSource(source) } catch {
            for i in dubJobs.indices { dubJobs[i].state = error.localizedDescription; dubJobs[i].failed = true }
            return
        }
        func set(_ lang: String, _ state: String, failed: Bool = false, done: Bool = false) {
            guard let i = dubJobs.firstIndex(where: { $0.language == lang }) else { return }
            dubJobs[i].state = state; dubJobs[i].failed = failed; dubJobs[i].done = done
        }
        let audio = subfolder("Audio")
        await withTaskGroup(of: Void.self) { group in
            for lang in languages {
                group.addTask { @MainActor in
                    do {
                        set(lang, "Uploading")
                        let id = try await Dubbing.start(file: prepared.file, language: lang, name: "\(self.project.name) \(lang)")
                        set(lang, "Dubbing")
                        // Up to forty minutes: a long film in a busy hour takes a while.
                        var ready = false
                        for _ in 0..<480 {
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            let s = try await Dubbing.status(id)
                            if s.state == "dubbed" { ready = true; break }
                            if s.state == "failed" || s.error != nil { throw ServiceError(message: s.error ?? "ElevenLabs could not dub this.") }
                        }
                        guard ready else { throw ServiceError(message: "Still not finished after forty minutes. It may yet appear in your ElevenLabs account.") }
                        set(lang, "Bringing it in")
                        let data = try await Dubbing.audio(id, language: lang)
                        // ElevenLabs answers with MP3 for sound and MP4 when a video was sent; the first bytes say which.
                        let isMP4 = data.count > 12 && String(data: data[4..<8], encoding: .ascii) == "ftyp"
                        let file = audio.appendingPathComponent("dub-\(lang)-" + UUID().uuidString.prefix(8) + (isMP4 ? ".m4a" : ".mp3"))
                        try data.write(to: file)
                        let d = AudioCache.shared.duration(file)
                        guard d > 0 else { throw ServiceError(message: "The dubbed sound could not be read.") }
                        var t = Track(name: "Dub · \(Dubbing.name(lang))", kind: .dialogue)
                        t.spaceMode = .dry
                        // Muted to begin with, so several languages do not all speak at once.
                        t.mute = self.project.tracks.contains { $0.name.hasPrefix("Dub · ") && !$0.mute }
                        t.clips = [Clip(name: "\(sourceName) in \(Dubbing.name(lang))", start: prepared.start, duration: d,
                                        takes: [Take(file: "Audio/" + file.lastPathComponent, duration: d)])]
                        self.mutate { $0.tracks.append(t) }
                        set(lang, "Done", done: true)
                    } catch {
                        set(lang, error.localizedDescription, failed: true)
                    }
                }
            }
        }
    }
}

/// File › Dub Into Other Languages.
struct DubSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var source: UUID?
    @State private var chosen: Set<String> = []
    @State private var search = ""
    @State private var working = false

    var body: some View {
        let sources = store.dubSources
        VStack(alignment: .leading, spacing: 12) {
            Text("Dub").font(.system(size: 20, weight: .semibold)).tracking(-0.3)
            Text("ElevenLabs re-voices the speech in each language you pick, keeping the timing and the speakers' voices. Each language arrives on its own Voice-over track.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if sources.isEmpty {
                Label("There is nothing to dub yet. Import a video with speech, or put a voice on a Voice-over track.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Dub from", selection: $source) {
                    ForEach(sources, id: \.id) { s in Text(s.name).tag(s.id) }
                }
                .disabled(working)
            }
            if store.dubJobs.isEmpty || !working && store.dubJobs.allSatisfy({ $0.done }) && chosen.isEmpty {
                picker
            }
            if !store.dubJobs.isEmpty {
                VStack(spacing: 5) {
                    ForEach(store.dubJobs) { j in
                        HStack(spacing: 9) {
                            if j.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.5)) }
                            else if j.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
                            else { ProgressView().controlSize(.small) }
                            Text(Dubbing.name(j.language)).font(.system(size: 12.5, weight: .semibold))
                            Spacer(minLength: 8)
                            Text(j.state).font(.system(size: 11.5)).foregroundStyle(j.failed ? Theme.danger : Theme.secondary)
                                .lineLimit(2).multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
            HStack {
                if working { Text("This takes a few minutes. You can close this and keep working.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                Spacer()
                Button(working || !store.dubJobs.isEmpty ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if store.dubJobs.isEmpty {
                    Button("Dub \(chosen.count) Language\(chosen.count == 1 ? "" : "s")") {
                        working = true
                        let langs = Dubbing.languages.map(\.code).filter(chosen.contains), from = source
                        Task { await store.dub(source: from, into: langs); working = false }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || sources.isEmpty)
                } else if !working {
                    Button("Dub More") { store.dubJobs = []; chosen = [] }
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            if source == nil || !sources.contains(where: { $0.id == source }) { source = sources.first?.id }
            working = store.dubJobs.contains { !$0.done && !$0.failed }
        }
    }

    @ViewBuilder private var picker: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            TextField("Find a language", text: $search).textFieldStyle(.plain).font(.system(size: 12.5))
            if !chosen.isEmpty { Text("\(chosen.count) chosen").font(.system(size: 11.5)).foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        let shown = Dubbing.languages.filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(shown, id: \.code) { l in
                    let on = chosen.contains(l.code)
                    HStack(spacing: 6) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 12)).foregroundStyle(on ? Theme.accent : Theme.tertiary)
                        Text(l.name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(on ? Theme.accent.opacity(0.14) : Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { if on { chosen.remove(l.code) } else { chosen.insert(l.code) } }
                }
            }
        }
        .frame(height: 230)
        Text("Each language is charged separately by ElevenLabs, by the length of the speech.")
            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
    }
}
