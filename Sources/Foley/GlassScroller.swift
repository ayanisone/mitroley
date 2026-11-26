import AppKit
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// A scroll bar as a sliver of glass: no track, a thin clear capsule with a lit upper edge that floats over what it scrolls,
/// thickens a little under the pointer, and fades away when nothing is moving. It takes no room of its own.
final class GlassScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { self == GlassScroller.self }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 11 }

    private var over = false { didSet { if over != oldValue { swell() } } }
    private var pressed = false
    /// 0 thin … 1 thick, eased between the two so it swells and settles instead of jumping.
    private var fat: CGFloat = 0
    private var timer: Timer?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); over = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); over = false }
    override func mouseDown(with event: NSEvent) {
        pressed = true; swell()
        super.mouseDown(with: event)   // returns when the button comes up
        pressed = false; swell()
    }

    private func swell() {
        guard timer == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { fat = over || pressed ? 1 : 0; needsDisplay = true; return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let goal: CGFloat = self.over || self.pressed ? 1 : 0
            self.fat += (goal - self.fat) * 0.3
            if abs(goal - self.fat) < 0.02 { self.fat = goal; t.invalidate(); self.timer = nil }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // No track: only the glass.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func draw(_ dirtyRect: NSRect) { drawKnob() }

    override func drawKnob() {
        let slot = rect(for: .knob)
        guard slot.width > 0, slot.height > 0 else { return }
        let across = bounds.width > bounds.height
        let thick = 3.5 + 3.5 * fat
        // Hugs the outer edge, a hair off it, and never shorter than a pill.
        var r = across
            ? NSRect(x: slot.minX + 2, y: bounds.maxY - thick - 2, width: max(22, slot.width - 4), height: thick)
            : NSRect(x: bounds.maxX - thick - 2, y: slot.minY + 2, width: thick, height: max(22, slot.height - 4))
        if across { r.origin.x = min(r.origin.x, bounds.maxX - r.width - 2) } else { r.origin.y = min(r.origin.y, bounds.maxY - r.height - 2) }
        let pill = NSBezierPath(roundedRect: r, xRadius: thick / 2, yRadius: thick / 2)
        // A soft dark rim first, so it still reads over a bright waveform or picture.
        NSColor.black.withAlphaComponent(0.28).setStroke()
        let rim = NSBezierPath(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), xRadius: thick / 2 + 0.5, yRadius: thick / 2 + 0.5)
        rim.lineWidth = 1
        rim.stroke()
        // The body: clear glass, brighter along one edge as if lit from above.
        let lift = 0.10 * fat + (pressed ? 0.08 : 0)
        let body = NSGradient(colors: [NSColor.white.withAlphaComponent(0.46 + lift), NSColor.white.withAlphaComponent(0.2 + lift), NSColor.white.withAlphaComponent(0.3 + lift)],
                              atLocations: [0, 0.55, 1], colorSpace: .sRGB)
        body?.draw(in: pill, angle: across ? (isFlipped ? 90 : -90) : 0)
        // A fine bright line just inside the edge: the glint.
        NSColor.white.withAlphaComponent(0.5 + 0.2 * fat).setStroke()
        let glint = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0.5, thick / 2 - 0.5), yRadius: max(0.5, thick / 2 - 0.5))
        glint.lineWidth = 0.5
        glint.stroke()
    }
    deinit { timer?.invalidate() }
}

extension NSScrollView {
    /// Swaps in the glass scroll bars, floating over the content.
    func useGlassScrollers() {
        if !(verticalScroller is GlassScroller) { verticalScroller = GlassScroller() }
        if !(horizontalScroller is GlassScroller) { horizontalScroller = GlassScroller() }
        if scrollerStyle != .overlay { scrollerStyle = .overlay }
        verticalScroller?.scrollerStyle = .overlay
        horizontalScroller?.scrollerStyle = .overlay
    }
}

/// Sits behind a SwiftUI ScrollView, the same size as it, finds the AppKit scroll view drawn in that place and gives it
/// the glass scroll bars.
private struct GlassScrollerProbe: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // Mac settings can ask for bars that are always shown; keep ours when that changes.
            NotificationCenter.default.removeObserver(self)
            if window != nil {
                NotificationCenter.default.addObserver(self, selector: #selector(apply), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            }
        }
        override func layout() { super.layout(); apply(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.apply() } }
        @objc func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let root = self.window?.contentView else { return }
                let mine = self.convert(self.bounds, to: nil)
                guard mine.width > 4, mine.height > 4 else { return }
                // The scroll view that shares most of this place. SwiftUI's can be a little larger or smaller than the view
                // it was made for, so a share of the area is asked for, not an exact fit.
                var best: (NSScrollView, CGFloat)?
                func look(_ v: NSView) {
                    if let s = v as? NSScrollView, !(s is TimelineScrollView) {
                        let f = s.convert(s.bounds, to: nil), both = f.intersection(mine)
                        let share = both.isNull ? 0 : both.width * both.height / max(1, max(f.width * f.height, mine.width * mine.height))
                        if share > 0.6, share > (best?.1 ?? 0) { best = (s, share) }
                        return
                    }
                    for c in v.subviews { look(c) }
                }
                look(root)
                best?.0.useGlassScrollers()
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) { v.apply() }
}

extension View {
    /// On a ScrollView: thin glass scroll bars in place of the system's.
    func glassScrollers() -> some View { background(GlassScrollerProbe().allowsHitTesting(false)) }
}
