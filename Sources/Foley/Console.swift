import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// The mixer as a console: narrow strips side by side, divided by hairlines, each with a pan knob, small lit keys, a
/// long-throw fader with a scale beside it and a segmented meter. Colour is kept for what carries meaning: the track's
/// own stripe, a lit key, the meter. The cards it replaces are still there (Settings › Mixer).
enum ConsoleMetrics {
    /// How wide a strip is. Drag the line between two strips to change it; every strip follows.
    static var strip: CGFloat { CGFloat(Size.shared.strip) }
    /// The one width every strip and the cables read. Held in an observed object, so all of them are redrawn together
    /// on every step of a drag; kept between launches.
    @Observable final class Size {
        static let shared = Size()
        /// A width chosen by dragging. nil: the strips share out the width of the mixer, so they fill it from side to side.
        var chosen = UserDefaults.standard.object(forKey: "consoleStripChosen") as? Double {
            didSet { if let chosen { UserDefaults.standard.set(chosen, forKey: "consoleStripChosen") } else { UserDefaults.standard.removeObject(forKey: "consoleStripChosen") } }
        }
        /// The width that fills the mixer just now.
        var fitted = 64.0
        var strip: Double { min(maxStrip, max(chosen == nil ? fitStrip : minStrip, chosen ?? fitted)) }
        /// Works out the width that fills `width` points with this many strips beside the master.
        func fit(width: CGFloat, strips: Int, buses: Bool) {
            let room = Double(width) - 20 - Double(divider) * (buses ? 2 : 1) - 20
            let next = (room / Double(strips + 1) * 2).rounded(.down) / 2
            if abs(next - fitted) > 0.2 { fitted = next }
        }
    }
    /// The narrowest a strip is let go when fitting: under this the keys no longer sit side by side, and the mixer scrolls.
    static let fitStrip = 62.0
    static var master: CGFloat { strip + 20 }
    static let minStrip = 56.0, maxStrip = 150.0
    /// The step between the tracks, the buses and the master.
    static let divider: CGFloat = 10
    static let green = Color(red: 0.36, green: 0.80, blue: 0.56)
    static let amber = Color(red: 0.94, green: 0.74, blue: 0.32)
}

struct ConsoleMixer: View {
    @Environment(Store.self) private var store
    var docked = false
    @AppStorage("showCables") private var cables = true

    var body: some View {
        let p = store.project
        let buses = p.groups ?? []
        VStack(spacing: 0) {
            if p.tracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.vertical.3").font(.system(size: 26)).foregroundStyle(Theme.tertiary)
                    Text("No tracks yet").font(.system(size: 14, weight: .semibold))
                    Text("Add a track on the timeline and its strip appears here.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(p.tracks.enumerated()), id: \.element.id) { i, t in ConsoleTrack(track: t, number: i + 1) }
                            if !buses.isEmpty {
                                Color.clear.frame(width: ConsoleMetrics.divider)
                                ForEach(buses) { g in ConsoleBus(group: g) }
                            }
                            Color.clear.frame(width: ConsoleMetrics.divider)
                            ConsoleMaster()
                        }
                        .frame(maxHeight: .infinity)
                        if cables { Cables(compact: docked, console: true) }
                    }
                    .padding(.horizontal, 10).padding(.top, docked ? 6 : 10).padding(.bottom, 2)
                }
                .glassScrollers()
                // The strips share out the width, so the console runs from one side to the other without being resized by hand.
                .onChange(of: [geo.size.width, CGFloat(p.tracks.count + buses.count), buses.isEmpty ? 0 : 1], initial: true) { _, v in
                    ConsoleMetrics.Size.shared.fit(width: v[0], strips: Int(v[1]), buses: v[2] > 0)
                }
                }
            }
            if !docked {
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    Text("\(p.tracks.count) track\(p.tracks.count == 1 ? "" : "s")\(buses.isEmpty ? "" : ", \(buses.count) bus\(buses.count == 1 ? "" : "es")")").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
                    CablesSwitch()
                    Spacer()
                    Text("Drag a knob or fader up and down · Shift for fine · drag the line between strips to resize them").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 16).frame(height: 32)
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Parts

