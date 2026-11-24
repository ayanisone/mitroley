import SwiftUI
import AppKit

extension Metrics {
    static let group: CGFloat = 34
    static let master: CGFloat = 46
}

/// A row in an inspector list: label on the left, detail and chevron on the right.
struct ListRow<Lead: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder var lead: Lead
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                lead
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Groups

struct GroupHeader: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: TrackGroup

    var body: some View {
        let selected = store.selection == .group(group.id)
        let count = store.project.tracks.filter { $0.groupID == group.id }.count
        HStack(spacing: 6) {
            Button {
                withAnimation(Motion.quick(reduceMotion)) { store.editGroup(group.id) { $0.collapsed.toggle() } }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .frame(width: 17, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .help(group.collapsed ? "Show the tracks in this group" : "Fold the tracks away")
            Text(group.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.tertiary)
            Spacer(minLength: 2)
            ChipToggle(label: "M", on: group.mute, tint: Theme.danger) { store.editGroup(group.id) { $0.mute.toggle() } }
            ChipToggle(label: "S", on: group.solo) { store.editGroup(group.id) { $0.solo.toggle() } }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: Metrics.group)
        .background(selected ? Color.white.opacity(0.1) : Color.white.opacity(0.045))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .group(group.id) }
        .contextMenu {
            Button(group.collapsed ? "Show Tracks" : "Fold Tracks") { store.editGroup(group.id) { $0.collapsed.toggle() } }
            Button("Ungroup") { store.ungroup(group.id) }
        }
    }
}

/// The group's row in the timeline: a small picture of every clip inside it.
struct GroupLane: View {
    @Environment(Store.self) private var store
    let group: TrackGroup
    let pps: Double

    var body: some View {
        let members = store.project.tracks.filter { $0.groupID == group.id }
        SlicedCanvas(start: 0, width: CGFloat(store.project.duration * pps) + 24) { ctx, size, _ in
            guard !members.isEmpty else { return }
            let row = min(5, (size.height - 10) / CGFloat(members.count))
            for (i, t) in members.enumerated() {
                let y = 5 + CGFloat(i) * row
                for c in t.clips {
                    let rect = CGRect(x: c.start * pps, y: y, width: max(1.5, c.duration * pps), height: max(1, row - 1))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(t.kind.color.opacity(group.mute || t.mute ? 0.25 : 0.7)))
                }
            }
        }
        .frame(height: Metrics.group)
        .background(Color.white.opacity(0.045))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { g in
            store.selection = .group(group.id)
            store.player.seek(Double(g.location.x) / pps)
        })
    }
}

struct GroupPanel: View {
    @Environment(Store.self) private var store
    let group: TrackGroup

