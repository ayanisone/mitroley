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

/// The row of tools in the timeline's corner.
struct ToolStrip: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { t in
                let on = store.tool == t
                Button { store.tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.secondary)
                        .frame(width: 25, height: 21)
                        .background(on ? Theme.accent : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .help(t.help)
            }
        }
    }
}
