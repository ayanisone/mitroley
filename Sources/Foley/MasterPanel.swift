import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// The output meter in the transport bar. Click it for the master bus: compressor, limiter and loudness.
struct MasterMeter: View {
    @Environment(Store.self) private var store
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                VStack(spacing: 3) {
                    bar(store.player.masterL)
                    bar(store.player.masterR)
                }
                .frame(width: 72)
                IntegratedReadout()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .help("Output level and integrated loudness. Click for the master compressor, limiter and loudness meter.")
        .popover(isPresented: $open, arrowEdge: .top) {
            MasterPanel().environment(store)
        }
    }

    private func bar(_ level: Float) -> some View {
        let db = linearToDb(Double(level))
        let u = min(1, max(0, (db + 54) / 54))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(db > -1 ? Theme.danger : (db > -9 ? Theme.accent : Color(red: 0.3, green: 0.85, blue: 0.5)))
                    .frame(width: max(0, geo.size.width * u))
            }
        }
        .frame(height: 4)
    }
}

private struct IntegratedReadout: View {
    @Environment(Store.self) private var store
    var body: some View {
        let m = store.player.loudness
        VStack(alignment: .trailing, spacing: 0) {
            Text(m.integrated.map { String(format: "%.1f", $0) } ?? "–.–")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(store.player.isPlaying ? Color.white : Theme.secondary)
            Text("LUFS").font(.system(size: 7.5, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.tertiary)
        }
        .frame(width: 36, alignment: .trailing)
    }
}

struct MasterPanel: View {
    @Environment(Store.self) private var store
    @State private var measuring = false
    @State private var rows: [MixMeasure] = []
    @State private var problem: String?
    private let good = Color(red: 0.3, green: 0.85, blue: 0.5)

    private var d: BusDynamics { store.project.dynamics ?? BusDynamics() }

    private func slide(_ kp: WritableKeyPath<BusDynamics, Double>, _ range: ClosedRange<Double>, log: Bool = false, reset: Double) -> Slide {
        Slide(value: d[keyPath: kp], range: range, log: log, reset: reset, begin: { store.beginGesture() }) { v in
            store.live { p in
                var x = p.dynamics ?? BusDynamics()
                x[keyPath: kp] = v
                p.dynamics = x
            }
        }
    }

    private func trim(_ kp: WritableKeyPath<Project, Double?>) -> Slide {
        Slide(value: store.project[keyPath: kp] ?? 0, range: -12...6, reset: 0, begin: { store.beginGesture() }) { v in
            store.live { $0[keyPath: kp] = abs(v) < 0.05 ? nil : v }
        }
    }

    private func toggle(_ kp: WritableKeyPath<BusDynamics, Bool>) -> Binding<Bool> {
        Binding(get: { d[keyPath: kp] }, set: { v in
            store.mutate { p in
                var x = p.dynamics ?? BusDynamics()
                x[keyPath: kp] = v
                p.dynamics = x
            }
        })
    }

