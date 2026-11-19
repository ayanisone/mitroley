import AppKit
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// What the voice helper can do to the app itself, as opposed to the session: look at what is on screen, scroll, zoom,
/// open and close panels, pick tools, press menu items. The session commands (tracks, clips, sound) are in Commands.
extension VoiceAgent {
    static let interfaceCommands = """
        - look: What is on screen right now: playhead, what part of the timeline is visible, zoom, what is selected, which tool and panels are open, the menus. No arguments.
        - scroll: Scrolls the timeline or a panel.
            arguments: where (string): timeline, side_panel (settings of the selected thing, on the right) or panel (whatever sheet or window is in front, such as Settings or Claude). Default timeline; to_time (number): timeline only, seconds to bring to the middle of the view; track (string): timeline only, a track name to bring into view; direction (string): left, right, up, down, start, end, top or bottom; amount (number): how far, in screens. Default 0.8
        - zoom: Zooms the timeline.
            arguments: direction (string): in, out or fit; level (number): 1 shows the whole film, up to 40; around (number): seconds to keep in the middle
        - show: Opens a part of the app.
            arguments: place (string): settings, export, claude, room, session, master_effects
        - close: Closes a panel, or everything that is open.
            arguments: place (string): settings, export, claude, room, master_effects, side_panel or all
        - set_tool: Picks the editing tool.
            arguments: tool (string): pointer, scissors, mute, solo, marquee, gain or fade
        - set_edit_mode: How clips move when dragged.
            arguments: mode (string): slip, snap or grid
        - switch_cut: Opens another cut of the film (the A/B switch).
            arguments: cut (string): its letter (A, B, C) or name
        - undo and redo: Step back or forward through changes. No arguments.
        - menu: Presses a menu item, for anything not covered above (save, new session, import, export a track, and so on).
            arguments: title (string): the item's name as it appears in the menu, for example "Save As…"
        - set_helper_voice: Changes the voice you yourself speak with. It takes effect the next time the helper is started, so tell the person to switch the helper off and on.
            arguments: voice (string): part of a voice's name, or "default". Leave out to hear which voices there are.
        To select a clip, track, scene or space and show its settings, use focus. To move the playhead, use transport.
        """

