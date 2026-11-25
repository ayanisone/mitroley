import Accelerate
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// A look over the finished mix for the faults that show up at cuts and edges: the background jumping in level across a
/// cut, dead air, peaks that will clip, and a sound chopped off at the end. Measured from one render of the mix; nothing is
/// changed. The idea of checking the background level either side of a cut is from cutcheck (MIT, Tom Goldfinch).
struct CutFinding: Identifiable, Equatable {
    enum Kind: String { case jump, silence, peak, chopped }
    let id = UUID()
    let kind: Kind
    let time: Double
    let title: String
    let detail: String
    static func == (a: CutFinding, b: CutFinding) -> Bool { a.id == b.id }
}

enum CutCheck {
    /// The level of 50 ms windows across the mix, in dBFS.
    static func levels(_ l: [Float], _ r: [Float], rate: Double) -> [Float] {
        let hop = Int(rate / 20), n = min(l.count, r.count) / hop
        var out = [Float](repeating: -120, count: n)
        for f in 0..<n {
            var a: Float = 0, b: Float = 0
            l.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + f * hop, 1, &a, vDSP_Length(hop)) }
            r.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + f * hop, 1, &b, vDSP_Length(hop)) }
            out[f] = 10 * log10(max(1e-12, (a + b) / 2))
        }
        return out
    }

    /// The quiet level of a stretch: what stays under the events, which is the room or the ambience. The 20th percentile.
    static func floor(_ v: ArraySlice<Float>) -> Float? {
        guard v.count >= 4 else { return nil }
        let s = v.sorted()
        return s[s.count / 5]
    }

    static func run(l: [Float], r: [Float], rate: Double, cuts: [Double], duration: Double, fps: Double, limited: Bool = false) -> [CutFinding] {
        let lv = levels(l, r, rate: rate)
        guard !lv.isEmpty else { return [] }
        var out: [CutFinding] = []
        func tc(_ t: Double) -> String { timecode(t, fps: fps) }
        let filmFrames = min(lv.count, Int(duration * 20))

        // 1. The background either side of each cut, over the second before and the second after.
        for c in cuts where c > 0.5 && c < duration - 0.5 {
            let i = Int(c * 20)
            guard i - 20 >= 0, i + 20 <= lv.count, let a = floor(lv[(i - 20)..<(i - 1)]), let b = floor(lv[(i + 1)..<(i + 20)]) else { continue }
            // Both sides silent is not a jump, and neither is a cut into or out of silence that is meant.
            guard max(a, b) > -55 else { continue }
            let d = b - a
            if abs(d) >= 8 {
                out.append(CutFinding(kind: .jump, time: c, title: "Background \(d > 0 ? "jumps up" : "drops") \(String(format: "%.0f", abs(d))) dB at the cut",
                                      detail: "At \(tc(c)) the quiet level goes from \(String(format: "%.0f", a)) to \(String(format: "%.0f", b)) dBFS. Let the ambience run across the cut, or crossfade it."))
            }
        }

        // 2. Dead air: nothing at all for a third of a second or more, inside the film.
        var start: Int?
        for f in 0...filmFrames {
            let silent = f < filmFrames && lv[f] < -72
            if silent, start == nil { start = f }
            if !silent, let s = start {
                let len = Double(f - s) / 20
                if len >= 0.35 {
                    out.append(CutFinding(kind: .silence, time: Double(s) / 20, title: "Nothing is heard for \(String(format: "%.1f", len)) s",
                                          detail: "From \(tc(Double(s) / 20)) to \(tc(Double(f) / 20)). Even a quiet scene has room tone; total silence reads as a fault."))
                }
                start = nil
            }
        }

        // 3. Peaks over -1 dBFS, one finding per second at most.
        let hop = Int(rate / 20)
        var last = -10.0
        // With a limiter on the master the peaks are already held, so there is nothing to report.
        for f in 0..<(limited ? 0 : lv.count) {
            var pl: Float = 0, pr: Float = 0
            l.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + f * hop, 1, &pl, vDSP_Length(hop)) }
            r.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + f * hop, 1, &pr, vDSP_Length(hop)) }
            let pk = 20 * log10(max(1e-9, max(pl, pr)))
            let t = Double(f) / 20
            if pk > -1, t - last >= 1 {
                last = t
                out.append(CutFinding(kind: .peak, time: t, title: "Peak at \(String(format: "%+.1f", pk)) dBFS",
                                      detail: "At \(tc(t)). Over -1 it can distort once it is turned into AAC or MP3. Lower the loudest track here, or add a limiter on the master."))
            }
        }

        // 4. Still sounding where the film ends.
        let end = Int(duration * 20)
        if end >= 2, end <= lv.count, let e = lv[(end - 2)..<end].max(), e > -45 {
            out.append(CutFinding(kind: .chopped, time: max(0, duration - 0.5), title: "Still sounding at the last frame",
                                  detail: "The mix is at \(String(format: "%.0f", e)) dBFS when the film ends, so it is cut off. Fade the last sounds out, or let the export keep its tail."))
        }
        return out.sorted { $0.time < $1.time }
    }
}

