import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// The mixer: every track as a channel strip, then the buses, then the master. A strip has pan, mute, solo, a fader and a
/// meter, and under them where its effects sit against the fader, what it ducks under, and where it is sent.
struct MixerView: View {
    @Environment(Store.self) private var store
    /// Inside the main window: no footer, and it takes whatever height it is given.
    var docked = false

    var body: some View {
        let p = store.project
        let buses = p.groups ?? []
        VStack(spacing: 0) {
            if p.tracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.vertical.3").font(.system(size: 26)).foregroundStyle(Theme.tertiary)
                    Text("No tracks yet").font(.system(size: 14, weight: .semibold))
                    Text("Add a track on the timeline and its fader appears here.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(p.tracks) { t in ChannelStrip(track: t, compact: docked) }
                            if !buses.isEmpty {
                                Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 6)
                                ForEach(buses) { g in BusStrip(group: g, compact: docked) }
                            }
                            Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 6)
                            MasterStrip(compact: docked)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        Cables(compact: docked)
                    }
                    .padding(docked ? 10 : 14)
                }
            }
            if !docked {
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    Text("\(p.tracks.count) track\(p.tracks.count == 1 ? "" : "s")\(buses.isEmpty ? "" : ", \(buses.count) bus\(buses.count == 1 ? "" : "es")")").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("Drag a cable from a track's socket to a bus, the master or another track · double-click a fader to reset").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 16).frame(height: 34)
            }
        }
        .background(Theme.panel)
    }
}

private let stripWidth: CGFloat = 84
/// The rows under the fader are the same height on every strip, so they line up across the mixer.
private let rowHeight: CGFloat = 22

/// A small button in a strip: one line of text on a quiet plate, lit when `on`.
private struct StripLabel: View {
    let text: String
    var symbol: String?
    var on = false
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.secondary)
        .padding(.horizontal, 5)
        .frame(width: stripWidth - 14, height: rowHeight)
        .background(on ? tint : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct StripChip: View {
    let label: String
    let on: Bool
    var tint: Color = Theme.accent
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.secondary)
                .frame(width: 30, height: rowHeight)
                .background(on ? tint : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .hint(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The shell every strip shares: the coloured cap, the name, then whatever the strip puts in its rows.
/// Compact (under the timeline) puts the name on one line and expects the strip to lay its controls beside the fader.
private struct StripShell<Content: View>: View {
    let color: Color
    let symbol: String
    let name: String
    var width = stripWidth
    var compact = false
    var selected = false
    var dim = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 7) {
            Capsule().fill(color).frame(height: 3)
            if compact {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    Text(name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 16)
            } else {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(height: 14)
                Text(name).font(.system(size: 11.5, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: width - 12, height: 30)
            }
            content
        }
        .padding(.horizontal, 7).padding(.vertical, 8)
        .frame(width: compact ? compactWidth(width) : width)
        .frame(maxHeight: .infinity)
        .background(selected ? Color.white.opacity(0.07) : Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? color.opacity(0.6) : .clear, lineWidth: 1))
        .opacity(dim ? 0.6 : 1)
    }
    private func compactWidth(_ w: CGFloat) -> CGFloat { stripOuter(w, compact: true) }
}

/// How wide a strip is on screen. Compact: fader and meter on the left, a column of controls as wide as a tall strip's rows on the right.
private func stripOuter(_ w: CGFloat, compact: Bool) -> CGFloat {
    compact ? w - 14 + 8 + 30 + 7 + (w > stripWidth ? 17 : 5) + 14 : w
}

/// The cables' motion: every cable hangs from its two sockets and its middle is a weight on a spring, so it sways when it is
/// replugged, dragged, or brushed by the pointer, then settles. The clock only runs while something is still moving.
@Observable private final class CableSim {
    struct Body { var p: CGPoint; var v = CGVector.zero }
    /// Bumped once per step, so the drawing follows.
    var tick = 0
    @ObservationIgnored var bodies: [String: Body] = [:]
    @ObservationIgnored var rests: [String: CGPoint] = [:]
    @ObservationIgnored var pointer: CGPoint?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var last = CACurrentMediaTime()

    /// Where a cable's middle is now. A cable seen for the first time starts at its socket and falls into place.
    func middle(_ key: String, rest: CGPoint, from start: CGPoint) -> CGPoint {
        rests[key] = rest
        if let b = bodies[key] { return b.p }
        bodies[key] = Body(p: start)
        return start
    }

    func wake() {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30, now - last))
        last = now
        var moving = false
        for key in Array(bodies.keys) {
            guard let rest = rests[key], var b = bodies[key] else { bodies[key] = nil; continue }
            // A soft spring back to where the cable hangs, lightly damped so it swings past and returns.
            var ax = (rest.x - b.p.x) * 150 - b.v.dx * 11, ay = (rest.y - b.p.y) * 150 - b.v.dy * 11
            if let m = pointer {
                let dx = b.p.x - m.x, dy = b.p.y - m.y, d = max(1, hypot(dx, dy))
                if d < 46 { let push = (1 - d / 46) * 2600; ax += dx / d * push; ay += dy / d * push }
            }
            b.v.dx += ax * dt; b.v.dy += ay * dt
            b.p.x += b.v.dx * dt; b.p.y += b.v.dy * dt
            bodies[key] = b
            if abs(b.v.dx) + abs(b.v.dy) > 1.5 || abs(rest.x - b.p.x) + abs(rest.y - b.p.y) > 0.4 { moving = true }
        }
        rests = rests.filter { bodies[$0.key] != nil }
        tick &+= 1
        // Settled, even with the pointer resting on it: stop the clock until something changes.
        if !moving { timer?.invalidate(); timer = nil }
    }

    func forget(_ key: String) { bodies[key] = nil; rests[key] = nil }
    deinit { timer?.invalidate() }
}

