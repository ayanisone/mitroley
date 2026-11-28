import SwiftUI
import AppKit

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// The lanes: everything that scrolls both ways.
struct LanesRoot: View {
    @Environment(Store.self) private var store
    @Environment(ZoomLive.self) private var live
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
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .coordinateSpace(.named("lanes"))
        // During a pinch the one-pass drawing stands in for what is in the lanes. Only the contents step aside: the
        // tint behind them stays, so the timeline and the track names over it keep exactly the tone they have at rest.
        .opacity(live.active ? 0.01 : 1)
        // Room for the track names on the left and the ruler strip on top, which float over this.
        .padding(.leading, Metrics.header + 1)
        .padding(.top, Metrics.ruler + Metrics.film + Metrics.scene)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
    }
}

/// Ruler, filmstrip and scenes: scrolls sideways with the lanes, stays put vertically.
struct PinnedRoot: View {
    @Environment(ZoomLive.self) private var live
    let pps: Double
    let contentWidth: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                RulerView(pps: pps)
                FilmstripView(pps: pps)
                SceneLane(pps: pps)
            }
        }
        .opacity(live.active ? 0.01 : 1)
        .frame(width: contentWidth, height: Metrics.ruler + Metrics.film + Metrics.scene, alignment: .topLeading)
        .background { GlassCover() }
    }
}

/// Track names: scrolls up and down with the lanes, stays put sideways.
struct HeadersRoot: View {
    @Environment(ZoomLive.self) private var live
    @Environment(TimelineScroll.self) private var scroll
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // While track height is being changed these are the real names, sized to the height the fingers have reached
            // and moved to where the lanes are being drawn, so nothing about their look changes.
            TrackHeaders().frame(width: Metrics.header)
                .offset(y: live.active ? scroll.y - live.y : 0)
            Rectangle().fill(Theme.line).frame(width: 1)
        }
        // Exactly the height it is given, with the names hung from the top: while the tracks are being made taller the
        // names are taller than this, and without a least height of nothing they were centred and slid out of step.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background { PanelTint() }
    }
}

