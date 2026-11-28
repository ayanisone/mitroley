import AVFoundation
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

// MARK: - Opening

/// The name and a short chime when the app opens, then it gets out of the way.
struct Splash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("startupSound") private var sound = true
    @State private var phase = 0        // 0 hidden, 1 shown, 2 leaving, 3 gone
    private static var player: AVAudioPlayer?
    private static var shown = false

    var body: some View {
        if phase < 3 {
            // Only the logo, over the app as it is: no card, no fill.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
                .scaleEffect(reduceMotion ? 1 : (phase == 0 ? 0.94 : phase == 1 ? 1 : 1.04))
                .opacity(phase == 1 ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !Self.shown, !CommandLine.arguments.contains("--selftest") else { phase = 3; return }
                Self.shown = true
                if sound { Self.chime() }
                withAnimation(.easeOut(duration: 0.25)) { phase = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeInOut(duration: 0.45)) { phase = 2 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { phase = 3 }
                }
            }
        }
    }

    /// Your own opening sound, if you put one here: ~/Library/Application Support/mitroley/opening.wav (or .mp3, .m4a, .aif).
    static var custom: URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mitroley")
        return ["wav", "aif", "aiff", "m4a", "mp3"].map { dir.appendingPathComponent("opening." + $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One soft, warm chord that swells in and rings out, made here so there is no sound file to ship.
    static func chime() {
        if let custom, let p = try? AVAudioPlayer(contentsOf: custom) {
            player = p
            p.play()
            return
        }
        let wav = chord()
        player = try? AVAudioPlayer(data: wav)
        player?.volume = 0.55
        player?.play()
    }

    /// D major, open: D3, A3, D4, F♯4, A4. Sines with a touch of second harmonic, each side tuned a hair apart for width.
    static func chord() -> Data {
        let rate = 48000.0, length = 2.4
        let n = Int(rate * length)
        let notes: [(hz: Double, level: Double)] = [(146.83, 0.9), (220.0, 0.7), (293.66, 0.8), (369.99, 0.55), (440.0, 0.4)]
        var pcm = Data(capacity: n * 4)
        for i in 0..<n {
            let t = Double(i) / rate
            // In over 60 ms, then a slow fall; the last 0.3 s fades to nothing so it never clicks off.
            let swell = min(1, t / 0.06), fall = exp(-t * 1.9), tail = min(1, (length - t) / 0.3)
            let env = swell * swell * (3 - 2 * swell) * fall * tail
            var l = 0.0, r = 0.0
            for (k, note) in notes.enumerated() {
                let drift = 0.35 + 0.1 * Double(k)
                // Higher notes die away sooner, as on a struck string.
                let own = exp(-t * Double(k) * 0.35)
                l += note.level * own * (sin(2 * .pi * (note.hz - drift) * t) + 0.12 * sin(2 * .pi * 2 * (note.hz - drift) * t))
                r += note.level * own * (sin(2 * .pi * (note.hz + drift) * t) + 0.12 * sin(2 * .pi * 2 * (note.hz + drift) * t))
            }
            let a = Int16(max(-1, min(1, l * env * 0.2)) * 32000), b = Int16(max(-1, min(1, r * env * 0.2)) * 32000)
            withUnsafeBytes(of: a.littleEndian) { pcm.append(contentsOf: $0) }
            withUnsafeBytes(of: b.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        // Added piece by piece: one long chain of + is more than the compiler will work out.
        var wav = Data("RIFF".utf8)
        wav.append(u32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        for part in [u32(16), u16(1), u16(2), u32(Int(rate)), u32(Int(rate) * 4), u16(4), u16(16)] { wav.append(part) }
        wav.append(Data("data".utf8))
        wav.append(u32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

// MARK: - Problem reports

/// When the app quit unexpectedly last time, macOS wrote a report. This finds it and offers to send it, so a crash
/// on someone else's Mac can be seen and fixed. Nothing is sent unless they press Send, and they see what goes.
enum ProblemReports {
    static var version: String {
        let b = Bundle.main.infoDictionary
        return "\(b?["CFBundleShortVersionString"] as? String ?? "?") (\(b?["CFBundleVersion"] as? String ?? "?"))"
    }
    static var system: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion), \(String(cString: model))"
    }

    /// The newest crash report for this app that has not been looked at yet.
    static func latest() -> URL? {
        let d = UserDefaults.standard
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        // The first time, only crashes from now on count.
        guard let since = d.object(forKey: "crashSeen") as? Double else { d.set(Date().timeIntervalSince1970, forKey: "crashSeen"); return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { ($0.lastPathComponent.hasPrefix("Foley") || $0.lastPathComponent.lowercased().hasPrefix("mitroley")) && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { u -> (URL, Double)? in
                let t = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return t > since ? (u, t) : nil
            }
            .max { $0.1 < $1.1 }?.0
    }

    static func seen() { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "crashSeen") }

    /// The part of a crash report that says what went wrong: the kind of failure and where the app was at the time.
    /// No file contents, no session, no keys; paths under the home folder are shortened.
    static func summary(of report: URL) -> String {
        guard let text = try? String(contentsOf: report, encoding: .utf8) else { return "(the report could not be read)" }
        var lines: [String] = []
        // A .ips report is one line of facts, then the detail as JSON.
        if let split = text.firstIndex(of: "\n"),
           let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: split)...].utf8))) as? [String: Any] {
            if let e = body["exception"] as? [String: Any] {
                lines.append("Failure: \((e["type"] as? String) ?? "?") \((e["signal"] as? String) ?? "") \((e["subtype"] as? String) ?? "")")
            }
            if let t = (body["termination"] as? [String: Any])?["indicator"] as? String { lines.append("Ended by: \(t)") }
            if let asi = body["asi"] as? [String: Any] { for (_, v) in asi { if let a = v as? [String] { lines += a.prefix(3).map { "Note: \($0)" } } } }
            let images = (body["usedImages"] as? [[String: Any]]) ?? []
            let threads = (body["threads"] as? [[String: Any]]) ?? []
            let index = (body["faultingThread"] as? Int) ?? 0
            if index < threads.count, let frames = threads[index]["frames"] as? [[String: Any]] {
                lines.append("Where it was (thread \(index)):")
                for f in frames.prefix(16) {
                    let image = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                    lines.append("  \(image)  \((f["symbol"] as? String) ?? "0x" + String((f["imageOffset"] as? Int) ?? 0, radix: 16))")
                }
            }
        }
        if lines.isEmpty { lines = text.split(separator: "\n").prefix(40).map(String.init) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return lines.joined(separator: "\n").replacingOccurrences(of: home, with: "~")
    }

    /// Opens a new report on the project's page, filled in. The person reads it and presses Submit themselves.
    static func send(title: String, body: String) {
        var c = URLComponents(string: "https://github.com/ayanisone/mitroley/issues/new")!
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: String(body.prefix(5500)))]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    static func report(_ crash: URL?) {
        var body = "**What happened**\n(Say what you were doing.)\n\n**mitroley** \(version)\n**Mac** \(system)\n"
        if let crash { body += "\n**From the crash report**\n```\n\(summary(of: crash))\n```\n" }
        send(title: crash == nil ? "Problem: " : "Crash: ", body: body)
    }
}

/// The bar that appears when the last run ended in a crash.
struct CrashBar: View {
    @State private var report: URL?
    var body: some View {
        Group {
            if let report {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("mitroley quit unexpectedly last time").font(.system(size: 12, weight: .semibold))
                        Text("Sending the report helps get it fixed. You see what is sent before it goes.").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    }
                    Button("Send Report") { ProblemReports.report(report); ProblemReports.seen(); self.report = nil }.buttonStyle(PillButtonStyle(prominent: true))
                    Button("Not Now") { ProblemReports.seen(); self.report = nil }.buttonStyle(PillButtonStyle())
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.25)) { report = ProblemReports.latest() }
        }
    }
}

