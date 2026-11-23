import SwiftUI
import AppKit

struct TimelineView: View {
    @Environment(Store.self) private var store
    @State private var scroll = TimelineScroll()
    @State private var pinch: (zoom: Double, vzoom: Double, time: Double, x: CGFloat, vertical: Bool, base: CGFloat)?
    private var live: ZoomLive { store.zoomLive }
    @State private var settle: Task<Void, Never>?
    @State private var fitWidth: CGFloat = 0
    @State private var refit: Task<Void, Never>?
    @State private var lastHeight = 0.0

    var body: some View {
        GeometryReader { geo in
            let visible = max(300, geo.size.width - Metrics.header - 1)
            let duration = max(1, store.project.duration)
            // The timeline is scaled to the width it last settled at, not the width of this instant: while the window or
            // the side panel is being resized it keeps its scale, and is fitted once when the resizing stops.
            let fit = fitWidth > 0 ? fitWidth : visible
            let pps = Double(fit - 24) / duration * store.zoom
            let contentWidth = CGFloat(store.project.duration * pps) + 24
            let pinned = Metrics.ruler + Metrics.film + Metrics.scene
            let rows = store.project.rows.count + store.project.tracks.reduce(0) { $0 + ($1.lane == nil ? 0 : 1) }
            ZStack(alignment: .topLeading) {
                // One native scroll view for both directions. The ruler strip and the track names float in it.
                TimelineHost(store: store, scroll: scroll, pps: pps, contentWidth: contentWidth) { total, x, option, ended in
                    pinched(total: total, at: x, option: option, ended: ended, pps: pps, visible: fit, duration: duration)
                }
                .clipped()
                TimelineCorner()
                    .frame(width: Metrics.header, height: pinned)
                    .background(Theme.panel)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1).offset(x: 1) }
            }
            .onChange(of: store.vzoom) { _, _ in store.relayoutTimeline?() }
            .onChange(of: rows) { _, _ in store.relayoutTimeline?() }
            // While a pinch is under way the timeline is drawn in one pass at the zoom the fingers have reached.
            .overlay(alignment: .topLeading) {
                ZoomPreview()
                    .frame(width: visible, height: geo.size.height)
                    .clipped()
                    .padding(.leading, Metrics.header + 1)
            }
            .onChange(of: visible, initial: true) { _, v in
                scroll.width = v
                if fitWidth == 0 { fitWidth = v; return }
                refit?.cancel()
                refit = Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    if !Task.isCancelled { fitWidth = v }
                }
            }
        }
        .environment(scroll)
        .environment(live)
        .background(Theme.panel)
    }

    /// A pinch reported by the scroll view. Laying out every clip on every tick of a pinch is too slow, so the pinch
    /// drives a one-pass drawing of the timeline (ZoomPreview), and the real timeline is laid out once when it pauses or ends.
    private func pinched(total: CGFloat, at location: CGFloat, option: Bool, ended: Bool, pps: Double, visible: CGFloat, duration: Double) {
        if pinch == nil {
            let x = max(0, location - Metrics.header - 1)
            pinch = (store.zoom, store.vzoom, Double(scroll.x + x) / pps, x, option, 1)
        }
        guard let start = pinch else { return }
        if ended {
            settle?.cancel()
            commitZoom()
            pinch = nil
            return
        }
        let m = Double(total / start.base)
        if start.vertical {
            // Track height: laid out for real, a few times a second.
            let now = CACurrentMediaTime()
            live.target = min(3, max(0.75, start.vzoom * m))
            if now - lastHeight > 0.1 {
                lastHeight = now
                store.vzoom = live.target
            }
            return
        }
        let zoom = min(40, max(1, start.zoom * m))
        live.target = zoom
        live.pps = Double(visible - 24) / duration * zoom
        // Keep the moment under the pointer under the pointer.
        live.x = max(0, CGFloat(start.time * live.pps) - start.x)
        live.active = true
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let now = pinch else { return }
            commitZoom()
            // Carry on from the new zoom if the fingers are still down.
            pinch = (store.zoom, store.vzoom, now.time, now.x, now.vertical, total)
        }
    }

    /// Lays the real timeline out at the zoom the pinch has reached, scrolled to where the drawing was.
    private func commitZoom() {
        guard let start = pinch else { return }
        if start.vertical {
            if live.target > 0 { store.vzoom = live.target }
        } else if live.active {
            store.zoom = live.target
            store.scrollTimeline?(CGPoint(x: live.x, y: max(0, scroll.y)))
            // The drawing stays up for a moment so the real timeline never shows half laid out.
            Task {
                try? await Task.sleep(nanoseconds: 80_000_000)
                live.active = false
            }
        }
        live.target = 0
    }
}

/// Vertical guide lines behind the tracks: the regular time grid.
struct GridLayer: View {
    @Environment(Store.self) private var store
    @Environment(TimelineScroll.self) private var scroll
    let pps: Double
    static let color = Color(red: 0.42, green: 0.72, blue: 1.0)

