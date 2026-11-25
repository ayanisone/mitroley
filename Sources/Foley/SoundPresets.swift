import AVFoundation
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// A ready-made sound for a track: "phone call", "underwater", "old record". Each one is a short chain of the
/// effects that come with macOS, already set. They run live and in every export like any other plug-in, cost almost
/// nothing, and each link can be opened and changed afterwards.
struct SoundPreset: Identifiable {
    /// One effect in the chain: Apple's four-letter code for it, and the settings by parameter number.
    struct Link { let code: String; let name: String; let set: [UInt64: Float] }
    let name: String
    let about: String
    let group: String
    let chain: [Link]
    var id: String { name }

    private static func hp(_ hz: Float, res: Float = 0) -> Link { Link(code: "hpas", name: "High-pass", set: [0: hz, 1: res]) }
    private static func lp(_ hz: Float, res: Float = 0) -> Link { Link(code: "lpas", name: "Low-pass", set: [0: hz, 1: res]) }
    private static func peak(_ hz: Float, q: Float, db: Float) -> Link { Link(code: "pmeq", name: "EQ", set: [0: hz, 1: q, 2: db]) }
    /// Grit: `crush` lowers the sample rate (0…100), `drive` is the soft-clip gain in dB, `mix` how much is heard.
    private static func grit(crush: Float = 0, drive: Float = -6, mix: Float = 100, ring: Float = 0, ringHz: Float = 60) -> Link {
        Link(code: "dist", name: "Distortion", set: [2: 0, 3: crush, 4: 0, 5: crush > 0 ? 100 : 0, 6: 1, 7: 0, 8: 0, 9: 100,
                                                    10: ringHz, 11: ringHz, 12: 50, 13: ring, 14: drive, 15: mix])
    }
    private static func echo(_ secs: Float, feedback: Float, mix: Float, tone: Float = 6000) -> Link {
        Link(code: "dely", name: "Echo", set: [0: mix, 1: secs, 2: feedback, 3: tone])
    }
    private static func room(mix: Float, low: Float, high: Float) -> Link {
        Link(code: "rvb2", name: "Reverb", set: [0: mix, 1: 0, 2: 0.008, 3: 0.05, 4: low, 5: high, 6: 1])
    }
    private static func pitch(_ cents: Float) -> Link { Link(code: "nutp", name: "Pitch", set: [1: cents, 4: 8, 6: 1, 7: 1]) }
    private static func squeeze(threshold: Float, headroom: Float, gain: Float = 0, attack: Float = 0.01, release: Float = 0.12) -> Link {
        Link(code: "dcmp", name: "Compressor", set: [0: threshold, 1: headroom, 2: 1, 3: -100, 4: attack, 5: release, 6: gain])
    }
    private static func limit(pre: Float = 0) -> Link { Link(code: "lmtr", name: "Limiter", set: [0: 0.002, 1: 0.02, 2: pre]) }