    var body: some View {
        let members = store.project.tracks.filter { $0.groupID == group.id }
        VStack(alignment: .leading, spacing: 2) {
            Text("GROUP").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
            Text(group.name).font(.system(size: 19, weight: .semibold)).tracking(-0.3).lineLimit(2)
        }
        QuietField(placeholder: "Name", text: Binding(get: { group.name }, set: { v in store.editGroup(group.id, undoable: false) { $0.name = v } }))

        SectionTitle("Mix")
        Field(title: "Volume", value: String(format: "%+.1f dB", group.volume)) {
            Slide(value: group.volume, range: -48...12, reset: 0, begin: { store.beginGesture() }) { v in
                store.editGroup(group.id, undoable: false) { $0.volume = v }
            }
        }
        Caption("Moves every track in the group together, on top of each track's own fader.")
        HStack(spacing: 8) {
            Button(group.mute ? "Unmute" : "Mute") { store.editGroup(group.id) { $0.mute.toggle() } }.buttonStyle(PillButtonStyle())
            Button(group.solo ? "Unsolo" : "Solo") { store.editGroup(group.id) { $0.solo.toggle() } }.buttonStyle(PillButtonStyle())
        }

        SectionTitle("Tracks")
        ForEach(members) { t in
            ListRow(title: t.name, detail: "\(t.clips.count)", lead: {
                Image(systemName: t.kind.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(t.kind.color).frame(width: 14)
            }) { store.selection = .track(t.id) }
        }
        Button("Ungroup") { store.ungroup(group.id) }.buttonStyle(PillButtonStyle()).padding(.top, 6)
    }
}

/// Menu items for putting a track into a group.
struct GroupMenuItems: View {
    @Environment(Store.self) private var store
    let track: Track
    var body: some View {
        ForEach(store.project.groups ?? []) { g in
            Button { store.setGroup(g.name, for: [track.id]) } label: {
                if track.groupID == g.id { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
            }
        }
        ForEach(["SFX", "Ambience", "Music"].filter { n in !(store.project.groups ?? []).contains { $0.name == n } }, id: \.self) { n in
            Button("New: \(n)") { store.setGroup(n, for: [track.id]) }
        }
        Button("New Group") {
            let n = (store.project.groups?.count ?? 0) + 1
            if let id = store.setGroup("Group \(n)", for: [track.id]) { store.selection = .group(id) }
        }
        if track.groupID != nil {
            Divider()
            Button("Remove from Group") { store.setGroup(nil, for: [track.id]) }
        }
    }
}

// MARK: - Versions

/// A, B, C: the cuts of this film. Switching keeps the playhead on the same picture.
struct VersionSwitch: View {
    @Environment(Store.self) private var store
    var body: some View {
        let list = store.versionList
        SegmentedPill(options: list.enumerated().map { (value: $1, label: String(UnicodeScalar(UInt8(65 + min(25, $0))))) },
                      selection: store.folder, segmentWidth: 30, settleFirst: true) { store.switchVersion(to: $0) }
            .help("Cuts of this film, oldest first. Switching stays on the same moment of picture.")
    }
}

struct RevisionSection: View {
    @Environment(Store.self) private var store
    let revision: Revision

    var body: some View {
        SectionTitle("Revised cut")
        Caption("Made from \(revision.from). " + revision.summary)
        if revision.ranges.isEmpty {
            Caption("Nothing new needs sound.")
        } else {
            Caption("These stretches are new picture and have no sound yet:")
            ForEach(revision.ranges) { r in
                ListRow(title: r.kind == "new" ? "New shot" : "Shot runs longer", detail: "\(shortTime(r.start)) – \(shortTime(r.end))", lead: {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }) {
                    store.setLoop(r.start, r.end)
                    store.player.seek(r.start)
                }
            }
            Button("Ask Claude to Sound These") {
                store.showClaude = true
                store.agent.send("This session was made from a revised cut. Add sound only to the new and longer stretches, and leave everything else as it is.", store: store)
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(store.agent.running)
        }
    }
}

// MARK: - Footsteps

struct StepsSection: View {
    @Environment(Store.self) private var store
    let track: Track
    @State private var surface = ""
    @State private var working = false

