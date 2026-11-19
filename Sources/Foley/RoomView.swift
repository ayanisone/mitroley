import SwiftUI
import SceneKit

/// What the room window shows for one spatial track.
struct RoomDot: Identifiable {
    var id: UUID
    var name: String
    var color: NSColor
    var now: Vec3
    var past: [Vec3]
    var future: [Vec3]
    var level: Double       // 0…1 meter position
    var silent: Bool
}

enum Speakers {
    /// Same order the 7.1.4 export uses.
    static let names = ["L", "R", "C", "LFE", "Lrs", "Rrs", "Lss", "Rss", "Ltf", "Rtf", "Ltr", "Rtr"]
    static let places: [Vec3] = [
        Vec3(x: -1, y: 1, z: 0), Vec3(x: 1, y: 1, z: 0), Vec3(x: 0, y: 1, z: 0), Vec3(x: -0.45, y: 1, z: -0.3),
        Vec3(x: -1, y: -1, z: 0), Vec3(x: 1, y: -1, z: 0), Vec3(x: -1, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0),
        Vec3(x: -0.6, y: 0.5, z: 1), Vec3(x: 0.6, y: 0.5, z: 1), Vec3(x: -0.6, y: -0.5, z: 1), Vec3(x: 0.6, y: -0.5, z: 1),
    ]
    /// Left to right as drawn in the meter strip.
    static let meterOrder = [0, 2, 1, 6, 7, 4, 5, 8, 9, 10, 11, 3]

    /// How much signal each speaker is getting right now, from the same panner the 7.1.4 export uses.
    @MainActor static func levels(_ store: Store) -> [Double] {
        let p = store.project, t = store.player.time, anySolo = p.anySolo
        var power = [Double](repeating: 0, count: 12)
        for tr in p.tracks {
            let level = Double(store.player.trackLevels[tr.id] ?? 0)
            guard level > 0.00005 else { continue }
            let m = p.mix(for: tr, at: t, anySolo: anySolo)
            var g = [Double](repeating: 0, count: 12)
            if tr.spatial {
                g = Exporter.pan714(m.position).map(Double.init)
            } else {
                let a = (min(1, max(-1, m.pan)) + 1) / 2 * Double.pi / 2
                g[0] = cos(a); g[1] = sin(a)
            }
            // The room's reverb wraps around: front, sides, rears and a little overhead.
            let wet = min(1, m.sends.values.reduce(0, +))
            for (c, k) in [(0, 0.8), (1, 0.8), (6, 0.45), (7, 0.45), (4, 0.3), (5, 0.3), (8, 0.3), (9, 0.3), (10, 0.2), (11, 0.2)] { g[c] += wet * k }
            g[3] += tr.lfeSend * 0.316
            for c in 0..<12 { power[c] += pow(level * g[c], 2) }
        }
        return p.format.fold(power: power).map { min(1, max(0, (linearToDb($0.squareRoot()) + 54) / 54)) }
    }
}

/// A window with the room in 3D: drag to orbit, pinch or scroll to zoom. Objects move with the playhead,
/// speakers light up with the signal they receive, and the strip underneath meters all twelve channels.
struct RoomView: View {
    @Environment(Store.self) private var store
    @State private var view = RoomScene.Camera.threeQuarter
    @State private var viewTick = 0
    @AppStorage("roomPinned") private var pinned = true
    @AppStorage("roomMeterHeight") private var meterHeight = 210.0
    @State private var meterStart: Double?
    private let trail = 2.0

    private func dots() -> [RoomDot] {
        let p = store.project, t = store.player.time, anySolo = p.anySolo
        return p.tracks.filter(\.spatial).map { tr in
            func pos(_ at: Double) -> Vec3 { p.mix(for: tr, at: min(p.duration, max(0, at)), anySolo: anySolo).position }
            let steps = Array(stride(from: 0.0, through: trail, by: 0.08))
            let playing = tr.clips.contains { t >= $0.start && t < $0.end }
            let level = Double(store.player.trackLevels[tr.id] ?? 0)
            return RoomDot(id: tr.id, name: tr.name, color: NSColor(tr.kind.color), now: pos(t),
                           past: steps.map { pos(t - $0) }, future: steps.map { pos(t + $0) },
                           level: min(1, max(0, (linearToDb(level) + 54) / 54)),
                           silent: !playing || p.mix(for: tr, at: t, anySolo: anySolo).gain <= 0.0001)
        }
    }

