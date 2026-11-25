import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// One look for the whole app: the dark it sits on, the colour it speaks in, and the three colours its backdrop moves through.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let about: String
    let bg: Color
    let panel: Color
    let accent: Color
    let danger: Color
    /// What text and hairlines are tinted with. Near white, leaning warm or cool with the theme.
    let ink: Color
    let glow: [Color]

    private static func c(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }

    static let all: [Palette] = [
        Palette(id: "ember", name: "Ember", about: "The original: near black and amber.",
                bg: Color(red: 0.047, green: 0.047, blue: 0.055), panel: Color(red: 0.082, green: 0.082, blue: 0.094),
                accent: Color(red: 1.0, green: 0.62, blue: 0.11), danger: Color(red: 1.0, green: 0.36, blue: 0.33), ink: .white,
                glow: [c(0x3a2410), c(0xff9e1c), c(0x7a3b12)]),
        Palette(id: "lily", name: "Lily", about: "Dusty mauve and cream, like pressed flowers.",
                bg: c(0x171216), panel: c(0x231b21), accent: c(0xf1dfc4), danger: c(0xe26a78), ink: c(0xfff4ea),
                glow: [c(0x5b3f52), c(0xf1e6c8), c(0x8d7fb0)]),
        Palette(id: "moth", name: "Moth", about: "Teal dark, pale mint and a crimson wing.",
                bg: c(0x070e0f), panel: c(0x0f1a1b), accent: c(0xbfe3cf), danger: c(0xd0455f), ink: c(0xeafff5),
                glow: [c(0x1c4a48), c(0xa8324a), c(0xcfe6d6)]),
        Palette(id: "bloom", name: "Bloom", about: "Navy and moss with a sand halftone.",
                bg: c(0x090d19), panel: c(0x111829), accent: c(0xdcc294), danger: c(0xf07f6e), ink: c(0xfdf6e6),
                glow: [c(0x2c5a39), c(0xdcc294), c(0xe7a9a0)]),
        Palette(id: "cloud", name: "Cloud", about: "Ink blue and bone, one colour and its shadow.",
                bg: c(0x06090f), panel: c(0x0e131f), accent: c(0xece6c9), danger: c(0xf0766a), ink: c(0xf4f3e6),
                glow: [c(0x1a2442), c(0x8fa39c), c(0xece6c9)]),
        Palette(id: "iris", name: "Iris", about: "Oxblood and parchment, with a little olive.",
                bg: c(0x140a0c), panel: c(0x201114), accent: c(0xe0556a), danger: c(0xffb14a), ink: c(0xf6eedb),
                glow: [c(0x7a1f2b), c(0xd8cfae), c(0x76843f)]),
        Palette(id: "seraph", name: "Seraph", about: "Black terminal, violet light, an orange rule.",
                bg: c(0x050308), panel: c(0x0e0a15), accent: c(0xcdb0ff), danger: c(0xff6a3d), ink: c(0xf3ecff),
                glow: [c(0xff6a3d), c(0xc9a6ff), c(0xff8fc7)]),
    ]
    static func named(_ id: String?) -> Palette { all.first { $0.id == id } ?? all[0] }
}

/// The colours every view asks for. They follow the chosen palette.
enum Theme {
    /// Read through an observable holder, so every view that asks for a colour is redrawn when the theme changes.
    @Observable final class Look {
        static let shared = Look()
        var palette = Palette.named(UserDefaults.standard.string(forKey: "theme"))
    }
    static var current: Palette {
        get { Look.shared.palette }
        set { Look.shared.palette = newValue }
    }
    static var bg: Color { current.bg }
    static var panel: Color { current.panel }
    static var raised: Color { current.ink.opacity(0.06) }
    static var lane: Color { current.ink.opacity(0.028) }
    static var line: Color { current.ink.opacity(0.08) }
    static var secondary: Color { current.ink.opacity(0.56) }
    static var tertiary: Color { current.ink.opacity(0.34) }
    static var accent: Color { current.accent }
    static var danger: Color { current.danger }
}

