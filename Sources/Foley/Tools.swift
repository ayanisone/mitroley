import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// What a click or drag on the timeline does. One key each, as in other editors.
enum Tool: String, CaseIterable, Identifiable {
    case pointer, scissors, mute, solo, marquee, gain, fade
    var id: String { rawValue }

    var key: Character {
        switch self {
        case .pointer: "v"
        case .scissors: "c"
        case .mute: "m"
        case .solo: "s"
        case .marquee: "r"
        case .gain: "g"
        case .fade: "f"
        }
    }

    var symbol: String {
        switch self {
        case .pointer: "cursorarrow"
        case .scissors: "scissors"
        case .mute: "speaker.slash.fill"
        case .solo: "headphones"
        case .marquee: "rectangle.dashed"
        case .gain: "arrow.up.and.down"
        case .fade: "line.diagonal"
        }
    }

    var help: String {
        let k = String(key).uppercased()
        switch self {
        case .pointer: return "Pointer (\(k)): select, move and trim clips."
        case .scissors: return "Scissors (\(k)): click a clip to cut it there."
        case .mute: return "Mute (\(k)): click a clip to silence it or bring it back. Click an empty part of a track to mute the track."
        case .solo: return "Solo (\(k)): click a clip or a track to hear that track alone. Click again to let the rest back in."
        case .marquee: return "Marquee (\(k)): drag across a track to select a stretch of time. Delete removes it; Esc lets go."
        case .gain: return "Gain (\(k)): drag a clip up or down to make it louder or quieter."
        case .fade: return "Fade (\(k)): drag in the first half of a clip to set its fade in, in the second half for its fade out."
        }
    }
}

/// A stretch of one track picked out with the marquee tool.
struct Marquee: Equatable {
    var track: UUID
    var start: Double
    var end: Double
}

extension Track {
    /// Takes the stretch a…b out of the track: clips inside it go, clips reaching into it are trimmed, a clip that
    /// spans it is cut in two. What is left keeps playing exactly what it played before.
    mutating func remove(from a: Double, to b: Double) {
        guard b - a > 0.001 else { return }
        var out: [Clip] = []
        for c in clips {
            if c.end <= a || c.start >= b { out.append(c); continue }
            let source = c.take?.duration ?? 0
            func tail(_ c: Clip) -> Clip {
                // The part after b.
                var t = c
                let delta = b - c.start
                t.start = b
                t.duration = c.end - b
                t.offset = c.offset + delta * c.speed
                if c.loop, source > 0 { t.offset = t.offset.truncatingRemainder(dividingBy: source) }
                t.fadeIn = min(c.fadeIn, 0.01)
                return t
            }
            if c.start < a {
                var head = c
                head.duration = a - c.start
                head.fadeOut = min(c.fadeOut, 0.01)
                out.append(head)
                if c.end > b {
                    var t = tail(c)
                    t.id = UUID()
                    out.append(t)
                }
            } else if c.end > b {
                out.append(tail(c))
            }
        }
        clips = out
    }
}

extension Store {
    func deleteMarquee() {
        guard let m = marquee, let i = project.trackIndex(m.track) else { return }
        let a = min(m.start, m.end), b = max(m.start, m.end)
        mutate { $0.tracks[i].remove(from: a, to: b) }
        marquee = nil
        selection = .track(m.track)
    }

    func toggleClipMute(_ id: UUID) {
        mutate { p in
            guard let l = p.locate(clip: id) else { return }
            let now = p.tracks[l.track].clips[l.clip].muted == true
            p.tracks[l.track].clips[l.clip].muted = now ? nil : true
        }
    }

    func toggleTrack(_ id: UUID, solo: Bool) {
        mutate { p in
            guard let i = p.trackIndex(id) else { return }
            if solo { p.tracks[i].solo.toggle() } else { p.tracks[i].mute.toggle() }
        }
    }
}