/// The patch bay under the strips: a socket under every strip, and a cable from each track to where it plays into.
/// Drag from a track's socket to a bus's or the master's to send it there. Drag onto another track to sidechain: that track
/// then dips while this one is heard (drag the same way again to undo). Solid cables carry sound; dashed ones are sidechains.
private struct Cables: View {
    @Environment(Store.self) private var store
    let compact: Bool
    @State private var sim = CableSim()
    /// A cable being dragged: the socket it comes from and where the pointer has it.
    @State private var pulling: (from: Int, at: CGPoint)?

    private struct Port { let x: CGFloat; let track: UUID?; let bus: UUID?; let master: Bool }
    private static let top: CGFloat = 7
    private static let height: CGFloat = 66

    private var ports: [Port] {
        let p = store.project
        let w = stripOuter(stripWidth, compact: compact)
        var x: CGFloat = 0, out: [Port] = []
        for t in p.tracks { out.append(Port(x: x + w / 2, track: t.id, bus: nil, master: false)); x += w + 8 }
        if let g = p.groups, !g.isEmpty {
            x += 9
            for b in g { out.append(Port(x: x + w / 2, track: nil, bus: b.id, master: false)); x += w + 8 }
        }
        x += 9
        out.append(Port(x: x + stripOuter(stripWidth + 12, compact: compact) / 2, track: nil, bus: nil, master: true))
        return out
    }

    private func nearest(_ ports: [Port], to x: CGFloat, within: CGFloat = 26) -> Int? {
        guard let i = ports.indices.min(by: { abs(ports[$0].x - x) < abs(ports[$1].x - x) }), abs(ports[i].x - x) < within else { return nil }
        return i
    }

