import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// The timeline while it is being pinched. Laying out the real timeline (hundreds of small views) on every
/// tick of a pinch is too slow, so for the length of the pinch the whole thing is drawn here in one pass at
/// the zoom the fingers have reached: sharp text, true proportions, nothing stretched. When the pinch pauses
/// or ends, the real timeline is laid out once at that zoom and this steps aside.
struct ZoomPreview: View {
    @Environment(Store.self) private var store
    @Environment(ZoomLive.self) private var live
    @Environment(TimelineScroll.self) private var scroll

    var body: some View {
        if live.active {
            let pps = live.pps, x0 = live.x, scrollY = scroll.y
            Canvas { ctx, size in
                draw(&ctx, size, pps: pps, x0: x0, scrollY: scrollY)
            }
            .background(Theme.panel)
            .allowsHitTesting(false)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, pps: Double, x0: CGFloat, scrollY: CGFloat) {
        let p = store.project
        let pinned = Metrics.ruler + Metrics.film + Metrics.scene
        func x(_ t: Double) -> CGFloat { CGFloat(t * pps) - x0 }
        let content = CGFloat(p.extent * pps) + 24
        let right = min(size.width, content - x0)
        let line = Theme.line

        // Lanes, under the pinned strip.
        var lanes = ctx
        lanes.clip(to: Path(CGRect(x: 0, y: pinned, width: size.width, height: size.height - pinned)))
        var y = pinned - scrollY
        var rows: [(top: CGFloat, height: CGFloat)] = []
        for row in p.rows {
            switch row {
            case .group(let group, _):
                let h = Metrics.group
                if y + h > pinned && y < size.height {
                    lanes.fill(Path(CGRect(x: 0, y: y, width: right, height: h)), with: .color(.white.opacity(0.045)))
                    let members = p.tracks.filter { $0.groupID == group.id }
                    let each = members.isEmpty ? 0 : min(5, (h - 10) / CGFloat(members.count))
                    for (i, t) in members.enumerated() {
                        for c in t.clips where x(c.end) > 0 && x(c.start) < size.width {
                            let r = CGRect(x: x(c.start), y: y + 5 + CGFloat(i) * each, width: max(1.5, CGFloat(c.duration * pps)), height: max(1, each - 1))
                            lanes.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(t.kind.color.opacity(group.mute || t.mute ? 0.25 : 0.7)))
                        }
                    }
                    lanes.fill(Path(CGRect(x: 0, y: y + h - 1, width: right, height: 1)), with: .color(line))
                }
                rows.append((y, h))
                y += h
            case .track(let track):
                let h = store.rowHeight(track)
                if y + h > pinned && y < size.height { drawTrack(&lanes, track, top: y, height: h, right: right, size: size, pps: pps, x: x) }
                rows.append((y, h))
                y += h
                if let param = track.lane {
                    let lh = Metrics.lane
                    if y + lh > pinned && y < size.height { drawAutomation(&lanes, track, param, top: y, right: right, size: size, pps: pps, x0: x0) }
                    y += lh
                }
            }
        }
        lanes.fill(Path(CGRect(x: 0, y: y, width: right, height: Metrics.master)), with: .color(.white.opacity(0.045)))
        lanes.fill(Path(CGRect(x: 0, y: y + Metrics.master - 1, width: right, height: 1)), with: .color(line))

        if store.showTimeGrid {
            var step = store.gridStep
            var every = 1
            while step * Double(every) * pps < 7 { every *= every == 1 ? 2 : (every == 2 ? 5 : 2); if every > 100000 { break } }
            step *= Double(every)
            let major = max(1, Int((1 / step).rounded()))
            var i = max(0, Int((Double(x0) / pps / step).rounded(.down)))
            while Double(i) * step <= p.duration + 0.0001 {
                let gx = x(Double(i) * step)
                if gx > size.width { break }
                lanes.fill(Path(CGRect(x: gx, y: pinned, width: 1, height: size.height - pinned)),
                           with: .color(GridLayer.color.opacity(step >= 1 || i % major == 0 ? 0.22 : 0.09)))
                i += 1
            }
        }

        // Pinned strip: ruler, filmstrip, scenes.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: pinned)), with: .color(Theme.panel))
        drawRuler(&ctx, p, size: size, pps: pps, x0: x0)
        drawFilm(&ctx, p, top: Metrics.ruler, size: size, pps: pps, x: x)
        drawScenes(&ctx, p, top: Metrics.ruler + Metrics.film, right: right, size: size, pps: pps, x: x)

        // Playhead.
        let px = x(store.player.time)
        if px > -6 && px < size.width + 6 {
            ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.accent))
            ctx.fill(Path(roundedRect: CGRect(x: px - 5.5, y: 0, width: 11, height: 13), cornerRadius: 2.5), with: .color(Theme.accent))
        }
    }

    private func drawTrack(_ ctx: inout GraphicsContext, _ track: Track, top: CGFloat, height: CGFloat, right: CGFloat,
                           size: CGSize, pps: Double, x: (Double) -> CGFloat) {
        let color = track.kind.color
        ctx.fill(Path(CGRect(x: 0, y: top, width: right, height: height)),
                 with: .color(store.selection == .track(track.id) ? Color.white.opacity(0.045) : Theme.lane))
        if store.showSceneGrid {
            for s in store.project.scenes where s.start > 0.01 {
                let gx = x(s.start)
                if gx >= 0 && gx <= size.width { ctx.fill(Path(CGRect(x: gx, y: top, width: 1, height: height)), with: .color(.white.opacity(0.1))) }
            }
        }
        for clip in track.clips {
            let cx = x(clip.start), w = max(4, CGFloat(clip.duration * pps)), h = height - 8
            guard cx + w > 0 && cx < size.width else { continue }
            let rect = CGRect(x: cx, y: top + 4, width: w, height: h)
            let shape = Path(roundedRect: rect, cornerRadius: 6, style: .continuous)
            let selected = store.selection == .clip(clip.id)
            let empty = clip.takes.isEmpty
            ctx.fill(shape, with: .color(color.opacity(empty ? (selected ? 0.2 : 0.08) : (selected ? 0.4 : 0.24))))
            var inside = ctx
            inside.clip(to: shape)
            // Waveform, only the part on screen.
            let from = max(0, -cx), to = min(w, size.width - cx)
            if let take = clip.take, to > from {
                let wave = WaveCanvas.path(clip: clip, url: store.url(for: take), pps: pps, from: from, width: to - from, height: h - 18)
                inside.translateBy(x: cx + from, y: top + 4 + 15)
                inside.fill(wave, with: .color(color.opacity(0.95)))
                inside.translateBy(x: -(cx + from), y: -(top + 4 + 15))
            }
            // Fades.
            let fin = min(w, CGFloat(clip.fadeIn * pps)), fout = min(w, CGFloat(clip.fadeOut * pps))
            inside.translateBy(x: cx, y: top + 4)
            if fin >= 4 {
                let curve = FadeCurves.curve(from: 0, to: fin, height: h) { clip.inShape.gain(Float($0 / fin)) }
                var shade = curve
                shade.addLine(to: .zero); shade.closeSubpath()
                inside.fill(shade, with: .color(.black.opacity(0.35)))
                inside.stroke(curve, with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            if fout >= 4 {
                let curve = FadeCurves.curve(from: w - fout, to: w, height: h) { clip.outShape.gain(Float((w - $0) / fout)) }
                var shade = curve
                shade.addLine(to: CGPoint(x: w, y: 0)); shade.closeSubpath()
                inside.fill(shade, with: .color(.black.opacity(0.35)))
                inside.stroke(curve, with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            inside.translateBy(x: -cx, y: -(top + 4))
            if w > 18 {
                let name = clip.pending > 0 && empty ? "Generating…" : clip.name
                inside.draw(Text(name).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white.opacity(0.92)),
                            at: CGPoint(x: max(cx, 0) + 6, y: top + 4 + 7.5), anchor: .leading)
            }
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.4, dy: 0.4), cornerRadius: 6, style: .continuous),
                       with: .color(selected ? Color.white.opacity(0.9) : color.opacity(empty ? 0.9 : 0.55)),
                       style: StrokeStyle(lineWidth: selected ? 1.5 : 0.75, dash: empty ? [4, 3] : []))
        }
        ctx.fill(Path(CGRect(x: 0, y: top + height - 1, width: right, height: 1)), with: .color(Theme.line))
    }

    private func drawAutomation(_ ctx: inout GraphicsContext, _ track: Track, _ param: AutoParam, top: CGFloat, right: CGFloat,
                                size: CGSize, pps: Double, x0: CGFloat) {
        let pad: CGFloat = 8, h = Metrics.lane, color = track.kind.color
        func y(_ v: Double) -> CGFloat { top + pad + CGFloat(1 - param.unit(v)) * (h - 2 * pad) }
        ctx.fill(Path(CGRect(x: 0, y: top, width: right, height: h)), with: .color(.black.opacity(0.18)))
        let keys = track.keys(param)
        if !keys.isEmpty {
            var path = Path()
            var sx: CGFloat = 0
            path.move(to: CGPoint(x: 0, y: y(interpolate(keys, at: Double(x0) / pps, log: param.isLog) ?? keys[0].value)))
            while sx <= right {
                let v = interpolate(keys, at: Double(sx + x0) / pps, log: param.isLog) ?? keys[0].value
                path.addLine(to: CGPoint(x: sx, y: y(v)))
                sx += 1.5
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            for k in keys {
                let kx = CGFloat(k.time * pps) - x0
                guard kx > -8 && kx < size.width + 8 else { continue }
                let dot = Path(ellipseIn: CGRect(x: kx - 5, y: y(k.value) - 5, width: 10, height: 10))
                ctx.fill(dot, with: .color(color))
                ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
        }
        ctx.fill(Path(CGRect(x: 0, y: top + h - 1, width: right, height: 1)), with: .color(Theme.line))
    }

    private func drawRuler(_ ctx: inout GraphicsContext, _ p: Project, size: CGSize, pps: Double, x0: CGFloat) {
        let h = Metrics.ruler
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * pps >= 64 } ?? 600
        if let r = p.loopRange {
            let on = store.player.loop
            let band = CGRect(x: CGFloat(r.lowerBound * pps) - x0, y: 0, width: CGFloat((r.upperBound - r.lowerBound) * pps), height: h)
            ctx.fill(Path(band), with: .color(Theme.accent.opacity(on ? 0.28 : 0.1)))
            ctx.fill(Path(CGRect(x: band.minX, y: 0, width: band.width, height: 2)), with: .color(Theme.accent.opacity(on ? 1 : 0.4)))
        }
        var t = max(0, (Double(x0) / pps / step).rounded(.down) - 1) * step
        while t <= p.duration + 0.001 {
            let tx = CGFloat(t * pps) - x0
            if tx > size.width { break }
            ctx.fill(Path(CGRect(x: tx, y: h - 7, width: 1, height: 7)), with: .color(.white.opacity(0.25)))
            let label = step < 1 ? String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                                 : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
            ctx.draw(Text(label).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.45)),
                     at: CGPoint(x: tx + 4, y: h / 2 - 2), anchor: .leading)
            for k in 1..<4 {
                let mx = CGFloat((t + step * Double(k) / 4) * pps) - x0
                ctx.fill(Path(CGRect(x: mx, y: h - 3, width: 1, height: 3)), with: .color(.white.opacity(0.14)))
            }
            t += step
        }
    }

    private func drawFilm(_ ctx: inout GraphicsContext, _ p: Project, top: CGFloat, size: CGSize, pps: Double, x: (Double) -> CGFloat) {
        let frames = store.filmstrip, h = Metrics.film
        let total = CGFloat((p.video?.duration ?? p.duration) * pps)
        guard !frames.isEmpty, total > 0 else {
            ctx.fill(Path(CGRect(x: x(0), y: top, width: total, height: h)), with: .color(Theme.lane))
            return
        }
        let each = total / CGFloat(frames.count)
        var film = ctx
        film.opacity = 0.8
        for (i, image) in frames.enumerated() {
            let fx = x(0) + CGFloat(i) * each
            guard fx + each > 0 && fx < size.width else { continue }
            let cell = CGRect(x: fx, y: top, width: each, height: h)
            // Fill the cell, keeping the picture's shape, as the real filmstrip does.
            let s = image.size
            let scale = max(each / max(1, s.width), h / max(1, s.height))
            let w = s.width * scale, ih = s.height * scale
            var one = film
            one.clip(to: Path(cell))
            one.draw(Image(nsImage: image), in: CGRect(x: cell.midX - w / 2, y: cell.midY - ih / 2, width: w, height: ih))
        }
    }

    private func drawScenes(_ ctx: inout GraphicsContext, _ p: Project, top: CGFloat, right: CGFloat, size: CGSize,
                            pps: Double, x: (Double) -> CGFloat) {
        ctx.fill(Path(CGRect(x: 0, y: top, width: right, height: Metrics.scene)), with: .color(.black.opacity(0.2)))
        for scene in p.scenes {
            let sx = x(scene.start), w = max(2, CGFloat((scene.end - scene.start) * pps) - 1)
            guard sx + w > 0 && sx < size.width else { continue }
            let space = p.space(scene.spaceID)
            let color = space?.color ?? Color.white.opacity(0.35)
            let selected = store.selection == .scene(scene.id)
            let rect = CGRect(x: sx, y: top + 3, width: w, height: Metrics.scene - 6)
            let shape = Path(roundedRect: rect, cornerRadius: 5, style: .continuous)
            ctx.fill(shape, with: .color(color.opacity(selected ? 0.5 : 0.26)))
            var inside = ctx
            inside.clip(to: shape)
            inside.fill(Path(ellipseIn: CGRect(x: sx + 7, y: rect.midY - 3, width: 6, height: 6)), with: .color(color))
            var tx = sx + 18
            if let status = scene.status {
                let tag = inside.resolve(Text(status == "new" ? "NEW" : "LONGER").font(.system(size: 8.5, weight: .bold)).foregroundColor(.black.opacity(0.85)))
                let tw = tag.measure(in: CGSize(width: 200, height: 20)).width + 8
                inside.fill(Path(roundedRect: CGRect(x: tx, y: rect.midY - 6.5, width: tw, height: 13), cornerRadius: 6.5), with: .color(Theme.accent))
                inside.draw(tag, at: CGPoint(x: tx + 4, y: rect.midY), anchor: .leading)
                tx += tw + 5
            }
            let name = inside.resolve(Text(scene.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white))
            inside.draw(name, at: CGPoint(x: tx, y: rect.midY), anchor: .leading)
            if let space, w > 150 {
                let nw = name.measure(in: CGSize(width: 1000, height: 20)).width
                inside.draw(Text(space.name).font(.system(size: 10.5)).foregroundColor(Theme.secondary), at: CGPoint(x: tx + nw + 5, y: rect.midY), anchor: .leading)
            }
            if selected { ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 5, style: .continuous), with: .color(.white.opacity(0.85)), lineWidth: 1) }
        }
    }
}