    var body: some View {
        if store.showTimeGrid {
            // Drawn for the part of the timeline near the screen, a page at a time, so scrolling does not redraw it.
            let total = CGFloat(store.project.duration * pps) + 24
            let w = scroll.window(start: 0, width: total) ?? (0, min(total, scroll.width))
            let x0 = Double(w.lo)
            let duration = store.project.duration
            let unit = store.gridStep
            Canvas { ctx, size in
                var step = unit
                // Never closer than 7 pt: thin the lines out when zoomed far out.
                var every = 1
                while step * Double(every) * pps < 7 { every *= every == 1 ? 2 : (every == 2 ? 5 : 2); if every > 100000 { break } }
                step *= Double(every)
                let major = max(1, Int((1 / step).rounded()))
                var i = max(0, Int((x0 / pps / step).rounded(.down)))
                while Double(i) * step <= duration + 0.0001 {
                    let x = Double(i) * step * pps - x0
                    if x > size.width { break }
                    let strong = step >= 1 || i % major == 0
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                             with: .color(Self.color.opacity(strong ? 0.22 : 0.09)))
                    i += 1
                }
            }
            .frame(width: w.hi - w.lo)
            .offset(x: w.lo)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Left column

struct TimelineCorner: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SegmentedPill(options: [(EditMode.slip, "Slip"), (EditMode.snap, "Snap"), (EditMode.grid, "Grid")],
                              selection: store.editMode, segmentWidth: 50, height: 24, size: 11.5) { store.editMode = $0 }
                    .help("Slip: clips move freely. Snap: clips pull to scenes, other clips and the playhead. Grid: clips lock to the time grid. Hold ⌘ while dragging to move freely in any mode.")
                Spacer(minLength: 0)
                Menu {
                    Toggle("Scene Lines", isOn: Binding(get: { store.showSceneGrid }, set: { store.showSceneGrid = $0 }))
                    Toggle("Time Grid", isOn: Binding(get: { store.showTimeGrid }, set: { store.showTimeGrid = $0 }))
                    Divider()
                    Picker("Grid Size", selection: Binding(get: { store.gridUnit }, set: { store.gridUnit = $0; store.showTimeGrid = true })) {
                        ForEach(GridUnit.allCases) { u in Text(u.title).tag(u) }
                    }
                    Button("Zoom to Fit") { store.zoom = 1 }
                    Picker("Track Height", selection: Binding(get: { store.vzoom }, set: { store.vzoom = $0 })) {
                        Text("Small").tag(0.75); Text("Medium").tag(1.0); Text("Large").tag(1.6); Text("Extra Large").tag(2.4)
                    }
                } label: {
                    Image(systemName: "grid").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(store.showTimeGrid ? GridLayer.color : Theme.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Grid lines, grid size, zoom and track height")
            }
            .padding(.horizontal, 12)
            .frame(height: Metrics.ruler + Metrics.film)
            HStack {
                Text("SCENES").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
                Spacer()
                Button { store.splitScene(at: store.player.time) } label: {
                    Image(systemName: "scissors").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(PressStyle(scale: 0.88))
                .help("Split the scene at the playhead (⌘B)")
            }
            .padding(.horizontal, 12)
            .frame(height: Metrics.scene)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

struct TrackHeaders: View {
    @Environment(Store.self) private var store
    /// The track being dragged to a new place, and where it would land.
    @State private var moving: UUID?
    @State private var slot: TrackSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.project.rows) { row in
                switch row {
                case .group(let group, _):
                    GroupHeader(group: group)
                case .track(let track):
                    TrackHeader(track: track, moving: moving == track.id,
                                onMove: { y in
                                    moving = track.id
                                    slot = store.trackSlots().min { abs($0.y - y) < abs($1.y - y) }
                                },
                                onDrop: {
                                    if let s = slot { store.moveTrack(track.id, to: s) }
                                    moving = nil
                                    slot = nil
                                })
                    if let param = track.lane {
                        LaneHeader(track: track, param: param)
                    }
                }
            }
            MasterHeader()
            Menu {
                ForEach(TrackKind.allCases) { kind in
                    Button { store.selection = .track(store.addTrack(kind: kind)) } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
                Divider()
                Button { store.groupByKind() } label: { Label("Group Tracks by Kind", systemImage: "rectangle.3.group") }
            } label: {
                Label("Add Track", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .coordinateSpace(.named("trackHeaders"))
        // Where a dragged track will land.
        .overlay(alignment: .topLeading) {
            if let slot {
                Rectangle().fill(Theme.accent).frame(height: 2)
                    .offset(y: slot.y - 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct TrackHeader: View {
    @Environment(Store.self) private var store
    let track: Track
    var moving = false
    /// Called with the pointer's height in the header column while the track is dragged, and once when it is let go.
    var onMove: (CGFloat) -> Void = { _ in }
    var onDrop: () -> Void = {}
    @State private var renaming = false
    @State private var heightStart: Double?
    @State private var dragging = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let selected = store.selection == .track(track.id)
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5).fill(track.kind.color).frame(width: 3, height: 40)
                .padding(.leading, track.groupID == nil ? 0 : 9)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: track.kind.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(track.kind.color)
                        .frame(width: 14)
                    if renaming {
                        TextField("Name", text: Binding(get: { track.name }, set: { v in
                            store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].name = v } }
                        }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit { renaming = false }
                        .onChange(of: nameFocused) { _, on in if !on { renaming = false } }
                        .onAppear { store.beginGesture(); nameFocused = true }
                    } else {
                        Text(track.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .onTapGesture(count: 2) { renaming = true }
                            .help("Double-click to rename")
                    }
                    if track.spatial {
                        Image(systemName: "move.3d").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                            .help("Spatial object")
                    }
                    Spacer(minLength: 2)
                    ChipToggle(label: "M", on: track.mute, tint: Theme.danger) { edit { $0.mute.toggle() } }
                    ChipToggle(label: "S", on: track.solo) { edit { $0.solo.toggle() } }
                }
                HStack(spacing: 8) {
                    Slide(value: track.volume, range: -48...12, tint: track.kind.color, reset: 0, label: Slide.decibels, begin: { store.beginGesture() }) { v in
                        store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].volume = v } }
                    }
                    // Pan: left and right. On a spatial track it moves the sound's left–right position.
                    Slide(value: track.spatial ? track.position.x : track.pan, range: -1...1, tint: Theme.secondary, reset: 0, label: Slide.side, begin: { store.beginGesture() }) { v in
                        let x = abs(v) < 0.04 ? 0 : v
                        store.live { p in
                            guard let i = p.trackIndex(track.id) else { return }
                            if p.tracks[i].spatial { p.tracks[i].position.x = x } else { p.tracks[i].pan = x }
                        }
                    }
                    .frame(width: 46)
                    .help("Pan: \(panLabel). Double-click to centre.")
                    TrackMeter(id: track.id, color: track.kind.color)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: store.rowHeight(track))
        .background(selected ? Theme.raised : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .track(track.id) }
        // Drag the header up or down to move the track. It starts only after 4 pt of vertical travel,
        // so clicks, renaming and the volume slider keep working.
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("trackHeaders"))
            .onChanged { g in
                if !dragging {
                    guard abs(g.translation.height) >= 4, abs(g.translation.height) >= abs(g.translation.width) else { return }
                    dragging = true
                }
                onMove(g.location.y)
            }
            .onEnded { _ in
                if dragging { onDrop() }
                dragging = false
            }, including: renaming ? .subviews : .all)
        .opacity(moving ? 0.4 : 1)
        // Drag the bottom edge to make this track taller or shorter.
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.clear).frame(height: 6).contentShape(Rectangle())
                .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if heightStart == nil { heightStart = Double(store.rowHeight(track)) / store.vzoom; store.beginGesture() }
                        let h = min(320, max(46, (heightStart ?? 62) + Double(g.translation.height) / store.vzoom))
                        store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].height = h } }
                    }
                    .onEnded { _ in heightStart = nil })
        }
        .contextMenu {
            Button("Rename") { renaming = true }
            if track.height != nil { Button("Reset Height") { edit { $0.height = nil } } }
            ForEach(AutoParam.allCases) { p in
                Button("Show \(p.title) Automation") { edit { $0.lane = p } }
            }
            Divider()
            Button("Move up") { store.moveTrack(track.id, -1) }.disabled(!store.canMoveTrack(track.id, -1))
            Button("Move down") { store.moveTrack(track.id, 1) }.disabled(!store.canMoveTrack(track.id, 1))
            Menu("Export This Track") {
                Button("With its effects…") { store.exportTrackAsking(track.id, effects: true) }
                Button("Without effects…") { store.exportTrackAsking(track.id, effects: false) }
            }
            Menu("Group") { GroupMenuItems(track: track) }
            Divider()
            Button("Delete Track", role: .destructive) {
                store.selection = .track(track.id)
                store.deleteSelection()
            }
        }
    }

    private var panLabel: String {
        let v = track.spatial ? track.position.x : track.pan
        return abs(v) < 0.005 ? "centre" : String(format: "%@ %.0f", v < 0 ? "left" : "right", abs(v) * 100)
    }

    private func edit(_ change: @escaping (inout Track) -> Void) {
        store.mutate { p in if let i = p.trackIndex(track.id) { change(&p.tracks[i]) } }
    }
}

