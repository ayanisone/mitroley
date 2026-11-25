import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            exit(SelfTest.run(args[i + 1]))
        }
        if let i = args.firstIndex(of: "--snapshot-panner"), i + 1 < args.count {
            MainActor.assumeIsolated { PannerSnapshot.write(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--cuts"), i + 1 < args.count {
            // Prints the detected cuts of a video, and every frame difference above a small floor.
            let url = URL(fileURLWithPath: args[i + 1])
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let samples = await VideoAnalysis.frameDifferences(url)
                let cuts = VideoAnalysis.cuts(from: samples)
                print("cuts:", cuts.map { String(format: "%.3f", $0) }.joined(separator: " "))
                if args.contains("--verbose") {
                    print(samples.filter { $0.d > 0.02 }.map { String(format: "%.3f(%.3f)", $0.t, $0.d) }.joined(separator: " "))
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--conform"), i + 2 < args.count {
            // Compares two cuts of a film and prints what matched. With a third path, also conforms that project.json.
            let a = URL(fileURLWithPath: args[i + 1]), b = URL(fileURLWithPath: args[i + 2])
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let t0 = Date()
                async let fa = Conform.frames(a)
                async let fb = Conform.frames(b)
                let (old, new) = await (fa, fb)
                guard let ia = try? await VideoAnalysis.info(a), let ib = try? await VideoAnalysis.info(b) else { print("unreadable"); sem.signal(); return }
                let so = Conform.shots(old, duration: ia.duration), sn = Conform.shots(new, duration: ib.duration)
                let m = Conform.match(old: old, new: new, oldShots: so, newShots: sn)
                print("old shots \(so.count), new shots \(sn.count), \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                for s in m.segments { print(String(format: "same  new %7.3f–%7.3f  = old %7.3f–%7.3f", s.start, s.end, s.start + s.delta, s.end + s.delta)) }
                for r in m.ranges { print(String(format: "%@ new %7.3f–%7.3f", r.kind.padding(toLength: 6, withPad: " ", startingAt: 0), r.start, r.end)) }
                var report = m.report
                if i + 3 < args.count, let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 3])),
                   let p = try? JSONDecoder().decode(Project.self, from: data) {
                    let (q, rep) = Conform.apply(p, video: ib, segments: m.segments, ranges: m.ranges, report: m.report)
                    report = rep
                    print("scenes \(p.scenes.count) → \(q.scenes.count); clips \(p.tracks.reduce(0) { $0 + $1.clips.count }) → \(q.tracks.reduce(0) { $0 + $1.clips.count })")
                    for s in q.scenes { print(String(format: "  %7.3f–%7.3f  %@ %@", s.start, s.end, s.name, s.status ?? "")) }
                }
                print(report.summary)
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--steps"), i + 1 < args.count {
            for s in Steps.slices(URL(fileURLWithPath: args[i + 1])) { print(String(format: "%.3f +%.3f peak %.3f", s.start, s.length, s.peak)) }
            exit(0)
        }
        FoleyApp.main()
    }
}