    var body: some View {
        let d = self.d
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Master bus").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                Text("Both work on every channel at once. They listen to the loudest channel and turn all of them down together, so a hit in one speaker never moves the image, and no channel can clip.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

                header("Compressor", toggle(\.compressor))
                Group {
                    Field(title: "Threshold", value: String(format: "%.1f dB", d.threshold)) { slide(\.threshold, -48...0, reset: -18) }
                    Field(title: "Ratio", value: String(format: "%.1f : 1", d.ratio)) { slide(\.ratio, 1...12, reset: 3) }
                    Field(title: "Attack", value: String(format: "%.0f ms", d.attack)) { slide(\.attack, 0.5...120, log: true, reset: 10) }
                    Field(title: "Release", value: String(format: "%.0f ms", d.release)) { slide(\.release, 20...1200, log: true, reset: 150) }
                    Field(title: "Make-up", value: String(format: "%+.1f dB", d.makeup)) { slide(\.makeup, 0...18, reset: 0) }
                    Reduction(which: \.compressor)
                }
                .opacity(d.compressor ? 1 : 0.4)
                .disabled(!d.compressor)

                header("Limiter", toggle(\.limiter))
                Group {
                    Field(title: "Ceiling", value: String(format: "%.1f dBTP", d.ceiling)) { slide(\.ceiling, -6...0, reset: -1) }
                    Field(title: "Release", value: String(format: "%.0f ms", d.limiterRelease)) { slide(\.limiterRelease, 20...800, log: true, reset: 120) }
                    Reduction(which: \.limiter)
                }
                .opacity(d.limiter ? 1 : 0.4)
                .disabled(!d.limiter)

                SectionTitle("Fold-down trims")
                Field(title: "Surrounds", value: String(format: "%+.1f dB", store.project.surroundTrim ?? 0)) { trim(\.surroundTrim) }
                Field(title: "Heights", value: String(format: "%+.1f dB", store.project.heightTrim ?? 0)) { trim(\.heightTrim) }
                Text("How loud the surround and height speakers are when the 7.1.4 mix is folded to 5.1, stereo or laptop and phone. The 7.1.4 itself is not changed.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)

                HStack {
                    SectionTitle("Loudness")
                    Spacer()
                    Button("Reset") { store.player.loudness.reset() }.buttonStyle(PillButtonStyle())
                }
                LoudnessReadout(ceiling: d.ceiling)
                Text("Target −14 LUFS integrated, peaks under −1 dBTP. This reads what you are hearing now; the full mix in every format is measured below.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(measuring ? "Measuring" : "Measure full mix") { measure() }
                        .buttonStyle(PillButtonStyle()).disabled(measuring)
                    if measuring { ProgressView().controlSize(.small) }
                }
                if let problem {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                if !rows.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(rows) { r in
                            HStack {
                                Text(r.name).font(.system(size: 12))
                                Spacer()
                                Text(r.lufs.map { String(format: "%.1f LUFS", $0) } ?? "silent")
                                    .foregroundStyle(tint(lufs: r.lufs))
                                    .frame(width: 84, alignment: .trailing)
                                Text(String(format: "%.1f dBTP", r.truePeak))
                                    .foregroundStyle(r.truePeak > d.ceiling + 0.05 ? Theme.danger : Theme.secondary)
                                    .frame(width: 78, alignment: .trailing)
                            }
                            .font(.system(size: 11.5).monospacedDigit())
                        }
                    }
                    .padding(10)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(18)
        }
        .frame(width: 320, height: 620)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
    }

    private func header(_ title: String, _ on: Binding<Bool>) -> some View {
        HStack {
            SectionTitle(title)
            Spacer()
            Toggle("", isOn: on).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    private func tint(lufs: Double?) -> Color {
        guard let v = lufs else { return Theme.tertiary }
        if v > -13 { return Theme.danger }
        return v >= -16 ? good : Theme.accent
    }

    private func measure() {
        measuring = true
        problem = nil
        Task {
            do { rows = try await store.measureMix() } catch { problem = error.localizedDescription }
            measuring = false
        }
    }
}

/// Gain reduction bar: fills from the right as the bus turns the mix down.
private struct Reduction: View {
    @Environment(Store.self) private var store
    let which: KeyPath<LoudnessMeter, Double>
    var body: some View {
        let db = -store.player.loudness[keyPath: which]
        HStack(spacing: 8) {
            Text("Reduction").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(min(1, db / 12)))
                }
            }
            .frame(height: 4)
            Text(String(format: "%.1f dB", db)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(db > 0.05 ? Color.white : Theme.tertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private struct LoudnessReadout: View {
    @Environment(Store.self) private var store
    let ceiling: Double
    private let good = Color(red: 0.3, green: 0.85, blue: 0.5)

    var body: some View {
        let m = store.player.loudness
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(m.integrated.map { String(format: "%.1f", $0) } ?? "–.–")
                    .font(.system(size: 30, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint(m.integrated))
                Text("LUFS INTEGRATED").font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
            small("Momentary", m.momentary, "%.1f", Color.white)
            small("Short", m.shortTerm, "%.1f", Color.white)
            small("True peak", m.truePeak, "%.1f", (m.truePeak ?? -99) > ceiling + 0.05 ? Theme.danger : Color.white)
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tint(_ v: Double?) -> Color {
        guard let v else { return Theme.tertiary }
        if v > -13 { return Theme.danger }
        return v >= -16 ? good : Color.white
    }

    private func small(_ title: String, _ v: Double?, _ f: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(v.map { String(format: f, $0) } ?? "–").font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(v == nil ? Theme.tertiary : color)
            Text(title.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.tertiary)
        }
    }
}

extension Store {
    /// Renders the session in the background and measures every format it folds to.
    func measureMix() async throws -> [MixMeasure] {
        let p = project, folder = self.folder
        return try await Task.detached(priority: .userInitiated) {
            try Exporter.measure(p, resolve: { Store.url(for: $0, in: folder) })
        }.value
    }
}
