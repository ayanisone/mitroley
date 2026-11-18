import Foundation
import Observation

struct AgentEntry: Identifiable, Equatable {
    enum Kind { case user, claude, action, error }
    var id = UUID()
    var kind: Kind
    var text: String
}

/// Claude working inside the session. It looks at frames of the video, reads the storyboard,
/// and edits the session through the same commands the MCP bridge exposes.
@MainActor @Observable
final class AgentState {
    var entries: [AgentEntry] = []
    var running = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// How hard Claude thinks before it acts: low, medium or high. High unless changed in the Claude panel.
    static var effort: String {
        let e = UserDefaults.standard.string(forKey: "claudeEffort") ?? "high"
        return ["low", "medium", "high"].contains(e) ? e : "high"
    }
    static var model: String { UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-opus-5-5" }

    static let system = """
    You are the sound supervisor inside mitroley, a small Mac app for putting sound effects and ambience to picture. \
    The people using it make short AI-generated films: commercials, reels, tutorials. Their generated sound effects \
    usually ignore what the picture is doing. A room tone keeps playing after the character has walked into another \
    room, footsteps sound the same in a kitchen and in a cave. Your job is to make the sound belong to the picture.

    How the app thinks:
    - Scenes are regions on the timeline. Each scene points at a space.
    - A space is what a place sounds like: reverb, echo, how dark the reflections are, and how muffled or quiet \
    direct sound becomes there.
    - A track set to follow takes on the space of whichever scene the playhead is in, and crossfades between spaces \
    over the scene's transition time. So footsteps on one foley track pick up a cave's reverb the moment the scene \
    becomes a cave. You do not need a separate track per room.
    - Ambience is different: each place has its own background sound, so give each scene its own ambience clip and \
    overlap neighbouring clips with fades as long as the scene transition. When the listener can still hear the \
    previous place from the next one, keep that clip going quietly and muffle it with highCut automation.
    - Spatial tracks are point sources with a room position, which can be automated to follow what moves on screen.

    How to work:
    1. Call get_project, then analyze_video to see the picture. Read the storyboard if there is one; it tells you \
    intent the frames cannot. Wherever a boundary, an event or a movement is unclear, look closer: get_frames for \
    exact moments, or analyze_video with start and end to step through one shot several frames a second.
    2. Decide where the acoustic space changes. That is often at a cut, but a move between rooms inside one shot \
    counts too, with a transition of a second or more.
    3. Define the spaces the film needs (start from templates), then write the scene lane with set_scenes.
    4. Set up tracks, then place sound. If clips already exist, keep them and fit them to the picture: move, trim, \
    fade, switch takes, automate. Use generate_sfx only where something on screen has no sound yet. Each generation \
    costs the user credits, so do not regenerate what already works. If elevenlabs_key_set is false, generate_sfx \
    still places the cue (prompt and timing, no audio) so the user can generate everything later with one click; \
    say so in your summary.
    5. You cannot hear, so measure. Call measure_takes before you sync or balance anything. Generated sounds often \
    start late inside the file and vary in level by tens of dB: set each hit's offset to its onset so it lands on \
    its frame, pick the take whose shape fits (steady for beds, a clean start for hits), and set gain_db from the \
    measured levels so beds sit well under the events.
    6. Automate in detail. This is where the sound starts to belong to the picture, so go shot by shot, not scene \
    by scene, and write to several lanes:
    - Perspective. When the camera is wide or far from a source, lower its volume and its highCut; when it is \
    close, open both up. A source that leaves the frame but is still nearby stays, quieter and duller.
    - Position. On spatial tracks, put x where the source is on screen, y for near or far, z for height, and move \
    them with the source. Follow movement with several keyframes, not just a start and an end.
    - Space amount. Close-ups are drier (lower send); wide shots let more of the room in.
    - Room for events. Dip ambience a few dB under an important hit and bring it back.
    - Cuts and moves. At a cut, use curve "hold" on the last keyframe before it so the value jumps on the frame. \
    For anything that travels (a walk, a camera move, a door opening), use "smooth".
    Work one scene at a time with set_automation's from and to, so each pass refines a stretch without wiping \
    the rest. Prefer many small, motivated moves over a few big ones, and do not automate what the picture does \
    not show.
    Music: only when asked. Use compose_music with a genre, mood and instruments for the whole piece, and your own \
    sections, one per scene or run of shots, each with styles that say how the music should feel there, so the \
    score turns where the picture turns. Instrumental unless the user asks for vocals. Put it on a dry music \
    track and set its level under the effects.
    Footsteps: never lay one long footsteps clip under a walk; it will not match the feet. Step through the \
    walking shot with analyze_video (start, end, interval 0.1 or less), note the time each foot lands, then call \
    place_steps with those times and the shoe and surface. Do the same for any repeated contact (hoofs, claps, \
    hammering). If a footsteps clip already exists, pass it as source_clip and clear the old one with \
    replace_from and replace_to.
    Revised cuts: when get_project shows a revision, the session came from an earlier cut and already has its \
    sound. Work only inside the revision's needs_sound stretches: look at them, give new scenes a space with \
    set_scenes-level care (rewrite the whole lane, keeping every other scene exactly as it is), and add cues \
    there. Check that beds running across a new shot still suit it. Do not regenerate or re-time anything else.
    Groups: when a session has more than about six tracks, group them with set_group (SFX, Ambience, Music) so \
    the user can balance and mute them together.
    Voice-over: when asked to redo the voices in the film, call transcribe_voices to get the lines and their \
    times, look at those moments to see who speaks, then list_voices and choose voices that fit the characters \
    (age, gender, accent; for Indian characters use Indian voices, searching the library if the account has \
    none). Say each line with speak_line at its original start, on one voice track. For several people speaking \
    together, layer three or four voices on the same line.
    The film's own sound: if the user wants to reuse sounds from the original video, use original_sound and \
    tell them which track holds what; you cannot hear it, so they choose.
    7. Finish with a short plain summary of what you changed and anything you were unsure about, with timecodes.

    Times are in seconds. You cannot hear the audio, so say so when a choice between takes needs ears.
    """

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    func send(_ text: String, store: Store) {
        guard !running else { return }
        guard let key = Secrets.get(.anthropic) else {
            entries.append(AgentEntry(kind: .error, text: "Add your Anthropic API key in Settings to let Claude work on the session."))
            return
        }
        entries.append(AgentEntry(kind: .user, text: text))
        running = true
        task = Task { [weak self] in
            await self?.loop(text, key: key, store: store)
            self?.running = false
        }
    }

    @ObservationIgnored private var messages: [[String: Any]] = []

    func reset() {
        stop()
        entries = []
        messages = []
    }

    private func loop(_ text: String, key: String, store: Store) async {
        messages.append(["role": "user", "content": text])
        for _ in 0..<90 {
            if Task.isCancelled { return }
            let response: [String: Any]
            do { response = try await request(key: key) } catch {
                entries.append(AgentEntry(kind: .error, text: error.localizedDescription))
                messages.removeLast()
                return
            }
            let content = (response["content"] as? [[String: Any]]) ?? []
            let stop = response["stop_reason"] as? String ?? ""
            if stop == "refusal" {
                entries.append(AgentEntry(kind: .error, text: "Claude declined this request."))
                messages.removeLast()
                return
            }
            // Keep the full content (including thinking blocks) so the next turn stays valid.
            messages.append(["role": "assistant", "content": content])
            for block in content where block["type"] as? String == "text" {
                if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entries.append(AgentEntry(kind: .claude, text: t))
                }
            }
            let calls = content.filter { $0["type"] as? String == "tool_use" }
            if stop != "tool_use" || calls.isEmpty {
                if stop == "max_tokens" { entries.append(AgentEntry(kind: .error, text: "Claude ran out of room mid-answer. Ask it to continue.")) }
                return
            }
            var results: [[String: Any]] = []
            for call in calls {
                if Task.isCancelled { return }
                let name = call["name"] as? String ?? ""
                let input = (call["input"] as? [String: Any]) ?? [:]
                entries.append(AgentEntry(kind: .action, text: Self.describe(name, input)))
                var result: [String: Any] = ["type": "tool_result", "tool_use_id": call["id"] as? String ?? ""]
                do {
                    let out = try await store.commands.call(name, input)
                    var blocks: [[String: Any]] = [["type": "text", "text": Self.json(out.json)]]
                    for img in out.images {
                        guard let data = try? Data(contentsOf: URL(fileURLWithPath: img.path)) else { continue }
                        blocks.append(["type": "text", "text": img.label])
                        blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
                    }
                    result["content"] = blocks
                } catch {
                    result["content"] = error.localizedDescription
                    result["is_error"] = true
                    entries.append(AgentEntry(kind: .error, text: error.localizedDescription))
                }
                results.append(result)
            }
            messages.append(["role": "user", "content": results])
        }
        entries.append(AgentEntry(kind: .error, text: "Stopped after 90 steps. Ask Claude to continue if there is more to do."))
    }

