import AVFoundation
import Observation
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// A helper you talk to. It is an ElevenLabs agent that hears you, answers aloud, and works the app through the same
/// commands Claude uses. It follows whatever language you speak and can change mid-conversation.
@MainActor @Observable
final class VoiceAgent {
    enum State: Equatable { case off, connecting, listening, speaking, working(String) }
    var state = State.off
    var heard = ""          // the last thing the person said, as the agent heard it
    var said = ""           // the last thing the agent said
    var problem: String?

    @ObservationIgnored private weak var store: Store?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let speaker = AVAudioPlayerNode()
    @ObservationIgnored private var converter: AVAudioConverter?
    @ObservationIgnored private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    @ObservationIgnored private let play = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    @ObservationIgnored private var pending = 0     // spoken chunks still to play
    /// Bump when the prompt or tools change, so the agent on the account is brought up to date.
    private static let version = 2

    var isOn: Bool { state != .off }

    func toggle(_ store: Store) {
        if isOn { stop() } else { Task { await start(store) } }
    }

    // MARK: Setting the agent up on the account

    private static func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = try ElevenLabs.request("https://api.elevenlabs.io" + path, method: method)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw ServiceError(message: status == 401 || status == 403
                ? "This ElevenLabs key is not allowed to use agents. In ElevenLabs, give the key access to Agents (ElevenAgents) and try again."
                : "ElevenLabs agents: \(status) \(text)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func prompt() -> String {
        var lines: [String] = []
        for t in Commands.tools {
            guard let name = t["name"] as? String, let d = t["description"] as? String else { continue }
            let props = ((t["input_schema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            let args = props.keys.sorted().map { k -> String in
                let p = props[k] as? [String: Any]
                return "\(k) (\((p?["type"] as? String) ?? "any")): \((p?["description"] as? String) ?? "")"
            }
            lines.append("- \(name): \(d)" + (args.isEmpty ? "" : "\n    arguments: " + args.joined(separator: "; ")))
        }
        return """
        You are the voice helper inside mitroley, a Mac app for fitting sound effects, ambience, music and voice to a video. \
        The person is at the app right now, talking to you. Keep answers short and spoken-style: one or two sentences, no lists, no markdown.

        LANGUAGE. Answer in the language the person is speaking. If they change language, change with them at once, mid-conversation, \
        and use the language detection tool so your voice follows. Hindi mixed with English (Hinglish) is common: match it.

        DOING THINGS. You can work the app. Call run_command with the command's name and its arguments as a JSON object written as a string, \
        for example name "transport", arguments_json "{\\"action\\":\\"play\\"}". Start with get_project when you need to know what is in the session. \
        Do what is asked without asking permission for ordinary edits; every change can be undone with Command-Z. Ask first only before deleting \
        tracks or clips, or before generating sound, which spends the person's ElevenLabs credits. Say in a few words what you did.

        SHOWING THINGS. When asked where something is or what it does, explain briefly and call show_in_app to open that part of the app.

        WHERE THINGS ARE.
        - Picture at the top, with the playback bar under it: play, timecode, loop, the video's own sound, A/B switch between cuts, output meter (click it for master effects: compressor, limiter, surround reverb, fold-down trims, loudness), session format menu (7.1.4, 5.1, binaural, stereo), Stereo/Spatial listening switch.
        - Tools float at the left of the picture: V pointer, C scissors, M mute, S solo, R marquee, G gain, F fade.
        - Timeline below: ruler (Command-click twice to set a loop), filmstrip, scenes, then tracks. Slip/Snap/Grid in its corner. Each track has volume, pan, mute and solo. Right-click a track to export it; right-click a clip to download or mute it.
        - Side panel on the right shows settings for whatever is selected: a clip (takes, fades, gain), a track (new sound, mix, space, plug-ins, position), a scene, a space (reverb or an impulse response), or the session when you click the picture.
        - Toolbar at the top right: Room (3D view of where sounds are, with speaker meters and loudness), Claude (typed assistant), Export, Settings (keys, default format, where sessions and exports go, autosave).

        COMMANDS (for run_command):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Makes the agent and its two tools on the person's ElevenLabs account once, and brings them up to date after app updates.
    private func agentID() async throws -> String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "voiceAgentID"), d.integer(forKey: "voiceAgentVersion") == Self.version { return id }
        var tools: [String] = []
        let specs: [[String: Any]] = [
            ["type": "client", "name": "run_command", "expects_response": true, "response_timeout_secs": 120,
             "description": "Runs one mitroley command on the open session and returns its result as JSON.",
             "parameters": ["type": "object", "required": ["name", "arguments_json"], "properties": [
                "name": ["type": "string", "description": "The command's name, exactly as listed in the instructions."],
                "arguments_json": ["type": "string", "description": "The command's arguments as a JSON object in a string. Use {} for none."]]]],
            ["type": "client", "name": "show_in_app", "expects_response": true, "response_timeout_secs": 20,
             "description": "Opens a part of the app so the person can see it.",
             "parameters": ["type": "object", "required": ["place"], "properties": [
                "place": ["type": "string", "description": "One of: settings, export, claude, room, session, master_effects."]]]],
        ]
        for spec in specs {
            let made = try await Self.send("POST", "/v1/convai/tools", ["tool_config": spec])
            guard let id = made["id"] as? String else { throw ServiceError(message: "ElevenLabs did not return a tool id.") }
            tools.append(id)
        }
        let languages = ["hi", "es", "fr", "de", "pt", "it", "ja", "ko", "zh", "ar", "ta", "ru", "id", "tr", "nl", "pl"]
        let config: [String: Any] = [
            "agent": [
                "first_message": "Hi. What would you like to do?",
                "language": "en",
                "prompt": [
                    "prompt": Self.prompt(),
                    "tool_ids": tools,
                    "built_in_tools": ["language_detection": ["type": "system", "name": "language_detection", "description": "",
                                                              "params": ["system_tool_type": "language_detection"]]],
                ] as [String: Any],
            ] as [String: Any],
            "tts": ["model_id": "eleven_flash_v2_5", "agent_output_audio_format": "pcm_16000"],
            "asr": ["user_input_audio_format": "pcm_16000"],
            "language_presets": Dictionary(uniqueKeysWithValues: languages.map { ($0, ["overrides": [String: Any]()] as [String: Any]) }),
        ]
        let id: String
        if let old = d.string(forKey: "voiceAgentID"),
           (try? await Self.send("PATCH", "/v1/convai/agents/\(old)", ["conversation_config": config])) != nil {
            id = old
        } else {
            let made = try await Self.send("POST", "/v1/convai/agents/create", ["name": "mitroley helper", "conversation_config": config])
            guard let new = made["agent_id"] as? String else { throw ServiceError(message: "ElevenLabs did not return an agent id.") }
            id = new
        }
        d.set(id, forKey: "voiceAgentID")
        d.set(Self.version, forKey: "voiceAgentVersion")
        return id
    }

    // MARK: The conversation

    private func start(_ store: Store) async {
        self.store = store
        problem = nil
        heard = ""; said = ""
        state = .connecting
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail("The microphone is off for mitroley. Turn it on in System Settings › Privacy & Security › Microphone.")
            return
        }
        do {
            let id = try await agentID()
            let signed = try await Self.send("GET", "/v1/convai/conversation/get-signed-url?agent_id=\(id)")
            guard let text = signed["signed_url"] as? String, let url = URL(string: text) else { throw ServiceError(message: "ElevenLabs did not return a link to the agent.") }
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            sendJSON(["type": "conversation_initiation_client_data"])
            try startAudio()
            state = .listening
            receive(task)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        engine.inputNode.removeTap(onBus: 0)
        speaker.stop()
        engine.stop()
        pending = 0
        state = .off
    }

    private func fail(_ message: String) {
        stop()
        problem = message
    }

    private func startAudio() throws {
        let input = engine.inputNode
        // The Mac's echo canceller, so the helper does not hear its own voice from the speakers.
        try? input.setVoiceProcessingEnabled(true)
        if speaker.engine == nil { engine.attach(speaker) }
        engine.connect(speaker, to: engine.mainMixerNode, format: play)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conv = AVAudioConverter(from: format, to: wire) else { throw ServiceError(message: "No microphone was found.") }
        converter = conv
        let wire = self.wire
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * wire.sampleRate / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            conv.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            let chunk = Data(bytes: samples[0], count: Int(out.frameLength) * 2).base64EncodedString()
            Task { @MainActor in self?.sendJSON(["user_audio_chunk": chunk]) }
        }
        engine.prepare()
        try engine.start()
        speaker.play()
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .failure(let error):
                    if self.isOn { self.fail("The helper disconnected: \(error.localizedDescription)") }
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(event)
                    }
                    self.receive(task)
                }
            }
        }
    }

    private func handle(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "ping":
            if let id = (e["ping_event"] as? [String: Any])?["event_id"] { sendJSON(["type": "pong", "event_id": id]) }
        case "audio":
            if let b64 = (e["audio_event"] as? [String: Any])?["audio_base_64"] as? String, let data = Data(base64Encoded: b64) { speak(data) }
        case "interruption":
            // The person started talking: stop mid-word.
            speaker.stop(); speaker.play()
            pending = 0
            state = .listening
        case "user_transcript":
            if let t = (e["user_transcription_event"] as? [String: Any])?["user_transcript"] as? String { heard = t }
        case "agent_response":
            if let t = (e["agent_response_event"] as? [String: Any])?["agent_response"] as? String { said = t }
        case "agent_response_correction":
            if let t = (e["agent_response_correction_event"] as? [String: Any])?["corrected_agent_response"] as? String { said = t }
        case "client_tool_call":
            if let call = e["client_tool_call"] as? [String: Any] { Task { await self.run(call) } }
        default:
            break
        }
    }

    private func speak(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: play, frameCapacity: AVAudioFrameCount(frames)), let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[0][i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        pending += 1
        state = .speaking
        speaker.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pending = max(0, self.pending - 1)
                if self.pending == 0, self.state == .speaking { self.state = .listening }
            }
        }
    }

    private func run(_ call: [String: Any]) async {
        guard let store, let id = call["tool_call_id"] as? String, let tool = call["tool_name"] as? String else { return }
        let params = (call["parameters"] as? [String: Any]) ?? [:]
        var result = "", failed = false
        do {
            switch tool {
            case "run_command":
                let name = (params["name"] as? String) ?? ""
                let text = (params["arguments_json"] as? String) ?? "{}"
                let args = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
                guard Commands.tools.contains(where: { ($0["name"] as? String) == name }) else { throw ServiceError(message: "There is no command called \(name).") }
                state = .working(name.replacingOccurrences(of: "_", with: " "))
                let out = try await store.commands.call(name, args)
                let data = try JSONSerialization.data(withJSONObject: out.json)
                result = String(String(data: data, encoding: .utf8)?.prefix(12000) ?? "")
            case "show_in_app":
                switch (params["place"] as? String) ?? "" {
                case "settings": store.showSettings = true
                case "export": store.showExport = true
                case "claude": store.showClaude = true
                case "session": store.showSession()
                case "room": store.openRoom?()
                case "master_effects": store.showMaster.toggle()
                default: throw ServiceError(message: "Unknown place.")
                }
                result = "{\"ok\":true}"
            default:
                throw ServiceError(message: "Unknown tool.")
            }
        } catch {
            result = error.localizedDescription
            failed = true
        }
        if case .working = state { state = .listening }
        sendJSON(["type": "client_tool_result", "tool_call_id": id, "result": result, "is_error": failed])
    }
}

/// The helper's button in the toolbar and the strip that shows what it heard and said.
struct VoiceAgentButton: View {
    @Environment(Store.self) private var store
    var body: some View {
        let agent = store.voiceAgent
        Button { agent.toggle(store) } label: {
            Label("Voice helper", systemImage: agent.isOn ? "waveform.circle.fill" : "waveform.circle")
        }
        .help(agent.isOn ? "Stop the voice helper" : "Talk to the voice helper: ask it anything or have it work the app for you. Uses your ElevenLabs agent minutes.")
    }
}

struct VoiceAgentStrip: View {
    @Environment(Store.self) private var store
    var body: some View {
        let agent = store.voiceAgent
        if agent.isOn || agent.problem != nil {
            HStack(spacing: 10) {
                Image(systemName: agent.problem != nil ? "exclamationmark.triangle.fill" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(agent.problem != nil ? Theme.danger : Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: agent.state == .speaking)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(agent)).font(.system(size: 12, weight: .semibold))
                    let line = agent.problem ?? (agent.state == .speaking || agent.heard.isEmpty ? agent.said : agent.heard)
                    if !line.isEmpty {
                        Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(2)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                }
                Button { agent.problem == nil ? agent.stop() : (agent.problem = nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22).background(Color.white.opacity(0.08), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .help(agent.problem == nil ? "End the conversation" : "Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glass(in: Capsule())
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func title(_ agent: VoiceAgent) -> String {
        if agent.problem != nil { return "Voice helper" }
        switch agent.state {
        case .off: return "Voice helper"
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        case .working(let what): return "Working: \(what)"
        }
    }
}
