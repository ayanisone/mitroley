import SwiftUI
import AVFoundation
import AppKit

struct MainView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timelineHeight: CGFloat = 380
    @State private var dragStart: CGFloat?
    @AppStorage("dockHeight") private var dockHeight = 360.0
    @State private var dockStart: CGFloat?
    @AppStorage("browserWidth") private var browserWidth = 380.0
    @State private var browserStart: CGFloat?

    var body: some View {
        @Bindable var store = store
        let side = min(520, max(300, CGFloat(browserWidth)))
        HStack(spacing: 0) {
            if store.browser {
                LibraryView(side: true)
                    .frame(width: side)
                    // One surface with its hairline, run to the top of the window like the panel on the right.
                    .background {
                        Theme.panel
                            .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                            .ignoresSafeArea()
                    }
                    .overlay(alignment: .trailing) {
                        Color.clear.frame(width: 9).contentShape(Rectangle()).offset(x: 4)
                            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { g in
                                    if browserStart == nil { browserStart = side }
                                    browserWidth = Double(min(520, max(300, (browserStart ?? side) + g.translation.width)))
                                }
                                .onEnded { _ in browserStart = nil })
                            .onTapGesture(count: 2) { browserWidth = 380 }
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
            }
            GeometryReader { geo in
                // The dock under the timeline takes its height first; the picture always keeps at least 160 pt.
                // With the dock open the timeline may go down to 150 pt, so the picture keeps 230.
                let least: CGFloat = store.dock == nil ? 180 : 150
                let dock = store.dock == nil ? 0 : min(max(326, CGFloat(dockHeight)), max(326, geo.size.height - 230 - least))
                let maxTimeline = max(least, geo.size.height - (dock > 0 ? 230 : 220) - dock)
                let tl = min(maxTimeline, max(least, timelineHeight))
                VStack(spacing: 0) {
                    VideoPane()
                    // One handle resizes picture against timeline. The drag is measured against the window: measured against the
                    // handle itself, which moves as it is dragged, the height chased its own tail and flickered.
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                        .overlay(Rectangle().fill(Color.clear).frame(height: 9).contentShape(Rectangle())
                            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { g in
                                    if dragStart == nil { dragStart = tl }
                                    timelineHeight = min(maxTimeline, max(180, (dragStart ?? tl) - g.translation.height))
                                }
                                .onEnded { _ in dragStart = nil }))
                    TimelineView()
                        .frame(height: tl)
                        // Tell the flag where the panels are, so it goes out of focus behind them.
                        .onChange(of: tl + dock, initial: true) { _, h in FlagLayout.bottom = h + (dock > 0 ? 2 : 1) }
                    if dock > 0 {
                        Rectangle()
                            .fill(Theme.line)
                            .frame(height: 1)
                            .overlay(Rectangle().fill(Color.clear).frame(height: 9).contentShape(Rectangle())
                                .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                    .onChanged { g in
                                        if dockStart == nil { dockStart = dock }
                                        dockHeight = Double(min(max(326, geo.size.height - 380), max(326, (dockStart ?? dock) - g.translation.height)))
                                    }
                                    .onEnded { _ in dockStart = nil }))
                        DockPanel()
                            .frame(height: dock)
                    }
                }
            }
            if store.sideOpen {
                Group {
                    if store.showClaude { ClaudePanel() } else { Inspector() }
                }
                .frame(width: Metrics.inspector)
                // The panel and its hairline edge are one surface, so they run to the top of the window
                // together and the edge lines up through the toolbar.
                .background {
                    Theme.panel
                        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
                        .ignoresSafeArea()
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .background { Backdrop().ignoresSafeArea() }
        .onChange(of: store.browser ? side : 0, initial: true) { _, w in FlagLayout.left = w }
        .onChange(of: store.sideOpen, initial: true) { _, open in FlagLayout.inspector = open ? Metrics.inspector : 0 }
        .animation(Motion.ui(reduceMotion), value: store.browser)
        .animation(Motion.ui(reduceMotion), value: store.sideOpen)
        .navigationTitle(store.project.name)
        // No separate title-bar material: the picture side and the panel side each keep their own colour to the top.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RoomButton()
                Button { store.toggleDock("mixer") } label: { Image(systemName: "slider.vertical.3") }
                    .hint("Mixer under the timeline: faders, buses, routing and sidechain (⌥⌘M)")
                Button { store.browser.toggle() } label: { Image(systemName: "sidebar.left") }
                    .hint("Library down the left side: your own sounds, ready to drag onto a track (⌥⌘L)")
                Button { store.showClaude.toggle() } label: {
                    Label("Claude", systemImage: "sparkle")
                }
                .hint("Let Claude fit the sound to the picture (⌘K)")
                Button { store.showExport = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .hint("Export the mix (⌘E)")
                Button { store.showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .hint("API keys and models (⌘,)")
                Button { store.toggleSide() } label: { Image(systemName: "sidebar.right") }
                    .hint(store.sideOpen ? "Put the panel on the right away, for more room (⌥⌘I)" : "Bring back the panel on the right (⌥⌘I)")
            }
        }
        .overlay(alignment: .top) { VoiceAgentStrip().animation(Motion.ui(reduceMotion), value: store.voiceAgent.isOn) }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Text(toast.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(toast.isError ? Theme.danger : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glass(in: Capsule())
                    .padding(.top, 10)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        // Text fields in a freshly shown inspector must not swallow the transport keys.
        .onChange(of: store.selection) { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .animation(Motion.ui(reduceMotion), value: store.toast)
        .animation(Motion.ui(reduceMotion), value: store.showClaude)
        .sheet(isPresented: $store.showExport) { ExportSheet().environment(store) }
        .sheet(isPresented: $store.showDub) { DubSheet().environment(store) }
        .sheet(isPresented: $store.showCutCheck) { CutCheckSheet().environment(store) }
        .overlay(alignment: .bottom) { CrashBar() }
        .overlay(alignment: .bottomLeading) { HintBox() }
        .overlay { Splash() }
        .sheet(isPresented: $store.showSettings) { SettingsSheet().environment(store) }
        // Icons only, and no "Icon and Text" choice to fall into: it also overrides a mode saved by an earlier launch.
        .background(RoomOpener())
        .background(WindowAccessor { w in
            TitleBarDoubleClick.install()
            guard let bar = w.toolbar else { return }
            bar.displayMode = .iconOnly
            bar.allowsDisplayModeCustomization = false
            bar.allowsUserCustomization = false
        })
    }
}

/// Hands the hosting NSWindow to `configure` once the view is in it, and again on every update.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    final class Probe: NSView {
        var configure: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            configure?(w)
            // SwiftUI attaches the toolbar after the content, so look once more on the next turn.
            DispatchQueue.main.async { [weak self] in if let w = self?.window { self?.configure?(w) } }
        }
    }
    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.configure = configure
        return v
    }
    func updateNSView(_ v: Probe, context: Context) {
        v.configure = configure
        if let w = v.window { configure(w) }
    }
}

