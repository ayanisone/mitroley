import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// Where the timeline is scrolled to. Kept out of the timeline's own state so scrolling re-runs only
/// the few small views that follow it, not every lane and clip.
@Observable final class TimelineScroll {
    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0
    /// `x` in steps of 512 pt. Views that only need to know roughly what is on screen read this, so they
    /// are redrawn once per step instead of on every scroll tick.
    private(set) var page = 0
    var width: CGFloat = 1400
    /// The height of the part of the timeline on screen, ruler strip included.
    var height: CGFloat = 600

    func set(x nx: CGFloat, y ny: CGFloat) {
        if nx != x { x = nx }
        if ny != y { y = ny }
        let p = Int((max(0, nx) / 512).rounded(.down))
        if p != page { page = p }
    }

    /// The part of a strip that is on screen or within a page of it, in the strip's own coordinates.
    /// `start` is the strip's left edge in timeline points. nil = nothing of it is near the screen.
    func window(start: CGFloat, width w: CGFloat) -> (lo: CGFloat, hi: CGFloat)? {
        let left = CGFloat(page) * 512 - 512 - start
        let right = CGFloat(page) * 512 + 512 + width + 512 - start
        let lo = max(0, left), hi = min(w, right)
        return hi > lo ? (lo, hi) : nil
    }
}

/// A Canvas that only exists for the part of a long strip that is near the screen. Zoomed in, a strip can be
/// tens of thousands of points wide; drawing all of it is what made the timeline stutter. The drawing code
/// still works in the strip's full coordinates and is told which range is worth drawing.
struct SlicedCanvas: View {
    @Environment(TimelineScroll.self) private var scroll
    let start: CGFloat
    let width: CGFloat
    let draw: (inout GraphicsContext, CGSize, ClosedRange<CGFloat>) -> Void

    var body: some View {
        if width <= 2048 {
            Canvas { ctx, size in draw(&ctx, size, 0...max(0, size.width)) }
        } else if let w = scroll.window(start: start, width: width) {
            Canvas { ctx, size in
                ctx.translateBy(x: -w.lo, y: 0)
                draw(&ctx, CGSize(width: width, height: size.height), w.lo...w.hi)
            }
            .frame(width: w.hi - w.lo)
            .offset(x: w.lo)
            .frame(width: width, alignment: .leading)
        } else {
            Color.clear
        }
    }
}

/// A pinch in progress: the zoom the fingers have reached, before the real timeline has been laid out at it.
@Observable final class ZoomLive {
    /// True while the one-pass drawing stands in for the real timeline.
    var active = false { didSet { if !active, shown { shown = false } } }
    /// True once the one-pass drawing has really been drawn for this pinch. The real timeline stays on screen until
    /// then: hidden the moment the pinch began, it left the lanes blank for the tenth of a second the first drawing takes.
    var shown = false
    /// How long the drawing last took, and how long its first one of this pinch took, in milliseconds.
    @ObservationIgnored var lastDraw = 0.0
    @ObservationIgnored var firstDraw = 0.0
    /// Points per second and scroll offset the drawing uses.
    var pps = 1.0
    var x: CGFloat = 0
    /// Track height is what is changing: the drawing uses `target` as the height factor and `y` as its scroll offset.
    var vertical = false
    var y: CGFloat = 0
    /// The track height factor the fingers have reached, for the track names, which follow it live.
    var rows = 1.0
    /// The zoom (or track height factor) to commit.
    @ObservationIgnored var target = 0.0 { didSet { if vertical, target > 0, rows != target { rows = target } } }
}