// MARK: - Files with many channels

/// A surround file brought in as one track per speaker, each named and placed where that speaker is.
enum SpeakerSplit {
    /// Speaker names and room positions (x left to right, y back to front, z up) for the usual channel counts.
    static func layout(channels: Int, adm: Bool) -> [(name: String, pos: Vec3?)]? {
        let l = ("L", Vec3(x: -1, y: 1, z: 0)), r = ("R", Vec3(x: 1, y: 1, z: 0)), c = ("C", Vec3(x: 0, y: 1, z: 0))
        let lfe: (String, Vec3?) = ("LFE", nil)
        let lss = ("Lss", Vec3(x: -1, y: 0, z: 0)), rss = ("Rss", Vec3(x: 1, y: 0, z: 0))
        let lrs = ("Lrs", Vec3(x: -1, y: -1, z: 0)), rrs = ("Rrs", Vec3(x: 1, y: -1, z: 0))
        let ltf = ("Ltf", Vec3(x: -1, y: 0.5, z: 1)), rtf = ("Rtf", Vec3(x: 1, y: 0.5, z: 1))
        let ltr = ("Ltr", Vec3(x: -1, y: -0.5, z: 1)), rtr = ("Rtr", Vec3(x: 1, y: -0.5, z: 1))
        let lts = ("Lts", Vec3(x: -1, y: 0, z: 1)), rts = ("Rts", Vec3(x: 1, y: 0, z: 1))
        func some(_ a: [(String, Vec3)]) -> [(name: String, pos: Vec3?)] { a.map { ($0.0, Optional($0.1)) } }
        // A Dolby Atmos master: a 7.1.2 bed in its own order, then the objects.
        if adm, channels >= 10 {
            return some([l, r, c]) + [lfe] + some([lss, rss, lrs, rrs, lts, rts]) + (0..<(channels - 10)).map { ("Object \($0 + 1)", Optional(Vec3(x: 0, y: 1, z: 0))) }
        }
        switch channels {
        case 3: return some([l, r, c])
        case 4: return some([l, r, ("Ls", lrs.1), ("Rs", rrs.1)])
        case 6: return some([l, r, c]) + [lfe] + some([("Ls", lss.1), ("Rs", rss.1)])
        case 8: return some([l, r, c]) + [lfe] + some([lrs, rrs, lss, rss])
        case 10: return some([l, r, c]) + [lfe] + some([lrs, rrs, lss, rss, lts, rts])
        case 12: return some([l, r, c]) + [lfe] + some([lrs, rrs, lss, rss, ltf, rtf, ltr, rtr])
        default: return nil
        }
    }

