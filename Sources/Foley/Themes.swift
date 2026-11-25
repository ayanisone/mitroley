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

/// Swatches to choose the look from, and the picture that moves behind the film in that look.
struct ThemePicker: View {
    @Environment(Store.self) private var store
    @AppStorage("backdropStamp") private var stamp = 0
    var body: some View {
        let has = Backdrop.picture(for: store.theme) != nil
        HStack(spacing: 8) {
            Button(has ? "Change This Theme's Picture…" : "Choose a Picture for This Theme…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.message = "Choose a picture to move behind the film in the \(Theme.current.name) theme."
                if panel.runModal() == .OK, let url = panel.url { Backdrop.set(url, for: store.theme) }
            }
            .buttonStyle(PillButtonStyle())
            if has { Button("Remove Picture") { Backdrop.set(nil, for: store.theme) }.buttonStyle(PillButtonStyle()) }
        }
        .id(stamp)
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

/// The backdrop behind the picture: the theme's own picture, with wind blowing through it. The picture is bent by a slow,
/// drifting field, the way cloth or water moves, never broken into dots. A theme without a picture is plain.
/// Pictures live on this Mac only, in ~/Library/Application Support/mitroley/Backdrops, one per theme, named after it.
struct Backdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("movingBackdrop") private var moving = true
    @AppStorage("backdropStamp") private var stamp = 0

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mitroley/Backdrops", isDirectory: true)
    }
    /// The picture for a theme, if one has been put there.
    static func picture(for theme: String) -> URL? {
        ["jpg", "jpeg", "png", "webp", "heic", "tiff"].map { folder.appendingPathComponent(theme + "." + $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// Copies a picture in as this theme's backdrop, replacing the one it had. nil removes it.
    static func set(_ file: URL?, for theme: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        while let old = picture(for: theme) { try? FileManager.default.removeItem(at: old) }
        if let file { try? FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(theme + "." + file.pathExtension.lowercased())) }
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "backdropStamp") + 1, forKey: "backdropStamp")
    }

    var body: some View {
        let theme = Theme.current
        ZStack {
            Theme.bg
            if let url = Self.picture(for: theme.id) {
                WindPicture(url: url, moving: moving && !reduceMotion)
                    .id("\(url.path)-\(stamp)")
                // Held back, and darker towards the edges, so the film and the controls stay the brightest things there.
                Theme.bg.opacity(0.38)
                RadialGradient(colors: [.clear, Theme.bg.opacity(0.35), Theme.bg.opacity(0.85)], center: .center, startRadius: 160, endRadius: 820)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A picture that fills its view and is bent by a drifting field, so it moves like something light in a wind.
struct WindPicture: NSViewRepresentable {
    let url: URL
    let moving: Bool

    final class Host: NSView {
        private let context = CIContext(options: [.cacheIntermediates: false])
        private var source: CIImage?
        private var fitted: CIImage?
        private var fittedSize = CGSize.zero
        private var timer: Timer?
        private let field = Host.makeField()
        var moving = true { didSet { if moving != oldValue { schedule() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.contentsGravity = .resize
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }

        func load(_ url: URL) {
            source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            fitted = nil
            draw()
        }

        /// A small tile of smooth, repeating noise: red bends the picture sideways, green up and down. Mid grey is no bend.
        static func makeField() -> CIImage {
            let n = 96
            var px = [UInt8](repeating: 255, count: n * n * 4)
            func wave(_ x: Double, _ y: Double, _ terms: [(Double, Double, Double, Double)]) -> Double {
                var v = 0.0, total = 0.0
                for (fx, fy, amp, phase) in terms { v += amp * sin(2 * .pi * (fx * x + fy * y) + phase); total += amp }
                return 0.5 + 0.5 * v / total
            }
            for y in 0..<n {
                for x in 0..<n {
                    let u = Double(x) / Double(n), w = Double(y) / Double(n)
                    let r = wave(u, w, [(1, 0, 1, 0.3), (1, 1, 0.7, 1.9), (2, -1, 0.45, 4.1), (3, 2, 0.25, 2.2)])
                    let g = wave(u, w, [(0, 1, 1, 1.1), (1, -1, 0.7, 0.4), (-1, 2, 0.45, 3.3), (2, 3, 0.25, 5.0)])
                    let i = (y * n + x) * 4
                    px[i] = UInt8(r * 255); px[i + 1] = UInt8(g * 255); px[i + 2] = 128
                }
            }
            let image = CIImage(bitmapData: Data(px), bytesPerRow: n * 4, size: CGSize(width: n, height: n), format: .RGBA8, colorSpace: nil)
            return image.applyingFilter("CIAffineTile", parameters: [:])
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); draw() }

        private func schedule() {
            timer?.invalidate()
            timer = nil
            guard window != nil, moving else { draw(); return }
            let t = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.draw() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        deinit { timer?.invalidate() }

        private func draw() {
            guard let source, bounds.width > 4, bounds.height > 4, window?.occlusionState.contains(.visible) != false else { return }
            // Drawn at one pixel per point: soft enough for a backdrop, and a quarter of the work on a Retina screen.
            let size = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
            if fitted == nil || fittedSize != size {
                fitted = Host.fit(source, to: size)
                fittedSize = size
            }
            guard let fitted else { return }
            let out = moving ? Host.blow(fitted, field: field, at: CACurrentMediaTime()) : fitted
            guard let cg = context.createCGImage(out, from: CGRect(origin: .zero, size: size)) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = cg
            CATransaction.commit()
        }

        /// The picture scaled to cover `size`, a little over, so bent edges never show.
        static func fit(_ source: CIImage, to size: CGSize) -> CIImage {
            let e = source.extent
            let s = max(size.width / e.width, size.height / e.height) * 1.08
            return source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: (size.width - e.width * s) / 2, y: (size.height - e.height * s) / 2))
        }

        /// The picture as the wind has it at time `t`.
        static func blow(_ fitted: CIImage, field: CIImage, at t: Double) -> CIImage {
            // Two layers of the field, a broad slow one and a finer quick one, both travelling downwind.
            func layer(_ scale: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CIImage {
                field.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: CGFloat(t) * dx, y: CGFloat(t) * dy))
            }
            let broad = layer(5.5, 60, 9), fine = layer(2.2, 130, -16)
            let bend = fine.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: broad, kCIInputTimeKey: 0.55])
            // Gusts: the wind rises and falls rather than blowing evenly.
            let gust = 78 + 30 * sin(t * 0.37) + 14 * sin(t * 0.91 + 1.3)
            return fitted.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: ["inputDisplacementImage": bend, kCIInputScaleKey: gust])
        }

        /// Writes the backdrop as it would be drawn at two moments, to look at without a screen.
        static func writeTest(_ url: URL, to dir: URL) {
            guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { print("could not read \(url.path)"); return }
            let size = CGSize(width: 1100, height: 420), ctx = CIContext(), field = makeField()
            let fitted = fit(source, to: size)
            for (name, image) in [("still", fitted), ("wind-a", blow(fitted, field: field, at: 3)), ("wind-b", blow(fitted, field: field, at: 4.5))] {
                guard let cg = ctx.createCGImage(image, from: CGRect(origin: .zero, size: size)) else { print("render failed: \(name)"); continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            }
            print("written")
        }
    }

    func makeNSView(context: Context) -> Host {
        let v = Host()
        v.moving = moving
        v.load(url)
        return v
    }
    func updateNSView(_ v: Host, context: Context) { v.moving = moving }
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
