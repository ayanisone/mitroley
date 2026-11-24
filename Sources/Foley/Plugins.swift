import AVFoundation
import AudioToolbox
import CoreAudioKit
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// One Audio Unit effect on a track. The plug-in itself is found on the Mac by its three codes; its settings travel in `state`.
struct PluginSlot: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var maker: String
    var type: UInt32
    var subtype: UInt32
    var manufacturer: UInt32
    var bypass = false
    var state: Data?        // the plug-in's own settings, as it saved them
    var preset: String?     // set when this slot is one link of a ready-made sound preset

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype, componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}

enum Plugins {
    /// Every Audio Unit effect installed on this Mac.
    static func installed() -> [AVAudioUnitComponent] {
        // Two kinds of effect: plain ones, and "music effects" that can also take MIDI (FabFilter ships its plug-ins as these).
        var found: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let any = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            found += AVAudioUnitComponentManager.shared().components(matching: any)
        }
        return found
            .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    static func isInstalled(_ slot: PluginSlot) -> Bool {
        !AVAudioUnitComponentManager.shared().components(matching: slot.description).isEmpty
    }

    /// Loads the plug-in and gives it back its settings. nil if it is not on this Mac.
    static func make(_ slot: PluginSlot) -> AVAudioUnit? {
        guard isInstalled(slot) else { return nil }
        let unit = AVAudioUnitEffect(audioComponentDescription: slot.description)
        restore(slot, into: unit)
        unit.auAudioUnit.shouldBypassEffect = slot.bypass
        return unit
    }

    static func restore(_ slot: PluginSlot, into unit: AVAudioUnit) {
        guard let data = slot.state,
              let state = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
        unit.auAudioUnit.fullState = state
    }

    static func state(of unit: AVAudioUnit) -> Data? {
        guard let state = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }
}

extension Store {
    /// Copies each open plug-in's current settings into the session, so saving, exporting or rebuilding the engine keeps them.
    func capturePluginStates() {
        var p = project
        var changed = false
        for nodes in player.graph.tracks {
            guard let i = p.trackIndex(nodes.id), var slots = p.tracks[i].plugins else { continue }
            for (id, unit) in nodes.plugins {
                guard let j = slots.firstIndex(where: { $0.id == id }), let data = Plugins.state(of: unit), slots[j].state != data else { continue }
                slots[j].state = data
                changed = true
            }
            p.tracks[i].plugins = slots
        }
        if changed { project = p }
    }

    func addPlugin(_ c: AVAudioUnitComponent, to track: UUID) {
        let d = c.audioComponentDescription
        let slot = PluginSlot(name: c.name, maker: c.manufacturerName, type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer)
        mutate { p in
            guard let i = p.trackIndex(track) else { return }
            p.tracks[i].plugins = (p.tracks[i].plugins ?? []) + [slot]
        }
        openPlugin(slot.id)
    }

    func removePlugin(_ id: UUID, from track: UUID) {
        PluginWindows.close(id)
        mutate { p in
            guard let i = p.trackIndex(track) else { return }
            p.tracks[i].plugins?.removeAll { $0.id == id }
            if p.tracks[i].plugins?.isEmpty == true { p.tracks[i].plugins = nil }
        }
    }

    func setPluginBypass(_ id: UUID, on track: UUID, _ bypass: Bool) {
        mutate { p in
            guard let i = p.trackIndex(track), let j = p.tracks[i].plugins?.firstIndex(where: { $0.id == id }) else { return }
            p.tracks[i].plugins?[j].bypass = bypass
        }
    }

    /// Opens the plug-in's own window.
    func openPlugin(_ id: UUID) {
        for nodes in player.graph.tracks {
            guard let unit = nodes.plugins.first(where: { $0.id == id })?.unit else { continue }
            let name = project.tracks.first { $0.id == nodes.id }?.plugins?.first { $0.id == id }?.name ?? "Plug-in"
            PluginWindows.open(id, unit: unit, title: name) { [weak self] in self?.capturePluginStates(); self?.save() }
            return
        }
        say("That plug-in is not installed on this Mac.", error: true)
    }
}

/// The floating windows plug-ins show their own controls in.
@MainActor enum PluginWindows {
    private static var windows: [UUID: NSWindow] = [:]
    private static var observers: [UUID: NSObjectProtocol] = [:]

    static func open(_ id: UUID, unit: AVAudioUnit, title: String, closed: @escaping () -> Void) {
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); return }
        unit.auAudioUnit.requestViewController { controller in
            DispatchQueue.main.async {
                // Plug-ins without a window of their own get the system's plain list of their controls.
                let content: NSViewController = controller ?? {
                    let generic = AUGenericViewController()
                    generic.auAudioUnit = unit.auAudioUnit
                    return generic
                }()
                let w = NSWindow(contentViewController: content)
                w.title = title
                w.styleMask = [.titled, .closable, .miniaturizable]
                w.level = .floating
                w.hidesOnDeactivate = true
                w.isReleasedWhenClosed = false
                w.center()
                windows[id] = w
                observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        closed()
                        windows[id] = nil
                        if let o = observers[id] { NotificationCenter.default.removeObserver(o) }
                        observers[id] = nil
                    }
                }
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    static func close(_ id: UUID) { windows[id]?.close() }
    static func closeAll() { for w in Array(windows.values) { w.close() } }
}

/// The plug-ins on a track, in the inspector.
struct PluginSection: View {
    @Environment(Store.self) private var store
    let track: Track
    @State private var installed: [AVAudioUnitComponent] = []

    var body: some View {
        HStack {
            SectionTitle("Plug-ins")
            Spacer()
            Menu {
                if installed.isEmpty { Text("Looking for Audio Units") }
                let makers = Dictionary(grouping: installed, by: \.manufacturerName)
                ForEach(makers.keys.sorted(), id: \.self) { maker in
                    Menu(maker) {
                        ForEach(makers[maker] ?? [], id: \.self) { c in
                            Button(c.name) { store.addPlugin(c, to: track.id) }
                        }
                    }
                }
            } label: {
                Label("Add", systemImage: "plus").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
        }
        .task { if installed.isEmpty { installed = Plugins.installed() } }
        let slots = track.plugins ?? []
        if slots.isEmpty {
            Caption("Audio Unit effects installed on this Mac. They run on this track after its filters and before its space, in the order listed, live and in every export.")
        }
        ForEach(slots) { slot in
            let missing = !Plugins.isInstalled(slot)
            HStack(spacing: 8) {
                Button { store.openPlugin(slot.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slot.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(missing ? "Not installed on this Mac" : slot.maker).font(.system(size: 10.5))
                            .foregroundStyle(missing ? Theme.danger : Theme.tertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .help("Open the plug-in's window")
                Toggle("", isOn: Binding(get: { !slot.bypass }, set: { v in store.setPluginBypass(slot.id, on: track.id, !v) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(slot.bypass ? "Switch on" : "Bypass")
                Button { store.removePlugin(slot.id, from: track.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.secondary)
                        .frame(width: 20, height: 20).background(Color.white.opacity(0.07), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .help("Remove from the track")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(slot.bypass ? 0.55 : 1)
        }
    }
}