    var body: some View {
        let p = store.project
        let ports = self.ports
        let width = (ports.last?.x ?? 0) + stripOuter(stripWidth + 12, compact: compact) / 2
        var selected: UUID? { if case .track(let id) = store.selection { return id } else { return nil } }
        let target = pulling.flatMap { pull in nearest(ports, to: pull.at.x).flatMap { $0 == pull.from ? nil : $0 } }
        Canvas { ctx, size in
            _ = sim.tick
            let top = Self.top
            func x(track id: UUID?) -> CGFloat? { id.flatMap { i in ports.first { $0.track == i }?.x } }
            func x(bus id: UUID?) -> CGFloat? { id.flatMap { i in ports.first { $0.bus == i }?.x } }
            let master = ports.last?.x ?? 0
            func cable(_ key: String, _ a: CGPoint, _ b: CGPoint, _ color: Color, strong: Bool, dashed: Bool = false) {
                let sag = min(size.height - top - 6, 15 + abs(b.x - a.x) * 0.055) * (dashed ? 0.62 : 1)
                let rest = CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + sag)
                let m = sim.middle(key, rest: rest, from: a)
                // A curve that passes through the weight.
                let control = CGPoint(x: 2 * m.x - (a.x + b.x) / 2, y: 2 * m.y - (a.y + b.y) / 2)
                var path = Path()
                path.move(to: a)
                path.addQuadCurve(to: b, control: control)
                ctx.stroke(path, with: .color(.black.opacity(strong ? 0.35 : 0.15)), style: StrokeStyle(lineWidth: strong ? 4.5 : 3, lineCap: .round))
                ctx.stroke(path, with: .color(color.opacity(strong ? 0.95 : 0.32)),
                           style: StrokeStyle(lineWidth: strong ? 2.2 : 1.5, lineCap: .round, dash: dashed ? [5, 4] : []))
                if dashed {
                    var head = Path()
                    head.move(to: CGPoint(x: b.x, y: b.y + 2)); head.addLine(to: CGPoint(x: b.x - 4, y: b.y + 10)); head.addLine(to: CGPoint(x: b.x + 4, y: b.y + 10)); head.closeSubpath()
                    ctx.fill(head, with: .color(color.opacity(strong ? 0.95 : 0.4)))
                }
            }
            func at(_ x: CGFloat) -> CGPoint { CGPoint(x: x, y: top) }
            for t in p.tracks {
                guard let a = x(track: t.id) else { continue }
                let strong = selected == nil || selected == t.id
                // The cable being pulled out of this socket is drawn from the pointer instead.
                if pulling.map({ ports[$0.from].track == t.id }) != true || target.map({ ports[$0].track != nil }) == true {
                    cable("t-\(t.id)", at(a), at(x(bus: t.groupID) ?? master), t.kind.color, strong: strong)
                }
                if let d = t.duck {
                    let sources = d.source.map { [$0] } ?? p.tracks.filter { $0.kind == .dialogue && $0.id != t.id }.map(\.id)
                    for sid in sources { if let b = x(track: sid) { cable("s-\(sid)-\(t.id)", at(b), at(a), Theme.accent, strong: strong, dashed: true) } }
                }
            }
            for g in p.groups ?? [] { if let a = x(bus: g.id) { cable("b-\(g.id)", at(a), at(master), Color(white: 0.78), strong: selected == nil) } }
            if let pull = pulling {
                let from = ports[pull.from]
                let color = from.track.flatMap { id in p.tracks.first { $0.id == id }?.kind.color } ?? Color(white: 0.78)
                let end = target.map { at(ports[$0].x) } ?? pull.at
                cable("pull", at(from.x), end, target.map { ports[$0].track != nil } == true ? Theme.accent : color, strong: true, dashed: target.map { ports[$0].track != nil } == true)
            }
            for (i, port) in ports.enumerated() {
                let lit = (port.track != nil && port.track == selected) || target == i
                let r: CGFloat = target == i ? 6.5 : 4.5
                let rect = CGRect(x: port.x - r, y: top - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.09)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(lit ? Theme.accent : Color.white.opacity(port.track == nil ? 0.8 : 0.5)), lineWidth: target == i ? 2 : 1.5)
            }
        }
        .frame(width: width, height: Self.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let at): sim.pointer = at; sim.wake()
            case .ended: sim.pointer = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if pulling == nil {
                    guard let i = nearest(ports, to: g.startLocation.x), !ports[i].master else { return }
                    pulling = (i, g.location)
                } else {
                    pulling?.at = g.location
                }
                sim.pointer = nil
                sim.wake()
            }
            .onEnded { g in
                defer { pulling = nil; sim.forget("pull"); sim.wake() }
                let moved = hypot(g.translation.width, g.translation.height) > 5
                guard moved else { tap(ports, at: g.startLocation.x, selected: selected); return }
                guard let pull = pulling, let j = nearest(ports, to: g.location.x), j != pull.from else { return }
                let from = ports[pull.from], to = ports[j]
                guard let source = from.track else { return }   // a bus always plays into the master
                if to.master { store.setGroup(nil, for: [source]) }
                else if let name = p.group(to.bus)?.name { store.setGroup(name, for: [source]) }
                else if let other = to.track {
                    // Onto another track: that track dips while this one is heard. The same drag again takes it off.
                    let already = p.tracks.first { $0.id == other }?.duck?.source == source
                    Task { await store.setDucking(other, on: !already, source: .some(source)) }
                }
            })
        .onChange(of: MixGraph.busSignature(p) + p.tracks.map { "\($0.groupID?.uuidString ?? "-")\($0.duck?.source?.uuidString ?? ($0.duck == nil ? "" : "v"))" }.joined()) { _, _ in sim.wake() }
        .onAppear { sim.wake() }
        .hint("Drag from a track's socket to a bus or the master to send it there. Drag onto another track to sidechain: that track dips while this one is heard. Dashed cables are sidechains.")
        .accessibilityLabel("Routing: each track's output")
    }

    private func tap(_ ports: [Port], at x: CGFloat, selected: UUID?) {
        guard let i = nearest(ports, to: x) else { return }
        let port = ports[i]
        if let id = port.track { store.selection = .track(id); return }
        guard let from = selected else { store.say("Drag from a track's socket to this one to plug it in."); return }
        if port.master { store.setGroup(nil, for: [from]) }
        else if let name = store.project.group(port.bus)?.name { store.setGroup(name, for: [from]) }
    }
}