/// Reads its level on its own so meters do not redraw the timeline.
struct TrackMeter: View {
    @Environment(Store.self) private var store
    let id: UUID
    let color: Color
    var body: some View {
        let level = store.player.trackLevels[id] ?? 0
        let u = min(1, max(0, (linearToDb(Double(level)) + 54) / 54))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.08))
            Capsule().fill(color.opacity(0.9)).frame(width: 36 * u)
        }
        .frame(width: 36, height: 3)
    }
}

struct LaneHeader: View {
    @Environment(Store.self) private var store
    let track: Track
    let param: AutoParam
    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AutoParam.allCases) { p in
                    Button(p.title) { store.mutate { pr in if let i = pr.trackIndex(track.id) { pr.tracks[i].lane = p } } }
                }
            } label: {
                Text(param.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            if !track.keys(param).isEmpty {
                Button("Clear") {
                    store.mutate { p in if let i = p.trackIndex(track.id) { p.tracks[i].automation[param.rawValue] = nil } }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            }
            Button {
                store.mutate { p in if let i = p.trackIndex(track.id) { p.tracks[i].lane = nil } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(PressStyle(scale: 0.85))
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: Metrics.lane)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - Ruler, filmstrip, playhead

struct RulerView: View {
    @Environment(Store.self) private var store
    let pps: Double
    @State private var drag: RulerDrag?
    @State private var pointer = RulerPointer()

    /// What a drag on the ruler does, decided when it starts.
    private enum RulerDrag {
        case scrub, command
        case mark(Double)
        case edge(fixed: Double)
        case move(offset: Double, length: Double)
    }

    /// Where the pointer last hovered, for the context menu. A plain class so hovering does not redraw the ruler.
    private final class RulerPointer { var x: CGFloat = 0 }

    var body: some View {
        SlicedCanvas(start: 0, width: CGFloat(store.project.duration * pps) + 24) { ctx, size, near in
            let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { $0 * pps >= 64 } ?? 600
            if let r = store.project.loopRange {
                // The loop region: bright while looping is on, faint while it is off.
                let on = store.player.loop
                let band = CGRect(x: r.lowerBound * pps, y: 0, width: (r.upperBound - r.lowerBound) * pps, height: size.height)
                ctx.fill(Path(band), with: .color(Theme.accent.opacity(on ? 0.28 : 0.1)))
                ctx.fill(Path(CGRect(x: band.minX, y: 0, width: band.width, height: 2)), with: .color(Theme.accent.opacity(on ? 1 : 0.4)))
            }
            var t = max(0, (Double(near.lowerBound) / pps / step).rounded(.down) - 1) * step
            while t <= store.project.duration + 0.001 {
                let x = t * pps
                if x > Double(near.upperBound) { break }
                ctx.fill(Path(CGRect(x: x, y: size.height - 7, width: 1, height: 7)), with: .color(.white.opacity(0.25)))
                let label = step < 1 ? String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                                     : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
                ctx.draw(Text(label).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.45)),
                         at: CGPoint(x: x + 4, y: size.height / 2 - 2), anchor: .leading)
                for k in 1..<4 {
                    let mx = (t + step * Double(k) / 4) * pps
                    ctx.fill(Path(CGRect(x: mx, y: size.height - 3, width: 1, height: 3)), with: .color(.white.opacity(0.14)))
                }
                t += step
            }
            if let p = store.loopPending {
                // A loop start waiting for its end: a line with a small flag.
                let x = p * pps
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.accent))
                var flag = Path()
                flag.move(to: CGPoint(x: x + 1, y: 0))
                flag.addLine(to: CGPoint(x: x + 8, y: 3.5))
                flag.addLine(to: CGPoint(x: x + 1, y: 7))
                flag.closeSubpath()
                ctx.fill(flag, with: .color(Theme.accent))
            }
        }
        .frame(height: Metrics.ruler)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                pointer.x = p.x
                (edge(near: p.x) != nil ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            case .ended: NSCursor.arrow.set()
            }
        }
        // Drag moves the playhead, Shift-drag marks a loop, a loop edge resizes it, ⌥-drag inside it moves it; ⌘-click twice sets one.
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let t = time(g.location.x)
                if drag == nil { drag = begin(at: g.startLocation.x) }
                switch drag {
                case .mark(let a):
                    store.setLoop(min(a, t), max(a, t))
                case .edge(let fixed):
                    var lo = min(fixed, t), hi = max(fixed, t)
                    if hi - lo < 0.05 { if t >= fixed { hi = lo + 0.05 } else { lo = hi - 0.05 } }
                    let duration = store.project.duration
                    lo = max(0, lo); hi = min(duration, hi)
                    store.live { $0.loopStart = lo; $0.loopEnd = hi }
                case .move(let offset, let length):
                    let lo = min(max(0, t - offset), max(0, store.project.duration - length))
                    store.live { $0.loopStart = lo; $0.loopEnd = lo + length }
                case .scrub:
                    store.player.seek(t)
                case .command, nil:
                    break
                }
            }
            .onEnded { g in
                switch drag {
                case .mark:
                    if store.project.loopRange == nil { store.clearLoop() }
                case .command:
                    if hypot(g.translation.width, g.translation.height) < 3 { commandClick(at: g.startLocation.x) }
                default:
                    break
                }
                drag = nil
            })
        .help("Drag to move the playhead. ⌘-click twice, or Shift-drag, to set a loop. Drag a loop edge to resize it, ⌥-drag to move it.")
        .contextMenu {
            Button("Set Loop Start Here") { setEdge(time(pointer.x), start: true) }
            Button("Set Loop End Here") { setEdge(time(pointer.x), start: false) }
            Divider()
            Button("Loop Selection") { store.loopSelection() }
            Button("Clear Loop Region") { store.clearLoop() }.disabled(store.project.loopRange == nil)
        }
    }

    private func time(_ x: CGFloat) -> Double { min(store.project.duration, max(0, Double(x) / pps)) }

    /// The loop edge within 6 px of `x`, as the edge that stays put while dragging.
    private func edge(near x: CGFloat) -> Double? {
        guard let r = store.project.loopRange else { return nil }
        let dl = abs(Double(x) - r.lowerBound * pps), du = abs(Double(x) - r.upperBound * pps)
        guard min(dl, du) <= 6 else { return nil }
        return dl <= du ? r.upperBound : r.lowerBound
    }

    private func begin(at x: CGFloat) -> RulerDrag {
        let mods = NSEvent.modifierFlags
        let t = time(x)
        if mods.contains(.command) { return .command }
        if mods.contains(.shift) { store.loopPending = nil; return .mark(t) }
        if mods.contains(.option), let r = store.project.loopRange, r.contains(t) {
            return .move(offset: t - r.lowerBound, length: r.upperBound - r.lowerBound)
        }
        if let fixed = edge(near: x) { return .edge(fixed: fixed) }
        return .scrub
    }

    /// First ⌘-click marks a loop start; the second sets the loop. A second click on the mark cancels it.
    private func commandClick(at x: CGFloat) {
        let t = time(x)
        guard let p = store.loopPending else { store.loopPending = t; return }
        store.loopPending = nil
        if abs(t - p) * pps <= 4 { return }
        setLoop(min(p, t), max(p, t))
    }

    /// From the context menu: moves one edge of the loop, or starts or finishes one.
    private func setEdge(_ t: Double, start: Bool) {
        if let p = store.loopPending {
            if start { store.loopPending = t } else { store.loopPending = nil; setLoop(min(p, t), max(p, t)) }
        } else if let r = store.project.loopRange {
            let other = start ? r.upperBound : r.lowerBound
            setLoop(min(other, t), max(other, t))
        } else if start {
            store.loopPending = t
        } else {
            let from = store.player.time
            setLoop(min(from, t), max(from, t))
        }
    }

    private func setLoop(_ a: Double, _ b: Double) {
        let duration = store.project.duration
        let lo = min(a, max(0, duration - 0.05))
        store.setLoop(lo, max(b, lo + 0.05))
        store.player.loop = true
    }
}