/// A strip's frame: the colour stripe and name plate on top, then its controls, with a hairline down its right side.
private struct ConsoleShell<Content: View>: View {
    let color: Color
    let name: String
    let number: String
    /// Added to the shared strip width (the master is a little wider).
    var extra: CGFloat = 0
    var selected = false
    var dim = false
    /// A small mark in the number's place, for strips that have no number.
    var symbol: String?
    /// Given a new name when the plate is double-clicked and typed into. nil: this strip cannot be renamed.
    var rename: ((String) -> Void)?
    @ViewBuilder let content: Content
    @State private var start: Double?
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !t.isEmpty, t != name { rename?(t) }
    }

    var body: some View {
        let width = ConsoleMetrics.strip + extra
        VStack(spacing: 5) {
            VStack(spacing: 0) {
                Rectangle().fill(color.opacity(dim ? 0.35 : 0.85)).frame(height: 2)
                // 26 pt tall, so the name sits in the middle of its plate with clear space under the colour line.
                // The name itself is centred in the plate, to the pixel. Its number (a small mark on a bus or the master)
                // hangs off the name's left edge at a fixed 4 pt, so the gap is the same on every strip and the number
                // never pulls the name off centre. The side padding keeps room for it beside a long name.
                Group {
                    if editing {
                        TextField("", text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 10.5, weight: .semibold)).multilineTextAlignment(.center)
                            .focused($typing)
                            .onSubmit { commit() }
                            .onExitCommand { editing = false }
                            .onChange(of: typing) { _, on in if !on, editing { commit() } }
                    } else {
                        Text(name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                            .overlay(alignment: .leading) {
                                Group {
                                    if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .semibold)) }
                                    else { Text(number).font(.system(size: 9, weight: .medium).monospacedDigit()) }
                                }
                                .foregroundStyle(Theme.tertiary)
                                .fixedSize()
                                .alignmentGuide(.leading) { $0.width + 4 }
                            }
                    }
                }
                .padding(.horizontal, 15)
                .frame(height: 26).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    guard rename != nil else { return }
                    draft = name; editing = true
                    DispatchQueue.main.async { typing = true }
                })
                .hint(rename == nil ? name : "\(name). Double-click to rename.")
            }
            .background(selected ? color.opacity(0.22) : Color.black.opacity(0.2))
            content
        }
        .padding(.bottom, 5)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(selected ? 0.08 : 0.2))
        .overlay(alignment: .trailing) { Rectangle().fill(start == nil ? Theme.line : Theme.accent.opacity(0.7)).frame(width: 1) }
        .opacity(dim ? 0.62 : 1)
        // The line between strips is a handle: drag it to make every strip wider or narrower; double-click to reset.
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 7).contentShape(Rectangle())
                .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        let size = ConsoleMetrics.Size.shared
                        if start == nil { start = size.strip }
                        let next = min(ConsoleMetrics.maxStrip, max(ConsoleMetrics.minStrip, ((start ?? size.strip) + Double(g.translation.width)).rounded()))
                        if next != size.chosen { size.chosen = next }
                    }
                    .onEnded { _ in start = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded { ConsoleMetrics.Size.shared.chosen = nil })
                .hint("Drag to make the mixer's strips wider or narrower. Double-click to have them fill the width again.")
                .offset(x: 3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

/// The face of a small console key: dark and quiet when off, filled with its colour when on.
private struct KeyFace: View {
    var label = ""
    var symbol: String?
    let on: Bool
    var tint: Color = Theme.accent
    var width: CGFloat = 27
    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            else { Text(label).font(.system(size: 8.5, weight: .bold, design: .rounded)) }
        }
        .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.secondary)
        .frame(width: width, height: 17)
        .background(on ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.black.opacity(0.32)),
                    in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(on ? 0.25 : 0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
    }
}

