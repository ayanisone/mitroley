import SwiftUI
import AppKit

// MARK: - Palette and metrics

enum Theme {
    static let bg = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let panel = Color(red: 0.082, green: 0.082, blue: 0.094)
    static let raised = Color.white.opacity(0.06)
    static let lane = Color.white.opacity(0.028)
    static let line = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.11)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.33)
}

enum Metrics {
    static let header: CGFloat = 216
    static let ruler: CGFloat = 24
    static let film: CGFloat = 40
    static let scene: CGFloat = 30
    static let track: CGFloat = 62
    static let lane: CGFloat = 56
    static let inspector: CGFloat = 308
}

extension TrackKind {
    var color: Color {
        switch self {
        case .ambience: Color(red: 0.25, green: 0.78, blue: 0.74)
        case .foley: Color(red: 1.0, green: 0.62, blue: 0.11)
        case .fx: Color(red: 0.69, green: 0.49, blue: 1.0)
        case .music: Color(red: 1.0, green: 0.42, blue: 0.62)
        case .dialogue: Color(red: 0.36, green: 0.66, blue: 1.0)
        }
    }
}

extension Space {
    var color: Color { Color(hue: hue, saturation: 0.52, brightness: 0.86) }
}

// MARK: - Motion
//
// Springs everywhere, critically damped by default. Bounce is reserved for things the hand threw.
// With Reduce Motion on, movement becomes a short fade.

enum Motion {
    static func ui(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 1)
    }
    static func quick(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.1) : .spring(response: 0.22, dampingFraction: 1)
    }
    static func thrown(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8)
    }
}

enum Haptics {
    /// A light tick on Force Touch trackpads when something snaps into place.
    static func snap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Buttons that answer on pointer-down

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.raised
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(prominent ? Theme.accent : tint, in: Capsule())
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Small square toggle used for mute, solo and similar switches.
struct ChipToggle: View {
    let label: String
    let on: Bool
    var tint: Color = Theme.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.secondary)
                .frame(width: 22, height: 20)
                .background(on ? tint : Theme.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.9))
    }
}

/// A two-or-more way switch drawn on an exact grid: equal segments, a 3 pt inset, and a selection
/// capsule that slides between them. Answers on pointer-down.
struct SegmentedPill<T: Hashable>: View {
    let options: [(value: T, label: String)]
    let selection: T
    var segmentWidth: CGFloat = 62
    var height: CGFloat = 26
    var size: CGFloat = 12
    /// For choices that are heavy to apply (opening another cut): the highlight lands first, then the change is made,
    /// so the work cannot freeze the highlight half way.
    var settleFirst = false
    let select: (T) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the highlight's centre is while it is being dragged.
    @State private var drag: CGFloat?
    @State private var pressed = false
    /// A choice made but not yet applied (see settleFirst).
    @State private var chosen: Int?

    private func centre(_ i: Int) -> CGFloat { CGFloat(i) * segmentWidth + segmentWidth / 2 }
    private func index(at x: CGFloat) -> Int { min(options.count - 1, max(0, Int((x / segmentWidth).rounded(.down)))) }

    // One highlight that slides: click a segment and it glides there; press and drag and it follows the pointer
    // exactly, then settles on the segment it is over when let go.
    var body: some View {
        let selected = chosen ?? (options.firstIndex { $0.value == selection } ?? 0)
        let last = centre(max(0, options.count - 1))
        let x = drag.map { min(last, max(segmentWidth / 2, $0)) } ?? centre(selected)
        let under = drag == nil ? selected : index(at: x)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(pressed ? 0.24 : 0.18))
                .frame(width: segmentWidth, height: height)
                .scaleEffect(pressed ? 0.96 : 1)
                .offset(x: x - segmentWidth / 2)
                .animation(drag == nil ? (reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8)) : nil, value: x)
                .animation(.spring(response: 0.22, dampingFraction: 0.85), value: pressed)
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    Text(option.label)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(i == under ? Color.white : Theme.secondary)
                        .frame(width: segmentWidth, height: height)
                        .animation(.easeOut(duration: 0.12), value: under)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                pressed = true
                // A plain click does not move it under the pointer; a drag does.
                if drag != nil || abs(g.translation.width) > 3 { drag = g.location.x }
            }
            .onEnded { g in
                let i = index(at: min(last, max(segmentWidth / 2, drag ?? g.location.x)))
                pressed = false
                drag = nil
                guard options[i].value != selection else { return }
                let value = options[i].value
                if settleFirst {
                    chosen = i
                    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.28)) {
                        select(value)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { chosen = nil }
                    }
                } else {
                    select(value)
                }
            })
        .padding(3)
        .background(Color.white.opacity(0.07), in: Capsule())
    }
}

