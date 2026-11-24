import SwiftUI
import AppKit

struct Inspector: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
        }
        .animation(Motion.quick(reduceMotion), value: store.selection)
    }

    @ViewBuilder private var content: some View {
        let p = store.project
        switch store.selection {
        case .clip(let id):
            if let l = p.locate(clip: id) { ClipPanel(clip: p.tracks[l.track].clips[l.clip], track: p.tracks[l.track]) } else { SessionPanel() }
        case .track(let id):
            if let i = p.trackIndex(id) { TrackPanel(track: p.tracks[i]).id(id) } else { SessionPanel() }
        case .scene(let id):
            if let s = p.scenes.first(where: { $0.id == id }) { ScenePanel(scene: s) } else { SessionPanel() }
        case .space(let id):
            if let s = p.space(id) { SpacePanel(space: s) } else { SessionPanel() }
        case .group(let id):
            if let g = p.group(id) { GroupPanel(group: g) } else { SessionPanel() }
        case .none:
            SessionPanel()
        }
    }
}

private struct PanelTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subtitle.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 19, weight: .semibold)).tracking(-0.3).lineLimit(2)
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Session (nothing selected)

struct SessionPanel: View {
    @Environment(Store.self) private var store

    var body: some View {
        let p = store.project
        PanelTitle(title: p.name, subtitle: "Session")
        QuietField(placeholder: "Session name", text: Binding(get: { store.project.name }, set: { v in store.live { $0.name = v } }))

        SectionTitle("Picture")
        if let v = p.video {
            Text("\(v.width)×\(v.height) · \(String(format: "%.2f", v.fps)) fps · \(shortTime(v.duration))")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Field(title: "Video's own sound", value: String(format: "%.0f%%", p.videoVolume * 100)) {
                Slide(value: p.videoVolume, range: 0...1, reset: 0, begin: { store.beginGesture() }) { v in store.live { $0.videoVolume = v } }
            }
            HStack(spacing: 8) {
                Button("Revised Cut…") { Panels.importRevision(store) }.buttonStyle(PillButtonStyle())
                    .help("Load a new cut of this film. Sounds move with their picture; only new shots are left to do.")
                Button("Replace Video…") { Panels.importVideo(store) }.buttonStyle(PillButtonStyle())
            }
            Menu {
                Button("As One Track") { Panels.originalSound(store, stems: false) }
                Button("Split into Stems…") { Panels.originalSound(store, stems: true) }
            } label: { Text("Use the film's own sound") }
        } else {
            Button("Choose Video…") { Panels.importVideo(store) }.buttonStyle(PillButtonStyle(prominent: true))
        }

        if let rev = p.revision { RevisionSection(revision: rev) }

        SectionTitle("Storyboard")
        QuietEditor(placeholder: "Paste the storyboard or shot list. Claude reads it alongside the frames.",
                    text: Binding(get: { store.project.storyboard }, set: { v in store.live { $0.storyboard = v } }), height: 110)

        HStack {
            SectionTitle("Spaces")
            Menu {
                ForEach(SpaceTemplate.all) { t in
                    Button(t.name) { store.selection = .space(store.addSpace(from: t)) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        if p.spaces.isEmpty {
            Text("A space is what a place sounds like. Give each scene one and every track that follows the scene takes on its acoustics.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(p.spaces) { s in
            Button { store.selection = .space(s.id) } label: {
                HStack(spacing: 8) {
                    Circle().fill(s.color).frame(width: 8, height: 8)
                    Text(s.name).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(s.reverb.title).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
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
}

// MARK: - Clip

struct ClipPanel: View {
    @Environment(Store.self) private var store
    let clip: Clip
    let track: Track
    @State private var moreCount = 2
    /// Length of the next takes. nil = as long as the clip is (sound), or the whole film (music).
    @State private var newLength: Double?
    @AppStorage("sfxInfluence") private var influence = 0.3

    private func live(_ change: @escaping (inout Clip) -> Void) {
        store.live { p in if let l = p.locate(clip: clip.id) { change(&p.tracks[l.track].clips[l.clip]) } }
    }
    private func slide(_ kp: WritableKeyPath<Clip, Double>, _ range: ClosedRange<Double>, reset: Double?) -> Slide {
        Slide(value: clip[keyPath: kp], range: range, tint: track.kind.color, reset: reset, begin: { store.beginGesture() }) { v in
            live { $0[keyPath: kp] = v }
        }
    }

    var body: some View {
        // A length chosen for one clip does not carry over to the next one selected.
        Color.clear.frame(height: 0).onChange(of: clip.id) { _, _ in newLength = nil }
        PanelTitle(title: clip.name, subtitle: "Clip · \(track.name)")
        QuietField(placeholder: "Name", text: Binding(get: { clip.name }, set: { v in live { $0.name = v } }))

        SectionTitle("Takes")
        if clip.takes.isEmpty && clip.pending == 0 {
            Text(clip.error ?? "No audio yet.").font(.system(size: 12)).foregroundStyle(clip.error == nil ? Theme.secondary : Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(clip.takes.enumerated()), id: \.element.id) { i, take in
            let active = i == clip.activeTake
            HStack(spacing: 8) {
                let playing = store.auditioning == take.id
                Button { store.playTake(take) } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 10))
                        .frame(width: 24, height: 24)
                        .background(playing ? track.kind.color.opacity(0.35) : Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(PressStyle(scale: 0.88))
                .help(playing ? "Stop" : "Listen to this take on its own")
                Text("Take \(i + 1)").font(.system(size: 13, weight: active ? .semibold : .regular))
                Spacer()
                Text(shortTime(take.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(active ? track.kind.color : Theme.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(active ? track.kind.color.opacity(0.16) : Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                store.mutate { p in if let l = p.locate(clip: clip.id) { p.tracks[l.track].clips[l.clip].activeTake = i } }
            }
        }
        if clip.pending > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating \(clip.pending) take\(clip.pending == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        if clip.takes.count > 1 {
            Text("Press 1–\(min(9, clip.takes.count)) to switch takes while it plays.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }

        SectionTitle(track.kind == .dialogue ? "Line" : "Prompt")
        if track.kind == .dialogue {
            VoicePicker(current: clip.voiceName) { v in
                Task {
                    var id = v.id
                    if let owner = v.owner {
                        do { id = try await ElevenLabs.addShared(owner: owner, voice: v.id, name: v.name) }
                        catch { store.say(error.localizedDescription, error: true); return }
                    }
                    store.mutate { p in if let l = p.locate(clip: clip.id) { p.tracks[l.track].clips[l.clip].voiceID = id; p.tracks[l.track].clips[l.clip].voiceName = v.name } }
                }
            }
        }
        QuietEditor(placeholder: track.kind == .dialogue ? "What is said" : track.kind == .music ? "Describe the music: genre, mood, instruments" : "Describe the sound to generate more takes", text: Binding(get: { clip.prompt }, set: { v in live { $0.prompt = v } }), height: 58)
        if track.kind == .music {
            LengthChoice(seconds: newLength, auto: "the whole film", start: min(600, max(3, clip.duration)), tint: track.kind.color) { newLength = $0 }
            Caption(newLength == nil ? "The new piece covers the film from start to end." : "The new piece starts where this clip starts. It may run shorter or longer than the film.")
            Button(clip.pending > 0 ? "Composing…" : "Compose Another Take") {
                let length = newLength
                Task { await store.recompose(clip.id, length: length) }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(clip.prompt.trimmingCharacters(in: .whitespaces).isEmpty || clip.pending > 0)
        } else {
        if track.kind != .dialogue {
            let length = newLength ?? min(30, max(0.5, clip.duration))
            Field(title: "Length", value: shortTime(length)) {
                HStack(spacing: 8) {
                    Slide(value: length, range: 0.5...30, log: true, tint: track.kind.color, reset: min(30, max(0.5, clip.duration)), begin: {}) { newLength = ($0 * 10).rounded() / 10 }
                    TimeEntry(seconds: length, placeholder: "", range: 0.5...30, width: 56) { newLength = $0 }
                }
            }
            .help("How long the next takes are. ElevenLabs makes sounds from half a second to 30 seconds.")
            Field(title: "Prompt influence", value: String(format: "%.0f%%", influence * 100)) {
                Slide(value: influence, range: 0...1, tint: track.kind.color, reset: 0.3, begin: {}) { influence = ($0 * 20).rounded() / 20 }
            }
            .help("How literally ElevenLabs follows the description. Higher is closer to the words with less variety between takes; lower is freer.")
        }
        HStack {
            Button("Generate \(moreCount) More") {
                let length = track.kind == .dialogue ? nil : newLength, influence = influence
                Task { await store.moreTakes(for: clip.id, count: moreCount, influence: influence, duration: length) }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(clip.prompt.trimmingCharacters(in: .whitespaces).isEmpty || clip.pending > 0 || (track.kind == .dialogue && clip.voiceID == nil))
            Stepper("", value: $moreCount, in: 1...4).labelsHidden()
        }
        }

        SectionTitle("Level and shape")
        Field(title: "Gain", value: String(format: "%+.1f dB", clip.gain)) { slide(\.gain, -24...12, reset: 0) }
        Field(title: "Speed", value: String(format: "%.2f×", clip.speed)) {
            Slide(value: clip.speed, range: 0.5...2, log: true, tint: track.kind.color, reset: 1, begin: { store.beginGesture() }) { v in
                live { $0.rate = abs(v - 1) < 0.02 ? nil : v }
            }
        }
        Field(title: "Fade in", value: shortTime(clip.fadeIn)) { slide(\.fadeIn, 0...max(0.1, min(6, clip.duration)), reset: 0.01) }
        Field(title: "Fade out", value: shortTime(clip.fadeOut)) { slide(\.fadeOut, 0...max(0.1, min(6, clip.duration)), reset: 0.05) }
        Field(title: "Fade in shape") {
            Picker("", selection: Binding(get: { clip.inShape }, set: { v in
                store.mutate { p in if let l = p.locate(clip: clip.id) { p.tracks[l.track].clips[l.clip].fadeInShape = v == .equalPower ? nil : v } }
            })) {
                ForEach(FadeShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
        }
        Field(title: "Fade out shape") {
            Picker("", selection: Binding(get: { clip.outShape }, set: { v in
                store.mutate { p in if let l = p.locate(clip: clip.id) { p.tracks[l.track].clips[l.clip].fadeOutShape = v == .equalPower ? nil : v } }
            })) {
                ForEach(FadeShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
        }
        Toggle("Loop to fill the clip", isOn: Binding(get: { clip.loop }, set: { v in
            store.mutate { p in if let l = p.locate(clip: clip.id) { p.tracks[l.track].clips[l.clip].loop = v } }
        }))
        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))

        if let x = track.crossfade(involving: clip.id) {
            SectionTitle("Crossfade")
            Field(title: "Length", value: shortTime(x.length)) {
                Slide(value: x.length, range: 0.005...2, tint: track.kind.color, reset: nil, begin: { store.beginGesture() }) { v in
                    store.setCrossfade(a: x.a.id, b: x.b.id, length: v, live: true)
                }
            }
            Field(title: "Shape") {
                Picker("", selection: Binding(get: { x.a.outShape }, set: { v in store.setCrossfadeShape(a: x.a.id, b: x.b.id, shape: v) })) {
                    ForEach([FadeShape.equalPower, .linear, .sCurve]) { Text($0 == .linear ? "Equal gain (linear)" : $0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
            Button("Remove") { store.removeCrossfade(a: x.a.id, b: x.b.id) }.buttonStyle(PillButtonStyle())
        } else if let x = track.crossfadePartner(of: clip.id) {
            Button(x.a.id == clip.id ? "Crossfade with next clip" : "Crossfade with previous clip") { store.crossfade(clip.id) }
                .buttonStyle(PillButtonStyle())
        }

        Text("Starts \(shortTime(clip.start)) · lasts \(shortTime(clip.duration))")
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
        Button("Delete Clip") { store.deleteSelection() }.buttonStyle(PillButtonStyle()).padding(.top, 4)
    }
}

// MARK: - Track

struct TrackPanel: View {
    @Environment(Store.self) private var store
    let track: Track
    @State private var prompt = ""
    /// A new sound starts at three seconds. Its length is changed on the clip, where more takes are made.
    private let length = 3.0
    @State private var takes = 3
    @State private var loop = false
    @AppStorage("sfxInfluence") private var influence = 0.3

    private func live(_ change: @escaping (inout Track) -> Void) {
        store.live { p in if let i = p.trackIndex(track.id) { change(&p.tracks[i]) } }
    }
    private func commit(_ change: @escaping (inout Track) -> Void) {
        store.mutate { p in if let i = p.trackIndex(track.id) { change(&p.tracks[i]) } }
    }
    private func slide(_ kp: WritableKeyPath<Track, Double>, _ range: ClosedRange<Double>, log: Bool = false, reset: Double?) -> Slide {
        Slide(value: track[keyPath: kp], range: range, log: log, tint: track.kind.color, reset: reset, begin: { store.beginGesture() }) { v in
            live { $0[keyPath: kp] = v }
        }
    }

    var body: some View {
        PanelTitle(title: track.name, subtitle: "\(track.kind.title) track")
        QuietField(placeholder: "Name", text: Binding(get: { track.name }, set: { v in live { $0.name = v } }))

        if track.kind == .music { ScoreSection(track: track) }
        if track.kind == .dialogue { VoiceOverSection(track: track) }
        if track.kind != .music && track.kind != .dialogue {
        SectionTitle("New sound")
        QuietEditor(placeholder: "Describe a sound, e.g. \"single footstep on wet stone, close\"", text: $prompt, height: 58)
        Field(title: "Prompt influence", value: String(format: "%.0f%%", influence * 100)) {
            Slide(value: influence, range: 0...1, tint: track.kind.color, reset: 0.3, begin: {}) { influence = ($0 * 20).rounded() / 20 }
        }
        .help("How literally ElevenLabs follows the description. Higher is closer to the words with less variety between takes; lower is freer.")
        HStack(spacing: 10) {
            Stepper("\(takes) take\(takes == 1 ? "" : "s")", value: $takes, in: 1...4).font(.system(size: 12))
            Spacer()
            Toggle("Loop", isOn: $loop).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        }
        HStack {
            Button("Generate at Playhead") {
                let text = prompt, start = store.player.time
                Task {
                    let id = await store.generate(prompt: text, track: track.id, start: start, duration: length, takes: takes, loop: loop, influence: influence)
                    if store.project.locate(clip: id) != nil { store.selection = .clip(id) }
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Import…") { Panels.importAudio(store, track: track.id) }.buttonStyle(PillButtonStyle())
        }
        }
        if track.kind == .foley { StepsSection(track: track) }
        if !Secrets.has(.elevenLabs) {
            Button("Add an ElevenLabs key to generate") { store.showSettings = true }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
        }

        SectionTitle("Mix")
        Field(title: "Volume", value: String(format: "%+.1f dB", track.volume)) { slide(\.volume, -48...12, reset: 0) }
        Field(title: "Sub (LFE)", value: track.lfeSend < 0.005 ? "Off" : String(format: "%.0f%%", track.lfeSend * 100)) { slide(\.lfeSend, 0...1, reset: 0) }
            .help("Sends this track's low end (below 120 Hz) to the sub channel as well. Heard in the 7.1.4 and Atmos exports; stereo and headphone monitoring are unchanged.")
        Menu { GroupMenuItems(track: track) } label: {
            Text(store.project.group(track.groupID).map { "Group: \($0.name)" } ?? "Add to a group")
        }

        SectionTitle("Space")
        Picker("", selection: Binding(get: { track.spaceMode }, set: { v in commit { $0.spaceMode = v } })) {
            ForEach(SpaceMode.allCases) { Text($0 == .follow ? "Follow" : $0 == .fixed ? "Fixed" : "Dry").tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        Text(track.spaceMode == .follow ? "Takes on the acoustics of whichever scene is playing."
             : track.spaceMode == .fixed ? "Always sounds like one place." : "Ignores spaces. Right for music and voice-over.")
            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        if track.spaceMode == .fixed {
            Menu {
                ForEach(store.project.spaces) { s in Button(s.name) { commit { $0.fixedSpace = s.id } } }
                Divider()
                ForEach(SpaceTemplate.all) { t in
                    Button("New: \(t.name)") { let id = store.addSpace(from: t); commit { $0.fixedSpace = id } }
                }
            } label: {
                Text(store.project.space(track.fixedSpace)?.name ?? "Choose a space")
            }
        }
        if track.spaceMode != .dry {
            Field(title: "Space amount", value: String(format: "%.0f%%", track.send * 100)) { slide(\.send, 0...1, reset: 1) }
        }
        Field(title: "Muffle", value: AutoParam.highCut.format(track.highCut)) { slide(\.highCut, 200...20000, log: true, reset: 20000) }
        Field(title: "Low cut", value: track.lowCut <= 25 ? "Off" : String(format: "%.0f Hz", track.lowCut)) { slide(\.lowCut, 20...2000, log: true, reset: 20) }

        PluginSection(track: track)

        SectionTitle("Position")
        Toggle("Spatial object", isOn: Binding(get: { track.spatial }, set: { v in commit { $0.spatial = v } }))
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        if track.spatial {
            PanPad(position: track.position, color: track.kind.color,
                   speakers: store.project.format == .binaural ? Array(0..<12) : store.project.format.channels,
                   begin: { store.beginGesture() }) { x, y in
                live { $0.position.x = x; $0.position.y = y }
            }
            .frame(maxWidth: 250)
            .frame(maxWidth: .infinity)
            Field(title: "Height", value: String(format: "%.2f", track.position.z)) { slide(\.position.z, 0...1, reset: 0) }
            if store.player.monitor == .stereo {
                Text("Switch monitoring to Spatial to hear depth and height. In Stereo only left–right is audible.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Field(title: "Pan", value: track.pan == 0 ? "Centre" : String(format: "%@ %.0f", track.pan < 0 ? "L" : "R", abs(track.pan) * 100)) {
                slide(\.pan, -1...1, reset: 0)
            }
        }

        SectionTitle("Automation")
        Menu {
            Button("None") { commit { $0.lane = nil } }
            ForEach(AutoParam.allCases) { p in Button(p.title) { commit { $0.lane = p } } }
        } label: {
            Text(track.lane.map { "Showing \($0.title)" } ?? "Show a lane")
        }
        Button("Delete Track") { store.deleteSelection() }.buttonStyle(PillButtonStyle()).padding(.top, 6)
            .onAppear { loop = track.kind == .ambience; if track.kind == .ambience { length = 10 } }
    }
}


// MARK: - Scene

struct ScenePanel: View {
    @Environment(Store.self) private var store
    let scene: SceneRegion

    private func live(_ change: @escaping (inout SceneRegion) -> Void) {
        store.live { p in if let i = p.scenes.firstIndex(where: { $0.id == scene.id }) { change(&p.scenes[i]) } }
    }
    private func commit(_ change: @escaping (inout SceneRegion) -> Void) {
        store.mutate { p in if let i = p.scenes.firstIndex(where: { $0.id == scene.id }) { change(&p.scenes[i]) } }
    }

    var body: some View {
        let space = store.project.space(scene.spaceID)
        PanelTitle(title: scene.name, subtitle: "Scene · \(shortTime(scene.start)) – \(shortTime(scene.end))")
        QuietField(placeholder: "Name", text: Binding(get: { scene.name }, set: { v in live { $0.name = v } }))

        SectionTitle("Space")
        Menu {
            Button("None") { commit { $0.spaceID = nil } }
            if !store.project.spaces.isEmpty {
                Divider()
                ForEach(store.project.spaces) { s in Button(s.name) { commit { $0.spaceID = s.id } } }
            }
            Divider()
            ForEach(SpaceTemplate.all) { t in
                Button("New: \(t.name)") { let id = store.addSpace(from: t); commit { $0.spaceID = id } }
            }
        } label: {
            HStack {
                Circle().fill(space?.color ?? Color.white.opacity(0.3)).frame(width: 8, height: 8)
                Text(space?.name ?? "No space")
            }
        }
        if let space {
            Button("Edit \(space.name)…") { store.selection = .space(space.id) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
        }
        Field(title: "Crossfade in", value: shortTime(scene.transition)) {
            Slide(value: scene.transition, range: 0.05...5, log: true, tint: space?.color ?? Theme.accent, reset: 0.12, begin: { store.beginGesture() }) { v in
                live { $0.transition = v }
            }
        }
        Text("Short for a hard cut. A second or more when the camera or a character moves from one place into the next.")
            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

        SectionTitle("Note")
        QuietEditor(placeholder: "What happens here", text: Binding(get: { scene.note }, set: { v in live { $0.note = v } }), height: 58)
        HStack {
            Button("Split at Playhead") { store.splitScene(at: store.player.time) }.buttonStyle(PillButtonStyle())
            Button("Delete") { store.deleteScene(scene.id) }.buttonStyle(PillButtonStyle())
        }
        .padding(.top, 4)
    }
}

// MARK: - Space

struct SpacePanel: View {
    @Environment(Store.self) private var store
    let space: Space

    private func live(_ change: @escaping (inout Space) -> Void) {
        store.live { p in if let i = p.spaces.firstIndex(where: { $0.id == space.id }) { change(&p.spaces[i]) } }
    }
    private func slide(_ kp: WritableKeyPath<Space, Double>, _ range: ClosedRange<Double>, log: Bool = false, reset: Double?) -> Slide {
        Slide(value: space[keyPath: kp], range: range, log: log, tint: space.color, reset: reset, begin: { store.beginGesture() }) { v in
            live { $0[keyPath: kp] = v }
        }
    }

    var body: some View {
        Button { store.selection = .none } label: {
            Label("Session", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
        }
        .buttonStyle(PressStyle())
        PanelTitle(title: space.name, subtitle: "Space")
        QuietField(placeholder: "Name", text: Binding(get: { space.name }, set: { v in live { $0.name = v } }))

        SectionTitle("Room")
        SegmentedPill(options: [(false, "Built-in reverb"), (true, "IR reverb")], selection: space.ir != nil, segmentWidth: 124) { useIR in
            if useIR { if space.ir == nil { store.chooseIR(space: space.id) } }
            else { store.mutate { p in if let i = p.spaces.firstIndex(where: { $0.id == space.id }) { p.spaces[i].ir = nil } } }
        }
        if let ir = space.ir {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(space.color)
                Text(String((ir as NSString).lastPathComponent.dropFirst(9))).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Change") { store.chooseIR(space: space.id) }.buttonStyle(PillButtonStyle())
            }
            Text("The room is the recording you loaded: an impulse response of a real space. Amount, brightness and echo still apply; type and size do not.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Menu {
            ForEach(ReverbKind.allCases) { k in
                Button(k.title) { store.mutate { p in if let i = p.spaces.firstIndex(where: { $0.id == space.id }) { p.spaces[i].reverb = k } } }
            }
        } label: { Text(space.reverb.title) }
        .disabled(space.ir != nil).opacity(space.ir != nil ? 0.4 : 1)
        Field(title: "Amount", value: String(format: "%.0f%%", space.wet * 100)) { slide(\.wet, 0...1, reset: nil) }
        Field(title: "Size", value: space.size.map { String(format: "%.0f%%", $0 * 100) } ?? "From type") {
            Slide(value: space.size ?? 0.5, range: 0...1, tint: space.color, reset: nil, begin: { store.beginGesture() }) { v in
                live { $0.size = v }
            }
        }
        Field(title: "Brightness", value: AutoParam.highCut.format(space.tone)) { slide(\.tone, 300...20000, log: true, reset: 9000) }

        SectionTitle("Echo")
        Field(title: "Amount", value: String(format: "%.0f%%", space.echo * 100)) { slide(\.echo, 0...1, reset: 0) }
        Field(title: "Time", value: String(format: "%.0f ms", space.echoTime * 1000)) { slide(\.echoTime, 0.05...1, log: true, reset: 0.18) }
        Field(title: "Repeats", value: String(format: "%.0f%%", space.echoFeedback * 100)) { slide(\.echoFeedback, 0...0.9, reset: 0.3) }

        SectionTitle("Direct sound")
        Field(title: "Muffle", value: AutoParam.highCut.format(space.muffle)) { slide(\.muffle, 200...20000, log: true, reset: 20000) }
        Field(title: "Trim", value: String(format: "%+.1f dB", space.dryTrim)) { slide(\.dryTrim, -24...6, reset: 0) }
        Text("Use these when sound is heard through something: a wall, a car door, water.")
            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

        SectionTitle("Ambience")
        QuietEditor(placeholder: "What this place sounds like when nothing happens",
                    text: Binding(get: { space.ambiencePrompt }, set: { v in live { $0.ambiencePrompt = v } }), height: 58)
        Button("Fill Its Scenes with Ambience") { Task { await store.fillAmbience(space: space.id) } }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(space.ambiencePrompt.isEmpty || !store.project.scenes.contains { $0.spaceID == space.id })
            .help("Generates a looping bed for every scene in this space, crossfaded at the scene edges")
        Button("Delete Space") { store.deleteSelection() }.buttonStyle(PillButtonStyle()).padding(.top, 4)
    }
}