private struct ConsoleKey: View {
    let label: String
    let on: Bool
    var tint: Color = Theme.accent
    let help: String
    let action: () -> Void
    var body: some View {
        Button { Haptic.tick(.generic); action() } label: { KeyFace(label: label, on: on, tint: tint) }
            .buttonStyle(PressStyle(scale: 0.96))
            .hint(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A rotary control. Drag up and down to turn it (Shift for fine), double-click to reset.
struct Knob: View {
    let value: Double
    let range: ClosedRange<Double>
    var tint: Color = Theme.accent
    var reset: Double?
    /// The arc grows from the middle (pan) instead of from the left end.
    var bipolar = false
    var size: CGFloat = 26
    let label: (Double) -> String
    let begin: () -> Void
    let change: (Double) -> Void
    @State private var dragging = false
    @State private var start = 0.0

    var body: some View {
        let u = (min(range.upperBound, max(range.lowerBound, value)) - range.lowerBound) / (range.upperBound - range.lowerBound)
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2 - 1.5
            // 270 degrees of travel, from seven-thirty round the top to four-thirty.
            let angle = 135 + 270 * u
            var track = Path()
            track.addArc(center: c, radius: r, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
            ctx.stroke(track, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let from = bipolar ? 270.0 : 135.0
            if abs(angle - from) > 0.5 {
                var arc = Path()
                arc.addArc(center: c, radius: r, startAngle: .degrees(min(from, angle)), endAngle: .degrees(max(from, angle)), clockwise: false)
                ctx.stroke(arc, with: .color(tint.opacity(dragging ? 1 : 0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            let body = Path(ellipseIn: CGRect(x: c.x - r + 3.5, y: c.y - r + 3.5, width: (r - 3.5) * 2, height: (r - 3.5) * 2))
            ctx.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.34), Color(white: 0.1)]), startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
            ctx.stroke(body, with: .color(.black.opacity(0.6)), lineWidth: 0.5)
            let a = angle * .pi / 180
            var pointer = Path()
            pointer.move(to: CGPoint(x: c.x + cos(a) * (r - 9), y: c.y + sin(a) * (r - 9)))
            pointer.addLine(to: CGPoint(x: c.x + cos(a) * (r - 4.5), y: c.y + sin(a) * (r - 4.5)))
            ctx.stroke(pointer, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: size, height: size)
        .scaleEffect(dragging ? 1.06 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 1), value: dragging)
        // No floating readout while turning: the value is already written under the knob.
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !dragging { dragging = true; begin(); start = value }
                let fine: Double = NSEvent.modifierFlags.contains(.shift) ? 0.25 : 1
                let v = min(range.upperBound, max(range.lowerBound, start - Double(g.translation.height) / 140 * (range.upperBound - range.lowerBound) * fine))
                // A detent where the knob passes its resting place.
                if let reset, (value - reset) * (v - reset) < 0 || (v == reset && value != reset) { Haptic.tick() }
                change(v)
            }
            .onEnded { _ in dragging = false })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if let reset { begin(); change(reset) } })
        .accessibilityElement()
        .accessibilityValue(label(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            begin(); change(min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step))))
        }
    }
}

/// A long-throw fader, -48 to +12 dB, with more travel around 0 where it matters.
struct ConsoleFader: View {
    let value: Double
    var tint: Color
    let begin: () -> Void
    let change: (Double) -> Void
    @State private var dragging = false
    @State private var grab: CGFloat = 0
    static let cap: CGFloat = 26

    /// Half the travel covers -12…+12, the rest -48…-12.
    static func unit(_ db: Double) -> Double {
        let d = min(12, max(-48, db))
        return d >= -12 ? 0.5 + (d + 12) / 24 * 0.5 : (d + 48) / 36 * 0.5
    }
    static func db(_ u: Double) -> Double {
        let c = min(1, max(0, u))
        return c >= 0.5 ? -12 + (c - 0.5) / 0.5 * 24 : -48 + c / 0.5 * 36
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, cap = Self.cap, travel = max(1, h - cap)
            let y = (1 - Self.unit(value)) * travel
            ZStack(alignment: .top) {
                // The slot the cap rides in.
                Capsule().fill(Color.black.opacity(0.6)).frame(width: 4)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .padding(.vertical, cap / 2 - 3)
                    .frame(maxHeight: .infinity)
                // A thread of the track's colour from the cap down: how far up the fader is, at a glance.
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.7), tint.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2, height: max(0, h - y - cap))
                    .offset(y: y + cap - 3)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(stops: [.init(color: Color(white: 0.95), location: 0), .init(color: Color(white: 0.72), location: 0.44),
                                                 .init(color: Color(white: 0.5), location: 0.5), .init(color: Color(white: 0.8), location: 0.56),
                                                 .init(color: Color(white: 0.58), location: 1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 20, height: cap)
                    .overlay(Rectangle().fill(Color.black.opacity(0.75)).frame(width: 20, height: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.black.opacity(0.55), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.55), radius: dragging ? 4 : 2.5, y: dragging ? 3 : 1.5)
                    .offset(y: y)
                    .animation(.spring(response: 0.2, dampingFraction: 1), value: dragging)
            }
            .frame(width: 24)
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
                    let fine = NSEvent.modifierFlags.contains(.shift)
                    let target = Self.db(1 - Double((g.location.y - grab - cap / 2) / travel))
                    // Shift: a quarter of the movement, for fine trims.
                    let v = ((fine ? value + (target - value) * 0.25 : target) * 10).rounded() / 10
                    // A detent at 0 dB, and a stop at each end of the travel.
                    if v != value, value * v < 0 || v == 0 || v >= 12 || v <= -48 { Haptic.tick(v == 0 || value * v < 0 ? .alignment : .levelChange) }
                    change(v)
                }
                .onEnded { _ in dragging = false })
            .simultaneousGesture(TapGesture(count: 2).onEnded { begin(); change(0) })
            .contextMenu {
                Button("Type a Value…") {
                    if let text = Ask.text("Type a level", info: "In dB, between -48 and 12.", value: String(format: "%.1f", value)),
                       let v = Double(text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-").filter({ "0123456789.-+".contains($0) })) {
                        begin(); change(min(12, max(-48, v)))
                    }
                }
                Button("Reset to 0 dB") { begin(); change(0) }
            }
        }
        .frame(width: 24)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(Slide.decibels(value))
        .accessibilityAdjustableAction { direction in begin(); change(min(12, max(-48, value + (direction == .increment ? 1 : -1)))) }
    }
}