    /// Runs one interface command. nil = not an interface command.
    func interface(_ name: String, _ a: [String: Any], _ store: Store) throws -> Any? {
        func str(_ k: String) -> String? { (a[k] as? String).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.flatMap { $0.isEmpty ? nil : $0 } }
        func num(_ k: String) -> Double? { (a[k] as? Double) ?? (a[k] as? NSNumber)?.doubleValue ?? (a[k] as? String).flatMap(Double.init) }
        switch name {
        case "look":
            return look(store)
        case "scroll":
            let target = str("where") ?? "timeline"
            if target == "timeline" { return try scrollTimeline(store, time: num("to_time"), track: a["track"] as? String, direction: str("direction"), amount: num("amount") ?? 0.8) }
            return try scrollPanel(side: target.contains("side"), direction: str("direction") ?? "down", amount: num("amount") ?? 0.8)
        case "zoom":
            let before = store.zoom
            var z = before
            if let l = num("level") { z = l }
            else {
                switch str("direction") ?? "in" {
                case "in": z = before * 2
                case "out": z = before / 2
                case "fit": z = 1
                default: throw ServiceError(message: "direction must be in, out or fit.")
                }
            }
            z = min(40, max(1, z))
            let middle = num("around") ?? visibleTimes(store).map { ($0.from + $0.to) / 2 } ?? store.player.time
            store.zoom = z
            // The timeline is laid out again at the new zoom on the next pass; then the same moment is brought back to the middle.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                _ = try? self.scrollTimeline(store, time: middle, track: nil, direction: nil, amount: 0)
            }
            return ["ok": true, "zoom": z]
        case "show":
            switch str("place") ?? "" {
            case "settings": store.showSettings = true
            case "export": store.showExport = true
            case "claude": store.showClaude = true
            case "session": store.showSession()
            case "room": store.openRoom?()
            case "master_effects", "master": store.showMaster = true
            default: throw ServiceError(message: "place must be settings, export, claude, room, session or master_effects.")
            }
            return ["ok": true]
        case "close":
            let place = str("place") ?? "all"
            let all = place == "all"
            if all || place == "settings" { store.showSettings = false }
            if all || place == "export" { store.showExport = false }
            if all || place == "claude" { store.showClaude = false }
            if all || place.hasPrefix("master") { store.showMaster = false }
            if all || place == "side_panel" || place == "session" { store.selection = .none }
            if all || place == "room" { NSApp.windows.first { $0.title == "Room" }?.close() }
            return ["ok": true]
        case "set_tool":
            guard let t = Tool(rawValue: str("tool") ?? "") else { throw ServiceError(message: "tool must be one of: " + Tool.allCases.map(\.rawValue).joined(separator: ", ")) }
            store.tool = t
            return ["ok": true, "tool": t.rawValue]
        case "set_edit_mode":
            guard let m = EditMode(rawValue: str("mode") ?? "") else { throw ServiceError(message: "mode must be slip, snap or grid.") }
            store.editMode = m
            return ["ok": true, "mode": m.rawValue]
        case "switch_cut":
            let want = str("cut") ?? ""
            let list = store.versionList
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            let url = list.enumerated().first { i, u in
                (i < letters.count && String(letters[i]) == want) || u.deletingPathExtension().lastPathComponent.lowercased() == want
            }?.element
            guard let url else { throw ServiceError(message: "There is no cut called \(want). The cuts are: " + list.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")) }
            if url != store.folder { store.switchVersion(to: url) }
            return ["ok": true, "cut": url.deletingPathExtension().lastPathComponent]
        case "undo":
            guard store.canUndo else { throw ServiceError(message: "There is nothing to undo.") }
            store.undo(); return ["ok": true]
        case "redo":
            guard store.canRedo else { throw ServiceError(message: "There is nothing to redo.") }
            store.redo(); return ["ok": true]
        case "menu":
            return try pressMenu((a["title"] as? String) ?? "")
        case "set_helper_voice":
            let d = UserDefaults.standard
            guard let want = str("voice") else {
                return ["current": d.string(forKey: "voiceAgentVoiceName") ?? "the ElevenLabs default", "some_voices": store.voices.prefix(25).map { $0.detail.isEmpty ? $0.name : "\($0.name) (\($0.detail))" }]
            }
            if want == "default" {
                d.removeObject(forKey: "voiceAgentVoice"); d.removeObject(forKey: "voiceAgentVoiceName")
                return ["ok": true, "voice": "default", "note": "Applies when the helper is next started."]
            }
            guard let v = store.voices.first(where: { $0.name.lowercased() == want }) ?? store.voices.first(where: { $0.name.lowercased().contains(want) }) else {
                throw ServiceError(message: "No voice on the account matches \(want). Some that are there: " + store.voices.prefix(25).map(\.name).joined(separator: ", "))
            }
            d.set(v.id, forKey: "voiceAgentVoice"); d.set(v.name, forKey: "voiceAgentVoiceName")
            return ["ok": true, "voice": v.name, "note": "Applies when the helper is next started."]
        default:
            return nil
        }
    }

    // MARK: Looking

    private func visibleTimes(_ store: Store) -> (from: Double, to: Double, pps: Double)? {
        guard let sv = Commands.timelineScrollView(), let doc = sv.documentView else { return nil }
        let duration = max(1, store.project.duration)
        let lanes = sv.contentView.bounds.width - Metrics.header - 1
        let pps = Double(doc.frame.width - Metrics.header - 1 - 24) / duration
        guard pps > 0, lanes > 0 else { return nil }
        let x = Double(sv.contentView.bounds.origin.x)
        return (max(0, x / pps), min(duration, (x + Double(lanes)) / pps), pps)
    }

    private func look(_ store: Store) -> [String: Any] {
        let p = store.project
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var out: [String: Any] = [
            "playhead_seconds": r(store.player.time), "playing": store.player.isPlaying, "film_length_seconds": r(p.duration),
            "zoom": r(store.zoom), "tool": store.tool.rawValue, "edit_mode": store.editMode.rawValue,
            "listening_as": String(describing: store.player.monitor), "session_format": p.format.title,
            "tracks": p.tracks.map(\.name), "scenes": p.scenes.map(\.name),
        ]
        if let v = visibleTimes(store) { out["timeline_shows_seconds"] = [r(v.from), r(v.to)] }
        switch store.selection {
        case .none: out["selected"] = "nothing"
        case .clip(let id):
            if let l = p.locate(clip: id) {
                let c = p.tracks[l.track].clips[l.clip]
                out["selected"] = ["clip": id.uuidString, "on_track": p.tracks[l.track].name, "starts_at": r(c.start)]
            }
        case .track(let id): out["selected"] = ["track": p.tracks.first { $0.id == id }?.name ?? ""]
        case .scene(let id): out["selected"] = ["scene": p.scenes.first { $0.id == id }?.name ?? ""]
        case .space: out["selected"] = "a space"
        case .group: out["selected"] = "a group of tracks"
        }
        var open: [String] = []
        if store.showSettings { open.append("settings") }
        if store.showExport { open.append("export") }
        if store.showClaude { open.append("claude") }
        if store.showMaster { open.append("master_effects") }
        if NSApp.windows.contains(where: { $0.title == "Room" && $0.isVisible }) { open.append("room") }
        if store.selection != .none, !store.showClaude { open.append("side_panel") }
        out["open"] = open
        out["cuts"] = store.versionList.map { $0.deletingPathExtension().lastPathComponent }
        out["menus"] = (NSApp.mainMenu?.items ?? []).compactMap { top -> String? in
            guard let sub = top.submenu, top.title != "Apple", !sub.title.isEmpty else { return nil }
            let items = sub.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }.map(\.title)
            return items.isEmpty ? nil : "\(sub.title): " + items.joined(separator: ", ")
        }
        return out
    }