/// The tools, as a column floating at the left of the picture. It picks the largest size that fits the height it
/// is given, so in a short window it shrinks instead of spilling over the title bar.
struct ToolStrip: View {
    var body: some View {
        ViewThatFits(in: .vertical) {
            ToolColumn(cell: 34, gap: 4)
            ToolColumn(cell: 28, gap: 2)
            ToolColumn(cell: 23, gap: 1)
            ToolColumn(cell: 19, gap: 0)
        }
    }
}

/// One column of tools with a single selector that glides between them. Click a tool, or press and slide along the
/// column: the selector follows the pointer exactly, stretches a little with its speed, and settles on the nearest tool.
private struct ToolColumn: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cell: CGFloat
    let gap: CGFloat
    /// Where the selector's centre is while it is being dragged, and how fast it is moving.
    @State private var drag: CGFloat?
    @State private var speed: CGFloat = 0
    @State private var pressed = false

    private var step: CGFloat { cell + gap }
    private var tools: [Tool] { Tool.allCases }
    private func centre(_ i: Int) -> CGFloat { CGFloat(i) * step + cell / 2 }
    private func index(at y: CGFloat) -> Int { min(tools.count - 1, max(0, Int((y / step).rounded(.down)))) }

    var body: some View {
        let selected = tools.firstIndex(of: store.tool) ?? 0
        let last = centre(tools.count - 1)
        let y = drag.map { min(last, max(cell / 2, $0)) } ?? centre(selected)
        // The tool under the selector lights up as it passes, before it settles.
        let under = drag == nil ? selected : index(at: y)
        // Moving fast, the selector stretches along its path and thins across it, like a drop of water.
        let stretch = reduceMotion ? 0 : min(0.32, abs(speed) / 2600)
        ZStack(alignment: .top) {
            selector
                .frame(width: cell, height: cell)
                .scaleEffect(x: (pressed ? 1.12 : 1) * (1 - stretch * 0.45), y: (pressed ? 1.12 : 1) * (1 + stretch))
                .offset(y: y - cell / 2)
                .animation(drag == nil ? (reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.72)) : nil, value: y)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: pressed)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: stretch)
            VStack(spacing: gap) {
                ForEach(Array(tools.enumerated()), id: \.element) { i, t in
                    Image(systemName: t.symbol)
                        .font(.system(size: max(9, cell * 0.38), weight: .semibold))
                        .foregroundStyle(i == under ? Color.black.opacity(0.85) : Theme.secondary)
                        .frame(width: cell, height: cell)
                        .help(t.help)
                        .animation(.easeOut(duration: 0.12), value: under)
                }
            }
        }
        .frame(width: cell, height: CGFloat(tools.count) * step - gap)
        .contentShape(Rectangle())
        // Responds on press, follows 1:1, and commits to the tool it is over when let go.
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                pressed = true
                drag = g.location.y
                speed = g.velocity.height
                let now = index(at: min(last, max(cell / 2, g.location.y)))
                if tools[now] != store.tool, abs(g.translation.height) < 3 { store.tool = tools[now] }
            }
            .onEnded { g in
                // Where a flick would carry it, not just where it was let go.
                let landing = g.location.y + g.velocity.height * 0.06
                store.tool = tools[index(at: min(last, max(cell / 2, landing)))]
                speed = 0
                pressed = false
                drag = nil
            })
        .padding(cell > 24 ? 6 : 4)
        .glass(in: Capsule())
    }

    /// The selector: a tinted lens of glass where the system has it, a lit disc otherwise.
    @ViewBuilder private var selector: some View {
        if #available(macOS 26.0, *) {
            Circle().fill(Theme.accent.opacity(0.92))
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: Circle())
        } else {
            Circle().fill(Theme.accent)
                .overlay(Circle().fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
                .shadow(color: Theme.accent.opacity(0.45), radius: 6, y: 1)
        }
    }
}