    var body: some View {
        let list = dots()
        let channels = Speakers.levels(store)
        var selected: UUID?
        if case .track(let id) = store.selection { selected = id }
        return VStack(spacing: 0) {
            RoomScene(dots: list, channels: channels, shown: store.project.format.channels, selected: selected, camera: view, cameraTick: viewTick)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        Button { viewTick += 1 } label: {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.07), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressStyle(scale: 0.92))
                        .help("Reset the view (double-click the room)")
                        Menu {
                            ForEach(MixFormat.allCases) { f in
                                Toggle(isOn: Binding(get: { f == store.project.format }, set: { if $0 { store.setFormat(f) } })) {
                                    Text(f.title)
                                    Text(f.detail)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(store.project.format.title).font(.system(size: 11.5, weight: .semibold))
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("What the session is mixed for. It decides which speakers and meters are shown here: Stereo and Binaural have two, 5.1 has six, 7.1.4 has twelve.")
                        SegmentedPill(options: [(RoomScene.Camera.threeQuarter, "3D"), (.front, "Front"), (.top, "Top"), (.side, "Side")],
                                      selection: view, segmentWidth: 52, height: 24, size: 11.5) { view = $0; viewTick += 1 }
                        Button { pinned.toggle() } label: {
                            Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(pinned ? Theme.accent : Theme.secondary)
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.07), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressStyle(scale: 0.92))
                        .help("Keep the Room in front of the main window")
                    }
                    .padding(12)
                }
                .overlay(alignment: .topLeading) {
                    Text(list.isEmpty ? "No spatial tracks yet. Turn on “Spatial object” for a track to see it here."
                                      : "Drag to look around · pinch or scroll to zoom · double-click to reset")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).padding(14)
                }
            // Drag this line to give the meters more or less room.
            Rectangle().fill(Theme.line).frame(height: 1)
                .overlay(Rectangle().fill(Color.clear).frame(height: 10).contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if meterStart == nil { meterStart = meterHeight }
                            meterHeight = min(460, max(130, (meterStart ?? meterHeight) - Double(g.translation.height)))
                        }
                        .onEnded { _ in meterStart = nil }))
            HStack(alignment: .top, spacing: 0) {
                ChannelMeters(levels: channels, format: store.project.format)
                Rectangle().fill(Theme.line).frame(width: 1)
                // Scrolls when the strip is short, so it never spills up over the room.
                ScrollView { RoomLoudness() }
                    .frame(width: 216)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rectangle().fill(Theme.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(list) { d in
                            Button { store.selection = .track(d.id) } label: {
                                HStack(spacing: 7) {
                                    Circle().fill(Color(nsColor: d.color).opacity(d.silent ? 0.35 : 1)).frame(width: 8, height: 8)
                                    Text(d.name).font(.system(size: 12, weight: selected == d.id ? .semibold : .regular))
                                        .foregroundStyle(d.silent ? Theme.tertiary : Color.white).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(String(format: "%+.2f  %+.2f  %.2f", d.now.x, d.now.y, d.now.z))
                                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle(scale: 0.97))
                        }
                    }
                    .padding(14)
                }
                .frame(width: 280)
            }
            .frame(height: meterHeight)
            .clipped()
            .background(Theme.panel)
        }
        .background(Theme.bg)
        .frame(minWidth: 820, minHeight: 560)
        // Pinned, the room floats over the nearly full-screen main window instead of dropping behind it on the first click there.
        .background(WindowAccessor { [pinned] w in
            w.level = pinned ? .floating : .normal
            // Pinned, it floats over mitroley only: it steps aside while another app is in front.
            w.hidesOnDeactivate = pinned
            if w.frameAutosaveName != "room" { w.setFrameAutosaveName("room") }
        })
    }
}