/// Lays a strip out: tall (controls above and below the fader) or compact (fader on the left, controls in a column beside it).
private struct StripLayout<Top: View, Meter: View, Bottom: View>: View {
    let compact: Bool
    let reading: String
    @ViewBuilder let top: Top
    @ViewBuilder let meter: Meter
    @ViewBuilder let bottom: Bottom
    var body: some View {
        let db = Text(reading).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85)).frame(height: 14)
        if compact {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 5) {
                    HStack(alignment: .bottom, spacing: 7) { meter }.frame(maxHeight: .infinity)
                    db.fixedSize()
                }
                VStack(spacing: 6) {
                    top
                    bottom
                    Spacer(minLength: 0)
                }
                .frame(width: stripWidth - 14)
            }
            .frame(maxHeight: .infinity)
        } else {
            top
            HStack(alignment: .bottom, spacing: 7) { meter }.frame(maxHeight: .infinity)
            db
            bottom
        }
    }
}

private struct ChannelStrip: View {
    @Environment(Store.self) private var store
    let track: Track
    var compact = false
    @State private var showDuck = false
    @State private var showRoom = false

    private func edit(_ change: @escaping (inout Track) -> Void) {
        store.mutate { p in if let i = p.trackIndex(track.id) { change(&p.tracks[i]) } }
    }