    // MARK: Scrolling

    private func scrollTimeline(_ store: Store, time: Double?, track: String?, direction: String?, amount: Double) throws -> [String: Any] {
        guard let sv = Commands.timelineScrollView(), let doc = sv.documentView, let v = visibleTimes(store) else { throw ServiceError(message: "The timeline is not on screen.") }
        let view = sv.contentView.bounds
        let lanes = Double(view.width - Metrics.header - 1)
        var x = Double(view.origin.x), y = Double(view.origin.y)
        let maxX = max(0, Double(doc.frame.width - view.width)), maxY = max(0, Double(doc.frame.height - view.height))
        if let time { x = time * v.pps - lanes / 2 }
        if let track {
            // Rows are of varying height, so a track is found by its share of the way down: close enough to bring it into view.
            let names = store.project.tracks.map { $0.name.lowercased() }
            guard let i = names.firstIndex(where: { $0 == track.lowercased() }) ?? names.firstIndex(where: { $0.contains(track.lowercased()) }) else {
                throw ServiceError(message: "There is no track called \(track).")
            }
            y = maxY * Double(i) / Double(max(1, names.count - 1))
            store.selection = .track(store.project.tracks[i].id)
        }
        switch direction {
        case "left": x -= lanes * amount
        case "right": x += lanes * amount
        case "up": y -= Double(view.height) * amount
        case "down": y += Double(view.height) * amount
        case "start": x = 0
        case "end": x = maxX
        case "top": y = 0
        case "bottom": y = maxY
        case nil: break
        default: throw ServiceError(message: "direction must be left, right, up, down, start, end, top or bottom.")
        }
        guard time != nil || track != nil || direction != nil else { throw ServiceError(message: "Say where to scroll: to_time, track or direction.") }
        x = min(maxX, max(0, x)); y = min(maxY, max(0, y))
        glide(sv, to: NSPoint(x: x, y: y))
        return ["ok": true, "timeline_shows_seconds": [((x / v.pps) * 100).rounded() / 100, ((min(store.project.duration, (x + lanes) / v.pps)) * 100).rounded() / 100],
                "note": maxX < 1 && (time != nil || direction == "left" || direction == "right") ? "The whole film already fits in the view. Zoom in to scroll sideways." : ""]
    }

