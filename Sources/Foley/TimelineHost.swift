import SwiftUI
import AppKit

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// The lanes: everything that scrolls both ways.
struct LanesRoot: View {
    @Environment(Store.self) private var store
    let pps: Double
    let contentWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            GridLayer(pps: pps)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.project.rows) { row in
                    switch row {
                    case .group(let group, _):
                        GroupLane(group: group, pps: pps)
                    case .track(let track):
                        TrackLane(track: track, pps: pps)
                        if let param = track.lane {
                            AutomationLane(track: track, param: param, pps: pps)
                        }
                    }
                }
                Rectangle().fill(Color.white.opacity(0.045)).frame(height: Metrics.master)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                Color.clear.frame(height: 44)
            }
            PlayheadView(pps: pps, handle: false)
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .coordinateSpace(.named("lanes"))
        // Room for the track names on the left and the ruler strip on top, which float over this.
        .padding(.leading, Metrics.header + 1)
        .padding(.top, Metrics.ruler + Metrics.film + Metrics.scene)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
    }
}

/// Ruler, filmstrip and scenes: scrolls sideways with the lanes, stays put vertically.
struct PinnedRoot: View {
    let pps: Double
    let contentWidth: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                RulerView(pps: pps)
                FilmstripView(pps: pps)
                SceneLane(pps: pps)
            }
            PlayheadView(pps: pps, handle: true)
        }
        .frame(width: contentWidth, height: Metrics.ruler + Metrics.film + Metrics.scene, alignment: .topLeading)
        .background { GlassCover() }
    }
}

/// Track names: scrolls up and down with the lanes, stays put sideways.
struct HeadersRoot: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            TrackHeaders().frame(width: Metrics.header)
            Rectangle().fill(Theme.line).frame(width: 1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { GlassCover() }
    }
}

/// A scroll view that reports pinches instead of magnifying itself.
final class TimelineScrollView: NSScrollView {
    /// (total magnification since the pinch began, x in this view, Option held, ended)
    var onPinch: ((CGFloat, CGFloat, Bool, Bool) -> Void)?
    private var total: CGFloat = 1

    override func magnify(with event: NSEvent) {
        if event.phase == .began { total = 1 }
        total *= 1 + event.magnification
        let x = convert(event.locationInWindow, from: nil).x
        let ended = event.phase == .ended || event.phase == .cancelled
        onPinch?(total, x, event.modifierFlags.contains(.option), ended)
        if ended { total = 1 }
    }
}

/// The timeline in a native scroll view. Scrolling moves layers and nothing else: the ruler strip and the track
/// names are floating subviews, pinned by AppKit, so a scroll tick never reaches the SwiftUI views inside.
struct TimelineHost: NSViewRepresentable {
    let store: Store
    let scroll: TimelineScroll
    let pps: Double
    let contentWidth: CGFloat
    let onPinch: (CGFloat, CGFloat, Bool, Bool) -> Void

    final class Coordinator: NSObject {
        var lanes: NSHostingView<AnyView>!
        var pinned: NSHostingView<AnyView>!
        var headers: NSHostingView<AnyView>!
        weak var view: TimelineScrollView?
        var scroll: TimelineScroll?
        var contentWidth: CGFloat = 0
        var pps = 0.0
        var pending: CGPoint?
        var laying = false
        var stale = true
        var lanesHeight: CGFloat = 0
        var headersHeight: CGFloat = 0
        var started = false

        @objc func boundsChanged(_ n: Notification) {
            guard let v = view else { return }
            let o = v.contentView.bounds.origin
            scroll?.set(x: o.x, y: o.y)
        }

        @objc func frameChanged(_ n: Notification) { layout() }

