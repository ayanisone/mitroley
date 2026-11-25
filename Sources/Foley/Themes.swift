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
    /// How bright the picture behind the window is kept (bright pictures lower), and which edge it hangs from.
    var dim: Float = 0.6
    var pinTop = false

    private static func c(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }

    static let all: [Palette] = [
        Palette(id: "ember", name: "Ember", about: "The original: near black and amber.",
                bg: Color(red: 0.047, green: 0.047, blue: 0.055), panel: Color(red: 0.082, green: 0.082, blue: 0.094),
                accent: Color(red: 1.0, green: 0.62, blue: 0.11), danger: Color(red: 1.0, green: 0.36, blue: 0.33), ink: .white,
                glow: [c(0x3a2410), c(0xff9e1c), c(0x7a3b12)]),
        Palette(id: "lily", name: "Lily", about: "Dusty mauve and cream, like pressed flowers.",
                bg: c(0x171216), panel: c(0x231b21), accent: c(0xd9a0c4), danger: c(0xe26a78), ink: c(0xfff4ea),
                glow: [c(0x5b3f52), c(0xf1e6c8), c(0x8d7fb0)], dim: 0.62, pinTop: false),
        Palette(id: "moth", name: "Moth", about: "Teal dark, pale mint and a crimson wing.",
                bg: c(0x070e0f), panel: c(0x0f1a1b), accent: c(0xc9d5a6), danger: c(0xd0455f), ink: c(0xeafff5),
                glow: [c(0x1c4a48), c(0xa8324a), c(0xcfe6d6)], dim: 0.7, pinTop: true),
        Palette(id: "bloom", name: "Bloom", about: "Navy and moss with a sand halftone.",
                bg: c(0x090d19), panel: c(0x111829), accent: c(0xd6c79a), danger: c(0xf07f6e), ink: c(0xfdf6e6),
                glow: [c(0x2c5a39), c(0xdcc294), c(0xe7a9a0)], dim: 0.72, pinTop: false),
        Palette(id: "cloud", name: "Cloud", about: "Ink blue and bone, one colour and its shadow.",
                bg: c(0x06090f), panel: c(0x0e131f), accent: c(0xe4e0cc), danger: c(0xf0766a), ink: c(0xf4f3e6),
                glow: [c(0x1a2442), c(0x8fa39c), c(0xece6c9)], dim: 0.58, pinTop: true),
        Palette(id: "iris", name: "Iris", about: "Oxblood and parchment, with a little olive.",
                bg: c(0x140a0c), panel: c(0x201114), accent: c(0xd0506a), danger: c(0xffb14a), ink: c(0xf6eedb),
                glow: [c(0x7a1f2b), c(0xd8cfae), c(0x76843f)], dim: 0.46, pinTop: false),
        Palette(id: "seraph", name: "Seraph", about: "Black terminal, violet light, an orange rule.",
                bg: c(0x050308), panel: c(0x0e0a15), accent: c(0xcdb0ff), danger: c(0xff6a3d), ink: c(0xf3ecff),
                glow: [c(0xff6a3d), c(0xc9a6ff), c(0xff8fc7)], dim: 0.55, pinTop: false),
    ]
    static func named(_ id: String?) -> Palette { all.first { $0.id == id } ?? all[0] }
}

/// The colours every view asks for. They follow the chosen palette.
enum Theme {
    /// Read through an observable holder, so every view that asks for a colour is redrawn when the theme changes.
    @Observable final class Look {
        static let shared = Look()
        var palette = Palette.named(UserDefaults.standard.string(forKey: "theme")) { didSet { refresh() } }
        /// True while the theme has a picture behind the window.
        var glass = false
        init() { refresh() }
        func refresh() { glass = Backdrops.picture(for: palette.id) != nil }
    }
    static var current: Palette {
        get { Look.shared.palette }
        set { Look.shared.palette = newValue }
    }
    static var bg: Color { current.bg }
    /// With a picture hung behind the window the panels are smoked glass, so its movement reads through them.
    static var panel: Color { Look.shared.glass ? current.panel.opacity(0.5) : current.panel }
    static var raised: Color { current.ink.opacity(0.06) }
    static var lane: Color { current.ink.opacity(0.028) }
    static var line: Color { current.ink.opacity(0.08) }
    static var secondary: Color { current.ink.opacity(0.56) }
    static var tertiary: Color { current.ink.opacity(0.34) }
    static var accent: Color { current.accent }
    static var danger: Color { current.danger }
}

/// Swatches to choose the look from, and the picture that moves behind the film in that look.
struct ThemePicker: View {
    @Environment(Store.self) private var store
    @AppStorage("backdropStamp") private var stamp = 0
    var body: some View {
        let has = Backdrops.picture(for: store.theme) != nil
        HStack(spacing: 8) {
            Button(has ? "Change This Theme's Picture…" : "Choose a Picture for This Theme…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.message = "Choose a picture to hang behind the window in the \(Theme.current.name) theme."
                if panel.runModal() == .OK, let url = panel.url { Backdrops.set(url, for: store.theme); Theme.Look.shared.refresh() }
            }
            .buttonStyle(PillButtonStyle())
            if has { Button("Remove Picture") { Backdrops.set(nil, for: store.theme); Theme.Look.shared.refresh() }.buttonStyle(PillButtonStyle()) }
        }
        .id(stamp)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            ForEach(Palette.all) { p in
                let on = store.theme == p.id
                Button { store.theme = p.id; store.say("Backdrop · \(p.name)") } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack {
                            if let thumb = ThemeThumbs.image(for: p.id, stamp: stamp) {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                HStack(spacing: 0) {
                                    ForEach(Array(([p.bg, p.panel] + p.glow + [p.accent]).enumerated()), id: \.offset) { _, c in c }
                                }
                            }
                        }
                        .frame(height: 54)
                        .frame(maxWidth: .infinity)
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


/// Small copies of the theme pictures for the picker, read once each.
enum ThemeThumbs {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    static func image(for theme: String, stamp: Int) -> NSImage? {
        let key = "\(theme)-\(stamp)"
        if let have = cache[key] { return have }
        guard let url = Backdrops.picture(for: theme), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = image
        return image
    }
}
