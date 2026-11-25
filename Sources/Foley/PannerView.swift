import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// Geometry shared by the panner's drawing and its dragging.
enum PannerMath {
    /// Room square (x right, y front, both −1…1) → unit disc. The square's corners land on the rim at 45°.
    static func disc(_ x: Double, _ y: Double) -> CGPoint {
        let h = hypot(x, y)
        guard h > 1e-9 else { return .zero }
        let k = max(abs(x), abs(y)) / h
        return CGPoint(x: x * k, y: y * k)
    }

    /// Unit disc → room square.
    static func square(_ d: CGPoint) -> (x: Double, y: Double) {
        var dx = Double(d.x), dy = Double(d.y)
        let r = hypot(dx, dy)
        guard r > 1e-9 else { return (0, 0) }
        if r > 1 { dx /= r; dy /= r }
        let k = min(1, r) / max(abs(dx), abs(dy))
        return (min(1, max(-1, dx * k)), min(1, max(-1, dy * k)))
    }

    /// Degrees from straight ahead, positive to the right.
    static func azimuth(_ x: Double, _ y: Double) -> Double {
        let d = disc(x, y)
        guard hypot(d.x, d.y) > 1e-6 else { return 0 }
        return atan2(Double(d.x), Double(d.y)) * 180 / .pi
    }

    static func wrap(_ a: Double) -> Double {
        var v = a.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 }
        if v < -180 { v += 360 }
        return v
    }

    /// Half the width, in degrees, of the lit arc: how widely the sound is spread around the listener. It is the
    /// energy-weighted spread of the speakers carrying the sound, so it changes smoothly as the puck moves and never
    /// jumps from one speaker to the next. Near the centre the sound is everywhere and the arc opens to a full ring.
    static func spread(_ p: Vec3, gains: [Float]) -> Double {
        let az = azimuth(p.x, p.y)
        var energy = 0.0, moment = 0.0
        for (i, g) in gains.enumerated() where i != 3 && g > 0 {
            let s = Speakers.places[i]
            let d = wrap(azimuth(s.x, s.y) - az), e = Double(g * g)
            energy += e
            moment += e * d * d
        }
        var half = energy > 0 ? 14 + 1.5 * (moment / energy).squareRoot() : 14
        let d = disc(p.x, p.y), r = Double(hypot(d.x, d.y))
        if r < 0.45 {
            // Ease towards the full ring over the inner part of the disc.
            let t = 1 - r / 0.45
            half += (180 - half) * t * t * (3 - 2 * t)
        }
        return min(180, max(14, half))
    }
}

/// Top-down surround panner. The puck is the sound; the speakers around the rim light up with the signal
/// each one gets (from the same panner the exports use), a lit arc on the rim follows the puck and shows
/// how widely the sound is spread, and the glow around the puck grows as the sound is lifted.
struct PanPad: View {
    let position: Vec3
    let color: Color
    /// Channels of the 7.1.4 order to draw as speakers (the sub is never drawn).
    var speakers: [Int] = Array(0..<12)
    let begin: () -> Void
    let change: (Double, Double) -> Void

    @State private var dragging = false
    @State private var virtual = CGPoint.zero
    @State private var previous = CGPoint.zero
    @State private var lastClick = Date.distantPast

    var body: some View {
        VStack(spacing: 8) {
            readouts
            GeometryReader { geo in
                let g = PannerDisc.Geometry(size: geo.size)
                PannerDisc(x: position.x, y: position.y, z: position.z, color: color, speakers: speakers, active: dragging)
                    .animation(dragging ? nil : .spring(response: 0.22, dampingFraction: 1), value: position.x)
                    .animation(dragging ? nil : .spring(response: 0.22, dampingFraction: 1), value: position.y)
                    .animation(dragging ? nil : .spring(response: 0.22, dampingFraction: 1), value: position.z)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !dragging {
                                dragging = true
                                begin()
                                let puck = g.point(PannerMath.disc(position.x, position.y))
                                // Grabbing the puck never makes it jump; clicking elsewhere brings it to the pointer.
                                virtual = hypot(v.startLocation.x - puck.x, v.startLocation.y - puck.y) < 16 ? puck : v.startLocation
                                previous = v.startLocation
                            }
                            let fine: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.25 : 1
                            virtual.x += (v.location.x - previous.x) * fine
                            virtual.y += (v.location.y - previous.y) * fine
                            previous = v.location
                            let s = PannerMath.square(g.unit(virtual))
                            change(s.x, s.y)
                        }
                        .onEnded { v in
                            dragging = false
                            guard hypot(v.translation.width, v.translation.height) < 3 else { return }
                            // A second click in place returns the sound to the middle of the room.
                            if Date().timeIntervalSince(lastClick) < 0.35 { change(0, 0); lastClick = .distantPast }
                            else { lastClick = Date() }
                        })
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .hint("Drag to place the sound. Hold Shift for fine moves. Double-click to centre it.")
    }

