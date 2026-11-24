import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// The mixer: every track as a channel strip with a fader, pan, mute, solo and a meter, and the master at the end.
struct MixerView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let p = store.project
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(p.tracks) { t in
                        ChannelStrip(track: t)
                    }
                    Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 6)
                    MasterStrip()
                }
                .padding(14)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Text("\(p.tracks.count) track\(p.tracks.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                Spacer()
                Text("Double-click a fader or pan to reset · right-click to type a value").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16).frame(height: 34)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.panel)
    }
}

private let stripWidth: CGFloat = 78

private struct ChannelStrip: View {
    @Environment(Store.self) private var store
    let track: Track

    private func edit(_ change: @escaping (inout Track) -> Void) {
        store.mutate { p in if let i = p.trackIndex(track.id) { change(&p.tracks[i]) } }
    }

    var body: some View {
        let selected = store.selection == .track(track.id)
        VStack(spacing: 8) {
            Rectangle().fill(track.kind.color).frame(height: 3).clipShape(Capsule())
            Image(systemName: track.kind.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(track.kind.color).frame(height: 14)
            Text(track.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                .frame(width: stripWidth - 12, height: 30)
            // Pan. On a spatial track it is the left–right position in the room.
            VStack(spacing: 2) {
                Slide(value: track.spatial ? track.position.x : track.pan, range: -1...1, tint: Theme.secondary, reset: 0, label: Slide.side, begin: { store.beginGesture() }) { v in
                    let x = abs(v) < 0.04 ? 0 : v
                    store.live { p in
                        guard let i = p.trackIndex(track.id) else { return }
                        if p.tracks[i].spatial { p.tracks[i].position.x = x } else { p.tracks[i].pan = x }
                    }
                }
                .frame(width: stripWidth - 18)
                Text(Slide.side(track.spatial ? track.position.x : track.pan)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            HStack(spacing: 5) {
                ChipToggle(label: "M", on: track.mute, tint: Theme.danger) { edit { $0.mute.toggle() } }
                ChipToggle(label: "S", on: track.solo) { edit { $0.solo.toggle() } }
            }
            HStack(alignment: .bottom, spacing: 7) {
                Fader(value: track.volume, tint: track.kind.color, begin: { store.beginGesture() }) { v in
                    store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].volume = v } }
                }
                LevelBar(level: store.player.trackLevels[track.id] ?? 0)
            }
            .frame(maxHeight: .infinity)
            Text(Slide.decibels(track.volume)).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85)).frame(height: 14)
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .frame(width: stripWidth)
        .frame(maxHeight: .infinity)
        .background(selected ? Color.white.opacity(0.07) : Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? track.kind.color.opacity(0.6) : .clear, lineWidth: 1))
        .opacity(track.mute ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .track(track.id) }
    }
}

private struct MasterStrip: View {
    @Environment(Store.self) private var store
    var body: some View {
        let v = store.project.masterVolume ?? 0
        VStack(spacing: 8) {
            Rectangle().fill(Color.white.opacity(0.7)).frame(height: 3).clipShape(Capsule())
            Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).frame(height: 14)
            Text("Master").font(.system(size: 11.5, weight: .semibold)).frame(width: stripWidth - 12, height: 30)
            // Empty where a track has pan and mute, so the faders line up across the mixer.
            Color.clear.frame(width: stripWidth - 18, height: 34)
            Color.clear.frame(height: 22)
            HStack(alignment: .bottom, spacing: 7) {
                Fader(value: v, tint: .white, begin: { store.beginGesture() }) { nv in
                    store.live { $0.masterVolume = abs(nv) < 0.05 ? nil : nv }
                }
                LevelBar(level: store.player.masterL)
                LevelBar(level: store.player.masterR)
            }
            .frame(maxHeight: .infinity)
            Text(Slide.decibels(v)).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85)).frame(height: 14)
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .frame(width: stripWidth + 14)
        .frame(maxHeight: .infinity)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A vertical fader, -48 to +12 dB, with more travel around 0 where it matters.
private struct Fader: View {
    let value: Double
    var tint: Color
    let begin: () -> Void
    let change: (Double) -> Void
    @State private var dragging = false
    @State private var grab: CGFloat = 0
    private let cap: CGFloat = 22

    // Travel: half of it covers -12…+12, the rest -48…-12.
    private func unit(_ db: Double) -> Double {
        let d = min(12, max(-48, db))
        return d >= -12 ? 0.5 + (d + 12) / 24 * 0.5 : (d + 48) / 36 * 0.5
    }
    private func db(_ u: Double) -> Double {
        let c = min(1, max(0, u))
        return c >= 0.5 ? -12 + (c - 0.5) / 0.5 * 24 : -48 + c / 0.5 * 36
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, travel = max(1, h - cap)
            let y = (1 - unit(value)) * travel
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 4).frame(maxHeight: .infinity)
                // The 0 dB mark.
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 14, height: 1).offset(y: (1 - unit(0)) * travel + cap / 2)
                Capsule().fill(tint.opacity(0.85)).frame(width: 4, height: max(0, h - y - cap / 2)).offset(y: y + cap / 2)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(white: 0.93))
                    .frame(width: 26, height: cap)
                    .overlay(Rectangle().fill(Color.black.opacity(0.55)).frame(width: 18, height: 1.5))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .scaleEffect(dragging ? 1.06 : 1)
                    .offset(y: y)
                    .animation(.spring(response: 0.2, dampingFraction: 1), value: dragging)
            }
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging {
                        dragging = true
                        begin()
                        let centre = y + cap / 2
                        grab = abs(g.startLocation.y - centre) <= cap ? g.startLocation.y - centre : 0
                    }
                    let u = 1 - Double((g.location.y - grab - cap / 2) / travel)
                    change((db(u) * 10).rounded() / 10)
                }
                .onEnded { _ in dragging = false })
            .simultaneousGesture(TapGesture(count: 2).onEnded { begin(); change(0) })
            .contextMenu {
                Button("Type a Value…") {
                    let alert = NSAlert()
                    alert.messageText = "Type a level"
                    alert.informativeText = "In dB, between -48 and 12."
                    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
                    field.stringValue = String(format: "%.1f", value)
                    alert.accessoryView = field
                    alert.addButton(withTitle: "Set")
                    alert.addButton(withTitle: "Cancel")
                    alert.window.initialFirstResponder = field
                    guard alert.runModal() == .alertFirstButtonReturn,
                          let v = Double(field.stringValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-").filter { "0123456789.-+".contains($0) }) else { return }
                    begin(); change(min(12, max(-48, v)))
                }
                Button("Reset") { begin(); change(0) }
            }
        }
        .frame(width: 30)
    }
}

/// A level meter that reads from the bottom up: green, amber near the top, red at the very top.
private struct LevelBar: View {
    let level: Float
    var body: some View {
        let db = linearToDb(Double(level))
        let u = min(1, max(0, (db + 54) / 54))
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(db > -1 ? Theme.danger : (db > -9 ? Theme.accent : Color(red: 0.3, green: 0.85, blue: 0.5)))
                    .frame(height: max(0, geo.size.height * u))
            }
        }
        .frame(width: 5)
    }
}