/// One meter per speaker of the session's format, on a dB scale, with a peak marker that holds for a moment.
struct ChannelMeters: View {
    let levels: [Double]
    var format = MixFormat.atmos714
    /// Highest recent level per channel, and when it was reached.
    @State private var holds = [Double](repeating: 0, count: 12)
    @State private var heldAt = [Date](repeating: .distantPast, count: 12)

    private static let floor = -54.0
    private static let marks: [Double] = [0, -6, -12, -20, -30, -40, -54]
    private static let green = Color(red: 0.36, green: 0.82, blue: 0.32)
    private static let yellow = Color(red: 0.93, green: 0.78, blue: 0.2)
    private static let orange = Color(red: 0.96, green: 0.52, blue: 0.16)

    private var groups: [(String, [Int])] {
        let all: [(String, [Int])] = [("Front", [0, 2, 1]), (format == .surround51 ? "Surround" : "Side", [6, 7]), ("Rear", [4, 5]), ("Overhead", [8, 9, 10, 11]), ("Sub", [3])]
        let has = Set(format.channels)
        return all.map { ($0.0, $0.1.filter(has.contains)) }.filter { !$0.1.isEmpty }
    }
    private func name(_ c: Int) -> String {
        format == .surround51 && c == 6 ? "Ls" : format == .surround51 && c == 7 ? "Rs" : Speakers.names[c]
    }
    /// 0…1 up the meter for a level in dB.
    private static func unit(_ db: Double) -> CGFloat { CGFloat(min(1, max(0, (db - floor) / -floor))) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The scale.
            GeometryReader { geo in
                // Fewer numbers when the meter is short, so they never run into each other.
                let marks: [Double] = geo.size.height > 150 ? Self.marks : geo.size.height > 90 ? [0, -12, -30, -54] : [0, -54]
                ForEach(marks, id: \.self) { m in
                    Text(m == 0 ? "0" : String(format: "%.0f", m))
                        .font(.system(size: 8.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.tertiary)
                        .frame(width: 22, alignment: .trailing)
                        .position(x: 11, y: geo.size.height * (1 - Self.unit(m)))
                }
            }
            .frame(width: 22)
            .padding(.bottom, 34)
            ForEach(groups, id: \.0) { group in
                VStack(spacing: 6) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(group.1, id: \.self) { c in
                            VStack(spacing: 5) {
                                bar(c)
                                Text(name(c)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(levels[c] > 0.02 ? Color.white : Theme.tertiary)
                                    .frame(width: 26)
                            }
                        }
                    }
                    Text(group.0.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: levels) { _, now in
            let t = Date()
            for c in 0..<min(12, now.count) {
                if now[c] >= holds[c] { holds[c] = now[c]; heldAt[c] = t }
                else if t.timeIntervalSince(heldAt[c]) > 1.2 { holds[c] = max(now[c], holds[c] - 0.02) }
            }
        }
        .help("How much signal each speaker of this session's format is getting right now, in dB below full scale, worked out with the same panner and fold-downs the exports use. The small bar is the highest level of the last second or so.")
    }

    private func bar(_ c: Int) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let level = CGFloat(levels[c]), hold = CGFloat(holds[c])
            let y20 = h * (1 - Self.unit(-20)), y6 = h * (1 - Self.unit(-6))
            ZStack(alignment: .bottom) {
                // The dim track shows the zones; the bright fill shows the signal.
                zones(h: h, y20: y20, y6: y6).opacity(0.22)
                zones(h: h, y20: y20, y6: y6)
                    .mask(alignment: .bottom) { Rectangle().frame(height: max(0, h * level)) }
                if hold > 0.02 {
                    let db = Double(hold) * -Self.floor + Self.floor
                    RoundedRectangle(cornerRadius: 1)
                        .fill(db > -6 ? Self.orange : db > -20 ? Self.yellow : Self.green)
                        .frame(height: 3)
                        .offset(y: -(h * hold - 1.5))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .animation(.linear(duration: 0.06), value: level)
        }
        .frame(width: 13)
    }

    private func zones(h: CGFloat, y20: CGFloat, y6: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Self.orange).frame(height: max(0, y6))
            Rectangle().fill(Self.yellow).frame(height: max(0, y20 - y6))
            Rectangle().fill(Self.green)
        }
    }
}