    var body: some View {
        let tapping = store.tapTrack == track.id
        let count = tapping ? store.taps.count : 0
        SectionTitle("Footsteps")
        QuietField(placeholder: "Shoe and surface, e.g. boots on snow", text: $surface)
        Caption(tapping ? "Play the film and press T each time a foot lands. \(count) marked."
                        : "Mark every footfall, then one walk is recorded and cut into single steps, a different one on each mark.")
        HStack(spacing: 8) {
            if tapping {
                Button(working ? "Placing…" : "Place \(count) Step\(count == 1 ? "" : "s")") {
                    let times = store.taps, text = surface
                    working = true
                    Task {
                        do {
                            let n = try await store.placeSteps(track: track.id, times: times, prompt: text)
                            store.say("Placed \(n) step\(n == 1 ? "" : "s").")
                            store.taps = []; store.tapTrack = nil
                        } catch { store.say(error.localizedDescription, error: true) }
                        working = false
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(working || count == 0 || surface.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { store.taps = []; store.tapTrack = nil }.buttonStyle(PillButtonStyle())
            } else {
                Button("Mark Steps") { store.taps = []; store.tapTrack = track.id }.buttonStyle(PillButtonStyle())
            }
        }
    }
}

// MARK: - Score

struct ScoreSection: View {
    @Environment(Store.self) private var store
    let track: Track
    @State private var composing = false
    @AppStorage("carveDepth") private var carve = 9.0

    static let genres = ["Cinematic orchestral", "Epic trailer", "Ambient", "Electronic", "Synthwave", "Lo-fi", "Pop", "Rock", "Hip-hop",
                         "Jazz", "Acoustic folk", "Solo piano", "Corporate upbeat", "Indian classical fusion", "Bollywood"]
    static let moods = ["Hopeful", "Triumphant", "Tense", "Dark", "Emotional", "Playful", "Calm", "Energetic", "Mysterious"]

    private var options: MusicOptions { store.project.music ?? MusicOptions() }
    private func set(_ change: @escaping (inout MusicOptions) -> Void) {
        store.live { p in var o = p.music ?? MusicOptions(); change(&o); p.music = o }
    }
    private func text(_ kp: WritableKeyPath<MusicOptions, String>) -> Binding<String> {
        Binding(get: { options[keyPath: kp] }, set: { v in set { $0[keyPath: kp] = v } })
    }
    private func choice(_ title: String, _ items: [String], _ kp: WritableKeyPath<MusicOptions, String>) -> some View {
        HStack(spacing: 6) {
            QuietField(placeholder: title, text: text(kp))
            Menu {
                ForEach(items, id: \.self) { item in Button(item) { set { $0[keyPath: kp] = item } } }
            } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    var body: some View {
        let o = options
        SectionTitle("Score")
        choice("Genre", Self.genres, \.genre)
        choice("Mood", Self.moods, \.mood)
        QuietField(placeholder: "Instruments, e.g. strings, piano, taiko", text: text(\.instruments))
        QuietField(placeholder: "Leave out, e.g. drums, electric guitar", text: text(\.avoid))
        Field(title: "Tempo", value: o.tempo.map { "\($0) BPM" } ?? "Auto") {
            Slide(value: Double(o.tempo ?? 50), range: 50...180, reset: 50, begin: {}) { v in
                set { $0.tempo = v < 54 ? nil : Int((v / 2).rounded()) * 2 }
            }
        }
        LengthChoice(seconds: o.length, auto: store.project.loopRange != nil && o.loopOnly ? "the loop region" : "the whole film",
                     start: store.project.duration, tint: track.kind.color) { v in set { $0.length = v } }
        if o.length != nil { Caption("Starts at the playhead, and may run shorter or longer than the film.") }
        SegmentedPill(options: [(false, "Instrumental"), (true, "With vocals")], selection: o.vocals, segmentWidth: 104) { v in set { $0.vocals = v } }
            .frame(maxWidth: .infinity)
        if o.vocals {
            QuietEditor(placeholder: "Lyrics, one line per row. Leave empty to let the singer improvise.", text: text(\.lyrics), height: 76)
        }
        Toggle("Change with each scene", isOn: Binding(get: { o.followScenes }, set: { v in set { $0.followScenes = v } }))
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        if store.project.loopRange != nil {
            Toggle("Only the loop region", isOn: Binding(get: { o.loopOnly }, set: { v in set { $0.loopOnly = v } }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        }
        Caption(o.followScenes ? "One piece that turns where the scenes do. Claude can write a mood for every shot: ask it to compose the music."
                               : "One continuous piece in a single mood.")
        HStack(spacing: 8) {
            Button(composing ? "Composing…" : "Compose Score") {
                composing = true
                Task {
                    do {
                        let id = try await store.composeMusic(style: "", track: track.id, options: o)
                        store.selection = .clip(id)
                    } catch { store.say(error.localizedDescription, error: true) }
                    composing = false
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(composing || o.summary.isEmpty)
            Button("Import…") { Panels.importAudio(store, track: track.id) }.buttonStyle(PillButtonStyle())
        }

        SectionTitle("Room for the voice")
        Field(title: "Most it takes out", value: String(format: "%.0f dB", carve)) {
            Slide(value: carve, range: 3...18, tint: track.kind.color, reset: 9, begin: {}) { carve = $0.rounded() }
        }
        Button("Carve Room for the Voice") { Task { await store.carveForVoice(track.id, maxCut: carve) } }
            .buttonStyle(PillButtonStyle())
        Caption("Lowers only the frequencies the voice is using, only while it speaks, so the music keeps its bass and air. Each clip gets a new take; the one before it is the original.")

        SectionTitle("Follow the film")
        Toggle("Duck under voice", isOn: Binding(get: { track.duck != nil }, set: { v in
            Task { await store.setDucking(track.id, on: v) }
        }))
        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        if let duck = track.duck {
            Field(title: "Dip", value: String(format: "%.0f dB", duck.depth)) {
                Slide(value: duck.depth, range: 3...18, reset: 9, begin: { store.beginGesture() }) { v in
                    // Moves the points that are already there; the timing is not worked out again.
                    let old = duck.depth
                    store.live { p in
                        guard let i = p.trackIndex(track.id) else { return }
                        p.tracks[i].duck = Duck(depth: v)
                        let key = AutoParam.volume.rawValue
                        p.tracks[i].automation[key] = p.tracks[i].automation[key]?.map { k in
                            var k = k
                            if abs(k.value + old) < 0.01 { k.value = -v }
                            return k
                        }
                    }
                }
            }
            Button("Listen for voice again") { Task { await store.setDucking(track.id, on: true) } }.buttonStyle(PillButtonStyle())
        }
        Caption(track.duck == nil ? "Off: the music plays at one level. On: it finds where someone speaks, on Voice-over tracks and in the film's own sound when that is turned up, and writes a Volume lane that dips under them."
                                  : "The dips are ordinary points in the Volume lane. Move or delete them as you like; listen again after the voice changes.")
        Toggle("Sit in each scene's space", isOn: Binding(get: { track.spaceMode == .follow }, set: { v in
            store.mutate { p in
                guard let i = p.trackIndex(track.id) else { return }
                p.tracks[i].spaceMode = v ? .follow : .dry
                // Music wants far less room than a footstep does.
                if v, p.tracks[i].send > 0.5 { p.tracks[i].send = 0.3 }
            }
        }))
        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        Caption(track.spaceMode == .follow ? "The music takes a little of each scene's reverb and muffling, like the effects do: it sounds as if it is playing in the room."
                                           : "Off: the music stays clean over every scene, as a score normally does.")
        Toggle("Place in the room (spatial)", isOn: Binding(get: { track.spatial }, set: { v in
            store.mutate { p in if let i = p.trackIndex(track.id) { p.tracks[i].spatial = v } }
        }))
        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        Caption(track.spatial ? "The music is one point in the room: place it with the panner under Position, or automate Left–Right, Depth and Height like any effect. It is heard that way in Spatial monitoring and in the binaural, 5.1, 7.1.4 and Atmos exports. Its left and right are folded into that one point."
                              : "Off: the music stays a normal stereo bed in the front left and right speakers of every format.")
    }
}

// MARK: - Master

/// The fader on everything: every track, its space and its sends move together.
struct MasterHeader: View {
    @Environment(Store.self) private var store
    var body: some View {
        let v = store.project.masterVolume ?? 0
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.7)).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: 14)
                    Text("Master").font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 2)
                    Text(String(format: "%+.1f dB", v)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
                Slide(value: v, range: -48...12, tint: Color.white.opacity(0.8), reset: 0, begin: { store.beginGesture() }) { x in
                    store.live { $0.masterVolume = abs(x) < 0.05 ? nil : x }
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: Metrics.master)
        .background(Color.white.opacity(0.045))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .help("Master volume: applies to the whole mix and to every export. Double-click to reset.")
    }
}