/// Dragging anywhere on the ruler or filmstrip moves the playhead with the pointer.
@MainActor
func scrub(_ store: Store, _ pps: Double) -> some Gesture {
    DragGesture(minimumDistance: 0).onChanged { g in
        store.player.seek(Double(g.location.x) / pps)
    }
}

struct FilmstripView: View {
    @Environment(Store.self) private var store
    let pps: Double
    var body: some View {
        let frames = store.filmstrip
        let width = CGFloat((store.project.video?.duration ?? store.project.duration) * pps)
        HStack(spacing: 0) {
            if frames.isEmpty {
                Rectangle().fill(Theme.lane)
            } else {
                ForEach(frames.indices, id: \.self) { i in
                    Image(nsImage: frames[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(frames.count), height: Metrics.film)
                        .clipped()
                }
            }
        }
        .frame(width: max(1, width), height: Metrics.film, alignment: .leading)
        .opacity(0.8)
        .contentShape(Rectangle())
        .gesture(scrub(store, pps))
        // Clicking the filmstrip also brings up the session's settings.
        .simultaneousGesture(TapGesture().onEnded { store.showSession() })
    }
}

struct PlayheadView: View {
    @Environment(Store.self) private var store
    let pps: Double
    var handle = true
    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: 1.5)
            .overlay(alignment: .top) {
                if handle {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 11, height: 13)
                }
            }
            .offset(x: CGFloat(store.player.time * pps) - 0.75)
            .allowsHitTesting(false)
    }
}

// MARK: - Scenes

struct SceneLane: View {
    @Environment(Store.self) private var store
    let pps: Double

    var body: some View {
        let scenes = store.project.scenes.sorted { $0.start < $1.start }
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.2))
            if scenes.isEmpty {
                Text("No scenes yet. Import a video, or split at the playhead with ⌘B.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 10)
                    .frame(height: Metrics.scene)
            }
            ForEach(Array(scenes.enumerated()), id: \.element.id) { i, scene in
                SceneBlock(scene: scene, next: i + 1 < scenes.count ? scenes[i + 1] : nil,
                           previous: i > 0 ? scenes[i - 1] : nil, pps: pps)
            }
        }
        .frame(height: Metrics.scene)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct SceneBlock: View {
    @Environment(Store.self) private var store
    let scene: SceneRegion
    let next: SceneRegion?
    let previous: SceneRegion?
    let pps: Double
    @State private var origin: Double?

    var body: some View {
        let space = store.project.space(scene.spaceID)
        let color = space?.color ?? Color.white.opacity(0.35)
        let prevColor = previous.flatMap { store.project.space($0.spaceID)?.color } ?? Color.white.opacity(0.35)
        let selected = store.selection == .scene(scene.id)
        let width = max(2, CGFloat((scene.end - scene.start) * pps) - 1)
        // The crossfade into this scene, drawn as a blend from the previous scene's colour.
        let blend = previous == nil ? 0 : min(width * 0.6, CGFloat(scene.transition * pps) / 2)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(selected ? 0.5 : 0.26))
            if blend > 3 {
                LinearGradient(colors: [prevColor.opacity(0.45), prevColor.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: blend)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                if let status = scene.status {
                    Text(status == "new" ? "NEW" : "LONGER")
                        .font(.system(size: 8.5, weight: .bold)).tracking(0.4)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 4).frame(height: 13)
                        .background(Theme.accent, in: Capsule())
                }
                Text(scene.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if let space, width > 150 {
                    Text(space.name).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 7)
            .frame(width: width, alignment: .leading)
            .clipped()
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.85) : Color.clear, lineWidth: 1)
        }
        .frame(width: width, height: Metrics.scene - 6)
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .scene(scene.id) }
        .overlay(alignment: .trailing) {
            if next != nil {
                Rectangle().fill(Color.clear).frame(width: 9).contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if origin == nil { origin = scene.end; store.beginGesture() }
                            guard let origin, let next else { return }
                            var t = origin + Double(g.translation.width) / pps
                            t = min(next.end - 0.1, max(scene.start + 0.1, t))
                            if abs(t - store.player.time) * pps < 7, t != store.player.time { t = store.player.time; Haptics.snap() }
                            store.live { p in
                                if let i = p.scenes.firstIndex(where: { $0.id == scene.id }) { p.scenes[i].end = t }
                                if let j = p.scenes.firstIndex(where: { $0.id == next.id }) { p.scenes[j].start = t }
                            }
                        }
                        .onEnded { _ in origin = nil })
                    .offset(x: 4)
            }
        }
        .offset(x: CGFloat(scene.start * pps), y: 3)
        .contextMenu {
            Button("Split at Playhead") { store.splitScene(at: store.player.time) }
            if scene.status != nil {
                Button("Mark as Done") { store.mutate { p in if let i = p.scenes.firstIndex(where: { $0.id == scene.id }) { p.scenes[i].status = nil } } }
            }
            Button("Delete Scene", role: .destructive) { store.deleteScene(scene.id) }
        }
    }
}

// MARK: - Track lane and clips