/// Loudness in the Room window: what you are hearing now, and the full mix in each format once measured.
struct RoomLoudness: View {
    @Environment(Store.self) private var store
    @State private var measuring = false
    @State private var rows: [MixMeasure] = []
    @State private var problem: String?

    var body: some View {
        let m = store.player.loudness
        VStack(alignment: .leading, spacing: 8) {
            Text(store.player.monitor == .spatial ? "YOU HEAR · BINAURAL" : "YOU HEAR · STEREO")
                .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(m.integrated.map { String(format: "%.1f", $0) } ?? "–.–")
                    .font(.system(size: 24, weight: .medium, design: .rounded).monospacedDigit())
                Text("LUFS").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            HStack(spacing: 10) {
                value("Moment", m.momentary)
                value("Short", m.shortTerm)
                value("Peak", m.truePeak)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Text("FULL MIX").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.tertiary)
                Spacer()
                Button(measuring ? "Measuring" : "Measure") { measure() }.buttonStyle(PillButtonStyle()).disabled(measuring)
            }
            if let problem { Text(problem).font(.system(size: 10.5)).foregroundStyle(Theme.danger).lineLimit(3) }
            if rows.isEmpty && problem == nil {
                Text("Renders the session and reads the loudness of the 7.1.4 (what an Atmos renderer plays), the 5.1 and the stereo versions.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { r in
                HStack {
                    Text(r.name).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(r.lufs.map { String(format: "%.1f", $0) } ?? "silent").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    Text(String(format: "%.1f", r.truePeak)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .help("Left number: integrated loudness in LUFS. Right number: true peak in dBTP. The top reading follows playback; reset it from the master effects' loudness meter.")
    }

    private func value(_ title: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v.map { String(format: "%.1f", $0) } ?? "–").font(.system(size: 11.5, weight: .medium).monospacedDigit())
            Text(title.uppercased()).font(.system(size: 7.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.tertiary)
        }
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

// MARK: - The 3D scene

struct RoomScene: NSViewRepresentable {
    enum Camera: Hashable { case threeQuarter, front, top, side }
    let dots: [RoomDot]
    let channels: [Double]
    var shown: [Int] = Array(0..<12)
    let selected: UUID?
    let camera: Camera
    let cameraTick: Int

    // Room size in scene units. Ear level is y = 0; the floor sits a little below it.
    static let half: CGFloat = 2.2, ceiling: CGFloat = 1.7, floor: CGFloat = -0.75

    static func point(_ v: Vec3) -> SCNVector3 {
        SCNVector3(CGFloat(v.x) * half, v.z >= 0 ? CGFloat(v.z) * ceiling : CGFloat(v.z) * 2.2, -CGFloat(v.y) * half)
    }

    /// The camera as a point on a sphere around a fixed target. Nothing can pan it, so the room never leaves the view.
    struct Orbit { var azimuth: CGFloat, elevation: CGFloat, distance: CGFloat }
    static let target = SCNVector3(0, 0.3, 0)

    static func orbit(_ c: Camera) -> Orbit {
        let d = half
        func from(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> Orbit {
            let dy = y - target.y, r = (x * x + dy * dy + z * z).squareRoot()
            return Orbit(azimuth: atan2(x, z), elevation: asin(dy / r), distance: r)
        }
        switch c {
        case .threeQuarter: return from(d * 1.9, d * 1.35, d * 2.6)
        case .front: return from(0, 0.5, d * 3.4)
        // 89°, not 90°: straight down has no defined "up" and the view would flip.
        case .top: return Orbit(azimuth: 0, elevation: 89 * .pi / 180, distance: d * 3.6 - target.y)
        case .side: return from(d * 3.4, 0.5, 0)
        }
    }

    /// Mouse drag orbits, pinch or vertical scroll zooms, double-click resets. No panning.
    final class OrbitView: SCNView {
        var onOrbit: ((CGFloat, CGFloat) -> Void)?
        var onZoom: ((CGFloat) -> Void)?
        var onReset: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { onReset?() } }
        override func mouseDragged(with e: NSEvent) { onOrbit?(-e.deltaX * 0.008, e.deltaY * 0.008) }
        override func scrollWheel(with e: NSEvent) {
            let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
            guard abs(dy) > abs(dx) else { return }
            onZoom?(exp(-dy * (e.hasPreciseScrollingDeltas ? 0.006 : 0.06)))
        }
        override func magnify(with e: NSEvent) { onZoom?(1 / max(0.2, 1 + e.magnification)) }
    }

    final class Coordinator {
        var objects: [UUID: (node: SCNNode, ball: SCNNode, past: SCNNode, future: SCNNode, drop: SCNNode)] = [:]
        var speakers: [SCNNode] = []
        var labels: [SCNNode] = []
        var cam = SCNNode()
        var tick = -1
        var preset = Camera.threeQuarter
        var orbit = RoomScene.orbit(.threeQuarter)
        // Close enough to fill the window, far enough that the whole room still fits.
        let nearest = RoomScene.orbit(.threeQuarter).distance * 0.6, farthest = RoomScene.orbit(.threeQuarter).distance * 1.6

        func place(animated: Bool) {
            let o = orbit, r = o.distance * cos(o.elevation), t = RoomScene.target
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.35 : 0
            if !animated { SCNTransaction.disableActions = true }
            cam.position = SCNVector3(t.x + r * sin(o.azimuth), t.y + o.distance * sin(o.elevation), t.z + r * cos(o.azimuth))
            SCNTransaction.commit()
        }
        func rotate(_ dAz: CGFloat, _ dEl: CGFloat) {
            orbit.azimuth = remainder(orbit.azimuth + dAz, 2 * .pi)
            orbit.elevation = min(89 * .pi / 180, max(-5 * .pi / 180, orbit.elevation + dEl))
            place(animated: false)
        }
        func zoom(_ factor: CGFloat) {
            orbit.distance = min(farthest, max(nearest, orbit.distance * factor))
            place(animated: false)
        }
        func reset() {
            orbit = RoomScene.orbit(preset)
            place(animated: true)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = OrbitView()
        let scene = SCNScene()
        v.scene = scene
        v.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.055, alpha: 1)
        v.allowsCameraControl = false
        v.antialiasingMode = .multisampling4X
        let coordinator = context.coordinator
        v.onOrbit = { coordinator.rotate($0, $1) }
        v.onZoom = { coordinator.zoom($0) }
        v.onReset = { coordinator.reset() }
        let root = scene.rootNode
        let H = Self.half, top = Self.ceiling, bottom = Self.floor

        func flat(_ color: NSColor, emission: NSColor = .black) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.emission.contents = emission
            m.isDoubleSided = true
            return m
        }
        func lines(_ pts: [(SCNVector3, SCNVector3)], _ color: NSColor) -> SCNNode {
            let verts = pts.flatMap { [$0.0, $0.1] }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                                elements: [SCNGeometryElement(indices: (0..<Int32(verts.count)).map { $0 }, primitiveType: .line)])
            g.materials = [flat(color)]
            return SCNNode(geometry: g)
        }
        // Floor grid and the room's edges.
        var grid: [(SCNVector3, SCNVector3)] = []
        for i in 0...8 {
            let u = -H + CGFloat(i) * H / 4
            grid.append((SCNVector3(u, bottom, -H), SCNVector3(u, bottom, H)))
            grid.append((SCNVector3(-H, bottom, u), SCNVector3(H, bottom, u)))
        }
        root.addChildNode(lines(grid, NSColor(white: 1, alpha: 0.09)))
        var edges: [(SCNVector3, SCNVector3)] = []
        for y in [bottom, top] {
            let c = [SCNVector3(-H, y, -H), SCNVector3(H, y, -H), SCNVector3(H, y, H), SCNVector3(-H, y, H)]
            for i in 0..<4 { edges.append((c[i], c[(i + 1) % 4])) }
        }
        for (x, z) in [(-H, -H), (H, -H), (H, H), (-H, H)] { edges.append((SCNVector3(x, bottom, z), SCNVector3(x, top, z))) }
        root.addChildNode(lines(edges, NSColor(white: 1, alpha: 0.28)))
        // Ear-level ring, so heights are easy to read.
        root.addChildNode(lines((0..<4).map { i in
            let c = [SCNVector3(-H, 0, -H), SCNVector3(H, 0, -H), SCNVector3(H, 0, H), SCNVector3(-H, 0, H)]
            return (c[i], c[(i + 1) % 4])
        }, NSColor(white: 1, alpha: 0.1)))
        // Floor and screen.
        let floorNode = SCNNode(geometry: SCNPlane(width: H * 2, height: H * 2))
        floorNode.geometry?.materials = [flat(NSColor(white: 1, alpha: 0.025))]
        floorNode.eulerAngles.x = -.pi / 2
        floorNode.position = SCNVector3(0, bottom - 0.002, 0)
        root.addChildNode(floorNode)
        let screen = SCNNode(geometry: SCNPlane(width: H * 1.25, height: 1.15))
        screen.geometry?.materials = [flat(NSColor(white: 1, alpha: 0.07))]
        screen.position = SCNVector3(0, 0.35, -H + 0.01)
        root.addChildNode(screen)
        // The listener.
        let head = SCNNode(geometry: SCNSphere(radius: 0.13))
        head.geometry?.materials = [flat(NSColor(white: 0.75, alpha: 1))]
        let body = SCNNode(geometry: SCNCone(topRadius: 0.07, bottomRadius: 0.2, height: 0.5))
        body.geometry?.materials = [flat(NSColor(white: 0.4, alpha: 1))]
        body.position = SCNVector3(0, -0.42, 0)
        root.addChildNode(head); root.addChildNode(body)
        // Speakers, each with its name.
        for (i, place) in Speakers.places.enumerated() {
            let sub = i == 3
            let box = SCNNode(geometry: SCNBox(width: sub ? 0.34 : 0.2, height: sub ? 0.34 : 0.28, length: sub ? 0.34 : 0.16, chamferRadius: 0.03))
            box.geometry?.materials = [flat(NSColor(white: 0.22, alpha: 1))]
            box.position = Self.point(place)
            box.look(at: SCNVector3(0, 0, 0))
            root.addChildNode(box)
            context.coordinator.speakers.append(box)
            let label = Self.label(Speakers.names[i], size: 0.13, color: NSColor(white: 1, alpha: 0.5))
            label.position = SCNVector3(box.position.x, box.position.y + (place.z >= 1 ? -0.28 : 0.3), box.position.z)
            root.addChildNode(label)
            context.coordinator.labels.append(label)
        }
        let cam = context.coordinator.cam
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 46
        cam.camera?.zNear = 0.05
        // A look-at constraint keeps the aim on the target even halfway through a preset animation.
        let aim = SCNNode()
        aim.position = Self.target
        root.addChildNode(aim)
        let look = SCNLookAtConstraint(target: aim)
        look.isGimbalLockEnabled = true
        cam.constraints = [look]
        root.addChildNode(cam)
        v.pointOfView = cam
        return v
    }

    static func label(_ text: String, size: CGFloat, color: NSColor) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0)
        t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        t.flatness = 0.2
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        t.materials = [m]
        let inner = SCNNode(geometry: t)
        let (lo, hi) = inner.boundingBox
        inner.position = SCNVector3(-(hi.x - lo.x) / 2 - lo.x, -lo.y, 0)
        let holder = SCNNode()
        holder.addChildNode(inner)
        holder.scale = SCNVector3(size / 10, size / 10, size / 10)
        holder.constraints = [SCNBillboardConstraint()]
        return holder
    }

    private func path(_ pts: [Vec3], _ color: NSColor) -> SCNGeometry? {
        guard pts.count > 1 else { return nil }
        let verts = pts.map(Self.point)
        var idx: [Int32] = []
        for i in 0..<(verts.count - 1) { idx += [Int32(i), Int32(i + 1)] }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        g.materials = [m]
        return g
    }

    func updateNSView(_ v: SCNView, context: Context) {
        guard let root = v.scene?.rootNode else { return }
        let c = context.coordinator
        if c.tick != cameraTick {
            c.tick = cameraTick
            c.preset = camera
            c.reset()
            v.pointOfView = c.cam
        }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for (i, s) in c.speakers.enumerated() where i < channels.count {
            let l = CGFloat(channels[i])
            s.isHidden = !shown.contains(i)
            if i < c.labels.count { c.labels[i].isHidden = s.isHidden }
            s.geometry?.firstMaterial?.diffuse.contents = NSColor(red: 0.22 + 0.78 * l, green: 0.22 + 0.4 * l, blue: 0.22 - 0.1 * l, alpha: 1)
        }
        let live = Set(dots.map(\.id))
        for (id, o) in c.objects where !live.contains(id) { o.node.removeFromParentNode(); o.past.removeFromParentNode(); o.future.removeFromParentNode(); o.drop.removeFromParentNode(); c.objects[id] = nil }
        for d in dots {
            if c.objects[d.id] == nil {
                let node = SCNNode()
                let ball = SCNNode(geometry: SCNSphere(radius: 0.11))
                let m = SCNMaterial(); m.lightingModel = .constant
                ball.geometry?.materials = [m]
                node.addChildNode(ball)
                let label = Self.label(d.name, size: 0.15, color: .white)
                label.position = SCNVector3(0, 0.22, 0)
                node.addChildNode(label)
                let past = SCNNode(), future = SCNNode(), drop = SCNNode()
                for n in [node, past, future, drop] { root.addChildNode(n) }
                c.objects[d.id] = (node, ball, past, future, drop)
            }
            guard let o = c.objects[d.id] else { continue }
            let p = Self.point(d.now)
            o.node.position = p
            o.node.opacity = d.silent ? 0.35 : 1
            let k = CGFloat(0.8 + 0.9 * d.level) * (selected == d.id ? 1.25 : 1)
            o.ball.scale = SCNVector3(k, k, k)
            o.ball.geometry?.firstMaterial?.diffuse.contents = selected == d.id ? d.color.blended(withFraction: 0.35, of: .white) ?? d.color : d.color
            o.past.geometry = path(d.past, d.color.withAlphaComponent(d.silent ? 0.3 : 0.95))
            o.future.geometry = path(d.future, d.color.withAlphaComponent(d.silent ? 0.12 : 0.35))
            // A line down to the floor shows where the object is in the room.
            o.drop.geometry = path([d.now, Vec3(x: d.now.x, y: d.now.y, z: Double(Self.floor / 2.2))], d.color.withAlphaComponent(0.3))
        }
        SCNTransaction.commit()
    }
}

/// Opens the room window. A view, because opening a window needs the environment.
struct RoomButton: View {
    @Environment(\.openWindow) private var openWindow
    var menu = false
    var body: some View {
        if menu {
            Button("Show Room") { openWindow(id: "room") }.keyboardShortcut("r")
        } else {
            Button { openWindow(id: "room") } label: { Image(systemName: "cube.transparent") }
                .help("Room: see where every spatial object is and how it moves (⌘R)")
                .onAppear { if CommandLine.arguments.contains("--room") { openWindow(id: "room") } }
        }
    }
}

/// Lets the store open the Room window (for the voice helper). Lives inside the main window, where the store is available.
struct RoomOpener: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Store.self) private var store
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { store.openRoom = { openWindow(id: "room") } }
    }
}
