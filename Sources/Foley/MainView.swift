import SwiftUI
import AVFoundation
import AppKit

struct MainView: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timelineHeight: CGFloat = 380
    @State private var dragStart: CGFloat?

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            GeometryReader { geo in
                let maxTimeline = max(200, geo.size.height - 220)
                let tl = min(maxTimeline, max(180, timelineHeight))
                VStack(spacing: 0) {
                    VideoPane()
                    // One handle resizes picture against timeline, tracking the pointer exactly.
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                        .overlay(Rectangle().fill(Color.clear).frame(height: 9).contentShape(Rectangle())
                            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    if dragStart == nil { dragStart = tl }
                                    timelineHeight = min(maxTimeline, max(180, (dragStart ?? tl) - g.translation.height))
                                }
                                .onEnded { _ in dragStart = nil }))
                    TimelineView()
                        .frame(height: tl)
                }
            }
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
        }
        .background(Theme.bg)
        .navigationTitle(store.project.name)
        // No separate title-bar material: the picture side and the panel side each keep their own colour to the top.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RoomButton()
                Button { store.showClaude.toggle() } label: {
                    Label("Claude", systemImage: "sparkle")
                }
                .help("Let Claude fit the sound to the picture (⌘K)")
                Button { store.showExport = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the mix (⌘E)")
                Button { store.showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("API keys and models (⌘,)")
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
        return v
    }
    func updateNSView(_ v: Host, context: Context) { v.playerLayer.player = player }
}

struct VideoPane: View {
    @Environment(Store.self) private var store
    @State private var targeted = false
    /// The one gap around the picture: above it, between it and the transport, and under the transport.
    static let gap: CGFloat = 12

    var body: some View {
        ZStack {
            Color.black
            if store.project.video != nil {
                // The picture keeps its shape inside what is left, centred; where it is shorter than that
                // space, the extra is shared equally above it and between it and the transport.
                PlayerLayerView(player: store.player.video)
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
            TransportBar().padding(.bottom, Self.gap)
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
                .help("Generates every dashed clip from its prompt with ElevenLabs")
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

    // Everything in the bar sits on one centre line, 16 pt apart, with 16 pt at both ends.
    var body: some View {
        HStack(spacing: 16) {
            Button { store.player.seek(store.player.loop ? (store.project.loopRange?.lowerBound ?? 0) : 0) } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 13)).frame(width: 20, height: 36)
            }
            .buttonStyle(PressStyle(scale: 0.88))
            .help("Back to start (Return)")

            Button { store.player.toggle() } label: {
                Image(systemName: store.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .help("Play or pause (Space)")

            Timecode()

            Button { store.player.loop.toggle() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(store.player.loop ? Theme.accent : Theme.secondary)
                    .frame(width: 20, height: 36)
            }
            .buttonStyle(PressStyle(scale: 0.88))
            .help(store.project.loopRange == nil ? "Loop the whole film. Shift-drag on the ruler to loop a section."
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
                Slide(value: store.project.videoVolume, range: 0...1, tint: Theme.secondary, reset: 0, begin: { store.beginGesture() }) { v in
                    store.live { $0.videoVolume = v }
                }
                .frame(width: 64)
            }
            .disabled(store.project.video == nil)
            .opacity(store.project.video == nil ? 0.35 : 1)
            .help("The video's own sound. Click the icon to mute or restore it.")
            if store.versionList.count > 1 {
                Rectangle().fill(Theme.line).frame(width: 1, height: 20)
                VersionSwitch()
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 20)
            MasterMeter()
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
            .help("What this session is mixed for. You can still export every other format from it.")
            SegmentedPill(options: [(MonitorMode.stereo, "Stereo"), (MonitorMode.spatial, "Spatial")],
                          selection: store.player.monitor) { store.player.monitor = $0 }
                .help("Spatial renders object tracks around you. Best on headphones.")
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