struct TrackLane: View {
    @Environment(Store.self) private var store
    let track: Track
    let pps: Double
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(targeted || store.dropTrack == track.id ? track.kind.color.opacity(0.12) : (store.selection == .track(track.id) ? Color.white.opacity(0.045) : Theme.lane))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard store.tool == .marquee else { return }
                        let limit = store.project.duration
                        store.marquee = Marquee(track: track.id, start: min(limit, max(0, Double(g.startLocation.x) / pps)),
                                                end: min(limit, max(0, Double(g.location.x) / pps)))
                    }
                    .onEnded { g in
                        switch store.tool {
                        case .marquee:
                            if abs(g.translation.width) < 3 { store.marquee = nil }
                        case .mute: store.toggleTrack(track.id, solo: false)
                        case .solo: store.toggleTrack(track.id, solo: true)
                        default:
                            guard abs(g.translation.width) < 4, abs(g.translation.height) < 4 else { return }
                            store.selection = .track(track.id)
                            store.player.seek(Double(g.location.x) / pps)
                        }
                    })
            // Scene boundaries carried down as guides.
            SlicedCanvas(start: 0, width: CGFloat(store.project.duration * pps) + 24) { ctx, size, _ in
                if store.showSceneGrid {
                    for s in store.project.scenes where s.start > 0.01 {
                        ctx.fill(Path(CGRect(x: s.start * pps, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.1)))
                    }
                }
                if store.tapTrack == track.id {
                    for t in store.taps {
                        ctx.fill(Path(roundedRect: CGRect(x: t * pps - 1, y: 8, width: 2, height: size.height - 16), cornerRadius: 1), with: .color(Theme.accent))
                    }
                }
            }
            .allowsHitTesting(false)
            ForEach(track.clips) { clip in
                ClipView(clip: clip, track: track, pps: pps)
            }
            ForEach(track.crossfades()) { x in
                CrossfadeView(fade: x, track: track, pps: pps)
            }
            if let m = store.marquee, m.track == track.id {
                let a = min(m.start, m.end), b = max(m.start, m.end)
                Rectangle().fill(Color.white.opacity(0.16))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: max(1, CGFloat((b - a) * pps)))
                    .offset(x: CGFloat(a * pps))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: store.rowHeight(track))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .dropDestination(for: URL.self) { urls, location in
            var t = max(0, Double(location.x) / pps)
            var any = false
            for url in urls where ["wav", "mp3", "m4a", "aif", "aiff", "caf", "flac"].contains(url.pathExtension.lowercased()) {
                if let id = store.importAudio(url, track: track.id, at: t), let l = store.project.locate(clip: id) {
                    t += store.project.tracks[l.track].clips[l.clip].duration
                    store.selection = .clip(id)
                    any = true
                }
            }
            return any
        } isTargeted: { targeted = $0 }
    }
}

/// Where two clips overlap: A's fade-out and B's fade-in drawn as an X. Drag an edge to change its length, the middle to move it.
struct CrossfadeView: View {
    @Environment(Store.self) private var store
    let fade: Crossfade
    let track: Track
    let pps: Double

    private enum Mode { case left, right, slide }
    @State private var origin: Crossfade?
    @State private var mode = Mode.slide
    @State private var moved = false