struct FoleyApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup("mitroley") {
            MainView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(minWidth: 1080, minHeight: 680)
                // In the window that is already open, not a second one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // Double-clicking a session in Finder, or dropping one on the Dock icon, opens it.
                .onOpenURL { url in
                    if url.pathExtension == AppPaths.sessionExtension || FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) { store.open(url) }
                }
                .onAppear {
                    Keys.install(store)
                    if UserDefaults.standard.bool(forKey: "showClaude") { store.showClaude = true }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { store.newSessionAsking() }.keyboardShortcut("n")
                Button("Open…") { Panels.openProject(store) }.keyboardShortcut("o")
                Divider()
                Button("Save") { store.saveNow() }.keyboardShortcut("s")
                Button("Save As…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Rename Session…") { store.renameSessionAsking() }
                Button("Share Session…") { store.shareSessionAsking() }
                Divider()
                Button("Import Video…") { Panels.importVideo(store) }.keyboardShortcut("i")
                Button("Import Revised Cut…") { Panels.importRevision(store) }.keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(store.project.video == nil)
                Menu("Use the Film's Own Sound") {
                    Button("As One Track") { Panels.originalSound(store, stems: false) }
                    Button("Split into Stems…") { Panels.originalSound(store, stems: true) }
                }
                .disabled(store.project.video == nil)
                Button("Dub Into Other Languages…") { store.showDub = true }
                Button("Export…") { store.showExport = true }.keyboardShortcut("e")
                Button("Show Session in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
            CommandGroup(replacing: .help) {
                Button(store.voiceAgent.isOn ? "Stop Voice Helper" : "Talk to Voice Helper") { store.voiceAgent.toggle(store) }
                    .keyboardShortcut("j")
                Divider()
                Button("Send a Suggestion…") { Panels.suggest() }
                Button("Report a Problem…") { ProblemReports.report(nil) }
                Button("mitroley on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/ayanisone/mitroley")!) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("Session") {
                RoomButton(menu: true)
                Button(store.dock == "mixer" ? "Hide Mixer" : "Show Mixer") { store.toggleDock("mixer") }.keyboardShortcut("m", modifiers: [.command, .option])
                Button(store.dock == "library" ? "Hide Library" : "Show Library") { store.toggleDock("library") }.keyboardShortcut("l", modifiers: [.command, .option])
                WindowButton(id: "picture", title: "Picture in Its Own Window", symbol: "", key: "p", help: "", menu: true, plain: true)
                WindowButton(id: "mixer", title: "Mixer in Its Own Window", symbol: "", key: "m", help: "", menu: true, plain: true)
                WindowButton(id: "library", title: "Library in Its Own Window", symbol: "", key: "l", help: "", menu: true, plain: true)
                Menu("Theme") {
                    ForEach(Palette.all) { p in
                        Toggle(p.name, isOn: Binding(get: { store.theme == p.id }, set: { if $0 { store.theme = p.id } }))
                    }
                }
                Toggle("Hint Box", isOn: Binding(get: { UserDefaults.standard.object(forKey: "hintBox") as? Bool ?? true }, set: { UserDefaults.standard.set($0, forKey: "hintBox") }))
                Button("Check the Mix at the Cuts…") { store.showCutCheck = true }.keyboardShortcut("k", modifiers: [.command, .option])
                Divider()
                Button("Duplicate Clip") { store.duplicateClip() }.keyboardShortcut("d")
                Button("Split Clip at Playhead") { store.splitClip() }.keyboardShortcut("t")
                Button("Crossfade Clips") { store.crossfade() }.keyboardShortcut("f")
                Button("Nudge Clip Earlier") { store.nudge(-1) }.keyboardShortcut(",", modifiers: [.option])
                Button("Nudge Clip Later") { store.nudge(1) }.keyboardShortcut(".", modifiers: [.option])
                Picker("Edit Mode", selection: Binding(get: { store.editMode }, set: { store.editMode = $0 })) {
                    Text("Slip").tag(EditMode.slip).keyboardShortcut("1", modifiers: [.option])
                    Text("Snap").tag(EditMode.snap).keyboardShortcut("2", modifiers: [.option])
                    Text("Grid").tag(EditMode.grid).keyboardShortcut("3", modifiers: [.option])
                }
                Divider()
                Button("Split Scene at Playhead") { store.splitScene(at: store.player.time) }.keyboardShortcut("b")
                Button("Ask Claude") { store.showClaude.toggle() }.keyboardShortcut("k")
                Divider()
                Button("Loop Selection") { store.loopSelection() }.keyboardShortcut("l")
                Button("Clear Loop Region") { store.clearLoop() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("New Extras Track (Muted)") { store.selection = .track(store.addExtrasTrack()) }
                Button("Group Tracks by Kind") { store.groupByKind() }.keyboardShortcut("g")
                Button("Move Track Up") { if let id = store.selectedTrack { store.moveTrack(id, -1) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(store.selectedTrack.map { !store.canMoveTrack($0, -1) } ?? true)
                Button("Move Track Down") { if let id = store.selectedTrack { store.moveTrack(id, 1) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(store.selectedTrack.map { !store.canMoveTrack($0, 1) } ?? true)
                ForEach(TrackKind.allCases) { kind in
                    Button("New \(kind.title) Track") { store.selection = .track(store.addTrack(kind: kind)) }
                }
            }
        }

        Window("Room", id: "room") {
            RoomView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 680)

        Window("Picture", id: "picture") {
            PictureWindow()
                .environment(store)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 560)

        Window("Mixer", id: "mixer") {
            MixerView()
                .frame(minWidth: 520, minHeight: 480)
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 900, height: 520)

        Window("Library", id: "library") {
            LibraryView()
                .frame(minWidth: 620, minHeight: 420)
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 760, height: 620)
    }
}

/// Bare-key shortcuts (space, delete, 1–4) that must not fire while typing in a text field.
@MainActor
enum Keys {
    private static var installed = false
    static func install(_ store: Store) {
        guard !installed else { return }
        installed = true
        // Clicking anywhere that is not a text field ends typing, so Space goes back to being play/pause.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let w = event.window, w.attachedSheet == nil, w.firstResponder is NSText,
               let hit = w.contentView?.hitTest(event.locationInWindow), !(hit is NSText), !(hit is NSTextField) {
                w.makeFirstResponder(nil)
            }
            // A press inside the library hands it the keys; a press anywhere else takes them back.
            if event.window?.attachedSheet == nil { store.library.active = store.library.hovered }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The sound library: up and down step through the sounds, also from its search box.
            let library = store.library
            let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            if library.active, plain, NSApp.keyWindow?.attachedSheet == nil, [125, 126].contains(event.keyCode), !library.shown.isEmpty {
                if let item = library.step(event.keyCode == 125 ? 1 : -1) {
                    if UserDefaults.standard.object(forKey: "libraryAutoplay") as? Bool ?? true { store.audition(path: item.path, again: true) } else { store.stopAudition() }
                }
                return nil
            }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return event }
            if library.active, plain, NSApp.keyWindow?.attachedSheet == nil {
                switch event.keyCode {
                case 49: // space: stop what is playing, or play the selected sound
                    if store.auditionPath != nil || store.auditioning != nil { store.stopAudition(); return nil }
                    if let item = library.pickedItem { store.audition(path: item.path, again: true); return nil }
                case 36 where library.pickedItem != nil: // return: place it at the playhead
                    if let item = library.pickedItem { store.place(item) }
                    return nil
                case 53 where store.auditionPath != nil:
                    store.stopAudition()
                    return nil
                default: break
                }
            }
            if NSApp.keyWindow?.attachedSheet != nil { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { return event }
            // One key picks a tool.
            if !event.modifierFlags.contains(.shift), let ch = event.charactersIgnoringModifiers?.lowercased().first,
               let t = Tool.allCases.first(where: { $0.key == ch }), !(ch == "t") {
                store.tool = t
                return nil
            }
            if event.charactersIgnoringModifiers == "\\", store.project.video != nil { // compare with the film's own sound
                store.player.filmOnly.toggle()
                return nil
            }
            switch event.keyCode {
            case 53 where store.marquee != nil: // esc: let go of the marquee
                store.marquee = nil
                return nil
            case 51, 117 where store.marquee != nil: // delete: take the marquee's stretch out
                store.deleteMarquee()
                return nil
            case 49: // space; while a take is auditioning it only stops that
                if store.auditioning != nil || store.auditionPath != nil { store.stopAudition() } else { store.player.toggle() }
                return nil
            case 53 where store.loopPending != nil: // esc: drop a half-set loop
                store.loopPending = nil
                return nil
            case 53 where store.showClaude && !store.showExport && !store.showSettings: // esc: put the assistant away
                store.showClaude = false
                return nil
            case 51, 117: // delete
                store.deleteSelection()
                return nil
            case 36, 115: // return, home
                store.player.seek(0)
                return nil
            case 17 where store.tapTrack != nil: // T: mark a footfall
                // A tap lands a little after the eye sees the foot: pull it back by a typical reaction lag.
                store.taps.append(max(0, store.player.time - (store.player.isPlaying ? 0.07 : 0)))
                Haptics.snap()
                return nil
            case 43 where store.selection != .none: store.nudge(-1); return nil   // ,
            case 47 where store.selection != .none: store.nudge(1); return nil    // .
            case 123: store.player.seek(store.player.time - 1 / store.project.fps); return nil
            case 124: store.player.seek(store.player.time + 1 / store.project.fps); return nil
            default: break
            }
            if let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n), case .clip(let id) = store.selection,
               let l = store.project.locate(clip: id), store.project.tracks[l.track].clips[l.clip].takes.indices.contains(n - 1) {
                store.mutate { $0.tracks[l.track].clips[l.clip].activeTake = n - 1 }
                return nil
            }
            return event
        }
    }
}

@MainActor
enum Panels {
    /// Opens a new issue on the project's GitHub page: the suggestion box.
    static func suggest() {
        NSWorkspace.shared.open(URL(string: "https://github.com/ayanisone/mitroley/issues/new?title=Suggestion%3A%20")!)
    }

    static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    static let audioTypes: [UTType] = [.audio, .wav, .mp3, .aiff, .mpeg4Audio]

    static func importVideo(_ store: Store) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = videoTypes
        panel.message = "Choose the video to put sound to"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url, store)
    }

    static func loadVideo(_ url: URL, _ store: Store) {
        Task {
            do { try await store.importVideo(url) } catch { store.say(error.localizedDescription, error: true) }
        }
    }

    static func importRevision(_ store: Store) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = videoTypes
        panel.message = "Choose the revised cut of this film. Sounds stay with their picture; only new shots are left to do."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await store.importRevision(url) } catch { store.say(error.localizedDescription, error: true) }
        }
    }

    static func originalSound(_ store: Store, stems: Bool) {
        if stems {
            let alert = NSAlert()
            alert.messageText = "Split the film's own sound into stems?"
            alert.informativeText = "ElevenLabs separates it into voice, drums, bass, guitar, piano and other. This uses credits and takes a minute or two. Sound effects are not a stem of their own: they mostly end up in “other”."
            alert.addButton(withTitle: "Split")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            do {
                if stems { try await store.splitOriginalSound() }
                else { store.selection = .track(try await store.addOriginalSound()) }
            } catch { store.say(error.localizedDescription, error: true) }
        }
    }

    static func clipStems(_ store: Store, _ id: UUID) {
        let alert = NSAlert()
        alert.messageText = "Split this sound into stems?"
        alert.informativeText = "ElevenLabs separates it into voice, drums, bass, guitar, piano and other, each on its own track. This uses credits and takes a minute or two. It is made for music: sound effects mostly end up in “other”."
        alert.addButton(withTitle: "Split")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await store.splitClipIntoStems(id) } catch { store.say(error.localizedDescription, error: true) }
        }
    }

    static func openProject(_ store: Store) {
        let panel = NSOpenPanel()
        panel.directoryURL = Store.library
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a mitroley session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.open(url)
    }

    static func importAudio(_ store: Store, track: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = audioTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var t = store.player.time
        for url in panel.urls {
            // A surround file can come in as one track per speaker, so each can be seen, heard and moved on its own.
            let channels = SpeakerSplit.channels(of: url)
            if channels > 2, SpeakerSplit.layout(channels: channels, adm: SpeakerSplit.isADM(url)) != nil {
                let alert = NSAlert()
                alert.messageText = "\(url.lastPathComponent) has \(channels) channels"
                alert.informativeText = "Split it into one track per speaker, each named (L, R, C, LFE, Lss…) and placed where that speaker is? Or bring it in as one clip, folded down to stereo."
                alert.addButton(withTitle: "One Track per Speaker")
                alert.addButton(withTitle: "One Stereo Clip")
                if alert.runModal() == .alertFirstButtonReturn {
                    let at = t
                    Task { await store.importSplit(url, at: at) }
                    continue
                }
            }
            if let id = store.importAudio(url, track: track, at: t), let l = store.project.locate(clip: id) {
                t += store.project.tracks[l.track].clips[l.clip].duration
                store.selection = .clip(id)
            }
        }
    }
}