// MARK: - Glass

extension View {
    /// A floating translucent surface. Liquid Glass where the system has it, a material otherwise.
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }
}

// MARK: - Slider

/// A slim slider that tracks the pointer 1:1 from where it was grabbed. Double-click resets.
struct Slide: View {
    let value: Double
    let range: ClosedRange<Double>
    var log = false
    var tint: Color = Theme.accent
    var reset: Double?
    /// What the value reads as. When set, it is shown above the knob while it is being dragged.
    var label: ((Double) -> String)?
    let begin: () -> Void
    let change: (Double) -> Void

    @State private var dragging = false
    @State private var grab: CGFloat = 0
    private let knob: CGFloat = 12

    static func decibels(_ v: Double) -> String { v <= -47.95 ? "Off" : String(format: "%+.1f dB", v) }
    static func side(_ v: Double) -> String {
        let n = Int((abs(v) * 100).rounded())
        return n == 0 ? "Centre" : (v < 0 ? "L \(n)" : "R \(n)")
    }

    private func unit(_ v: Double) -> Double {
        let c = min(range.upperBound, max(range.lowerBound, v))
        if log { return (Foundation.log(c) - Foundation.log(range.lowerBound)) / (Foundation.log(range.upperBound) - Foundation.log(range.lowerBound)) }
        return (c - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    private func value(_ u: Double) -> Double {
        let c = min(1, max(0, u))
        if log { return exp(Foundation.log(range.lowerBound) + c * (Foundation.log(range.upperBound) - Foundation.log(range.lowerBound))) }
        return range.lowerBound + c * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, u = unit(value)
            let x = u * (w - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 3)
                Capsule().fill(tint.opacity(0.9)).frame(width: x + knob / 2, height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.2 : 1)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    // The value, riding just under the knob while it is held, clear of the track's name.
                    .overlay(alignment: .bottom) {
                        if dragging, let label {
                            Text(label(value))
                                .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2.5)
                                .background(Color(white: 0.16), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                                .fixedSize()
                                .offset(y: 22)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .offset(x: x)
                    .animation(.spring(response: 0.2, dampingFraction: 1), value: dragging)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            dragging = true
                            begin()
                            // Grabbing the knob keeps the offset; clicking the track jumps to the pointer.
                            let centre = x + knob / 2
                            grab = abs(g.startLocation.x - centre) <= knob ? g.startLocation.x - centre : 0
                        }
                        change(value(Double((g.location.x - grab - knob / 2) / (w - knob))))
                    }
                    .onEnded { _ in dragging = false }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let reset { begin(); change(reset) }
            })
        }
        .frame(height: 18)
    }
}

/// Label, live value and a control underneath.
struct Field<Content: View>: View {
    let title: String
    var value: String = ""
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(value).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
            content
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

/// Plain text field in the app's style.
struct QuietField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct QuietEditor: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 64
    /// When set, Return calls this instead of starting a new line; Shift-Return or Option-Return still makes one.
    var onSubmit: (() -> Void)?
    @FocusState private var focused: Bool

    // A multi-line text field rather than a text view: the system then draws the hint, the caret and the
    // typed text on exactly the same line, and the box grows with what is written.
    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...10)
            .focused($focused)
            .onKeyPress(.return, phases: .down) { press in
                guard let onSubmit, !press.modifiers.contains(.shift), !press.modifiers.contains(.option) else { return .ignored }
                onSubmit()
                return .handled
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
    }
}