    static let all: [SoundPreset] = [
        // Through a device
        SoundPreset(name: "Phone call", about: "A voice on a phone line: narrow, a little gritty.", group: "Through a device",
                    chain: [hp(320), lp(3300), peak(1800, q: 1.2, db: 5), grit(crush: 18, drive: 3, mix: 55)]),
        SoundPreset(name: "AM radio", about: "A small radio: thin, crunchy, squeezed flat.", group: "Through a device",
                    chain: [hp(450), lp(4200), grit(crush: 8, drive: 8, mix: 70), squeeze(threshold: -28, headroom: 6, gain: 4)]),
        SoundPreset(name: "Walkie-talkie", about: "Handheld radio: very narrow and overdriven.", group: "Through a device",
                    chain: [hp(600), lp(2700), peak(1500, q: 2, db: 7), grit(crush: 30, drive: 12, mix: 85), squeeze(threshold: -30, headroom: 4, gain: 3)]),
        SoundPreset(name: "Megaphone", about: "Shouted through a horn, with a short slap off the walls.", group: "Through a device",
                    chain: [hp(500), lp(4000), peak(1600, q: 2.5, db: 9), grit(drive: 10, mix: 80), echo(0.09, feedback: 12, mix: 14, tone: 3500)]),
        SoundPreset(name: "Laptop speaker", about: "No bass at all, a hard little top end.", group: "Through a device",
                    chain: [hp(380, res: 3), lp(9000), peak(2600, q: 1.5, db: 4)]),
        SoundPreset(name: "Old TV", about: "A boxy set in the corner of the room.", group: "Through a device",
                    chain: [hp(220), lp(5200), peak(900, q: 1.5, db: 5), grit(drive: 2, mix: 35)]),
        // Age
        SoundPreset(name: "Old record", about: "Worn vinyl: rolled-off, midrange forward, softly distorted. Add a crackle sound on another track if you want the dust.", group: "Age",
                    chain: [hp(180), lp(5800), peak(1200, q: 1, db: 3), grit(drive: 0, mix: 30)]),
        SoundPreset(name: "Cassette", about: "Tape: dull top, thick, gently squeezed.", group: "Age",
                    chain: [hp(60), lp(7500), grit(drive: 1, mix: 25), squeeze(threshold: -24, headroom: 10, gain: 2)]),
        SoundPreset(name: "Lo-fi", about: "Crushed and grainy, like a cheap sampler.", group: "Age",
                    chain: [hp(120), lp(5000), grit(crush: 42, drive: -2, mix: 90)]),
        // Somewhere else
        SoundPreset(name: "Underwater", about: "Everything above a few hundred hertz is gone, with a slow wash.", group: "Somewhere else",
                    chain: [lp(520, res: 6), room(mix: 35, low: 2.2, high: 0.4)]),
        SoundPreset(name: "Behind a wall", about: "Next door: only the low end gets through.", group: "Somewhere else",
                    chain: [lp(700), Link(code: "lshf", name: "Low shelf", set: [0: 160, 1: 4])]),
        SoundPreset(name: "Far away", about: "Distant: less bass and top, more room than source.", group: "Somewhere else",
                    chain: [hp(250), lp(4500), room(mix: 45, low: 1.8, high: 0.9)]),
        SoundPreset(name: "Dream", about: "Soft and swimming in a long reverb.", group: "Somewhere else",
                    chain: [lp(6500), echo(0.33, feedback: 35, mix: 22, tone: 3500), room(mix: 55, low: 4.5, high: 2.2)]),
        SoundPreset(name: "Slapback", about: "One quick repeat, like a tiled corridor.", group: "Somewhere else",
                    chain: [echo(0.11, feedback: 0, mix: 28, tone: 7000)]),
        SoundPreset(name: "Echo", about: "Repeats that fade away.", group: "Somewhere else",
                    chain: [echo(0.38, feedback: 42, mix: 30, tone: 4500)]),
        // Creatures and machines
        SoundPreset(name: "Robot", about: "A metallic, buzzing voice.", group: "Creatures and machines",
                    chain: [grit(drive: -4, mix: 100, ring: 80, ringHz: 62), hp(150), lp(6000)]),
        SoundPreset(name: "Monster", about: "Pitched far down and roughened.", group: "Creatures and machines",
                    chain: [pitch(-800), grit(drive: 4, mix: 45), Link(code: "lshf", name: "Low shelf", set: [0: 180, 1: 6])]),
        SoundPreset(name: "Small voice", about: "Pitched up: a small creature or a toy.", group: "Creatures and machines",
                    chain: [pitch(700), hp(200)]),
        SoundPreset(name: "Ghost", about: "Thin, pitched slightly down, lost in reverb.", group: "Creatures and machines",
                    chain: [pitch(-200), hp(400), room(mix: 70, low: 5, high: 3.5)]),
        // Tools
        SoundPreset(name: "Compressor, gentle", about: "Evens out loud and quiet moments a little.", group: "Tools",
                    chain: [squeeze(threshold: -22, headroom: 14, gain: 2, attack: 0.02, release: 0.15)]),
        SoundPreset(name: "Compressor, firm", about: "Holds the level steady: good for voice under music.", group: "Tools",
                    chain: [squeeze(threshold: -30, headroom: 7, gain: 5, attack: 0.008, release: 0.1)]),
        SoundPreset(name: "Limiter", about: "Stops peaks from going over.", group: "Tools", chain: [limit()]),
        SoundPreset(name: "Punch", about: "Louder and denser, for hits and impacts.", group: "Tools",
                    chain: [squeeze(threshold: -26, headroom: 8, gain: 4, attack: 0.03, release: 0.08), limit(pre: 3)]),
    ]

