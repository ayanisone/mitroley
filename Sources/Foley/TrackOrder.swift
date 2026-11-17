import SwiftUI

/// A place between two timeline rows where a track can land: before `index` in the track list
/// (the list's count = at the end), in `group` (nil = outside any group). `y` is the top of the row below.
struct TrackSlot: Equatable {
    var y: CGFloat
    var index: Int
    var group: UUID?
}

extension Project {
    /// Every place a track can be dropped, top to bottom. A slot between two tracks of one group,
    /// or between a group's header and its first track, is inside that group; every other slot is outside all groups.
    func trackSlots(height: (TimelineRow) -> CGFloat) -> [TrackSlot] {
        let list = rows
        func groupOf(_ row: TimelineRow) -> UUID? {
            switch row {
            case .group(let g, _): g.collapsed ? nil : g.id
            case .track(let t): t.groupID
            }
        }
        var out: [TrackSlot] = []
        var y: CGFloat = 0
        for k in 0...list.count {
            let below = k < list.count ? list[k] : nil
            let above = k > 0 ? list[k - 1] : nil
            var index = tracks.count
            var group: UUID?
            if let below {
                switch below {
                case .group(_, let first): index = trackIndex(first) ?? tracks.count
                case .track(let t):
                    index = trackIndex(t.id) ?? tracks.count
                    if let g = t.groupID, let above, groupOf(above) == g { group = g }
                }
            }
            out.append(TrackSlot(y: y, index: index, group: group))
            if let below { y += height(below) }
        }
        return out
    }

    /// Takes a track out of the list and puts it back before `index` (counted in the list as it was), in `group`.
    mutating func moveTrack(_ id: UUID, before index: Int, group: UUID?) {
        guard let from = trackIndex(id) else { return }
        var t = tracks.remove(at: from)
        t.groupID = group
        tracks.insert(t, at: min(tracks.count, max(0, index > from ? index - 1 : index)))
        tidyGroups()
    }

    /// Moves a track to `position` in the list (0 = top). It joins a group when it lands between two tracks of that
    /// group, keeps its own group when it lands at that group's edge, and otherwise leaves its group.
    mutating func moveTrack(_ id: UUID, to position: Int) {
        guard let from = trackIndex(id) else { return }
        let own = tracks[from].groupID
        var rest = tracks
        rest.remove(at: from)
        let at = min(rest.count, max(0, position))
        let above = at > 0 ? rest[at - 1].groupID : nil
        let below = at < rest.count ? rest[at].groupID : nil
        var group: UUID?
        if let above, above == below { group = above }
        else if let own, own == above || own == below { group = own }
        moveTrack(id, before: at >= from ? at + 1 : at, group: group)
    }

    /// Track order and grouping, to tell whether a move changed anything.
    var trackOrder: [String] { tracks.map { $0.id.uuidString + ($0.groupID?.uuidString ?? "") } }
}

extension Store {
    /// Height of a row in the track header column: a group header, or a track with its automation lane.
    func headerHeight(_ row: TimelineRow) -> CGFloat {
        switch row {
        case .group: Metrics.group
        case .track(let t): rowHeight(t) + (t.lane != nil ? Metrics.lane : 0)
        }
    }

    func trackSlots() -> [TrackSlot] {
        let p = project
        return p.trackSlots(height: headerHeight)
    }

    /// Drops a track into a slot as one undoable change. Does nothing if it would land where it is.
    func moveTrack(_ id: UUID, to slot: TrackSlot) {
        var next = project
        next.moveTrack(id, before: slot.index, group: slot.group)
        guard next.trackOrder != project.trackOrder else { return }
        mutate { p in p.moveTrack(id, before: slot.index, group: slot.group) }
    }

    /// The nearest slot above (-1) or below (+1) the track that changes where it sits or which group it is in.
    func trackStep(_ id: UUID, _ direction: Int) -> TrackSlot? {
        let p = project
        guard let row = p.rows.firstIndex(where: { if case .track(let t) = $0 { t.id == id } else { false } }) else { return nil }
        // One unit per row, so a slot's y is the number of rows above it.
        let slots = p.trackSlots(height: { _ in 1 })
        let candidates = direction < 0
            ? slots.filter { $0.y <= CGFloat(row) }.reversed()
            : slots.filter { $0.y >= CGFloat(row + 1) }
        let now = p.trackOrder
        for s in candidates {
            var q = p
            q.moveTrack(id, before: s.index, group: s.group)
            if q.trackOrder != now { return s }
        }
        return nil
    }

    func canMoveTrack(_ id: UUID, _ direction: Int) -> Bool { trackStep(id, direction) != nil }

    /// Moves a track one place up (-1) or down (+1), stepping into and out of groups on the way.
    func moveTrack(_ id: UUID, _ direction: Int) {
        guard let s = trackStep(id, direction) else { return }
        mutate { p in p.moveTrack(id, before: s.index, group: s.group) }
    }

    /// The selected track, for the menu commands.
    var selectedTrack: UUID? {
        if case .track(let id) = selection, project.trackIndex(id) != nil { return id }
        return nil
    }
}

extension Store {
    /// Sets what the session is mixed for. Stereo listens in stereo; everything else listens spatially.
    func setFormat(_ f: MixFormat) {
        if f != project.format { mutate { $0.mixFormat = f } }
        player.monitor = f == .stereo ? .stereo : .spatial
    }
}