    private var width: CGFloat { max(1, CGFloat(fade.length * pps)) }
    private var height: CGFloat { store.rowHeight(track) - 8 }
    private var edge: CGFloat { min(6, width / 3) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.45))
            Canvas { ctx, size in
                let w = size.width, h = size.height
                // Positions are in seconds from the overlap's start, so each curve is drawn as it is heard.
                let a = fade.a, b = fade.b
                let aFade = CGFloat(a.fadeOut * pps), bFade = CGFloat(b.fadeIn * pps)
                let aEnd = CGFloat((a.end - fade.start) * pps)
                let out = FadeCurves.curve(from: 0, to: w, height: h) { x in
                    let left = aEnd - x
                    return aFade > 0 && left < aFade ? a.outShape.gain(Float(left / aFade)) : 1
                }
                let into = FadeCurves.curve(from: 0, to: w, height: h) { x in
                    bFade > 0 && x < bFade ? b.inShape.gain(Float(x / bFade)) : 1
                }
                ctx.stroke(out, with: .color(.white.opacity(0.9)), lineWidth: 1.25)
                ctx.stroke(into, with: .color(.white.opacity(0.9)), lineWidth: 1.25)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 0.75)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(drag)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): (p.x <= edge || p.x >= width - edge ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .help("Crossfade: drag an edge to change its length, drag the middle to move it")
        .offset(x: CGFloat(fade.start * pps), y: 4)
        .contextMenu {
            Menu("Shape") {
                ForEach([FadeShape.equalPower, .linear, .sCurve]) { s in
                    Button { store.setCrossfadeShape(a: fade.a.id, b: fade.b.id, shape: s) } label: {
                        let title = s == .linear ? "Equal gain (linear)" : s.title
                        if fade.a.outShape == s && fade.b.inShape == s { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            Button("Remove Crossfade") { store.removeCrossfade(a: fade.a.id, b: fade.b.id) }
        }
    }

    /// Left edge moves B's start, right edge moves A's end, the middle moves both. Fades always match the overlap.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("lanes"))
            .onChanged { g in
                if origin == nil {
                    origin = fade
                    moved = false
                    let x = g.startLocation.x - CGFloat(fade.start * pps)
                    mode = x <= edge ? .left : x >= width - edge ? .right : .slide
                }
                guard let o = origin else { return }
                if !moved {
                    guard abs(g.translation.width) > 2 else { return }
                    moved = true
                    store.beginGesture()
                }
                let dt = Double(g.translation.width) / pps
                let lo = min(o.start, o.earliestStart), hi = max(o.end, o.latestEnd)
                var s = o.start, e = o.end
                switch mode {
                case .left: s = min(o.end - 0.005, max(lo, o.start + dt))
                case .right: e = min(hi, max(o.start + 0.005, o.end + dt))
                case .slide:
                    let d = min(hi - o.end, max(lo - o.start, dt))
                    s = o.start + d
                    e = o.end + d
                }
                let pair = o.applied(bStart: s, aEnd: e)
                store.live { p in Store.put(pair, in: &p) }
            }
            .onEnded { _ in origin = nil }
    }
}

struct ClipView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let clip: Clip
    let track: Track
    let pps: Double

    private enum Mode { case move, left, right, fadeIn, fadeOut, gain, tool }
    @State private var origin: Clip?
    @State private var mode = Mode.move
    @State private var moved = false
    @State private var snapped: Double?
    @State private var cut: Double?
    @State private var hovering = false

    private var selected: Bool { store.selection == .clip(clip.id) }
    private var width: CGFloat { max(4, CGFloat(clip.duration * pps)) }
    private var height: CGFloat { store.rowHeight(track) - 8 }
    private var showsHandles: Bool { width > 40 }
    private var fadeInHandleX: CGFloat { min(width - 5, max(5, CGFloat(clip.fadeIn * pps))) }
    private var fadeOutHandleX: CGFloat { min(width - 5, max(5, width - CGFloat(clip.fadeOut * pps))) }

    /// The fade handle under a point inside the clip, if any. Handles win over the trim edges.
    private func fadeHandle(at x: CGFloat, _ y: CGFloat) -> Mode? {
        guard showsHandles, y < 14 else { return nil }
        let dIn = abs(x - fadeInHandleX), dOut = abs(x - fadeOutHandleX)
        guard min(dIn, dOut) < 9 else { return nil }
        return dIn <= dOut ? .fadeIn : .fadeOut
    }

    var body: some View {
        let color = track.kind.color
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(clip.takes.isEmpty ? (selected ? 0.2 : 0.08) : (selected ? 0.4 : 0.24)))
            WaveformView(clip: clip, url: clip.take.map { store.url(for: $0) }, color: color, pps: pps)
                .padding(.top, 15)
                .padding(.bottom, 3)
            FadeCurves(clip: clip, pps: pps)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 5) {
                if clip.pending > 0 {
                    ProgressView().controlSize(.mini)
                }
                Text(clip.pending > 0 && clip.takes.isEmpty ? "Generating…" : clip.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if clip.takes.count > 1 {
                    Text("\(clip.activeTake + 1)/\(clip.takes.count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.3), in: Capsule())
                }
                if clip.loop {
                    Image(systemName: "repeat").font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 6)
            .frame(width: width, height: 15, alignment: .leading)
            .clipped()
            if clip.error != nil && clip.takes.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.danger)
                    .frame(width: width, height: height)
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.9) : color.opacity(clip.takes.isEmpty ? 0.9 : 0.55),
                              style: StrokeStyle(lineWidth: selected ? 1.5 : 0.75, dash: clip.takes.isEmpty ? [4, 3] : []))
            if (hovering || selected) && showsHandles {
                fadeHandle(x: fadeInHandleX)
                fadeHandle(x: fadeOutHandleX)
            }
        }
        .frame(width: width, height: height)
        .opacity(clip.muted == true ? 0.32 : 1)
        .overlay(alignment: .topTrailing) {
            if clip.muted == true {
                Image(systemName: "speaker.slash.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.9)).padding(4)
            } else if store.tool == .gain, selected, abs(clip.gain) > 0.01 || origin != nil {
                Text(String(format: "%+.1f dB", clip.gain)).font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2).background(Color.black.opacity(0.55), in: Capsule()).padding(3)
            }
        }
        .contentShape(Rectangle())
        .gesture(drag)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hovering = true
                (fadeHandle(at: p.x, p.y) != nil ? NSCursor.pointingHand : p.x < 7 || p.x > width - 7 ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            case .ended:
                hovering = false
                NSCursor.arrow.set()
            }
        }
        .offset(x: CGFloat(clip.start * pps), y: 4)
        .animation(Motion.quick(reduceMotion), value: selected)
        .contextMenu {
            if clip.takes.count > 1 {
                ForEach(clip.takes.indices, id: \.self) { i in
                    Button("Take \(i + 1)") { edit { $0.activeTake = i } }
                }
                Divider()
            }
            Button(clip.loop ? "Stop Looping" : "Loop to Fill") { edit { $0.loop.toggle() } }
            Button("Duplicate") { store.selection = .clip(clip.id); store.duplicateClip() }
            // Not disabled by the playhead's position: reading it here would redraw every clip on every frame of playback.
            Button("Split at Playhead") { store.splitClip(clip.id) }
            Button(clip.muted == true ? "Unmute Clip" : "Mute Clip") { store.toggleClipMute(clip.id) }
            Button("Download Sound…") { store.downloadClipAsking(clip.id) }.disabled(clip.take == nil)
            Button("Crossfade with Neighbour") { store.crossfade(clip.id) }
                .disabled(track.crossfadePartner(of: clip.id) == nil)
            Menu("Fade In") {
                ForEach(FadeShape.allCases) { s in
                    Button { edit { $0.fadeInShape = s == .equalPower ? nil : s } } label: {
                        if clip.inShape == s { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            }
            Menu("Fade Out") {
                ForEach(FadeShape.allCases) { s in
                    Button { edit { $0.fadeOutShape = s == .equalPower ? nil : s } } label: {
                        if clip.outShape == s { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            }
            Button("Remove Fades") { edit { $0.fadeIn = 0; $0.fadeOut = 0 } }
            Menu("Move to Track") {
                ForEach(store.project.tracks.filter { $0.id != track.id }) { t in
                    Button(t.name) {
                        store.mutate { p in
                            guard let l = p.locate(clip: clip.id), let d = p.trackIndex(t.id) else { return }
                            p.tracks[d].clips.append(p.tracks[l.track].clips.remove(at: l.clip))
                        }
                    }
                }
            }
            Button("Delete", role: .destructive) {
                store.selection = .clip(clip.id)
                store.deleteSelection()
            }
        }
    }

    private func fadeHandle(x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
            .offset(x: x - 4, y: 1)
            .allowsHitTesting(false)
    }

    private func edit(_ change: @escaping (inout Clip) -> Void) {
        store.mutate { p in if let l = p.locate(clip: clip.id) { change(&p.tracks[l.track].clips[l.clip]) } }
    }

    /// One gesture: what it does is decided by where the clip was grabbed. Selection happens on pointer-down.
    private var drag: some Gesture {
        // Measured in the timeline's own space: measuring inside the clip would shift as the clip moves and make it shake.
        DragGesture(minimumDistance: 0, coordinateSpace: .named("lanes"))
            .onChanged { g in
                if origin == nil {
                    origin = clip
                    moved = false
                    snapped = nil
                    store.selection = .clip(clip.id)
                    let x = g.startLocation.x - CGFloat(clip.start * pps), y = g.startLocation.y - laneTop() - 4
                    cut = NSEvent.modifierFlags.contains(.command) || store.tool == .scissors ? clip.start + Double(x) / pps : nil
                    switch store.tool {
                    case .pointer:
                        if let m = fadeHandle(at: x, y) { mode = m }
                        else if x < 7 { mode = .left }
                        else if x > width - 7 { mode = .right }
                        else { mode = .move }
                    case .gain: mode = .gain
                    case .fade: mode = x < width / 2 ? .fadeIn : .fadeOut
                    case .scissors, .mute, .solo, .marquee: mode = .tool
                    }
                }
                guard let o = origin else { return }
                if store.tool == .marquee {
                    // Over a clip the marquee still selects time on the track.
                    let limit = store.project.duration
                    store.marquee = Marquee(track: track.id, start: min(limit, max(0, Double(g.startLocation.x) / pps)),
                                            end: min(limit, max(0, Double(g.location.x) / pps)))
                    return
                }
                if mode == .tool { return }
                if !moved {
                    guard abs(mode == .gain ? g.translation.height : g.translation.width) > 2 else { return }
                    moved = true
                    store.beginGesture()
                }
                if mode == .gain {
                    // Up is louder: 1 dB for every 4 points.
                    let db = min(24, max(-48, o.gain - Double(g.translation.height) / 4))
                    store.live { p in
                        guard let l = p.locate(clip: clip.id) else { return }
                        p.tracks[l.track].clips[l.clip].gain = (db * 2).rounded() / 2
                    }
                    return
                }
                if store.tool == .fade {
                    // The fade ends (or begins) where the pointer is.
                    let at = Double(g.location.x) / pps
                    store.live { p in
                        guard let l = p.locate(clip: clip.id) else { return }
                        if mode == .fadeIn { p.tracks[l.track].clips[l.clip].fadeIn = min(o.duration - o.fadeOut, max(0, at - o.start)) }
                        else { p.tracks[l.track].clips[l.clip].fadeOut = min(o.duration - o.fadeIn, max(0, o.end - at)) }
                    }
                    return
                }
                let dt = Double(g.translation.width) / pps
                let source = o.take?.duration ?? o.duration
                // Read everything snapping needs before the edit starts; reading the session mid-edit is not allowed.
                let targets = snapTargets()
                let over = mode == .move ? lane(under: g.location.y) : nil
                store.live { p in
                    guard let l = p.locate(clip: clip.id) else { return }
                    var c = p.tracks[l.track].clips[l.clip]
                    switch mode {
                    case .move:
                        c.start = snap(max(0, o.start + dt), length: o.duration, targets)
                    case .left:
                        let lowest = o.loop ? 0 : max(0, o.start - o.offset)
                        let s = min(o.end - 0.05, max(lowest, snap(o.start + dt, length: 0, targets)))
                        let delta = s - o.start
                        c.start = s
                        c.duration = o.duration - delta
                        var off = o.offset + delta
                        if o.loop, source > 0 { off = off.truncatingRemainder(dividingBy: source); if off < 0 { off += source } }
                        c.offset = max(0, off)
                    case .right:
                        let e = snap(o.end + dt, length: 0, targets)
                        let longest = o.loop ? Double.infinity : source - o.offset
                        c.duration = min(longest, max(0.05, e - o.start))
                    case .fadeIn:
                        c.fadeIn = min(o.duration - o.fadeOut, max(0, o.fadeIn + dt))
                    case .fadeOut:
                        c.fadeOut = min(o.duration - o.fadeIn, max(0, o.fadeOut - dt))
                    case .gain, .tool:
                        break
                    }
                    p.tracks[l.track].clips[l.clip] = c
                }
                store.dropTrack = mode == .move ? over : nil
            }
            .onEnded { _ in
                // ⌘-click without dragging cuts the clip right there.
                if let cut, !moved { store.splitClip(clip.id, at: cut) }
                cut = nil
                if !moved {
                    if store.tool == .mute { store.toggleClipMute(clip.id) }
                    if store.tool == .solo { store.toggleTrack(track.id, solo: true) }
                }
                if store.tool == .marquee, let m = store.marquee, abs(m.end - m.start) * pps < 3 { store.marquee = nil }
                // Dropped on another track: the clip moves there.
                if mode == .move, moved, let to = store.dropTrack, to != track.id {
                    store.live { p in
                        guard let l = p.locate(clip: clip.id), let d = p.trackIndex(to) else { return }
                        p.tracks[d].clips.append(p.tracks[l.track].clips.remove(at: l.clip))
                    }
                }
                store.dropTrack = nil
                origin = nil
            }
    }

    private func spans() -> [(id: UUID, top: CGFloat, bottom: CGFloat)] {
        var top: CGFloat = 0
        var out: [(id: UUID, top: CGFloat, bottom: CGFloat)] = []
        for row in store.project.rows {
            switch row {
            case .group: top += Metrics.group
            case .track(let t):
                out.append((t.id, top, top + store.rowHeight(t)))
                top += store.rowHeight(t) + (t.lane == nil ? 0 : Metrics.lane)
            }
        }
        return out
    }
    private func laneTop() -> CGFloat { spans().first { $0.id == track.id }?.top ?? 0 }

    /// The track whose lane is at height `y` in the timeline.
    private func lane(under y: CGFloat) -> UUID? {
        spans().first { y >= $0.top && y < $0.bottom }?.id ?? track.id
    }

    /// Snaps a time (the clip's start, or its end when `length` > 0 fits better) to scenes, the playhead and other clips.
    private func snapTargets() -> [Double] {
        var targets: [Double] = [0, store.player.time]
        for s in store.project.scenes { targets.append(s.start); targets.append(s.end) }
        for tr in store.project.tracks { for c in tr.clips where c.id != clip.id { targets.append(c.start); targets.append(c.end) } }
        return targets
    }

    private func snap(_ t: Double, length: Double, _ targets: [Double]) -> Double {
        // ⌘ held: move freely whatever the mode.
        if store.editMode == .slip || NSEvent.modifierFlags.contains(.command) { snapped = nil; return t }
        if store.editMode == .grid {
            let step = store.gridStep
            return (t / step).rounded() * step
        }
        let reach = 7 / pps
        var best: (delta: Double, target: Double)?
        for target in targets {
            for edge in length > 0 ? [0, length] : [0] {
                let d = target - (t + edge)
                if abs(d) < reach, abs(d) < abs(best?.delta ?? .infinity) { best = (d, target) }
            }
        }
        guard let best else {
            // Only let go of a snap once the clip is clearly away from it, so it cannot buzz on the edge.
            if let s = snapped, abs(s - t) > reach * 1.6, abs(s - (t + length)) > reach * 1.6 { snapped = nil }
            return t
        }
        if snapped != best.target { snapped = best.target; Haptics.snap() }
        return t + best.delta
    }
}

/// A clip's fades over its full height: shaded above each curve, with the curve drawn on top.
struct FadeCurves: View {
    let clip: Clip
    let pps: Double

    var body: some View {
        SlicedCanvas(start: CGFloat(clip.start * pps), width: CGFloat(clip.duration * pps)) { ctx, size, _ in
            let w = size.width, h = size.height
            let fin = min(w, CGFloat(clip.fadeIn * pps)), fout = min(w, CGFloat(clip.fadeOut * pps))
            if fin >= 4 {
                let curve = FadeCurves.curve(from: 0, to: fin, height: h) { x in clip.inShape.gain(Float(x / fin)) }
                var shade = curve
                shade.addLine(to: CGPoint(x: 0, y: 0))
                shade.closeSubpath()
                ctx.fill(shade, with: .color(.black.opacity(0.35)))
                ctx.stroke(curve, with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            if fout >= 4 {
                let curve = FadeCurves.curve(from: w - fout, to: w, height: h) { x in clip.outShape.gain(Float((w - x) / fout)) }
                var shade = curve
                shade.addLine(to: CGPoint(x: w, y: 0))
                shade.closeSubpath()
                ctx.fill(shade, with: .color(.black.opacity(0.35)))
                ctx.stroke(curve, with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    /// y = height · (1 − gain) from x0 to x1, one point per pixel.
    static func curve(from x0: CGFloat, to x1: CGFloat, height h: CGFloat, gain: (CGFloat) -> Float) -> Path {
        var path = Path()
        var x = x0
        path.move(to: CGPoint(x: x, y: h * CGFloat(1 - gain(x))))
        while x < x1 {
            x = min(x1, x + 1)
            path.addLine(to: CGPoint(x: x, y: h * CGFloat(1 - gain(x))))
        }
        return path
    }
}

/// Draws what will actually be heard: the source from its offset, looped if needed, scaled by gain and fades.
/// Only the part near the screen is drawn, and it is redrawn only when something it shows has changed.
struct WaveformView: View {
    @Environment(TimelineScroll.self) private var scroll
    let clip: Clip
    let url: URL?
    let color: Color
    let pps: Double

    var body: some View {
        let width = CGFloat(clip.duration * pps)
        if width <= 2048 {
            WaveCanvas(clip: clip, url: url, color: color, pps: pps, from: 0).equatable()
        } else if let w = scroll.window(start: CGFloat(clip.start * pps), width: width) {
            WaveCanvas(clip: clip, url: url, color: color, pps: pps, from: w.lo).equatable()
                .frame(width: w.hi - w.lo)
                .offset(x: w.lo)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear
        }
    }
}

struct WaveCanvas: View, Equatable {
    let clip: Clip
    let url: URL?
    let color: Color
    let pps: Double
    /// Where this canvas starts inside the clip, in points.
    let from: CGFloat

    static func == (a: WaveCanvas, b: WaveCanvas) -> Bool {
        let x = a.clip, y = b.clip
        return a.url == b.url && a.pps == b.pps && a.from == b.from && a.color == b.color
            && x.offset == y.offset && x.speed == y.speed && x.loop == y.loop && x.gain == y.gain && x.duration == y.duration
            && x.fadeIn == y.fadeIn && x.fadeOut == y.fadeOut && x.inShape == y.inShape && x.outShape == y.outShape
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Self.path(clip: clip, url: url, pps: pps, from: from, width: size.width, height: size.height), with: .color(color.opacity(0.95)))
        }
        .allowsHitTesting(false)
    }

    /// The waveform's outline for `width` points of a clip starting `from` points in, in a box `height` tall.
    static func path(clip: Clip, url: URL?, pps: Double, from: CGFloat, width: CGFloat, height: CGFloat) -> Path {
        guard let url else { return Path() }
        let peaks = AudioCache.shared.peaks(url)
        guard peaks.count > 1 else { return Path() }
        let rate = AudioCache.peaksPerSecond
        let gain = Float(dbToLinear(clip.gain))
        let mid = height / 2
        let n = Int(width)
        let span = max(1, Int(rate / pps))
        var top: [CGPoint] = []
        top.reserveCapacity(n + 1)
        var x = 0
        while x <= n {
            let rel = Double(from + CGFloat(x)) / pps
            var idx = Int((clip.offset + rel * clip.speed) * rate)
            if clip.loop { idx %= peaks.count } else if idx >= peaks.count { break }
            var m: Float = 0
            var k = 0
            while k < span {
                let j = clip.loop ? (idx + k) % peaks.count : min(peaks.count - 1, idx + k)
                if peaks[j] > m { m = peaks[j] }
                k += 1
            }
            var env: Float = 1
            if clip.fadeIn > 0, rel < clip.fadeIn { env *= clip.inShape.gain(Float(rel / clip.fadeIn)) }
            let left = clip.duration - rel
            if clip.fadeOut > 0, left < clip.fadeOut { env *= clip.outShape.gain(Float(max(0, left) / clip.fadeOut)) }
            let a = CGFloat(min(1, sqrt(m * gain * env)))   // sqrt lifts quiet detail into view
            top.append(CGPoint(x: CGFloat(x), y: mid - max(0.5, a * mid)))
            x += 1
        }
        guard top.count > 1 else { return Path() }
        var path = Path()
        path.move(to: top[0])
        for p in top.dropFirst() { path.addLine(to: p) }
        for p in top.reversed() { path.addLine(to: CGPoint(x: p.x, y: 2 * mid - p.y)) }
        path.closeSubpath()
        return path
    }
}

// MARK: - Automation

struct AutomationLane: View {
    @Environment(Store.self) private var store
    let track: Track
    let param: AutoParam
    let pps: Double
    @State private var dragging: UUID?

    private let pad: CGFloat = 8
    private func y(_ v: Double) -> CGFloat { pad + CGFloat(1 - param.unit(v)) * (Metrics.lane - 2 * pad) }
    private func value(_ y: CGFloat) -> Double { param.value(unit: 1 - Double((y - pad) / (Metrics.lane - 2 * pad))) }

    private var resting: Double {
        switch param {
        case .volume: 0
        case .highCut: track.highCut
        case .lowCut: track.lowCut
        case .send: track.send
        case .x: track.spatial ? track.position.x : track.pan
        case .y: track.position.y
        case .z: track.position.z
        }
    }

    var body: some View {
        let keys = track.keys(param)
        let color = track.kind.color
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.18))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { g in
                    let k = Keyframe(time: max(0, Double(g.location.x) / pps), value: value(g.location.y))
                    store.mutate { p in
                        guard let i = p.trackIndex(track.id) else { return }
                        var list = p.tracks[i].keys(param)
                        list.append(k)
                        p.tracks[i].automation[param.rawValue] = list.sorted { $0.time < $1.time }
                    }
                })
            SlicedCanvas(start: 0, width: CGFloat(store.project.duration * pps) + 24) { ctx, size, near in
                var path = Path()
                if keys.isEmpty {
                    path.move(to: CGPoint(x: 0, y: y(resting)))
                    path.addLine(to: CGPoint(x: size.width, y: y(resting)))
                    ctx.stroke(path, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                } else {
                    // Sampled from the same function the engine uses, so holds and eased curves draw as they sound.
                    var x = max(0, near.lowerBound - 3)
                    path.move(to: CGPoint(x: x, y: y(interpolate(keys, at: Double(x) / pps, log: param.isLog) ?? keys[0].value)))
                    while x <= min(size.width, near.upperBound + 3) {
                        let v = interpolate(keys, at: Double(x) / pps, log: param.isLog) ?? keys[0].value
                        path.addLine(to: CGPoint(x: x, y: y(v)))
                        x += 1.5
                    }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            if keys.isEmpty {
                Text("Double-click to add a point")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 10)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
            ForEach(keys) { k in
                Circle()
                    .fill(dragging == k.id ? Color.white : color)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .scaleEffect(dragging == k.id ? 1.3 : 1)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .position(x: CGFloat(k.time * pps), y: y(k.value))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lane-\(track.id)-\(param.rawValue)"))
                        .onChanged { g in
                            if dragging == nil { dragging = k.id; store.beginGesture() }
                            store.live { p in
                                guard let i = p.trackIndex(track.id) else { return }
                                var list = p.tracks[i].keys(param)
                                guard let j = list.firstIndex(where: { $0.id == k.id }) else { return }
                                list[j].time = min(p.duration, max(0, Double(g.location.x) / pps))
                                list[j].value = value(g.location.y)
                                p.tracks[i].automation[param.rawValue] = list.sorted { $0.time < $1.time }
                            }
                        }
                        .onEnded { _ in dragging = nil })
                    .contextMenu {
                        ForEach([("Straight line to next", nil as String?), ("Hold, then jump", "hold"), ("Ease in and out", "smooth")], id: \.0) { item in
                            Button(item.0) {
                                store.mutate { p in
                                    guard let i = p.trackIndex(track.id) else { return }
                                    var list = p.tracks[i].keys(param)
                                    if let j = list.firstIndex(where: { $0.id == k.id }) { list[j].curve = item.1 }
                                    p.tracks[i].automation[param.rawValue] = list
                                }
                            }
                        }
                        Divider()
                        Button("Delete Point", role: .destructive) {
                            store.mutate { p in
                                guard let i = p.trackIndex(track.id) else { return }
                                let list = p.tracks[i].keys(param).filter { $0.id != k.id }
                                p.tracks[i].automation[param.rawValue] = list.isEmpty ? nil : list
                            }
                        }
                    }
                    .help(param.format(k.value))
            }
        }
        .frame(height: Metrics.lane)
        .coordinateSpace(name: "lane-\(track.id)-\(param.rawValue)")
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