    var body: some View {
        let p = store.project
        let bus = p.group(track.groupID)
        let pre = track.fxBeforeFader == true
        let effects = (track.plugins ?? []).count
        StripShell(color: track.kind.color, symbol: track.kind.symbol, name: track.name, compact: compact, selected: store.selection == .track(track.id),
                   dim: track.mute || bus?.mute == true) {
          StripLayout(compact: compact, reading: Slide.decibels(track.volume)) {
            // Pan. On a spatial track it is the left–right position in the room.
            VStack(spacing: 2) {
                Slide(value: track.spatial ? track.position.x : track.pan, range: -1...1, tint: Theme.secondary, reset: 0, label: Slide.side, begin: { store.beginGesture() }) { v in
                    let x = abs(v) < 0.04 ? 0 : v
                    store.live { p in
                        guard let i = p.trackIndex(track.id) else { return }
                        if p.tracks[i].spatial { p.tracks[i].position.x = x } else { p.tracks[i].pan = x }
                    }
                }
                .frame(width: stripWidth - 20)
                Button { showRoom.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: track.spatial ? "cube.fill" : "cube").font(.system(size: 8.5, weight: .semibold))
                        Text(Slide.side(track.spatial ? track.position.x : track.pan)).font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(track.spatial ? Theme.accent : Theme.tertiary)
                    .frame(width: stripWidth - 20, height: 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hint("Room panner: place this track around and above the listener, as an object")
                .popover(isPresented: $showRoom, arrowEdge: .top) { RoomPanel(track: track) }
            }
            .frame(height: 34)
            HStack(spacing: 6) {
                StripChip(label: "M", on: track.mute, tint: Theme.danger, help: "Mute") { edit { $0.mute.toggle() } }
                StripChip(label: "S", on: track.solo, help: "Solo") { edit { $0.solo.toggle() } }
            }
          } meter: {
                Fader(value: track.volume, tint: track.kind.color, begin: { store.beginGesture() }) { v in
                    store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].volume = v } }
                }
                LevelBar(level: store.player.trackLevels[track.id] ?? 0)
          } bottom: {
            // Where the effects sit against the fader.
            HStack(spacing: 6) {
                StripChip(label: "Pre", on: pre, help: "Effects before the fader: the fader only changes the level. \(effects == 0 ? "This track has no effects yet." : "")") { edit { $0.fxBeforeFader = true } }
                StripChip(label: "Post", on: !pre, tint: Color.white.opacity(0.75), help: "Effects after the fader: pushing the fader drives the effects harder.") { edit { $0.fxBeforeFader = nil } }
            }
            // What it ducks under.
            Button { showDuck.toggle() } label: {
                StripLabel(text: track.duck == nil ? "Duck" : "Duck \(String(format: "%.0f", track.duck!.depth))", symbol: "arrow.down.to.line.compact", on: track.duck != nil)
            }
            .buttonStyle(PressStyle(scale: 0.95))
            .hint("Sidechain: dip this track while another one is heard")
            .onChange(of: store.peek) { _, v in if v == "duck", store.selection == .track(track.id) { showDuck = true; store.peek = nil } }
            .popover(isPresented: $showDuck, arrowEdge: .top) { DuckPanel(track: track) }
            // Where it is sent.
            Menu {
                Toggle("Master", isOn: Binding(get: { bus == nil }, set: { if $0 { store.setGroup(nil, for: [track.id]) } }))
                if !(p.groups ?? []).isEmpty {
                    Section("Buses") {
                        ForEach(p.groups ?? []) { g in
                            Toggle(g.name, isOn: Binding(get: { bus?.id == g.id }, set: { if $0 { store.setGroup(g.name, for: [track.id]) } }))
                        }
                    }
                }
                Divider()
                Button("New Bus…") {
                    if let name = Ask.text("Name the bus", info: "Tracks sent to a bus share one fader, mute and solo, and can share one sound.", value: "Bus \((p.groups ?? []).count + 1)") {
                        store.setGroup(name, for: [track.id])
                    }
                }
            } label: {
                StripLabel(text: bus?.name ?? "Master", symbol: "arrow.right")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .hint("Output: straight to the master, or through a bus")
          }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .track(track.id) }
    }
}

