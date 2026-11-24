import AppKit
import UniformTypeIdentifiers

// mitroley. Copyright © 2026 Ayan Mitra.

/// Where sessions and exports go, and how often a session is saved.
enum Places {
    /// Folder new sessions are made in. The user can change it in Settings.
    static var sessions: URL {
        if let p = UserDefaults.standard.string(forKey: "sessionsFolder"), FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p, isDirectory: true) }
        return AppPaths.library
    }

    /// Folder exports go to, or nil to use the Exports folder inside each session.
    static var exports: URL? {
        guard let p = UserDefaults.standard.string(forKey: "exportsFolder"), FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// Seconds between automatic saves. 0 = shortly after every change.
    static var autosave: Double { UserDefaults.standard.double(forKey: "autosaveSeconds") }

    static func chooseFolder(_ message: String, start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Choose"
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func tidy(_ name: String) -> String {
        let s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Untitled" : s
    }
}

extension Store {
    private func sessionPanel(_ title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.message = "A session is a folder holding the project, its sounds and its exports."
        panel.nameFieldStringValue = name
        panel.directoryURL = Places.sessions
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension != AppPaths.sessionExtension { url = url.deletingPathExtension().appendingPathExtension(AppPaths.sessionExtension) }
        return url
    }

    /// File › New Session: asks for a name and a place.
    func newSessionAsking() {
        guard let url = sessionPanel("New Session", name: "Untitled") else { return }
        create(at: url)
    }

    /// File › Save: writes the session now.
    func saveNow() {
        save()
        say("Saved")
    }

    /// File › Save As: copies the whole session (project, sounds, video, exports) to a new place and carries on there.
    func saveAs() {
        guard let url = sessionPanel("Save Session As", name: project.name) else { return }
        save()
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.copyItem(at: folder, to: url)
        } catch {
            say("Could not save there: \(error.localizedDescription)", error: true)
            return
        }
        if open(url) {
            mutate { $0.name = url.deletingPathExtension().lastPathComponent }
            save()
            say("Saved as \(url.deletingPathExtension().lastPathComponent)")
        }
    }

    /// File › Rename Session: renames the session's folder and the session itself.
    func renameSessionAsking() {
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "This renames the session and its folder in Finder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = project.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rename(to: field.stringValue)
    }

    func rename(to raw: String) {
        let name = Places.tidy(raw)
        guard name != folder.deletingPathExtension().lastPathComponent || name != project.name else { return }
        save()
        let target = folder.deletingLastPathComponent().appendingPathComponent(name + "." + AppPaths.sessionExtension, isDirectory: true)
        if target.path != folder.path {
            guard !FileManager.default.fileExists(atPath: target.path) else {
                say("There is already a session called \(name) in that folder.", error: true)
                return
            }
            do { try FileManager.default.moveItem(at: folder, to: target) } catch {
                say("Could not rename: \(error.localizedDescription)", error: true)
                return
            }
            guard open(target) else { return }
        }
        mutate { $0.name = name }
        save()
    }

    /// Where an export of this session goes: the folder chosen in Settings or the export sheet, else the session's own Exports folder.
    var exportsFolder: URL { Places.exports ?? subfolder("Exports") }
}

extension Store {
    /// Hints that appear when the pointer rests on a control. Read by AppKit at launch, so a change applies after restarting.
    func applyHoverHelp() {
        let on = UserDefaults.standard.object(forKey: "hoverHelp") as? Bool ?? true
        UserDefaults.standard.set(on ? 800 : 86_400_000, forKey: "NSInitialToolTipDelay")
    }
}