    static var groups: [String] { var seen: [String] = []; for p in all where !seen.contains(p.group) { seen.append(p.group) }; return seen }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    /// The chain as plug-in slots, each already holding its settings.
    func slots() -> [PluginSlot] {
        chain.compactMap { link in
            var slot = PluginSlot(name: "\(name): \(link.name)", maker: "Built in", type: kAudioUnitType_Effect, subtype: Self.fourCC(link.code),
                                  manufacturer: kAudioUnitManufacturer_Apple)
            guard Plugins.isInstalled(slot) else { return nil }
            let unit = AVAudioUnitEffect(audioComponentDescription: slot.description)
            guard let tree = unit.auAudioUnit.parameterTree else { return nil }
            for (address, value) in link.set {
                guard let p = tree.parameter(withAddress: address) else { continue }
                p.value = min(p.maxValue, max(p.minValue, value))
            }
            slot.state = Plugins.state(of: unit)
            slot.preset = name
            return slot
        }
    }
}

extension Store {
    /// Puts a preset's chain on a track, in place of any preset already there. Plug-ins added by hand are kept.
    func applyPreset(_ preset: SoundPreset?, to track: UUID) {
        capturePluginStates()
        guard let i = project.trackIndex(track) else { return }
        for old in (project.tracks[i].plugins ?? []) where old.preset != nil { PluginWindows.close(old.id) }
        let new = preset?.slots() ?? []
        mutate { p in
            guard let i = p.trackIndex(track) else { return }
            let kept = (p.tracks[i].plugins ?? []).filter { $0.preset == nil }
            let all = new + kept
            p.tracks[i].plugins = all.isEmpty ? nil : all
        }
    }
}

extension Store {
    /// One sound for a whole bus, in place of the one it had.
    func applyPreset(_ preset: SoundPreset?, toGroup id: UUID) {
        let new = preset?.slots() ?? []
        editGroup(id) { $0.plugins = new.isEmpty ? nil : new }
    }
}

/// Track inspector: pick a ready-made sound.
struct PresetSection: View {
    @Environment(Store.self) private var store
    let track: Track
    @State private var open = false

    var body: some View {
        let current = track.plugins?.first { $0.preset != nil }?.preset
        SectionTitle("Sound preset")
        Button { open.toggle() } label: {
            HStack {
                Text(current ?? "None").font(.system(size: 12.5, weight: .medium)).foregroundStyle(current == nil ? Theme.secondary : Color.white)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: store.peek) { _, v in if v == "presets" { open = true; store.peek = nil } }
        .popover(isPresented: $open, arrowEdge: .leading) {
            PresetList(current: current) { p in
                store.applyPreset(p, to: track.id)
                open = false
            }
        }
        Caption(SoundPreset.all.first { $0.name == current }?.about
                ?? "A ready-made sound for this track: phone, radio, underwater, old record and more. Built from the effects that come with macOS, so it is light, plays live and is in every export.")
    }
}

/// The presets as a list drawn here, so every row sits on the same grid: one height, one gap, headings evenly spaced.
struct PresetList: View {
    let current: String?
    let pick: (SoundPreset?) -> Void
    @State private var hover: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                row(name: "None", about: "The track as it is.", on: current == nil) { pick(nil) }
                ForEach(SoundPreset.groups, id: \.self) { group in
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 6)
                    Text(group).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 10).frame(height: 22, alignment: .leading)
                    ForEach(SoundPreset.all.filter { $0.group == group }) { p in
                        row(name: p.name, about: p.about, on: current == p.name) { pick(p) }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 380, height: 460)
    }

    private func row(name: String, about: String, on: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent).opacity(on ? 1 : 0).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(about).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(hover == name ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in if inside { hover = name } else if hover == name { hover = nil } }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