/// A bus: the tracks sent to it share its fader, mute and solo, and one sound if it has one.
private struct BusStrip: View {
    @Environment(Store.self) private var store
    let group: TrackGroup
    var compact = false
    @State private var showSound = false

    var body: some View {
        let members = store.project.tracks.filter { $0.groupID == group.id }
        let level = members.map { store.player.trackLevels[$0.id] ?? 0 }.max() ?? 0
        let sound = group.plugins?.first { $0.preset != nil }?.preset
        StripShell(color: Color(white: 0.78), symbol: "arrow.triangle.merge", name: group.name, compact: compact, selected: store.selection == .group(group.id), dim: group.mute) {
          StripLayout(compact: compact, reading: Slide.decibels(group.volume)) {
            Text("\(members.count) track\(members.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(Theme.tertiary).frame(height: 34)
            HStack(spacing: 6) {
                StripChip(label: "M", on: group.mute, tint: Theme.danger, help: "Mute the bus") { store.editGroup(group.id) { $0.mute.toggle() } }
                StripChip(label: "S", on: group.solo, help: "Solo the bus") { store.editGroup(group.id) { $0.solo.toggle() } }
            }
          } meter: {
                Fader(value: group.volume, tint: Color(white: 0.78), begin: { store.beginGesture() }) { v in
                    store.editGroup(group.id, undoable: false) { $0.volume = v }
                }
                LevelBar(level: level)
          } bottom: {
            Button { showSound.toggle() } label: { StripLabel(text: sound ?? "Sound", symbol: "wand.and.stars", on: sound != nil) }
                .buttonStyle(PressStyle(scale: 0.95))
                .hint("One sound for everything on this bus. Tracks placed as objects in the room skip it.")
                .popover(isPresented: $showSound, arrowEdge: .top) {
                    PresetList(current: sound) { preset in
                        store.applyPreset(preset, toGroup: group.id)
                        showSound = false
                    }
                }
            Menu {
                Button("Rename…") {
                    if let name = Ask.text("Rename the bus", info: "", value: group.name) { store.editGroup(group.id) { $0.name = name } }
                }
                Button("Remove the Bus") { store.ungroup(group.id) }
            } label: { StripLabel(text: "Bus", symbol: "ellipsis") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .hint("Rename or remove this bus. Removing it sends its tracks to the master.")
            StripLabel(text: "Master", symbol: "arrow.right").opacity(0.55).hint("A bus plays into the master")
          }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .group(group.id) }
    }
}

private struct MasterStrip: View {
    @Environment(Store.self) private var store
    var compact = false
    var body: some View {
        let v = store.project.masterVolume ?? 0
        StripShell(color: Color.white.opacity(0.85), symbol: "slider.horizontal.3", name: "Master", width: stripWidth + 12, compact: compact) {
            StripLayout(compact: compact, reading: Slide.decibels(v)) {
                // Empty where a track has pan, mute and solo, so the faders line up across the mixer.
                Color.clear.frame(height: 34)
                Color.clear.frame(height: rowHeight)
            } meter: {
                Fader(value: v, tint: .white, begin: { store.beginGesture() }) { nv in
                    store.live { $0.masterVolume = abs(nv) < 0.05 ? nil : nv }
                }
                LevelBar(level: store.player.masterL)
                LevelBar(level: store.player.masterR)
            } bottom: {
                Color.clear.frame(height: rowHeight)
                Color.clear.frame(height: rowHeight)
                Color.clear.frame(height: rowHeight)
            }
        }
    }
}

/// The room panner for one track: where it sits around and above the listener.
private struct RoomPanel: View {
    @Environment(Store.self) private var store
    let track: Track
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Place \(track.name)").font(.system(size: 13, weight: .semibold))
            Toggle("An object in the room", isOn: Binding(get: { track.spatial }, set: { v in
                store.mutate { p in if let i = p.trackIndex(track.id) { p.tracks[i].spatial = v } }
            }))
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            if track.spatial {
                PanPad(position: track.position, color: track.kind.color,
                       speakers: store.project.format == .binaural ? Array(0..<12) : store.project.format.channels,
                       begin: { store.beginGesture() }) { x, y in
                    store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].position.x = x; p.tracks[i].position.y = y } }
                }
                .frame(width: 228, height: 228)
                Field(title: "Height", value: String(format: "%.2f", track.position.z)) {
                    Slide(value: track.position.z, range: 0...1, reset: 0, begin: { store.beginGesture() }) { v in
                        store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].position.z = v } }
                    }
                }
                if store.player.monitor == .stereo {
                    Caption("Switch monitoring to Spatial to hear depth and height. In Stereo only left and right are heard.")
                }
            } else {
                Caption("Off: the track is part of the stereo bed and only pans left and right. On: it becomes an object you place anywhere around and above the listener, and it is exported as one in the Atmos file.")
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

/// Sidechain for one track: what it listens to, how far it dips, and the finer way that lowers only the clashing frequencies.
private struct DuckPanel: View {
    @Environment(Store.self) private var store
    let track: Track
    @State private var carve = 9.0

    var body: some View {
        let p = store.project
        let others = p.tracks.filter { $0.id != track.id }
        let source = track.duck?.source
        VStack(alignment: .leading, spacing: 10) {
            Text("Duck \(track.name)").font(.system(size: 13, weight: .semibold))
            Text("Listens to").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            Menu {
                Toggle("Nothing (off)", isOn: Binding(get: { track.duck == nil }, set: { if $0 { Task { await store.setDucking(track.id, on: false) } } }))
                Toggle("Every voice", isOn: Binding(get: { track.duck != nil && source == nil }, set: { if $0 { Task { await store.setDucking(track.id, on: true, source: .some(nil)) } } }))
                if !others.isEmpty {
                    Section("One track") {
                        ForEach(others) { t in
                            Toggle(t.name, isOn: Binding(get: { source == t.id }, set: { if $0 { Task { await store.setDucking(track.id, on: true, source: .some(t.id)) } } }))
                        }
                    }
                }
            } label: {
                HStack {
                    Text(track.duck == nil ? "Nothing (off)" : (p.tracks.first { $0.id == source }?.name ?? "Every voice")).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            if let duck = track.duck {
                Field(title: "Dip", value: String(format: "%.0f dB", duck.depth)) {
                    Slide(value: duck.depth, range: 3...18, reset: 9, begin: { store.beginGesture() }) { v in
                        let old = duck.depth
                        store.live { p in
                            guard let i = p.trackIndex(track.id) else { return }
                            p.tracks[i].duck?.depth = v
                            let key = AutoParam.volume.rawValue
                            p.tracks[i].automation[key] = p.tracks[i].automation[key]?.map { k in
                                var k = k
                                if abs(k.value + old) < 0.01 { k.value = -v }
                                return k
                            }
                        }
                    }
                }
                Button("Listen Again") { Task { await store.setDucking(track.id, on: true) } }.buttonStyle(PillButtonStyle())
            }
            Caption("The whole track dips while the other is heard. The dips are points in its Volume lane, so you can move them. Listen again after the other track changes.")
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("Or lower only what clashes").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            Field(title: "Most it lowers", value: String(format: "%.0f dB", carve)) {
                Slide(value: carve, range: 3...18, reset: 9, begin: {}) { carve = $0 }
            }
            Button("Make Room with EQ") { Task { await store.carveForVoice(track.id, maxCut: carve, source: source) } }.buttonStyle(PillButtonStyle())
            Caption("Follows \(p.tracks.first { $0.id == source }?.name ?? "the voice") moment by moment: many times a second it lowers only the frequencies the other sound is using just then, and leaves the rest alone. Each clip gets a new take; the take before it is the original.")
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// A one-line question in a small window.
@MainActor enum Ask {
    static func text(_ title: String, info: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
