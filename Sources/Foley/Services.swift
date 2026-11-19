import Foundation

// MARK: - Where things live

/// The app's folders. The app was first called Foley; on first run under the new name its folders and
/// sessions are moved across once, so nothing is left behind.
enum AppPaths {
    static let sessionExtension = "mitroley"

    static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent("mitroley", isDirectory: true), old = base.appendingPathComponent("Foley", isDirectory: true)
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: new) }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        return new
    }()

    static let library: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent("mitroley", isDirectory: true), old = base.appendingPathComponent("Foley", isDirectory: true)
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: new)
            for item in (try? fm.contentsOfDirectory(at: new, includingPropertiesForKeys: nil)) ?? [] where item.pathExtension == "foley" {
                try? fm.moveItem(at: item, to: item.deletingPathExtension().appendingPathExtension(sessionExtension))
            }
            if let last = UserDefaults.standard.string(forKey: "lastProject") {
                let moved = last.replacingOccurrences(of: old.path, with: new.path)
                UserDefaults.standard.set((moved as NSString).deletingPathExtension + "." + sessionExtension, forKey: "lastProject")
            }
        }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        return new
    }()
}

// MARK: - Secrets

/// API keys live in ~/Library/Application Support/mitroley/keys.json, readable only by this user account.
///
/// The login keychain would be the natural home, but it ties an item to the app's code signature, and an
/// unsigned build gets a new signature every time it is rebuilt: the key turns unreadable and macOS puts up
/// a permission dialog that stalls the app. Move this to the keychain once the app is signed with a stable identity.
/// Environment variables work as a fallback for scripted runs.
enum Secrets {
    enum Key: String {
        case elevenLabs = "elevenlabs"
        case anthropic = "anthropic"
        var env: String { self == .elevenLabs ? "ELEVENLABS_API_KEY" : "ANTHROPIC_API_KEY" }
    }
    private static var cache: [String: String]?
    private static var fileURL: URL { AppPaths.support.appendingPathComponent("keys.json") }

    private static func load() -> [String: String] {
        if let cache { return cache }
        var stored: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            stored = obj
        }
        cache = stored
        return stored
    }

    static func get(_ key: Key) -> String? {
        if let v = load()[key.rawValue], !v.isEmpty { return v }
        if let e = ProcessInfo.processInfo.environment[key.env], !e.isEmpty { return e }
        return nil
    }

    @discardableResult
    static func set(_ key: Key, _ value: String) -> Bool {
        var stored = load()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        stored[key.rawValue] = trimmed.isEmpty ? nil : trimmed
        cache = stored
        guard let data = try? JSONSerialization.data(withJSONObject: stored) else { return false }
        let url = fileURL
        // Create the file private from the start, then write.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        do { try data.write(to: url) } catch { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    static func has(_ key: Key) -> Bool { get(key) != nil }

    /// What is wrong with a key's shape, if anything. API keys are plain printable ASCII with no spaces;
    /// anything else cannot be sent in a request header and usually means the wrong thing was pasted.
    static func problem(_ value: String) -> String? {
        let scalars = value.unicodeScalars
        if scalars.isEmpty { return "The key is empty." }
        let bad = scalars.filter { !$0.isASCII || $0.value <= 32 || $0.value >= 127 }.count
        if bad == scalars.count { return "That is not a key: it has no usable characters. It may have been copied from a hidden field showing dots. Copy the key itself and paste it again." }
        if bad > 0 { return "The key contains \(bad) character\(bad == 1 ? "" : "s") that cannot be part of an API key (spaces, line breaks or symbols). Paste it again." }
        if scalars.count < 20 { return "That looks too short to be an API key (\(scalars.count) characters)." }
        return nil
    }

    /// A safe description of the saved key for display: length and last four characters only.
    static func hint(_ key: Key) -> String? {
        guard let v = get(key) else { return nil }
        if let p = problem(v) { return p }
        return "Saved key ends in \(v.suffix(4)) (\(v.count) characters)."
    }
}

