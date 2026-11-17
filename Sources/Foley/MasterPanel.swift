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
        .help("Output level and integrated loudness. Click for the master effects rack.")
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

    var body: some View {
        let effects = store.project.effects
        let missing = EffectKind.allCases.filter { k in !effects.contains { $0.kind == k } }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Master effects").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                    Spacer()
                    Menu {
                        ForEach(missing) { k in
                            Button(k.title) { store.mutate { $0.withEffect(k) { $0.on = true } } }
                        }
                    } label: {
                        Label("Add", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
                    .disabled(missing.isEmpty)
                }
                if effects.isEmpty {
                    Text("Nothing here, so the mix goes out untouched. Add an effect when you need one: a compressor, a limiter, surround reverb, fold-down trims or a loudness meter.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                ForEach(effects) { e in card(e) }
            }
            .padding(18)
        }
        .frame(width: 330, height: effects.isEmpty ? 190 : 640)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
    }

    private func card(_ e: Effect) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(e.kind.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { e.on }, set: { v in store.mutate { $0.withEffect(e.kind) { $0.on = v } } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(e.on ? "Bypass" : "Switch on")
                Button { store.mutate { $0.removeEffect(e.kind) } } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.secondary)
                        .frame(width: 20, height: 20).background(Color.white.opacity(0.07), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .help("Remove from the rack")
            }
            Text(e.kind.detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            Group {
                ForEach(e.kind.params) { spec in
                    Field(title: spec.title, value: String(format: spec.format, e.value(spec.key) * spec.scale)) {
                        Slide(value: e.value(spec.key), range: spec.range, log: spec.log, reset: spec.fallback, begin: { store.beginGesture() }) { v in
                            store.live { $0.withEffect(e.kind) { $0.values[spec.key] = v } }
                        }
                    }
                }
                switch e.kind {
                case .compressor: Reduction(which: \.compressor)
                case .limiter: Reduction(which: \.limiter)
                case .loudness: loudness(e)
                default: EmptyView()
                }
            }
            .opacity(e.on ? 1 : 0.4)
            .disabled(!e.on)
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func loudness(_ e: Effect) -> some View {
        let target = e.value("target")
        let ceiling = store.project.active(.limiter)?.value("ceiling") ?? -1
        LoudnessReadout(target: target, ceiling: ceiling)
        HStack {
            Button("Reset") { store.player.loudness.reset() }.buttonStyle(PillButtonStyle())
            Button(measuring ? "Measuring" : "Measure full mix") { measure() }
                .buttonStyle(PillButtonStyle()).disabled(measuring)
            if measuring { ProgressView().controlSize(.small) }
        }
        if measuring {
            Text("Rendering the whole session. This takes about as long as an export.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
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
                            .foregroundStyle(tint(r.lufs, target))
                            .frame(width: 84, alignment: .trailing)
                        Text(String(format: "%.1f dBTP", r.truePeak))
                            .foregroundStyle(r.truePeak > ceiling + 0.05 ? Theme.danger : Theme.secondary)
                            .frame(width: 78, alignment: .trailing)
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func tint(_ lufs: Double?, _ target: Double) -> Color {
        guard let v = lufs else { return Theme.tertiary }
        if v > target + 1 { return Theme.danger }
        return v >= target - 2 ? good : Theme.accent
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
    var target = -14.0
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
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tint(_ v: Double?) -> Color {
        guard let v else { return Theme.tertiary }
        if v > target + 1 { return Theme.danger }
        return v >= target - 2 ? good : Color.white
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