/// The marks beside a fader: where 0 dB is, and the steps either side.
private struct FaderScale: View {
    var body: some View {
        Canvas { ctx, size in
            let travel = max(1, size.height - ConsoleFader.cap)
            for (db, strong) in [(12.0, true), (6, false), (0, true), (-6, false), (-12, true), (-24, true), (-36, false), (-48, true)] {
                let y = (1 - ConsoleFader.unit(db)) * travel + ConsoleFader.cap / 2
                ctx.fill(Path(CGRect(x: size.width - (strong ? 5 : 3), y: y - 0.5, width: strong ? 5 : 3, height: 1)), with: .color(.white.opacity(db == 0 ? 0.6 : 0.22)))
                if strong {
                    ctx.draw(Text(db == 0 ? "0" : String(format: "%.0f", abs(db))).font(.system(size: 7, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(db == 0 ? 0.7 : 0.34)), at: CGPoint(x: size.width - 7, y: y), anchor: .trailing)
                }
            }
        }
        .frame(width: 16)
        .accessibilityHidden(true)
    }
}

/// A segmented meter on the same scale as the fader beside it, with a line that holds the last peak for a moment.
private struct ConsoleMeter: View {
    let level: Float
    @State private var hold: Float = 0
    @State private var held = Date.distantPast

    var body: some View {
        Canvas { ctx, size in
            let travel = max(1, size.height - ConsoleFader.cap), base = ConsoleFader.cap / 2
            func y(_ db: Double) -> CGFloat { (1 - ConsoleFader.unit(db)) * travel + base }
            let now = linearToDb(Double(max(level, 0.000001)))
            let step: CGFloat = 3
            var py = y(-48)
            while py > y(12) {
                // What level this segment stands for, read back off the scale.
                let u = 1 - Double((py - base) / travel)
                let db = ConsoleFader.db(u)
                let color = db > -1 ? Theme.danger : (db > -12 ? ConsoleMetrics.amber : ConsoleMetrics.green)
                ctx.fill(Path(CGRect(x: 0, y: py - 2, width: size.width, height: 2)), with: .color(db <= now && level > 0.0006 ? color.opacity(0.95) : Color.white.opacity(0.07)))
                py -= step
            }
            if hold > 0.0006 {
                let hdb = linearToDb(Double(hold))
                ctx.fill(Path(CGRect(x: 0, y: y(min(12, max(-48, hdb))) - 1, width: size.width, height: 1.5)), with: .color(hdb > -1 ? Theme.danger : Color.white.opacity(0.8)))
            }
        }
        .frame(width: 5)
        .onChange(of: level) { _, new in
            if new >= hold { hold = new; held = Date() }
            else if Date().timeIntervalSince(held) > 1.2 { hold = new < 0.0006 ? 0 : max(new, hold * 0.88) }
        }
        .accessibilityHidden(true)
    }
}

private struct Readout: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
            .frame(maxWidth: .infinity).frame(height: 15)
            .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .padding(.horizontal, 5)
    }
}

// MARK: - Strips