// MARK: - Picture

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Nothing painted around the picture, so what is behind the view shows beside it.
    var clear = false
    final class Host: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
    func makeNSView(context: Context) -> Host {
        let v = Host()
        v.playerLayer.player = player
        if clear { v.layer?.backgroundColor = NSColor.clear.cgColor }
        return v
    }
    func updateNSView(_ v: Host, context: Context) { v.playerLayer.player = player }
}

struct VideoPane: View {
    @Environment(Store.self) private var store
    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// The one gap around the picture: above it, between it and the transport, and under the transport.
    static let gap: CGFloat = 12

    var body: some View {
        ZStack {
            // Fills the pane whatever is in it, so the tools and transport keep their places when the picture is out.
            Color.clear
            if store.project.video != nil, store.pictureOut {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
                    Text("The picture is in its own window").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                    Button("Bring It Back") { dismissWindow(id: "picture") }.buttonStyle(PillButtonStyle())
                }
                .padding(.bottom, Self.gap + TransportBar.height + Self.gap)
            } else if store.project.video != nil {
                // The picture keeps its shape inside what is left, centred; where it is shorter than that
                // space, the extra is shared equally above it and between it and the transport.
                PlayerLayerView(player: store.player.video, clear: true)
                    .overlay(alignment: .topTrailing) {
                        Button { openWindow(id: "picture") } label: {
                            Image(systemName: "macwindow.on.rectangle").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 28, height: 24)
                                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(PressStyle(scale: 0.9))
                        .hint("Move the picture into a window of its own, for a second screen")
                        .padding(6)
                        .opacity(hovering ? 1 : 0)
                    }
                    .onHover { hovering = $0 }
                    // Clicking the picture shows the session's own settings (name, picture, revised cut, spaces).
                    .onTapGesture { store.showSession() }
                    .padding(.bottom, Self.gap + TransportBar.height + Self.gap)
                    .padding([.top, .horizontal], Self.gap)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "film")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.tertiary)
                    Text("Drop a video here")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.3)
                    Text("mitroley finds the shots, then you or Claude fit the sound to them.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                    Button("Choose Video…") { Panels.importVideo(store) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .padding(.top, 4)
                }
                .padding(.bottom, 50)
            }
            if targeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(8)
            }
            if let busy = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glass(in: Capsule())
            }
        }
        .overlay(alignment: .bottom) {
            // With the browser open there is less room: the bar sheds what matters least before it would run off the pane.
            ViewThatFits(in: .horizontal) {
                TransportBar()
                TransportBar(tight: 1)
                TransportBar(tight: 2)
                TransportBar(tight: 3)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, Self.gap)
        }
        // The editing tools: a column at the left of the picture, level with its middle.
        .overlay(alignment: .leading) {
            ToolStrip()
                .padding(.leading, 14)
                // Kept inside the picture area: clear of the title bar above and the transport below.
                .padding(.top, Self.gap)
                .padding(.bottom, TransportBar.height + Self.gap * 2)
        }
        .overlay(alignment: .topTrailing) {
            // Cues that were planned but have no sound yet.
            let missing = store.missingCues.count
            if missing > 0 || store.generatingAll {
                Button { Task { await store.generateMissing() } } label: {
                    HStack(spacing: 7) {
                        if store.generatingAll { ProgressView().controlSize(.small) } else { Image(systemName: "waveform.badge.plus") }
                        Text(store.generatingAll ? "Generating, \(missing) to go" : "Generate \(missing) Sound\(missing == 1 ? "" : "s")")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .glass(in: Capsule())
                }
                .buttonStyle(PressStyle())
                .disabled(store.generatingAll)
                .padding(14)
                .hint("Generates every dashed clip from its prompt with ElevenLabs")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }) else { return false }
            Panels.loadVideo(url, store)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Transport

struct TransportBar: View {
    static let height: CGFloat = 52
    @Environment(Store.self) private var store
    /// How much has been left out to fit a narrow pane: 1 drops the film's volume slider, 2 the meter as well,
    /// 3 the Mine and Film switch too (it is still on the \ key).
    var tight = 0

    // Everything in the bar sits on one centre line, 16 pt apart, with 16 pt at both ends.
    var body: some View {
        HStack(spacing: 16) {
            Button { store.player.seek(store.player.loop ? (store.project.loopRange?.lowerBound ?? 0) : 0) } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 13)).frame(width: 20, height: 36)
            }
            .buttonStyle(PressStyle(scale: 0.88))
            .hint("Back to start (Return)")

            Button { store.player.toggle() } label: {
                Image(systemName: store.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .hint("Play or pause (Space)")

            Timecode()

            Button { store.player.loop.toggle() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(store.player.loop ? Theme.accent : Theme.secondary)
                    .frame(width: 20, height: 36)
            }
            .buttonStyle(PressStyle(scale: 0.88))
            .hint(store.project.loopRange == nil ? "Loop the whole film. Shift-drag on the ruler to loop a section."
                                                 : "Loop the marked section")
            .contextMenu {
                Button("Loop Selection") { store.loopSelection() }
                Button("Clear Loop Region") { store.clearLoop() }.disabled(store.project.loopRange == nil)
            }

            Rectangle().fill(Theme.line).frame(width: 1, height: 20)
            // The video's own soundtrack: always within reach, click the speaker to mute or restore it.
            HStack(spacing: 8) {
                Button {
                    let v = store.project.videoVolume
                    store.mutate { $0.videoVolume = v > 0.001 ? 0 : 1 }
                } label: {
                    Image(systemName: store.project.videoVolume > 0.001 ? "film" : "film")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(store.project.videoVolume > 0.001 ? Color.white : Theme.tertiary)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: store.project.videoVolume > 0.001 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(store.project.videoVolume > 0.001 ? Theme.accent : Theme.tertiary)
                                .offset(x: 6, y: 4)
                        }
                        .frame(width: 24, height: 36)
                }
                .buttonStyle(PressStyle(scale: 0.88))
                if tight < 1 {
                    Slide(value: store.project.videoVolume, range: 0...1, tint: Theme.secondary, reset: 0, begin: { store.beginGesture() }) { v in
                        store.live { $0.videoVolume = v }
                    }
                    .frame(width: 64)
                }
            }
            .disabled(store.project.video == nil || store.player.filmOnly)
            .opacity(store.project.video == nil ? 0.35 : store.player.filmOnly ? 0.5 : 1)
            // Flip between what the film came with and what was made here, to compare them.
            if tight < 3 {
                SegmentedPill(options: [(false, "Mine"), (true, "Film")], selection: store.player.filmOnly, segmentWidth: 44, height: 26, size: 11.5) { store.player.filmOnly = $0 }
                    .disabled(store.project.video == nil)
                    .opacity(store.project.video == nil ? 0.35 : 1)
                    .hint("Compare: Mine plays the sound made here. Film plays only the video's own sound. Press \\ to flip.")
            }
            if store.versionList.count > 1 {
                Rectangle().fill(Theme.line).frame(width: 1, height: 20)
                VersionSwitch()
            }
            if tight < 2 {
                Rectangle().fill(Theme.line).frame(width: 1, height: 20)
                MasterMeter()
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 20)
            Menu {
                ForEach(MixFormat.allCases) { f in
                    Toggle(isOn: Binding(get: { f == store.project.format }, set: { if $0 { store.setFormat(f) } })) {
                        Text(f.title)
                        Text(f.detail)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.project.format.title).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color.white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .hint("What this session is mixed for. You can still export every other format from it.")
            SegmentedPill(options: [(MonitorMode.stereo, "Stereo"), (MonitorMode.spatial, "Spatial")],
                          selection: store.player.monitor) { store.player.monitor = $0 }
                .hint("Spatial renders object tracks around you. Best on headphones.")
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .glass(in: Capsule())
    }
}

/// Reads the playhead on its own so nothing else redraws 60 times a second.
struct Timecode: View {
    @Environment(Store.self) private var store
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(timecode(store.player.time, fps: store.project.fps))
                .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
                .tracking(-0.2)
            Text(timecode(store.project.duration, fps: store.project.fps))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
        .frame(width: 152, alignment: .leading)
    }
}



/// The mixer or the library, docked under the timeline. Either can be moved out into a window of its own.
struct DockPanel: View {
    @Environment(Store.self) private var store
    @AppStorage("mixerStyle") private var mixerStyle = "console"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let which = store.dock ?? "mixer"
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SegmentedPill(options: [(value: "mixer", label: "Mixer"), (value: "library", label: "Library")], selection: which, segmentWidth: 70, height: 24, size: 11.5) { store.dock = $0 }
                Spacer()
                if which == "mixer" {
                    Button { mixerStyle = mixerStyle == "console" ? "classic" : "console" } label: {
                        Text(mixerStyle == "console" ? "Console" : "Cards").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Theme.raised, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle(scale: 0.96))
                    .hint("The mixer's look: a console of narrow strips, or the rounded cards it had before. Click to switch.")
                }
                Button { openWindow(id: which); store.dock = nil } label: {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .hint("Move this into a window of its own")
                Button { store.dock = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary).frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .hint("Close")
            }
            .padding(.horizontal, 10).frame(height: 34)
            Rectangle().fill(Theme.line).frame(height: 1)
            if which == "library" { LibraryView(docked: true) } else { MixerView(docked: true) }
        }
        .background(Theme.panel)
    }
}


/// The picture alone, for a second screen. It is the same player, so it stays in step with the timeline.
struct PictureWindow: View {
    @Environment(Store.self) private var store
    var body: some View {
        ZStack {
            Color.black
            if store.project.video != nil {
                PlayerLayerView(player: store.player.video)
            } else {
                Text("No video in this session yet").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onAppear { store.pictureOut = true }
        .onDisappear { store.pictureOut = false }
    }
}
