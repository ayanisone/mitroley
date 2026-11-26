import IOKit.ps
import MetalKit
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// The backdrop: the theme's picture hung behind the whole window like a flag, rippling in a slow wind. One edge is pinned
/// and the far edge flutters more; folds are shaded light and dark; the edges fall away so the panels stay readable; a
/// little grain. Changing theme crossfades the two flags while both keep moving. This is the QC Reel's shader, line for
/// line, moved from WebGL to Metal. Each theme comes with a picture inside the app; one chosen on this Mac is kept in
/// ~/Library/Application Support/mitroley/Backdrops and takes its place.
enum Backdrops {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mitroley/Backdrops", isDirectory: true)
    }
    /// The pictures that come with the app, one for each theme that has one.
    static var shipped: URL? { Bundle.main.resourceURL?.appendingPathComponent("Backdrops", isDirectory: true) }
    private static let kinds = ["jpg", "jpeg", "png", "webp", "heic", "tiff"]
    private static func find(_ theme: String, in folder: URL) -> URL? {
        kinds.map { folder.appendingPathComponent(theme + "." + $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// Left in the folder when the picture a theme came with has been taken down, so it stays down.
    private static func bare(_ theme: String) -> URL { folder.appendingPathComponent(theme + ".none") }
    /// True when the picture showing is one chosen on this Mac, not the one the theme came with.
    static func isOwn(_ theme: String) -> Bool { find(theme, in: folder) != nil }
    /// The picture for a theme: the one chosen on this Mac, else the one the theme came with.
    static func picture(for theme: String) -> URL? {
        if let own = find(theme, in: folder) { return own }
        if FileManager.default.fileExists(atPath: bare(theme).path) { return nil }
        return shipped.flatMap { find(theme, in: $0) }
    }
    /// Copies a picture in as this theme's backdrop, replacing the one it had. nil takes the picture down.
    static func set(_ file: URL?, for theme: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        while let old = find(theme, in: folder) { try? FileManager.default.removeItem(at: old) }
        try? FileManager.default.removeItem(at: bare(theme))
        if let file { try? FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(theme + "." + file.pathExtension.lowercased())) }
        else if shipped.flatMap({ find(theme, in: $0) }) != nil { FileManager.default.createFile(atPath: bare(theme).path, contents: nil) }
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "backdropStamp") + 1, forKey: "backdropStamp")
    }
    /// Puts back the picture the theme came with.
    static func restore(_ theme: String) {
        while let old = find(theme, in: folder) { try? FileManager.default.removeItem(at: old) }
        try? FileManager.default.removeItem(at: bare(theme))
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "backdropStamp") + 1, forKey: "backdropStamp")
    }
    static func hasShipped(_ theme: String) -> Bool { shipped.flatMap { find(theme, in: $0) } != nil }
}

/// Where the panels sit over the flag, in points, so the flag can draw itself out of focus behind them.
/// Blurring it in its own shader costs almost nothing; a system blur over a moving picture would be redone every frame.
enum FlagLayout {
    nonisolated(unsafe) static var inspector: CGFloat = 0
    /// The browser down the left side, when it is open.
    nonisolated(unsafe) static var left: CGFloat = 0
    nonisolated(unsafe) static var bottom: CGFloat = 0
}

/// How much the backdrop moves, so a Mac with less to spare is not asked for more than it has.
enum MotionLevel: String, CaseIterable, Identifiable {
    case auto, smooth, light, still
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .smooth: "Smooth"
        case .light: "Light"
        case .still: "Still"
        }
    }
    var about: String {
        switch self {
        case .auto: "Smooth on power with room to spare. Light on battery, on a warm Mac, or on a Mac with four cores or 8 GB or less."
        case .smooth: "60 frames a second, whether or not mitroley is in front."
        case .light: "30 frames a second, the pointer does not stir it, and it rests when another app is in front."
        case .still: "The picture hangs still. Nothing is redrawn."
        }
    }
    static var chosen: MotionLevel { MotionLevel(rawValue: UserDefaults.standard.string(forKey: "motionLevel") ?? "") ?? .auto }

    /// What Automatic comes to on this Mac, right now.
    static var automatic: MotionLevel {
        let info = ProcessInfo.processInfo
        if info.activeProcessorCount <= 4 || info.physicalMemory <= 8 * 1_073_741_824 { return .light }
        if info.thermalState != .nominal { return .light }
        let source = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?
        if source == kIOPMBatteryPowerKey { return .light }
        return .smooth
    }
    /// The level in force: the one chosen, or what Automatic works out.
    static var current: MotionLevel { let c = chosen; return c == .auto ? automatic : c }
}