    private var readouts: some View {
        let d = PannerMath.disc(position.x, position.y)
        let r = Double(hypot(d.x, d.y))
        return HStack(spacing: 0) {
            readout("Angle", r < 0.01 || abs(PannerMath.azimuth(position.x, position.y)) < 0.5 ? "0°" : String(format: "%+.0f°", PannerMath.azimuth(position.x, position.y)))
            readout("Distance", String(format: "%.0f%%", r * 100))
            readout("Elevation", String(format: "%.0f°", position.z * 90))
        }
    }

    private func readout(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
            Text(value).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
    }
}

/// The drawing. Animatable, so the puck and its halos ease when a position changes from automation or undo.
struct PannerDisc: View, Animatable {
    var x: Double
    var y: Double
    var z: Double
    let color: Color
    let speakers: [Int]
    let active: Bool

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(x, AnimatablePair(y, z)) }
        set { x = newValue.first; y = newValue.second.first; z = newValue.second.second }
    }

    struct Geometry {
        let centre: CGPoint
        let rim: CGFloat        // outside of the speaker band
        let disc: CGFloat       // edge of the floor
        let travel: CGFloat     // how far the puck's centre can go
        init(size: CGSize) {
            let s = min(size.width, size.height)
            centre = CGPoint(x: size.width / 2, y: size.height / 2 + 5)
            rim = s / 2 - 12
            disc = rim - 13
            travel = disc - 9
        }
        func point(_ d: CGPoint) -> CGPoint { CGPoint(x: centre.x + d.x * travel, y: centre.y - d.y * travel) }
        func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - centre.x) / travel, y: (centre.y - p.y) / travel) }
        /// Point at `degrees` from straight ahead (clockwise), `radius` from the centre.
        func polar(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
            let a = degrees * .pi / 180
            return CGPoint(x: centre.x + CGFloat(sin(a)) * radius, y: centre.y - CGFloat(cos(a)) * radius)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let g = Geometry(size: size)
            let pos = Vec3(x: x, y: y, z: z)
            let gains = Exporter.pan714(pos)
            let d = PannerMath.disc(x, y)
            let r = Double(hypot(d.x, d.y))
            let az = PannerMath.azimuth(x, y)
            let puck = g.point(d)
            let white = Color.white

            // Floor.
            let floor = Path(ellipseIn: CGRect(x: g.centre.x - g.disc, y: g.centre.y - g.disc, width: g.disc * 2, height: g.disc * 2))
            ctx.fill(floor, with: .radialGradient(Gradient(colors: [white.opacity(0.095), white.opacity(0.035)]),
                                                  center: g.centre, startRadius: 0, endRadius: g.disc))
            // Speaker band.
            let band = (g.disc + g.rim) / 2
            ctx.stroke(circle(g.centre, band), with: .color(Color.black.opacity(0.42)), lineWidth: g.rim - g.disc)
            ctx.stroke(circle(g.centre, g.rim), with: .color(white.opacity(0.07)), lineWidth: 0.75)
            ctx.stroke(circle(g.centre, g.disc), with: .color(white.opacity(0.12)), lineWidth: 0.75)

            // Rings and spokes.
            for k in 1...3 {
                ctx.stroke(circle(g.centre, g.travel * CGFloat(k) / 4), with: .color(white.opacity(0.06)), lineWidth: 0.75)
            }
            ctx.stroke(circle(g.centre, g.travel), with: .color(white.opacity(0.085)), lineWidth: 0.75)
            for k in 0..<8 {
                let a = Double(k) * 45
                var p = Path()
                p.move(to: g.polar(a, 9)); p.addLine(to: g.polar(a, g.disc))
                ctx.stroke(p, with: .color(white.opacity(k % 2 == 0 ? 0.085 : 0.04)), lineWidth: 0.75)
            }

            // Halo: the ring the sound sits on, lit around the puck.
            let half = PannerMath.spread(pos, gains: gains)
            if r > 0.06 {
                let inner = min(half * 0.55, 150)
                ctx.stroke(arc(g, az - inner, az + inner, CGFloat(r) * g.travel), with: .color(color.opacity(0.42)),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                var line = Path()
                line.move(to: g.centre); line.addLine(to: puck)
                ctx.stroke(line, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(0.4)]), startPoint: g.centre, endPoint: puck),
                           lineWidth: 1)
            }

            // Halo: the arc of speakers carrying the sound, on the rim.
            let rimArc = half >= 179.5 ? circle(g.centre, g.disc + 2.5) : arc(g, az - half, az + half, g.disc + 2.5)
            for (w, o) in [(13.0, 0.07), (7.5, 0.16), (3.0, 0.95)] {
                ctx.stroke(rimArc, with: .color(color.opacity(o)), style: StrokeStyle(lineWidth: w, lineCap: .round))
            }

            // Speakers: brighter the more signal they get.
            for i in speakers where i != 3 && i < gains.count {
                let s = Speakers.places[i]
                let high = s.z > 0.5
                let a = PannerMath.azimuth(s.x, s.y)
                let lit = Double(min(1, max(0, gains[i])))
                let at = g.polar(a, high ? g.travel * 0.74 : band + 1.5)
                var glyph = ctx
                glyph.translateBy(x: at.x, y: at.y)
                glyph.rotate(by: .degrees(a))
                glyph.scaleBy(x: high ? 0.72 : 1, y: high ? 0.72 : 1)
                let shape = speakerGlyph()
                if lit > 0.02 { glyph.fill(shape, with: .color(color.opacity(lit))) }
                if high {
                    glyph.stroke(shape, with: .color(white.opacity(0.22 + 0.5 * lit)), lineWidth: 1)
                } else {
                    glyph.fill(shape, with: .color(white.opacity(0.2 + 0.45 * lit)))
                }
            }

            // Listener, seen from above, facing the screen.
            var nose = Path()
            nose.move(to: CGPoint(x: g.centre.x, y: g.centre.y - 7.5))
            nose.addLine(to: CGPoint(x: g.centre.x - 2.6, y: g.centre.y - 3.6))
            nose.addLine(to: CGPoint(x: g.centre.x + 2.6, y: g.centre.y - 3.6))
            nose.closeSubpath()
            ctx.fill(nose, with: .color(white.opacity(0.3)))
            ctx.fill(circle(g.centre, 4.5), with: .color(white.opacity(0.3)))

            // Halo: glow around the puck. It grows as the sound is lifted off the floor.
            let lift = CGFloat(z)
            let outer = 26 + 26 * lift, near = 13 + 15 * lift
            ctx.fill(circle(puck, outer), with: .radialGradient(Gradient(colors: [color.opacity(0.2), color.opacity(0)]),
                                                                center: puck, startRadius: 4, endRadius: outer))
            ctx.fill(circle(puck, near), with: .radialGradient(Gradient(colors: [color.opacity(0.5), color.opacity(0)]),
                                                               center: puck, startRadius: 5, endRadius: near))
            if lift > 0.02 {
                ctx.stroke(circle(puck, 9 + 13 * lift), with: .color(color.opacity(0.55)), lineWidth: 1)
            }
            let size: CGFloat = active ? 8 : 7
            ctx.fill(circle(CGPoint(x: puck.x, y: puck.y + 1.5), size + 0.5), with: .color(Color.black.opacity(0.35)))
            ctx.fill(circle(puck, size), with: .color(color))
            ctx.stroke(circle(puck, size), with: .color(white.opacity(0.95)), lineWidth: 1.5)

            ctx.draw(Text("SCREEN").font(.system(size: 8.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.tertiary),
                     at: CGPoint(x: g.centre.x, y: g.centre.y - g.rim - 8))
        }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// Arc between two bearings (degrees from straight ahead, clockwise).
    private func arc(_ g: Geometry, _ from: Double, _ to: Double, _ radius: CGFloat) -> Path {
        var p = Path()
        p.addArc(center: g.centre, radius: radius, startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
        return p
    }

    /// A small speaker pointing down the page (towards the centre once rotated to its bearing).
    private func speakerGlyph() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: -2.6, y: -4.6, width: 5.2, height: 3.6), cornerSize: CGSize(width: 1, height: 1))
        p.move(to: CGPoint(x: -2.2, y: -1.4))
        p.addLine(to: CGPoint(x: 2.2, y: -1.4))
        p.addLine(to: CGPoint(x: 4.6, y: 4.2))
        p.addLine(to: CGPoint(x: -4.6, y: 4.2))
        p.closeSubpath()
        return p
    }
}

enum PannerSnapshot {
    /// `Foley --snapshot-panner <png>`: draws the panner at six positions, to check its look without opening the app.
    @MainActor static func write(to url: URL) {
        let positions = [Vec3(x: 0, y: 0, z: 0), Vec3(x: -1, y: 1, z: 0), Vec3(x: 1, y: 0, z: 0),
                         Vec3(x: 0, y: -1, z: 0), Vec3(x: 0, y: 1, z: 1), Vec3(x: 0.25, y: 0.43, z: 0.4)]
        let colors: [Color] = [.purple, Theme.accent, .teal, .pink, .green, .purple]
        let sheet = HStack(spacing: 24) {
            ForEach(positions.indices, id: \.self) { i in
                PanPad(position: positions[i], color: colors[i], begin: {}) { _, _ in }.frame(width: 240)
            }
        }
        .padding(24)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let image = r.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