extension Store {
    private func wavPanel(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = exportsFolder
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Right-click a track › Export This Track. With effects: as it sounds in the mix (its space, filters, automation, fader,
    /// pan). Without: just its clips with their own gain and fades, centred, at full level.
    func exportTrackAsking(_ id: UUID, effects: Bool) {
        guard let track = project.tracks.first(where: { $0.id == id }) else { return }
        guard track.clips.contains(where: { $0.take != nil }) else { say("That track has no sound to export.", error: true); return }
        guard let url = wavPanel(Places.tidy(track.name) + (effects ? "" : " dry") + ".wav") else { return }
        var q = project
        for i in q.tracks.indices {
            q.tracks[i].solo = false
            q.tracks[i].mute = q.tracks[i].id != id
            if q.tracks[i].id == id, !effects {
                q.tracks[i].spaceMode = .dry
                q.tracks[i].lowCut = 20; q.tracks[i].highCut = 20000
                q.tracks[i].automation = [:]
                q.tracks[i].volume = 0; q.tracks[i].pan = 0
                q.tracks[i].spatial = false
                q.tracks[i].groupID = nil
            }
        }
        q.groups = q.groups?.map { var g = $0; g.solo = false; g.mute = false; if !effects { g.volume = 0 }; return g }
        if !effects { q.masterVolume = nil }
        let folder = self.folder
        busy = "Exporting \(track.name)"
        Task {
            defer { busy = nil }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let mix = try Exporter.render(q, mode: .stereo, resolve: { Store.url(for: $0, in: folder) })
                    var ch = [mix.l, mix.r]
                    _ = Exporter.protect(&ch)
                    try WAV.write(url, channels: ch)
                }.value
                say("Exported \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                say(error.localizedDescription, error: true)
            }
        }
    }

    /// Right-click a clip › Download Sound: saves the take that is playing, as the file ElevenLabs returned or the one imported.
    func downloadClipAsking(_ id: UUID) {
        guard let l = project.locate(clip: id) else { return }
        let clip = project.tracks[l.track].clips[l.clip]
        guard let take = clip.take else { return }
        let source = url(for: take)
        guard let dest = wavPanel(Places.tidy(clip.name) + "." + source.pathExtension) else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            say("Could not save the sound: \(error.localizedDescription)", error: true)
        }
    }
}

extension Store {
    /// File › Share Session: one .zip with everything the session needs, to send to someone else with mitroley.
    /// Exports and the stills made for Claude are left out; they are remade on the other side.
    func shareSessionAsking() {
        saveNow()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Places.tidy(project.name) + ".mitroley.zip"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = "The other person unzips it and double-clicks the session."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let source = folder, name = Places.tidy(project.name) + "." + AppPaths.sessionExtension
        busy = "Packing the session"
        Task {
            defer { busy = nil }
            do {
                let size = try await Task.detached(priority: .userInitiated) { () -> Int in
                    let fm = FileManager.default
                    let temp = fm.temporaryDirectory.appendingPathComponent("share-" + UUID().uuidString, isDirectory: true)
                    let copy = temp.appendingPathComponent(name, isDirectory: true)
                    try fm.createDirectory(at: copy, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: temp) }
                    for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where !["Exports", "Frames"].contains(item.lastPathComponent) {
                        try fm.copyItem(at: item, to: copy.appendingPathComponent(item.lastPathComponent))
                    }
                    try? fm.removeItem(at: dest)
                    let zip = Process()
                    zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    zip.arguments = ["-c", "-k", "--keepParent", copy.path, dest.path]
                    try zip.run()
                    zip.waitUntilExit()
                    guard zip.terminationStatus == 0 else { throw ExportError(message: "The session could not be zipped.") }
                    return ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int) ?? 0
                }.value
                say("Packed \(dest.lastPathComponent), \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch { say("Could not pack the session: \(error.localizedDescription)", error: true) }
        }
    }

    /// Shows the session's own settings in the side panel.
    func showSession() {
        selection = .none
        if showClaude, !anyAgentRunning { showClaude = false }
    }

    /// Asks ElevenLabs which speech models this account can use, so new ones appear without an app update.
    func loadVoiceModels() async {
        guard voiceModels.isEmpty, Secrets.has(.elevenLabs) else { return }
        voiceModels = (try? await ElevenLabs.speechModels()) ?? []
    }
}