extension Store {
    /// Renders the mix once and looks it over. Returns what it found, in time order.
    func checkCuts() async throws -> [CutFinding] {
        let p = project, folder = self.folder, video = videoURL
        busy = "Checking the mix at the cuts"
        defer { busy = nil }
        return try await Task.detached(priority: .userInitiated) {
            var mix = try Exporter.render(p, mode: .stereo, tail: 0, resolve: { Store.url(for: $0, in: folder) })
            // The film's own sound is part of what is heard.
            if p.videoVolume > 0.001, let video, let buf = AudioCache.shared.buffer(video), let ch = buf.floatChannelData {
                let g = Float(p.videoVolume)
                for i in 0..<min(mix.l.count, Int(buf.frameLength)) { mix.l[i] += ch[0][i] * g; mix.r[i] += ch[1][i] * g }
            }
            let cuts = p.scenes.map(\.start).filter { $0 > 0 }
            return CutCheck.run(l: mix.l, r: mix.r, rate: AudioCache.sampleRate, cuts: cuts, duration: p.duration, fps: p.fps,
                                limited: (p.rack ?? []).contains { $0.kind == .limiter && $0.on })
        }.value
    }
}

/// The findings as a list. Click one to go there.
struct CutCheckSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var findings: [CutFinding]?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check the mix").font(.system(size: 20, weight: .semibold)).tracking(-0.3)
            Text("Plays the whole mix through once, silently, and looks at every cut and both ends for the faults a viewer hears as mistakes. Nothing is changed.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Group {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let findings {
                    if findings.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.5))
                            Text("Nothing found").font(.system(size: 15, weight: .semibold))
                            Text("\(store.project.scenes.count) cut\(store.project.scenes.count == 1 ? "" : "s") checked: no jumps in the background, no dead air, no peaks over -1 dBFS, and the end is clean.")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(findings) { f in
                                    Button { store.player.seek(f.time) } label: { row(f) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Listening to the mix").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)
            HStack {
                if let findings, !findings.isEmpty {
                    Text("\(findings.count) thing\(findings.count == 1 ? "" : "s") to look at. Click one to go there.").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Check Again") { run() }.buttonStyle(PillButtonStyle()).disabled(findings == nil && failure == nil)
                Button("Done") { dismiss() }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.panel)
        .onAppear { run() }
    }

    private func run() {
        findings = nil
        failure = nil
        Task {
            do { findings = try await store.checkCuts() } catch { failure = "The mix could not be played through: \(error.localizedDescription)" }
        }
    }

    private func row(_ f: CutFinding) -> some View {
        let symbol = switch f.kind {
        case .jump: "arrow.up.arrow.down"
        case .silence: "speaker.slash.fill"
        case .peak: "exclamationmark.triangle.fill"
        case .chopped: "scissors"
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(f.kind == .peak ? Theme.danger : Theme.accent).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.system(size: 12.5, weight: .semibold))
                Text(f.detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(timecode(f.time, fps: store.project.fps)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}