        /// Sizes the document to its content and puts the floating parts in place.
        func layout() {
            guard let v = view, !laying else { return }
            laying = true
            defer { laying = false }
            let pinnedHeight = Metrics.ruler + Metrics.film + Metrics.scene
            let side = Metrics.header + 1
            let viewport = v.contentView.bounds.size
            // Asking SwiftUI how tall everything is means measuring every row; only done when rows may have changed.
            if stale {
                stale = false
                lanesHeight = lanes.intrinsicContentSize.height
                headersHeight = headers.intrinsicContentSize.height
            }
            // The document is as big as the timeline, whatever the window is doing: resizing the window then moves
            // nothing inside it.
            let width = side + contentWidth
            let height = max(lanesHeight, pinnedHeight + headersHeight)
            let doc = NSRect(x: 0, y: 0, width: width, height: height)
            if lanes.frame != doc { lanes.frame = doc }
            let hf = NSRect(x: headers.frame.origin.x, y: pinnedHeight, width: side, height: height - pinnedHeight)
            if headers.frame.size != hf.size || headers.frame.origin.y != hf.origin.y { headers.frame = hf }
            let pf = NSRect(x: side, y: pinned.frame.origin.y, width: contentWidth, height: pinnedHeight)
            if pinned.frame.size != pf.size || pinned.frame.origin.x != pf.origin.x { pinned.frame = pf }
            if !started, viewport.height > 0 {
                started = true
                scrollTo(.zero)
            }
            if let p = pending {
                pending = nil
                scrollTo(p)
            }
        }

        func scrollTo(_ p: CGPoint) {
            guard let v = view, let doc = v.documentView else { return }
            let size = v.contentView.bounds.size
            let x = min(max(0, p.x), max(0, doc.frame.width - size.width))
            let y = min(max(0, p.y), max(0, doc.frame.height - size.height))
            v.contentView.scroll(to: NSPoint(x: x, y: y))
            v.reflectScrolledClipView(v.contentView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func wrap<V: View>(_ v: V) -> AnyView {
        AnyView(v.environment(store).environment(scroll).environment(store.zoomLive).environment(\.colorScheme, .dark))
    }

    func makeNSView(context: Context) -> TimelineScrollView {
        let c = context.coordinator
        let v = TimelineScrollView()
        v.hasHorizontalScroller = true
        v.hasVerticalScroller = true
        v.autohidesScrollers = true
        v.scrollerStyle = .overlay
        // No fill of its own: the lanes bring their own, and a colour fixed here would not follow the theme.
        v.drawsBackground = false
        v.allowsMagnification = false
        v.usesPredominantAxisScrolling = false
        // Views do not clip by default; without this the floating track names show outside the timeline.
        v.clipsToBounds = true
        v.contentView.clipsToBounds = true
        c.lanes = NSHostingView(rootView: wrap(LanesRoot(pps: pps, contentWidth: contentWidth)))
        c.pinned = NSHostingView(rootView: wrap(PinnedRoot(pps: pps, contentWidth: contentWidth)))
        c.headers = NSHostingView(rootView: wrap(HeadersRoot()))
        for h in [c.lanes!, c.pinned!, c.headers!] {
            // Only used to ask each part how tall it wants to be; the frames are set by hand in layout().
            h.sizingOptions = [.intrinsicContentSize]
            h.translatesAutoresizingMaskIntoConstraints = true
            h.autoresizingMask = []
        }
        v.documentView = c.lanes
        // Pinned by AppKit: these do not move on the axis named.
        v.addFloatingSubview(c.pinned, for: .vertical)
        v.addFloatingSubview(c.headers, for: .horizontal)
        c.view = v
        c.scroll = scroll
        c.contentWidth = contentWidth
        c.pps = pps
        v.contentView.postsBoundsChangedNotifications = true
        v.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: v.contentView)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.frameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: v.contentView)
        v.onPinch = onPinch
        store.scrollTimeline = { [weak c] p in
            // The document may still be the old size; scroll now and again once it has been laid out.
            c?.pending = p
            c?.scrollTo(p)
        }
        store.relayoutTimeline = { [weak c] in DispatchQueue.main.async { c?.stale = true; c?.layout() } }
        DispatchQueue.main.async { c.layout() }
        return v
    }

    /// Takes whatever space it is offered. Without this SwiftUI asks the scroll view for its fitting size on every layout pass.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 400)
    }

    func updateNSView(_ v: TimelineScrollView, context: Context) {
        let c = context.coordinator
        // Only when the scale has changed: handing SwiftUI a new root re-lays-out every clip.
        if c.pps != pps || c.contentWidth != contentWidth {
            c.lanes.rootView = wrap(LanesRoot(pps: pps, contentWidth: contentWidth))
            c.pinned.rootView = wrap(PinnedRoot(pps: pps, contentWidth: contentWidth))
            c.pps = pps
            c.contentWidth = contentWidth
            c.stale = true
        }
        v.onPinch = onPinch
        c.layout()
        // Row heights can change without this view being told (track height); settle once more after SwiftUI has.
        if c.stale || c.lanesHeight == 0 { DispatchQueue.main.async { c.stale = true; c.layout() } }
    }
}