    private func scrollPanel(side: Bool, direction: String, amount: Double) throws -> [String: Any] {
        let timeline = Commands.timelineScrollView()
        func scrolls(in window: NSWindow) -> [NSScrollView] {
            var found: [NSScrollView] = []
            func walk(_ v: NSView) {
                if let s = v as? NSScrollView, s !== timeline, !s.isHidden, s.frame.height > 80, (s.documentView?.frame.height ?? 0) > s.contentView.bounds.height + 1 { found.append(s) }
                v.subviews.forEach(walk)
            }
            if let c = window.contentView { walk(c) }
            return found
        }
        let main = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil && $0.frame.width > 900 && $0.title != "Room" }
        var pick: NSScrollView?
        if side, let main {
            // The side panel is the scrolling area furthest to the right of the main window.
            pick = scrolls(in: main).max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
        } else {
            let front = [main?.attachedSheet, NSApp.keyWindow, NSApp.windows.first { $0.title == "Room" && $0.isVisible }, main].compactMap { $0 }
            for w in front {
                if let s = scrolls(in: w).max(by: { $0.frame.height < $1.frame.height }) { pick = s; break }
            }
        }
        guard let sv = pick, let doc = sv.documentView else { throw ServiceError(message: "Nothing there needs scrolling: it all fits.") }
        let view = sv.contentView.bounds
        let maxY = max(0, doc.frame.height - view.height)
        // In a flipped view "down the page" is a larger y; in an unflipped one it is smaller.
        let down: CGFloat = doc.isFlipped ? 1 : -1
        var y = view.origin.y
        switch direction {
        case "down": y += down * view.height * amount
        case "up": y -= down * view.height * amount
        case "top", "start": y = doc.isFlipped ? 0 : maxY
        case "bottom", "end": y = doc.isFlipped ? maxY : 0
        default: throw ServiceError(message: "direction must be up, down, top or bottom.")
        }
        y = min(maxY, max(0, y))
        glide(sv, to: NSPoint(x: view.origin.x, y: y))
        let place = doc.isFlipped ? y / max(1, maxY) : 1 - y / max(1, maxY)
        return ["ok": true, "position": place < 0.02 ? "top" : place > 0.98 ? "bottom" : "\(Int(place * 100)) percent of the way down"]
    }

    private func glide(_ sv: NSScrollView, to p: NSPoint) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sv.contentView.animator().setBoundsOrigin(p)
        } completionHandler: {
            MainActor.assumeIsolated { sv.reflectScrolledClipView(sv.contentView) }
        }
    }

    // MARK: Menus

    private func pressMenu(_ title: String) throws -> [String: Any] {
        func plain(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces) }
        let want = plain(title)
        guard !want.isEmpty else { throw ServiceError(message: "Say which menu item.") }
        var exact: (NSMenu, Int)?, close: (NSMenu, Int)?
        func walk(_ menu: NSMenu) {
            menu.update()
            for (i, item) in menu.items.enumerated() where !item.isSeparatorItem {
                if let sub = item.submenu { walk(sub); continue }
                let t = plain(item.title)
                if t == want, exact == nil { exact = (menu, i) }
                else if t.contains(want), close == nil { close = (menu, i) }
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
        guard let (menu, index) = exact ?? close else { throw ServiceError(message: "There is no menu item called \(title). Use look to see the menus.") }
        let item = menu.items[index]
        // Never from here: these end the conversation or the app.
        if item.action == #selector(NSApplication.terminate(_:)) { throw ServiceError(message: "Quitting is left to the person.") }
        guard item.isEnabled else { throw ServiceError(message: "\(item.title) is greyed out right now.") }
        menu.performActionForItem(at: index)
        return ["ok": true, "pressed": item.title]
    }
}