/// The playhead: a plain coloured layer that is only ever moved. As a SwiftUI view inside the lanes it made the whole
/// timeline run its layout again on every frame of playback, which was most of what playing cost.
final class PlayheadBar: NSView {
    private let knob = CALayer()
    init(handle: Bool) {
        super.init(frame: .zero)
        // Its own layer, made here: one handed out by the system later is not there yet to be coloured.
        layer = CALayer()
        wantsLayer = true
        layer?.zPosition = 50
        layer?.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        if handle {
            knob.cornerRadius = 2.5
            knob.cornerCurve = .continuous
            knob.actions = layer?.actions
            knob.frame = CGRect(x: -4.75, y: 0, width: 11, height: 13)
            layer?.addSublayer(knob)
            layer?.masksToBounds = false
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func tint(_ c: CGColor) {
        if layer?.backgroundColor != c { layer?.backgroundColor = c; knob.backgroundColor = c }
    }
}

/// A scroll view that reports pinches instead of magnifying itself.
final class TimelineScrollView: NSScrollView {
    /// (total magnification since the pinch began, x in this view, Option held, ended)
    var onPinch: ((CGFloat, CGPoint, Bool, Bool) -> Void)?
    private var total: CGFloat = 1

    /// The glass bars float over the lanes whatever the Mac's own setting says, so they never take a strip of the timeline.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    /// A finger on the trackpad: which one, and where, in points of the trackpad's own size.
    private struct Finger { let id: NSObjectProtocol; let x: CGFloat; let y: CGFloat }
    private var fingers: [Finger] = []
    /// Where the two fingers were when both came down.
    private var down: [Finger] = []
    /// The two-hand gesture is under way: a finger on the left and one on the right moving opposite ways, up and down.
    private var stretching = false
    private var stretch: CGFloat = 1
    /// A one-hand pinch is under way.
    private var pinching = false
    /// The one-hand pinch under way has its fingers one above the other.
    private var upright = false

    /// Where the pointer is in this view, measured from its top left. The view's own coordinates run up from the
    /// bottom, and using those made a height change hold on to the wrong row and jump somewhere else.
    private func fromTop(_ p: NSPoint) -> CGPoint {
        let q = convert(p, from: nil)
        return CGPoint(x: q.x, y: isFlipped ? q.y : bounds.height - q.y)
    }
    private func pointer() -> CGPoint {
        guard let w = window else { return .zero }
        return fromTop(w.mouseLocationOutsideOfEventStream)
    }

    private func follow(_ event: NSEvent) {
        fingers = event.touches(matching: .touching, in: nil).map { t in
            Finger(id: t.identity, x: t.normalizedPosition.x * max(1, t.deviceSize.width), y: t.normalizedPosition.y * max(1, t.deviceSize.height))
        }
        guard fingers.count == 2 else {
            if stretching { onPinch?(stretch, pointer(), true, true) }
            stretching = false; stretch = 1; down = []
            return
        }
        if down.count != 2 || !down.allSatisfy({ d in fingers.contains { $0.id.isEqual(d.id) } }) { down = fingers; return }
        // Each finger against where it came down; the one further left first.
        let pairs = down.compactMap { d in fingers.first { $0.id.isEqual(d.id) }.map { (d, $0) } }.sorted { $0.0.x < $1.0.x }
        guard pairs.count == 2 else { return }
        let left = pairs[0].1.y - pairs[0].0.y, right = pairs[1].1.y - pairs[1].0.y
        if !stretching {
            // It begins when the fingers are well apart side by side, and one has gone up while the other went down,
            // each by more than a few points and more than it moved sideways. Two fingers moving the same way is a scroll.
            let apart = pairs[1].0.x - pairs[0].0.x
            let sideways = max(abs(pairs[0].1.x - pairs[0].0.x), abs(pairs[1].1.x - pairs[1].0.x))
            let opposite = left * right < 0 && min(abs(left), abs(right)) > 3.5
            guard apart > 45, abs(pairs[1].0.y - pairs[0].0.y) < apart, opposite, sideways < max(abs(left), abs(right)) else { return }
            // A pinch the system had already begun with the same two fingers is put back to where it started and
            // finished, so the first few points of the movement do not also zoom time and shift the view.
            if pinching { onPinch?(1, pointer(), upright, false); onPinch?(1, pointer(), upright, true); pinching = false; total = 1 }
            stretching = true
            muteScroll = true
            mutePinch = true
            // Counted from here, so the height does not jump by what it took to recognise the gesture.
            down = fingers
            return
        }
        // Right finger up and left finger down makes the tracks taller; the other way makes them shorter.
        stretch = exp(min(3, max(-3, (right - left) / 150)))
        onPinch?(stretch, pointer(), true, false)
    }
    override func touchesBegan(with event: NSEvent) { follow(event); super.touchesBegan(with: event) }
    override func touchesMoved(with event: NSEvent) { follow(event); super.touchesMoved(with: event) }
    override func touchesEnded(with event: NSEvent) { follow(event); super.touchesEnded(with: event) }
    override func touchesCancelled(with event: NSEvent) {
        if stretching { onPinch?(stretch, pointer(), true, true) }
        stretching = false; stretch = 1; down = []; fingers = []
        super.touchesCancelled(with: event)
    }
    // While the two hands are changing track height, the same fingers must not also scroll or pinch.
    /// Scrolling that belongs to the fingers of a two-hand height change, including the glide the system adds after they
    /// lift, is thrown away. It was this, arriving after the gesture, that carried the view off somewhere else.
    private var muteScroll = false
    override func scrollWheel(with event: NSEvent) {
        if stretching { muteScroll = true; return }
        if muteScroll {
            // Only a scroll that starts afresh, with fingers newly down, counts again.
            if event.phase == .began || (event.phase == [] && event.momentumPhase == []) { muteScroll = false } else { return }
        }
        super.scrollWheel(with: event)
    }
    override func rotate(with event: NSEvent) {}

    /// The system's own pinch, made by the same two fingers as a two-hand height change, is thrown away until a new
    /// pinch begins. Its leftover steps, arriving after the hands stopped, were read as a pinch in time measured from
    /// nothing, and threw the view out to the whole timeline.
    private var mutePinch = false
    override func magnify(with event: NSEvent) {
        if stretching { return }
        if event.phase == .began { mutePinch = false }
        if mutePinch { return }
        // Steps of a pinch whose beginning was never seen have nothing to be measured from.
        if event.phase != .began, !pinching { return }
        if event.phase == .began {
            total = 1
            // Which way the fingers lie on the trackpad. Side by side zooms time; one above the other zooms the
            // height of the tracks. Holding Option does the same.
            upright = fingers.count >= 2 && abs(fingers[0].y - fingers[1].y) > abs(fingers[0].x - fingers[1].x) * 1.2
        }
        total = min(1000, max(0.001, total * (1 + event.magnification)))
        let ended = event.phase == .ended || event.phase == .cancelled
        pinching = !ended
        onPinch?(total, fromTop(event.locationInWindow), upright || event.modifierFlags.contains(.option), ended)
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
    /// During a pinch the one-pass drawing stands in for the lanes and the ruler strip; the track names stay.
    var standIn = false
    let onPinch: (CGFloat, CGPoint, Bool, Bool) -> Void

    final class Coordinator: NSObject {
        var lanes: NSHostingView<AnyView>!
        var pinned: NSHostingView<AnyView>!
        var headers: NSHostingView<AnyView>!
        weak var view: TimelineScrollView?
        var scroll: TimelineScroll?
        var contentWidth: CGFloat = 0
        var pps = 0.0
        /// Where the timeline should be scrolled to once it is big enough, and until when to keep trying. After a zoom
        /// the place may lie beyond the old size; scrolled once and forgotten, the view was cut short and landed on
        /// other tracks.
        var pending: CGPoint?
        var pendingUntil = 0.0
        var laying = false
        var stale = true
        var lanesHeight: CGFloat = 0
        var headersHeight: CGFloat = 0
        var started = false
        weak var store: Store?
        /// One bar from the top of the ruler to the bottom of the lanes, on the scroll view itself, where SwiftUI never
        /// lays anything out. Moved by hand when the film plays or the timeline scrolls.
        let bar = PlayheadBar(handle: true)

        /// Puts the playhead where the film is, and asks to be told when that changes.
        @MainActor func follow() {
            withObservationTracking { place() } onChange: { [weak self] in Task { @MainActor in self?.follow() } }
        }
        @MainActor func place() {
            guard let store, let v = view else { return }
            let x = Metrics.header + 1 + CGFloat(store.player.time * pps) - v.contentView.bounds.origin.x - 0.75
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.tint(NSColor(Theme.accent).cgColor)
            bar.isHidden = store.zoomLive.active || x < Metrics.header || x > v.bounds.width
            bar.frame = NSRect(x: x, y: 0, width: 1.5, height: v.bounds.height)
            CATransaction.commit()
        }

        @objc func boundsChanged(_ n: Notification) {
            guard let v = view else { return }
            let o = v.contentView.bounds.origin
            scroll?.set(x: o.x, y: o.y)
            if let s = scroll, s.height != v.contentView.bounds.height { s.height = v.contentView.bounds.height }
            MainActor.assumeIsolated { place() }
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
            if let s = scroll, s.height != viewport.height { s.height = viewport.height }
            // Asking SwiftUI how tall everything is means measuring every row; only done when rows may have changed.
            if stale {
                stale = false
                lanesHeight = lanes.intrinsicContentSize.height
                headersHeight = headers.intrinsicContentSize.height
            }
            // The document is as big as the timeline, whatever the window is doing: resizing the window then moves
            // nothing inside it.
            guard contentWidth.isFinite, contentWidth >= 0, lanesHeight.isFinite, headersHeight.isFinite else { return }
            let width = side + contentWidth
            // Never shorter than the space it is shown in, so the lanes' own background and the track column run to the
            // bottom and no bare strip is left under the last row.
            let height = max(lanesHeight, pinnedHeight + headersHeight, viewport.height)
            let doc = NSRect(x: 0, y: 0, width: width, height: height)
            if lanes.frame != doc { lanes.frame = doc }
            let hf = NSRect(x: headers.frame.origin.x, y: pinnedHeight, width: side, height: height - pinnedHeight)
            if headers.frame.size != hf.size || headers.frame.origin.y != hf.origin.y { headers.frame = hf }
            let pf = NSRect(x: side, y: pinned.frame.origin.y, width: contentWidth, height: pinnedHeight)
            if pinned.frame.size != pf.size || pinned.frame.origin.x != pf.origin.x { pinned.frame = pf }
            MainActor.assumeIsolated { place() }
            if !started, viewport.height > 0 {
                started = true
                scrollTo(.zero)
            }
            if let p = pending, let v = view {
                scrollTo(p)
                let o = v.contentView.bounds.origin
                if (abs(o.x - p.x) < 1 && abs(o.y - p.y) < 1) || CACurrentMediaTime() > pendingUntil { pending = nil }
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
        v.useGlassScrollers()
        // No fill of its own: the lanes bring their own, and a colour fixed here would not follow the theme.
        v.drawsBackground = false
        v.allowsMagnification = false
        v.usesPredominantAxisScrolling = false
        // So a pinch can be asked where its two fingers are (side by side, or one above the other).
        v.allowedTouchTypes = [.indirect]
        v.wantsRestingTouches = true
        // One notch of a mouse wheel moves most of a track, not a sliver of one.
        v.verticalLineScroll = 44
        v.horizontalLineScroll = 44
        v.verticalPageScroll = 20
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
        c.store = store
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
            c?.pendingUntil = CACurrentMediaTime() + 0.6
            c?.scrollTo(p)
        }
        store.relayoutTimeline = { [weak c] in
            // Measured again a few times as SwiftUI settles at the new sizes, so the document reaches its real size and a
            // scroll that is waiting for it can land.
            for delay in [0, 0.06, 0.15, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { c?.stale = true; c?.layout() }
            }
        }
        DispatchQueue.main.async { v.addSubview(c.bar, positioned: .above, relativeTo: nil); c.layout(); c.follow() }
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
        store.debugPinch = onPinch
        c.layout()
        c.place()
        // Row heights can change without this view being told (track height); settle once more after SwiftUI has.
        if c.stale || c.lanesHeight == 0 { DispatchQueue.main.async { c.stale = true; c.layout() } }
    }
}