    private func request(key: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // If a safety classifier declines the request, the API retries it on Anthropic's recommended fallback model.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": Self.system,
            "tools": Commands.tools,
            "messages": messages,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": Self.effort],
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var lastError = "Claude did not answer."
        for attempt in 0..<3 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if status == 200 { return obj }
            let message = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            switch status {
            case 401: throw ServiceError(message: "Anthropic did not accept the API key. Check it in Settings.")
            case 429, 500...599:
                lastError = status == 429 ? "Claude is rate limited right now. Try again in a minute." : "Anthropic had a server problem (\(status)). Try again."
                try await Task.sleep(nanoseconds: UInt64(2 + attempt * 4) * 1_000_000_000)
            default:
                throw ServiceError(message: "Claude request failed: \(message)")
            }
        }
        throw ServiceError(message: lastError)
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// A short human line for each thing Claude does.
    static func describe(_ name: String, _ a: [String: Any]) -> String {
        func t(_ k: String) -> String { a.num(k).map { String(format: "%.1fs", $0) } ?? "" }
        switch name {
        case "get_project": return "Reading the session"
        case "new_session": return "New session: \(a.str("name") ?? "")"
        case "analyze_video": return "Watching the video"
        case "get_frames": return "Looking closer at \(((a["times"] as? [Any]) ?? []).count) moments"
        case "list_space_templates": return "Checking the built-in spaces"
        case "define_space": return "Space: \(a.str("name") ?? "")"
        case "set_scenes": return "Writing \(((a["scenes"] as? [Any]) ?? []).count) scenes"
        case "add_track": return "New track: \(a.str("name") ?? "")"
        case "update_track": return "Adjusting track \(a.str("track") ?? "")"
        case "set_automation": return "Automating \(a.str("param") ?? "") on \(a.str("track") ?? "")"
        case "generate_sfx": return "Generating \"\(a.str("prompt") ?? "")\" at \(t("start"))"
        case "generate_missing": return "Generating the sounds that are still missing"
        case "compose_music": return "Composing music: \([a.str("genre"), a.str("mood"), a.str("style")].compactMap { $0 }.joined(separator: ", "))"
        case "transcribe_voices": return "Listening for voices in the film"
        case "list_voices": return "Looking for voices that fit"
        case "speak_line": return "\(a.str("voice") ?? "A voice") says \"\(a.str("text") ?? "")\" at \(t("start"))"
        case "import_revised_video": return "Comparing the revised cut with this one"
        case "get_revision": return "Checking what changed in this cut"
        case "set_group": return a.str("group").map { "Grouping tracks as \($0)" } ?? "Ungrouping tracks"
        case "place_steps": return "Placing \(((a["times"] as? [Any]) ?? []).count) footsteps on \(a.str("track") ?? "")"
        case "original_sound": return a.str("mode") == "stems" ? "Splitting the film's own sound into stems" : "Bringing in the film's own sound"
        case "add_audio_clip": return "Placing \(URL(fileURLWithPath: a.str("file") ?? "").lastPathComponent) at \(t("start"))"
        case "update_clip": return "Adjusting a clip"
        case "crossfade": return "Crossfading two clips"
        case "delete_clip": return "Removing a clip"
        case "delete_track": return "Removing track \(a.str("track") ?? "")"
        case "transport": return "Transport: \(a.str("action") ?? "")"
        case "focus": return "Showing you the result"
        case "measure_takes": return "Measuring the takes"
        case "set_loop": return "Marking a loop"
        case "set_master": return "Setting the master bus"
        case "measure_mix": return "Measuring the mix"
        case "set_monitor": return "Monitoring in \(a.str("mode") ?? "")"
        case "export": return "Exporting \(a.str("format") ?? "")"
        default: return name
        }
    }
}