/// Swatches to choose the look from.
struct ThemePicker: View {
    @Environment(Store.self) private var store
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            ForEach(Palette.all) { p in
                let on = store.theme == p.id
                Button { store.theme = p.id } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 0) {
                            ForEach(Array(([p.bg, p.panel] + p.glow + [p.accent]).enumerated()), id: \.offset) { _, c in c }
                        }
                        .frame(height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(p.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text(p.about).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(height: 26, alignment: .top)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? p.accent : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .accessibilityLabel("\(p.name) theme. \(p.about)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The backdrop behind the picture, done the way the QC Reel does it: the frame that is playing, reduced to an ordered
/// dither in two of the theme's colours and pushed about as if by wind. With no film it is the same wind over a soft slope
/// of light. It redraws about ten times a second and holds still when the Mac is set to reduce motion.
struct Backdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("movingBackdrop") private var moving = true
    /// The film frame nearest the playhead, if there is a film.
    var frame: NSImage?
    @State private var grid = FrameGrid()

    /// How bright a film frame is, cell by cell. Worked out once per frame and grid size.
    final class FrameGrid {
        private var key = ""
        private var lum: [Float] = []
        func luminance(of image: NSImage, cols: Int, rows: Int) -> [Float] {
            let k = "\(ObjectIdentifier(image).hashValue)-\(cols)x\(rows)"
            if k == key { return lum }
            key = k
            lum = [Float](repeating: 0, count: cols * rows)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return lum }
            // Fill the grid with the frame, cropping what does not fit, as a wallpaper would.
            let s = max(CGFloat(cols) / CGFloat(cg.width), CGFloat(rows) / CGFloat(cg.height))
            let w = CGFloat(cg.width) * s, h = CGFloat(cg.height) * s
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: (CGFloat(cols) - w) / 2, y: (CGFloat(rows) - h) / 2, width: w, height: h))
            guard let data = ctx.data else { return lum }
            let bytes = data.bindMemory(to: UInt8.self, capacity: cols * rows)
            for i in 0..<(cols * rows) { lum[i] = powf(Float(bytes[i]) / 255, 1.6) * 0.62 }
            return lum
        }
    }

    private static let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]].map { $0.map { ($0 + 0.5) / 16 } }

    @inline(__always) private static func wind(_ x: Double, _ y: Double, _ t: Double) -> Double {
        (sin(x * 0.9 + t * 0.5) * cos(y * 0.7 - t * 0.35) + sin((x + y) * 0.33 + t * 0.22) * 0.8 + sin(x * 0.2 - y * 0.3 + t * 0.13) * 0.6) / 2.4
    }

    var body: some View {
        let tint = Theme.current.glow[2], bright = Theme.current.glow[1]
        SwiftUI.TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || !moving)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000) * 0.5
            Canvas(rendersAsynchronously: true) { ctx, size in
                let cell: CGFloat = size.width > 1500 ? 13 : 11
                let cols = Int(ceil(size.width / cell)), rows = Int(ceil(size.height / cell))
                guard cols > 1, rows > 1 else { return }
                let lum = frame.map { grid.luminance(of: $0, cols: cols, rows: rows) }
                var low = Path(), high = Path()
                for y in 0..<rows {
                    for x in 0..<cols {
                        let n = Self.wind(Double(x) / 7, Double(y) / 7, t)
                        var v: Double
                        if let lum {
                            // The frame, read from a little upwind of each cell, so it leans and ripples.
                            let sx = min(cols - 1, max(0, Int((Double(x) + n * 2.6).rounded())))
                            let sy = min(rows - 1, max(0, Int((Double(y) + Self.wind(Double(y) / 7 + 3, Double(x) / 7, t) * 1.6).rounded())))
                            v = Double(lum[sy * cols + sx]) + n * 0.07
                        } else {
                            v = max(0, (n + 1) / 2 * 0.6 + Double(x) / Double(cols) * 0.22 - Double(y) / Double(rows) * 0.2 - 0.32) * 0.9
                        }
                        guard v > 0.02, v >= Self.bayer[y & 3][x & 3] else { continue }
                        let r = max(0.6, min(cell * 0.42, cell * 0.22 + CGFloat(v) * cell * 0.22))
                        let dot = Path(ellipseIn: CGRect(x: CGFloat(x) * cell + cell / 2 - r, y: CGFloat(y) * cell + cell / 2 - r, width: r * 2, height: r * 2))
                        if v > 0.82 { high.addPath(dot) } else { low.addPath(dot) }
                    }
                }
                ctx.fill(low, with: .color(tint.opacity(0.5)))
                ctx.fill(high, with: .color(bright.opacity(0.6)))
            }
        }
        .background(Theme.bg)
        // Darker towards the edges, so the picture and the controls stay the brightest things there.
        .overlay(RadialGradient(colors: [.clear, Theme.bg.opacity(0.55), Theme.bg.opacity(0.92)], center: .center, startRadius: 120, endRadius: 760))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Hints

/// What the pointer is resting on, in words. One small box in the corner shows it.
@Observable final class Hints {
    static let shared = Hints()
    var text: String?
}

extension View {
    /// The system tooltip, and the same words in the hint box while the pointer is over this.
    func hint(_ text: String) -> some View {
        help(text).onHover { inside in
            if inside { Hints.shared.text = text } else if Hints.shared.text == text { Hints.shared.text = nil }
        }
    }
}

/// The hint box: bottom left of the window, only while there is something to say. Switch it off in Settings or the Session menu.
struct HintBox: View {
    @AppStorage("hintBox") private var on = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let text = on ? Hints.shared.text.flatMap { $0.isEmpty ? nil : $0 } : nil
        ZStack(alignment: .bottomLeading) {
            if let text {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text(text).font(.system(size: 12)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .frame(maxWidth: 420, alignment: .leading)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                .padding(12)
                .transition(.opacity)
                .id(text)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: text)
        .allowsHitTesting(false)
    }
}