    /// Whether the file carries Atmos (ADM) information: an "axml" or "chna" chunk somewhere in it.
    static func isADM(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        func has(_ offset: UInt64, _ length: Int) -> Bool {
            try? h.seek(toOffset: offset)
            guard let d = try? h.read(upToCount: length) else { return false }
            return d.range(of: Data("axml".utf8)) != nil || d.range(of: Data("chna".utf8)) != nil
        }
        return has(0, 4096) || (size > 4_000_000 ? has(size - 4_000_000, 4_000_000) : has(0, Int(size)))
    }

    static func channels(of url: URL) -> Int { Int((try? AVAudioFile(forReading: url))?.fileFormat.channelCount ?? 0) }
}

extension Store {
    /// Brings a surround file in as one track per speaker. Each track is named for its speaker and sits there in the room.
    func importSplit(_ source: URL, at start: Double) async {
        let n = SpeakerSplit.channels(of: source)
        let adm = SpeakerSplit.isADM(source)
        guard let layout = SpeakerSplit.layout(channels: n, adm: adm) else {
            say("\(source.lastPathComponent) has \(n) channels, which is not a speaker layout mitroley knows.", error: true)
            return
        }
        busy = "Splitting \(source.lastPathComponent)"
        defer { busy = nil }
        let dir = subfolder("Audio").appendingPathComponent("split-" + UUID().uuidString.prefix(8), isDirectory: true)
        let base = source.deletingPathExtension().lastPathComponent
        let made = await Task.detached(priority: .userInitiated) { () -> [(String, Double)]? in
            guard let file = try? AVAudioFile(forReading: source),
                  let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let frames = Int(buf.frameLength), rate = file.processingFormat.sampleRate
            var out: [(String, Double)] = []
            for c in 0..<min(n, layout.count) {
                var mono = Array(UnsafeBufferPointer(start: ch[c], count: frames))
                // The app works at 48 kHz; other rates are converted when the clip is first played, so only the length matters here.
                let name = String(format: "%02d %@.wav", c + 1, layout[c].name)
                guard let outFile = try? AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]),
                    let one = AVAudioPCMBuffer(pcmFormat: outFile.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
                one.frameLength = AVAudioFrameCount(frames)
                mono.withUnsafeMutableBufferPointer { p in one.floatChannelData![0].update(from: p.baseAddress!, count: frames) }
                guard (try? outFile.write(from: one)) != nil else { return nil }
                out.append((name, Double(frames) / rate))
            }
            return out
        }.value
        guard let made else { say("\(source.lastPathComponent) could not be read.", error: true); return }
        let group = TrackGroup(name: base)
        mutate { p in
            p.groups = (p.groups ?? []) + [group]
            for (i, m) in made.enumerated() {
                var t = Track(name: layout[i].name, kind: .fx)
                t.spaceMode = .dry
                t.groupID = group.id
                if let pos = layout[i].pos { t.spatial = true; t.position = pos } else { t.lfe = 1 }
                t.clips = [Clip(name: "\(base) \(layout[i].name)", start: start, duration: m.1,
                                takes: [Take(file: "Audio/\(dir.lastPathComponent)/\(m.0)", duration: m.1)])]
                p.tracks.append(t)
            }
        }
        say("\(source.lastPathComponent): \(made.count) speakers, one track each" + (adm ? " (Atmos master: a 7.1.2 bed, then its objects)" : ""))
    }
}