// MARK: - ElevenLabs sound effects

struct ServiceError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum ElevenLabs {
    static var outputFormat: String {
        UserDefaults.standard.string(forKey: "elevenFormat") ?? "mp3_44100_128"
    }
    static var model: String {
        UserDefaults.standard.string(forKey: "elevenModel") ?? "eleven_text_to_sound_v3"
    }

    /// One take. `duration` nil lets the model decide (0.5…30 s otherwise).
    static func soundEffect(prompt: String, duration: Double?, influence: Double, loop: Bool) async throws -> (data: Data, ext: String) {
        guard let key = Secrets.get(.elevenLabs) else {
            throw ServiceError(message: "Add your ElevenLabs API key in Settings to generate sounds.")
        }
        if let problem = Secrets.problem(key) { throw ServiceError(message: "ElevenLabs key: " + problem) }
        let format = outputFormat
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/sound-generation?output_format=\(format)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": prompt, "prompt_influence": min(1, max(0, influence)), "model_id": model]
        if let duration { body["duration_seconds"] = min(30, max(0.5, (duration * 10).rounded() / 10)) }
        if loop { body["loop"] = true }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError(message: "No response from ElevenLabs.") }
        guard http.statusCode == 200 else {
            throw ServiceError(message: "ElevenLabs: " + describe(data, status: http.statusCode))
        }
        let ext = format.hasPrefix("mp3") ? "mp3" : format.hasPrefix("wav") ? "wav" : format.hasPrefix("opus") ? "opus" : "mp3"
        return (data, ext)
    }

    static var musicModel: String { UserDefaults.standard.string(forKey: "elevenMusic") ?? "music_v2_5" }

    /// Composes one piece of music from a plan of sections ("chunks"), each with its own length and styles.
    /// The sections follow the film, so the music changes where the picture does.
    static func music(chunks: [[String: Any]]) async throws -> (data: Data, ext: String) {
        guard let key = Secrets.get(.elevenLabs) else {
            throw ServiceError(message: "Add your ElevenLabs API key in Settings to compose music.")
        }
        if let problem = Secrets.problem(key) { throw ServiceError(message: "ElevenLabs key: " + problem) }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/music?output_format=auto")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["composition_plan": ["chunks": chunks], "model_id": musicModel])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 1200
        let (data, resp) = try await URLSession(configuration: config).data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError(message: "No response from ElevenLabs.") }
        guard http.statusCode == 200 else {
            var message = describe(data, status: http.statusCode)
            // ElevenLabs sometimes rejects wording (artist names, lyrics) and suggests a replacement.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["detail"] as? [String: Any],
               let extra = d["data"] as? [String: Any], let s = extra["prompt_suggestion"] as? String {
                message += " Suggested wording: " + s
            }
            throw ServiceError(message: "ElevenLabs music: " + message)
        }
        return (data, "mp3")
    }

    /// Splits a recording into stems (vocals, drums, bass, guitar, piano, other). Returns a zip of audio files.
    static func stems(of file: URL) async throws -> Data {
        guard let key = Secrets.get(.elevenLabs) else { throw ServiceError(message: "Add your ElevenLabs API key in Settings.") }
        if let problem = Secrets.problem(key) { throw ServiceError(message: "ElevenLabs key: " + problem) }
        let boundary = "mitroley-" + UUID().uuidString
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/music/stem-separation?output_format=mp3_44100_192")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func part(_ text: String) { body.append(text.data(using: .utf8)!) }
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"stem_variation_id\"\r\n\r\nsix_stems_v1\r\n")
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"original.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: file))
        part("\r\n--\(boundary)--\r\n")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 1500
        let (data, resp) = try await URLSession(configuration: config).upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError(message: "No response from ElevenLabs.") }
        guard http.statusCode == 200 else { throw ServiceError(message: "ElevenLabs stems: " + describe(data, status: http.statusCode)) }
        return data
    }

    // MARK: Voices

    private static func authed(_ url: String, method: String = "GET") throws -> URLRequest {
        guard let key = Secrets.get(.elevenLabs) else { throw ServiceError(message: "Add your ElevenLabs API key in Settings.") }
        if let problem = Secrets.problem(key) { throw ServiceError(message: "ElevenLabs key: " + problem) }
        guard let u = URL(string: url) else { throw ServiceError(message: "Bad request address.") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        return req
    }

    private static func json(_ req: URLRequest, what: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError(message: "No response from ElevenLabs.") }
        guard http.statusCode == 200 else { throw ServiceError(message: "ElevenLabs \(what): " + describe(data, status: http.statusCode)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func query(_ items: [String: String?]) -> String {
        var c = URLComponents()
        c.queryItems = items.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }
        return c.percentEncodedQuery ?? ""
    }

    static var voiceModel: String { UserDefaults.standard.string(forKey: "elevenVoice") ?? "eleven_multilingual_v2" }

    /// The film's speech as lines: who, what, from when to when.
    static func transcribe(_ file: URL) async throws -> [SpokenLine] {
        func attempt(_ model: String) async throws -> [String: Any] {
            let boundary = "mitroley-" + UUID().uuidString
            var req = try authed("https://api.elevenlabs.io/v1/speech-to-text", method: "POST")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
            }
            field("model_id", model); field("diarize", "true"); field("timestamps_granularity", "word"); field("tag_audio_events", "false")
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"film.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
            body.append(try Data(contentsOf: file))
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
            guard let http = resp as? HTTPURLResponse else { throw ServiceError(message: "No response from ElevenLabs.") }
            guard http.statusCode == 200 else { throw ServiceError(message: "ElevenLabs transcription: " + describe(data, status: http.statusCode)) }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        var obj: [String: Any]
        do { obj = try await attempt("scribe_v2") } catch { obj = try await attempt("scribe_v1") }
        var lines: [SpokenLine] = []
        var names: [String: String] = [:]
        for w in (obj["words"] as? [[String: Any]]) ?? [] where (w["type"] as? String) == "word" {
            guard let text = w["text"] as? String, let start = w.num("start"), let end = w.num("end") else { continue }
            let id = (w["speaker_id"] as? String) ?? "speaker_0"
            if names[id] == nil { names[id] = "Speaker \(names.count + 1)" }
            let speaker = names[id]!
            // A new line when the speaker changes or after a pause.
            if var last = lines.last, last.speaker == speaker, start - last.end < 0.9 {
                last.text += " " + text; last.end = end
                lines[lines.count - 1] = last
            } else {
                lines.append(SpokenLine(speaker: speaker, text: text, start: start, end: end))
            }
        }
        return lines
    }

    static func voices(search: String? = nil) async throws -> [Voice] {
        var out: [Voice] = [], token: String?
        for _ in 0..<5 {
            let q = query(["page_size": "100", "search": search, "next_page_token": token])
            let obj = try await json(try authed("https://api.elevenlabs.io/v2/voices?" + q), what: "voices")
            for v in (obj["voices"] as? [[String: Any]]) ?? [] {
                guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { continue }
                let l = (v["labels"] as? [String: Any]) ?? [:]
                func label(_ k: String) -> String { (l[k] as? String) ?? "" }
                out.append(Voice(id: id, name: name, accent: label("accent"), gender: label("gender"), age: label("age").replacingOccurrences(of: "_", with: " "),
                                 about: (v["description"] as? String) ?? label("description")))
            }
            token = obj["next_page_token"] as? String
            if (obj["has_more"] as? Bool) != true || token == nil { break }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Voices from the shared library. They carry an owner until they are added to the account.
    static func sharedVoices(search: String?, accent: String?, gender: String?) async throws -> [Voice] {
        let q = query(["page_size": "30", "search": search, "accent": accent?.lowercased(), "gender": gender?.lowercased(), "language": "en"])
        let obj = try await json(try authed("https://api.elevenlabs.io/v1/shared-voices?" + q), what: "voice library")
        return ((obj["voices"] as? [[String: Any]]) ?? []).compactMap { v in
            guard let id = v["voice_id"] as? String, let name = v["name"] as? String, let owner = v["public_owner_id"] as? String else { return nil }
            return Voice(id: id, name: name, accent: (v["accent"] as? String) ?? "", gender: (v["gender"] as? String) ?? "",
                         age: ((v["age"] as? String) ?? "").replacingOccurrences(of: "_", with: " "),
                         about: (v["description"] as? String) ?? (v["descriptive"] as? String) ?? "", owner: owner)
        }
    }

    /// Adds a shared-library voice to the account and returns the id to speak with.
    static func addShared(owner: String, voice: String, name: String) async throws -> String {
        var req = try authed("https://api.elevenlabs.io/v1/voices/add/\(owner)/\(voice)", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["new_name": name])
        let obj = try await json(req, what: "voice library")
        return (obj["voice_id"] as? String) ?? voice
    }

    static func speech(_ text: String, voice: String, settings: VoiceSettings? = nil) async throws -> (data: Data, ext: String) {
        var req = try authed("https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=mp3_44100_128", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text, "model_id": settings?.model ?? voiceModel]
        if let s = settings {
            body["voice_settings"] = ["stability": s.stability, "similarity_boost": s.similarity, "style": s.style,
                                      "use_speaker_boost": s.boost, "speed": s.speed]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError(message: "No response from ElevenLabs.") }
        guard http.statusCode == 200 else { throw ServiceError(message: "ElevenLabs voice: " + describe(data, status: http.statusCode)) }
        return (data, "mp3")
    }

    /// Every model on the account that can turn text into speech.
    static func speechModels() async throws -> [(id: String, name: String)] {
        let (data, resp) = try await URLSession.shared.data(for: try authed("https://api.elevenlabs.io/v1/models"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError(message: "Could not read the list of ElevenLabs models.")
        }
        return list.compactMap { m in
            guard (m["can_do_text_to_speech"] as? Bool) == true, let id = m["model_id"] as? String else { return nil }
            return (id, (m["name"] as? String) ?? id)
        }
    }

    /// Asks ElevenLabs whether it accepts a key. Costs nothing.
    static func verify(_ key: String) async -> (ok: Bool, message: String) {
        if let problem = Secrets.problem(key) { return (false, problem) }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else {
            return (false, "Could not reach ElevenLabs to check the key. Check the connection.")
        }
        if http.statusCode == 200 {
            var tier = ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sub = obj["subscription"] as? [String: Any] {
                if let t = sub["tier"] as? String { tier = t }
                if let used = sub["character_count"] as? Int, let limit = sub["character_limit"] as? Int {
                    return (true, "ElevenLabs accepted the key. \(tier.capitalized) plan, \(max(0, limit - used)) credits left.")
                }
            }
            return (true, "ElevenLabs accepted the key.")
        }
        // A key limited to certain features is still fine for sound effects.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["detail"] as? [String: Any],
           let status = d["status"] as? String, status == "missing_permissions" {
            return (true, "ElevenLabs accepted the key. It is a restricted key, so make sure sound effects are allowed on it.")
        }
        return (false, "ElevenLabs: " + describe(data, status: http.statusCode))
    }

    static func describe(_ data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = obj["detail"] as? [String: Any], let m = d["message"] as? String { return m }
            if let d = obj["detail"] as? String { return d }
            if let d = obj["detail"] as? [[String: Any]], let m = d.first?["msg"] as? String { return m }
        }
        switch status {
        case 401: return "the API key was not accepted."
        case 429: return "rate limit or quota reached. Try again in a moment."
        default: return "request failed (HTTP \(status))."
        }
    }
}