private struct ConsoleTrack: View {
    @Environment(Store.self) private var store
    let track: Track
    let number: Int
    @State private var showDuck = false
    @State private var showRoom = false

    private func rename(_ name: String) { edit { $0.name = name } }
    private func sends(to g: TrackGroup) -> Binding<Bool> {
        let id = track.id, here = track.groupID == g.id
        return Binding<Bool>(get: { here }, set: { on in if on { store.setGroup(g.name, for: [id]) } })
    }
    private func edit(_ change: @escaping (inout Track) -> Void) {
        store.mutate { p in if let i = p.trackIndex(track.id) { change(&p.tracks[i]) } }
    }

    var body: some View {
        let p = store.project
        let bus = p.group(track.groupID)
        let pre = track.fxBeforeFader == true
        let automated = AutoParam.allCases.filter { !track.keys($0).isEmpty }
        let pan = track.spatial ? track.position.x : track.pan
        ConsoleShell(color: track.kind.color, name: track.name, number: "\(number)", selected: store.selection == .track(track.id),
                     dim: track.mute || bus?.mute == true, rename: rename) {
            VStack(spacing: 1) {
                Knob(value: pan, range: -1...1, tint: track.kind.color, reset: 0, bipolar: true, label: Slide.side, begin: { store.beginGesture() }) { v in
                    let x = abs(v) < 0.04 ? 0 : v
                    store.live { p in
                        guard let i = p.trackIndex(track.id) else { return }
                        if p.tracks[i].spatial { p.tracks[i].position.x = x } else { p.tracks[i].pan = x }
                    }
                }
                .hint("Pan: drag up or down. Double-click for the centre.")
                Button { showRoom.toggle() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: track.spatial ? "cube.fill" : "cube").font(.system(size: 7, weight: .semibold))
                        Text(Slide.side(pan)).font(.system(size: 8.5).monospacedDigit())
                    }
                    .foregroundStyle(track.spatial ? Theme.accent : Theme.tertiary)
                    .frame(maxWidth: .infinity).frame(height: 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hint("Room panner: place this track around and above the listener, as an object")
                .popover(isPresented: $showRoom, arrowEdge: .top) { RoomPanel(track: track) }
            }
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    ConsoleKey(label: "M", on: track.mute, tint: Theme.danger, help: "Mute") { edit { $0.mute.toggle() } }
                    ConsoleKey(label: "S", on: track.solo, tint: ConsoleMetrics.amber, help: "Solo") { edit { $0.solo.toggle() } }
                }
                HStack(spacing: 3) {
                    ConsoleKey(label: pre ? "PRE" : "PST", on: pre, tint: Color(white: 0.82),
                               help: pre ? "Effects come before the fader: the fader only changes the level. Click for after."
                                         : "Effects come after the fader: pushing the fader drives them harder. Click for before.") { edit { $0.fxBeforeFader = pre ? nil : true } }
                    Menu {
                        Section(automated.isEmpty ? "No automation on \(track.name) yet" : "Automation on \(track.name)") {
                            ForEach(AutoParam.allCases) { param in
                                let count = track.keys(param).count
                                Button {
                                    edit { $0.lane = $0.lane == param ? nil : param }
                                    store.selection = .track(track.id)
                                } label: {
                                    Label(param.title + (count == 0 ? "" : "  ·  \(count) point\(count == 1 ? "" : "s")"),
                                          systemImage: track.lane == param ? "eye.fill" : (count == 0 ? "circle" : "circle.fill"))
                                }
                            }
                        }
                        if track.lane != nil {
                            Divider()
                            Button("Hide the Lane on the Timeline") { edit { $0.lane = nil } }
                        }
                    } label: { KeyFace(label: "A", on: !automated.isEmpty, tint: Theme.accent) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .hint(automated.isEmpty ? "Automation: none on this track. Click to open a lane on the timeline and draw some."
                                            : "Automation on this track: \(automated.map(\.title).joined(separator: ", ")). Click to show a lane.")
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                FaderScale()
                ConsoleFader(value: track.volume, tint: track.kind.color, begin: { store.beginGesture() }) { v in
                    store.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].volume = v } }
                }
                ConsoleMeter(level: store.player.trackLevels[track.id] ?? 0)
            }
            .frame(maxHeight: .infinity)
            Readout(text: Slide.decibels(track.volume))
            HStack(spacing: 3) {
                Button { showDuck.toggle() } label: { KeyFace(symbol: "arrow.down.to.line.compact", on: track.duck != nil, tint: Theme.accent, width: 18) }
                    .buttonStyle(PressStyle(scale: 0.96))
                    .hint(track.duck == nil ? "Sidechain: dip this track while another one is heard" : "Sidechain is on: this track dips \(String(format: "%.0f", track.duck!.depth)) dB")
                    .popover(isPresented: $showDuck, arrowEdge: .top) { DuckPanel(track: track) }
                Menu {
                    Toggle("Master", isOn: Binding(get: { bus == nil }, set: { if $0 { store.setGroup(nil, for: [track.id]) } }))
                    if !(p.groups ?? []).isEmpty {
                        Section("Buses") {
                            ForEach(p.groups ?? []) { g in
                                Toggle(g.name, isOn: sends(to: g))
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
                    Text(bus?.name ?? "Master").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                        .padding(.horizontal, 3).frame(maxWidth: .infinity).frame(height: 17)
                        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .hint("Output: straight to the master, or through a bus")
            }
            .padding(.horizontal, 5)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .track(track.id) }
        .onChange(of: store.peek) { _, v in if v == "duck", store.selection == .track(track.id) { showDuck = true; store.peek = nil } }
    }
}

private struct ConsoleBus: View {
    @Environment(Store.self) private var store
    let group: TrackGroup
    @State private var showSound = false

    var body: some View {
        let members = store.project.tracks.filter { $0.groupID == group.id }
        let level = members.map { store.player.trackLevels[$0.id] ?? 0 }.max() ?? 0
        let sound = group.plugins?.first { $0.preset != nil }?.preset
        ConsoleShell(color: Color(white: 0.78), name: group.name, number: "", selected: store.selection == .group(group.id), dim: group.mute,
                     symbol: "arrow.triangle.merge", rename: { name in store.editGroup(group.id) { $0.name = name } }) {
            VStack(spacing: 1) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary).frame(height: 26)
                Text("\(members.count) track\(members.count == 1 ? "" : "s")").font(.system(size: 8.5)).foregroundStyle(Theme.tertiary).frame(height: 11)
            }
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    ConsoleKey(label: "M", on: group.mute, tint: Theme.danger, help: "Mute the bus") { store.editGroup(group.id) { $0.mute.toggle() } }
                    ConsoleKey(label: "S", on: group.solo, tint: ConsoleMetrics.amber, help: "Solo the bus") { store.editGroup(group.id) { $0.solo.toggle() } }
                }
                HStack(spacing: 3) {
                    Button { showSound.toggle() } label: { KeyFace(label: "FX", on: sound != nil, tint: Theme.accent) }
                        .buttonStyle(PressStyle(scale: 0.96))
                        .hint(sound.map { "This bus has the \($0) sound. Click to change it." } ?? "One sound for everything on this bus. Tracks placed as objects in the room skip it.")
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
                    } label: { KeyFace(symbol: "ellipsis", on: false) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .hint("Rename or remove this bus. Removing it sends its tracks to the master.")
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                FaderScale()
                ConsoleFader(value: group.volume, tint: Color(white: 0.78), begin: { store.beginGesture() }) { v in
                    store.editGroup(group.id, undoable: false) { $0.volume = v }
                }
                ConsoleMeter(level: level)
            }
            .frame(maxHeight: .infinity)
            Readout(text: Slide.decibels(group.volume))
            Text("Master").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary).frame(height: 17)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .group(group.id) }
    }
}

private struct ConsoleMaster: View {
    @Environment(Store.self) private var store
    var body: some View {
        let v = store.project.masterVolume ?? 0
        ConsoleShell(color: Color.white.opacity(0.9), name: "MASTER", number: "", extra: 20, symbol: "sum") {
            // Empty where a track has its knob and keys, so every fader starts at the same height.
            Color.clear.frame(height: 38)
            Color.clear.frame(height: 37)
            HStack(alignment: .bottom, spacing: 3) {
                FaderScale()
                ConsoleFader(value: v, tint: .white, begin: { store.beginGesture() }) { nv in
                    store.live { $0.masterVolume = abs(nv) < 0.05 ? nil : nv }
                }
                ConsoleMeter(level: store.player.masterL)
                ConsoleMeter(level: store.player.masterR)
            }
            .frame(maxHeight: .infinity)
            Readout(text: Slide.decibels(v))
            Color.clear.frame(height: 17)
        }
    }
}
