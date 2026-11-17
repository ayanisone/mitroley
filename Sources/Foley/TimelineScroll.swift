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

/// Moves its content sideways with the timeline's scroll position without the parent having to know it.
struct FollowScroll: ViewModifier {
    @Environment(TimelineScroll.self) private var scroll
    /// -1 = slide against the scroll (pinned strips), 1 = ride along with it (the track names).
    let direction: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: direction < 0 ? -scroll.x : max(0, scroll.x))
    }
}

/// A pinch in progress: how far the timeline is stretched beyond the zoom it was last laid out at.
@Observable final class ZoomLive {
    var kx = 1.0
    var ky = 1.0
    /// The point in the timeline (in points from its left edge) that stays put while it stretches.
    var anchor: CGFloat = 0
}

/// Stretches its content with the pinch. Only this small wrapper follows the pinch; the lanes inside are not re-evaluated.
struct ZoomTransform: ViewModifier {
    @Environment(ZoomLive.self) private var live
    /// Width of the content, to place the anchor. 0 = this content does not stretch sideways (the track names).
    let width: CGFloat
    /// Whether this content grows taller with a track-height pinch.
    let vertical: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(x: width > 0 ? live.kx : 1, y: vertical ? live.ky : 1,
                            anchor: UnitPoint(x: width > 0 ? live.anchor / width : 0, y: 0))
    }
}