struct FlagView: NSViewRepresentable {
    /// The theme and a counter that changes when its picture is replaced.
    let theme: Palette
    let stamp: Int
    let wind: Bool
    /// The film is playing: the flag moves at half rate and leaves the machine to the sound.
    var playing = false

    func makeCoordinator() -> Renderer { Renderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = false
        view.clearColor = MTLClearColor(red: 0.027, green: 0.024, blue: 0.063, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.set(theme: theme, stamp: stamp, wind: wind, in: view)
        context.coordinator.level = MotionLevel.current
        let rate = context.coordinator.level == .light ? 30 : 60
        if view.preferredFramesPerSecond != rate { view.preferredFramesPerSecond = rate }
    }

    final class Renderer: NSObject, MTKViewDelegate {
        private struct Uniforms {
            var aA = SIMD2<Float>(1, 1), aB = SIMD2<Float>(1, 1), res = SIMD2<Float>(1, 1)
            var mouse = SIMD2<Float>(-9, -9), wake = SIMD2<Float>(-9, -9)
            var mixAB: Float = 1, dimA: Float = 1, dimB: Float = 1, t: Float = 0, wind: Float = 1, pinA: Float = 0, pinB: Float = 0
            var inspector: Float = 0, bottom: Float = 0, push: Float = 0, left: Float = 0
        }
        private struct Slot { var texture: MTLTexture?; var w = 1, h = 1; var dim: Float = 1; var pinTop = false; var real = false }

        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var slots = [Slot(), Slot()]      // 0 = the theme showing, 1 = the one it is fading from
        private var key = ""
        private var wind = true
        private var mixStart = CACurrentMediaTime() - 10
        private let t0 = CACurrentMediaTime()
        private weak var view: MTKView?
        /// Smooth or light; looked at again every couple of seconds, since power and heat change under Automatic.
        var level = MotionLevel.smooth
        private var frames = 0
        // The pointer as the cloth feels it: where it is, a point that trails behind it, and how hard it is moving.
        private var mouse = SIMD2<Float>(-9, -9), wake = SIMD2<Float>(-9, -9)
        private var push: Float = 0
        private var lastDraw = CACurrentMediaTime()

        /// Reads the pointer once per frame (no events, so it costs nothing when the flag is at rest).
        private func feel(_ view: MTKView, now: Double) {
            let dt = Float(min(0.1, max(0.001, now - lastDraw)))
            lastDraw = now
            var speed: Float = 0
            if level != .light, UserDefaults.standard.object(forKey: "backdropPointer") as? Bool ?? true, let window = view.window, view.bounds.width > 1 {
                let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if view.bounds.contains(p) {
                    let at = SIMD2(Float(p.x / view.bounds.width), Float(p.y / view.bounds.height))
                    if mouse.x > -1 {
                        let d = at - mouse
                        speed = min(1, (d.x * d.x + d.y * d.y).squareRoot() / dt * 0.9)
                        wake += (mouse - wake) * min(1, dt * 5)
                    } else { wake = at }
                    mouse = at
                } else { mouse = SIMD2(-9, -9) }
            } else { mouse = SIMD2(-9, -9) }
            // Rises fast with a sweep of the pointer, dies away over about a second.
            push += (speed - push) * min(1, dt * (speed > push ? 10 : 1.4))
        }

        func attach(_ view: MTKView) {
            self.view = view
            guard let device = view.device else { return }
            self.device = device
            queue = device.makeCommandQueue()
            guard let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "flag_vertex")
            d.fragmentFunction = library.makeFunction(name: "flag_fragment")
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: d)
            slots[0].texture = ink(device)
            slots[1].texture = ink(device)
            // Rest whenever nobody is looking, and start again when they are.
            let nc = NotificationCenter.default
            for name in [NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, UserDefaults.didChangeNotification,
                         Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.view?.isPaused = false })
            }
        }
        private var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// The wind blows whenever the window can be seen, in front or not, unless the Mac is saving
        /// power and is not running hot.
        private var allowed: Bool {
            let info = ProcessInfo.processInfo
            if level == .light && !NSApp.isActive { return false }
            return view?.window?.occlusionState.contains(.visible) != false && !info.isLowPowerModeEnabled
                && info.thermalState != .serious && info.thermalState != .critical
        }

        /// One pixel of the theme's own dark, for a theme without a picture.
        private func ink(_ device: MTLDevice, _ c: (UInt8, UInt8, UInt8) = (16, 6, 7)) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            var px: [UInt8] = [c.0, c.1, c.2, 255]
            t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
            return t
        }

        func set(theme: Palette, stamp: Int, wind: Bool, in view: MTKView) {
            self.wind = wind
            let k = "\(theme.id)-\(stamp)"
            if k != key, let device {
                key = k
                // What was showing becomes the one it fades from; the new theme takes its place.
                slots.swapAt(0, 1)
                var next = Slot(texture: nil, dim: theme.dim, pinTop: theme.pinTop)
                if let url = Backdrops.picture(for: theme.id), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary),
                   let tex = Self.texture(cg, device) {
                    next.texture = tex; next.w = cg.width; next.h = cg.height; next.real = true
                } else {
                    let c = NSColor(theme.bg).usingColorSpace(.sRGB) ?? .black
                    next.texture = ink(device, (UInt8(c.blueComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.redComponent * 255)))
                }
                slots[0] = next
                mixStart = CACurrentMediaTime()
            }
            view.isPaused = false
        }

        /// The picture as a texture, drawn into the byte order the view uses so no colour is swapped. Top row first.
        private static func texture(_ cg: CGImage, _ device: MTLDevice) -> MTLTexture? {
            let w = cg.width, h = cg.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
            // Smaller copies of the picture, made once: reading from them is what puts it out of focus behind the panels.
            if let buffer = device.makeCommandQueue()?.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: t)
                blit.endEncoding()
                buffer.commit()
            }
            return t
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Drawn at one pixel per point: it sits behind smoked glass, and that is a quarter of the work on a Retina screen.
            let scale: CGFloat = 1
            let want = CGSize(width: max(1, (view.bounds.width * scale).rounded()), height: max(1, (view.bounds.height * scale).rounded()))
            if view.drawableSize != want { view.drawableSize = want }
            guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = queue.makeCommandBuffer(), let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let now = CACurrentMediaTime()
            frames += 1
            if frames % 120 == 0 {
                level = MotionLevel.current
                let rate = level == .light ? 30 : 60
                if view.preferredFramesPerSecond != rate { view.preferredFramesPerSecond = rate }
            }
            feel(view, now: now)
            let mix = Float(min(1, (now - mixStart) / 1.1))
            func cover(_ s: Slot) -> SIMD2<Float> {
                guard s.real else { return SIMD2(1, 1) }
                let sa = Float(want.width / want.height), ia = Float(s.w) / Float(s.h)
                return sa > ia ? SIMD2(1, ia / sa) : SIMD2(sa / ia, 1)
            }
            var u = Uniforms()
            u.aA = cover(slots[0]); u.aB = cover(slots[1])
            u.res = SIMD2(Float(want.width), Float(want.height))
            u.mixAB = mix
            // Held a little darker than in the QC Reel: here controls sit straight on it, with no pane between.
            u.dimA = slots[0].real ? slots[0].dim * 0.78 : 1; u.dimB = slots[1].real ? slots[1].dim * 0.78 : 1
            u.t = Float(now - t0); u.wind = wind ? 1 : 0
            u.inspector = Float(FlagLayout.inspector * scale); u.bottom = Float(FlagLayout.bottom * scale); u.left = Float(FlagLayout.left * scale)
            u.mouse = mouse; u.wake = wake; u.push = wind ? push : 0
            u.pinA = slots[0].pinTop ? 1 : 0; u.pinB = slots[1].pinTop ? 1 : 0
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(slots[0].texture, index: 0)
            enc.setFragmentTexture(slots[1].texture, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            // Keep going while the wind blows on a real picture, or while a crossfade is under way. Otherwise rest.
            let animate = ((wind && slots[0].real) || mix < 1) && allowed
            if !animate { view.isPaused = true }
        }

        /// Wakes the loop when the window comes back into view.
        func resume() { view?.isPaused = false }

        static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 pos [[position]]; float2 v; };
        struct U { float2 aA; float2 aB; float2 res; float2 mouse; float2 wake; float mixAB; float dimA; float dimB; float t; float wind; float pinA; float pinB; float inspector; float bottom; float push; float left; };

        vertex V flag_vertex(uint vid [[vertex_id]]) {
            const float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
            V o; o.pos = float4(p[vid], 0, 1); o.v = p[vid] * 0.5 + 0.5; return o;
        }

        static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
        static float noise(float2 p) {
            float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash(i), hash(i + float2(1, 0)), f.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x), f.y);
        }
        static float fbm(float2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 3; i++) { s += a * noise(p); p = p * 2.03 + 7.3; a *= 0.5; } return s; }

        // Cloth: travelling waves that grow away from the pinned edge, plus a slow gust field. xy = how far to bend, z = fold shading.
        static float3 cloth(float2 uv, float pin, float phase, float t, float wind, constant U &u) {
            float free = mix(uv.x, 1.0 - uv.y, pin);
            float amp = wind * (0.015 + 0.07 * free * free);
            float gust = fbm(uv * 1.6 + float2(t * 0.09, -t * 0.05) + phase);
            float g = 0.6 + 0.8 * gust;
            float w1 = sin(uv.x * 7.0 - t * 1.9 * g + uv.y * 2.4 + phase);
            float w2 = sin(uv.y * 9.0 + t * 1.3 * g - uv.x * 3.1 + phase * 1.7);
            float w3 = sin((uv.x + uv.y) * 4.0 - t * 0.8 + gust * 3.0);
            float2 d = float2(w2 * 0.55 + w3 * 0.45, w1 * 0.75 + w3 * 0.25) * amp;
            d += (float2(gust, fbm(uv * 1.2 - t * 0.06 + 11.0)) - 0.5) * amp * 1.4;
            float slope = cos(uv.x * 7.0 - t * 1.9 * g + uv.y * 2.4 + phase) * 0.5 + cos(uv.y * 9.0 + t * 1.3 * g - uv.x * 3.1 + phase * 1.7) * 0.3;
            float shade = 1.0 + slope * (0.10 + 0.22 * free) * wind;
            // The pointer: the cloth bellies away from it, a ring runs outward, and a fainter one follows where it has been.
            if (u.push > 0.002) {
                float2 asp = float2(u.res.x / u.res.y, 1.0);
                float2 dv = (uv - u.mouse) * asp; float r = length(dv); float2 dir = dv / max(r, 0.0001);
                float belly = exp(-r * r / 0.018);
                float ring = sin(r * 34.0 - t * 7.0) * exp(-r * 5.5);
                d += dir / asp * (belly * 0.034 + ring * 0.007) * u.push;
                float2 dw = (uv - u.wake) * asp; float rw = length(dw);
                d += dw / max(rw, 0.0001) / asp * exp(-rw * rw / 0.03) * 0.016 * u.push;
                shade += (belly * 0.22 + ring * 0.08) * u.push;
            }
            return float3(d, shade);
        }

        static float3 sampleTheme(texture2d<float> tex, sampler s, float2 v, float2 a, float pin, float dim, float phase, float pane, constant U &u) {
            float3 c = cloth(v, pin, phase, u.t, u.wind, u);
            float2 uv = (v - 0.5) * a + 0.5 + c.xy;
            uv = clamp(uv, float2(0.001), float2(0.999));
            // Behind a panel: read a much smaller copy of the picture, which is the picture out of focus, and hold it darker.
            float3 col = tex.sample(s, float2(uv.x, 1.0 - uv.y), level(pane * 4.6)).rgb * mix(c.z, 1.0 + (c.z - 1.0) * 0.5, pane) * (1.0 - 0.22 * pane);
            float r = length((v - 0.5) * float2(u.res.x / u.res.y, 1.0) * 1.1);
            col *= dim * (1.05 - 0.45 * smoothstep(0.35, 1.15, r));
            return col;
        }

        fragment float4 flag_fragment(V in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> tA [[texture(0)]], texture2d<float> tB [[texture(1)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
            float pane = (in.pos.x > u.res.x - u.inspector || in.pos.x < u.left || in.pos.y > u.res.y - u.bottom) ? 1.0 : 0.0;
            float3 a = sampleTheme(tA, s, in.v, u.aA, u.pinA, u.dimA, 0.0, pane, u);
            float3 b = u.mixAB < 0.999 ? sampleTheme(tB, s, in.v, u.aB, u.pinB, u.dimB, 2.1, pane, u) : a;
            float3 col = mix(b, a, smoothstep(0.0, 1.0, u.mixAB));
            col += (hash(in.pos.xy + fract(u.t)) - 0.5) * 0.028 * (1.0 - pane);
            return float4(col, 1.0);
        }
        """
    }
}

/// The flag, with the theme, the wind switch and the Mac's reduce-motion setting read for it.
struct Backdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("motionLevel") private var level = MotionLevel.auto.rawValue
    @AppStorage("backdropStamp") private var stamp = 0
    @Environment(Store.self) private var store
    var body: some View {
        FlagView(theme: Theme.current, stamp: stamp, wind: MotionLevel.current != .still && !reduceMotion, playing: store.player.isPlaying)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
