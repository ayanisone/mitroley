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
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var speaker = AVAudioPlayerNode()
    @ObservationIgnored private var converter: AVAudioConverter?
    @ObservationIgnored private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    @ObservationIgnored private let play = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    @ObservationIgnored private var pending = 0     // spoken chunks still to play
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private var audioRunning = false
    // Talking over the helper. There is no echo canceller, so the helper's own voice coming back through the
    // microphone is told apart from the person by level: how loud the echo usually is for what is playing is
    // learned as it speaks, and anything well above that is the person.
    @ObservationIgnored private var playLevel: Float = 0     // how loud the helper is right now, held briefly
    @ObservationIgnored private var echoGain: Float = 0      // microphone level per unit of playback, learned
    @ObservationIgnored private var learned = 0
    @ObservationIgnored private var noise: Float = 0         // the room when nobody speaks
    @ObservationIgnored private var over = 0
    @ObservationIgnored private var preroll: [String] = []   // the last half second of microphone, sent when you cut in
    @ObservationIgnored private var deafUntil = Date.distantPast   // the rest of an interrupted answer is dropped
    @ObservationIgnored private var cutBelow = -1            // audio numbered at or below this belongs to an interrupted answer
    /// Bump when the prompt or tools change, so the agent on the account is brought up to date.
    private static let version = 5
    /// Everything the agent on the account depends on. When it changes, the agent is updated at the next start.
    private static var signature: String {
        let d = UserDefaults.standard
        return "\(version)|\(d.string(forKey: "voiceAgentVoice") ?? "")|\(d.string(forKey: "voiceAgentStyle") ?? "")"
    }

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
        let style = (UserDefaults.standard.string(forKey: "voiceAgentStyle") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        mitroley was made by Ayan Mitra. The person is at the app right now, talking to you. Keep answers short and spoken-style: one or two sentences, no lists, no markdown.

        LANGUAGE. Answer in the language the person is speaking. If they change language, change with them at once, mid-conversation, \
        and use the language detection tool so your voice follows. The person speaks English, Hindi and Bengali and mixes them freely \
        (Hinglish, Banglish): match whatever they just used. Bengali is "bn".
        \(style.isEmpty ? "" : "\nHOW TO BEHAVE. \(style)\n")

        DOING THINGS. You can work the app. Call run_command with the command's name and its arguments as a JSON object written as a string, \
        for example name "transport", arguments_json "{\\"action\\":\\"play\\"}". Start with get_project when you need to know what is in the session. \
        Do what is asked without asking permission for ordinary edits; every change can be undone with Command-Z. Ask first only before deleting \
        tracks or clips, or before generating sound, which spends the person's ElevenLabs credits. Say in a few words what you did.

        If the person starts talking while you are speaking, stop and listen. Never say you cannot do something in the app before trying: \
        if no command fits, use look to see what is on screen and menu to press a menu item.

        THE INTERFACE. These also go through run_command, and work the app itself rather than the session:
        \(VoiceAgent.interfaceCommands)

        EXPLAINING. When asked what something is, how to do something or why something sounds the way it does, answer plainly from what you know \
        about the app and about sound for picture, and show it: open the panel, select the thing or scroll to it while you explain. \
        Use look first when the question is about what is on screen right now.

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
        if let id = d.string(forKey: "voiceAgentID"), d.string(forKey: "voiceAgentSignature") == Self.signature { return id }
        let signature = Self.signature
        // The two tools have not changed since they were first made, so they are kept: no copies pile up on the account.
        var tools: [String] = d.stringArray(forKey: "voiceToolIDs") ?? []
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
        if tools.count != specs.count { tools = [] }
        for spec in specs where tools.count < specs.count {
            let made = try await Self.send("POST", "/v1/convai/tools", ["tool_config": spec])
            guard let id = made["id"] as? String else { throw ServiceError(message: "ElevenLabs did not return a tool id.") }
            tools.append(id)
        }
        d.set(tools, forKey: "voiceToolIDs")
        let voice = d.string(forKey: "voiceAgentVoice") ?? ""
        let european = ["es", "fr", "de", "pt", "it", "ja", "ko", "zh", "ar", "ru", "id", "tr", "nl", "pl"]
        // Newest voice model first: it is the one that speaks Bengali and the other Indian languages. Older ones are the fallback
        // for accounts that do not have it.
        let attempts: [(String, [String])] = [
            ("eleven_v4_turbo", ["hi", "bn", "ta", "te", "mr", "gu", "kn", "ml", "pa", "ur"] + european),
            ("eleven_v3_conversational", ["hi", "bn", "ta", "te", "mr", "gu", "kn", "ml", "pa", "ur"] + european),
            ("eleven_v3_conversational", ["hi", "bn", "ta"] + european),
            ("eleven_flash_v2", ["hi", "ta"] + european),
        ]
        var lastError: Error = ServiceError(message: "The helper could not be set up.")
        for (model, languages) in attempts {
        var tts: [String: Any] = ["model_id": model, "agent_output_audio_format": "pcm_16000"]
        if !voice.isEmpty { tts["voice_id"] = voice }
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
            "tts": tts,
            "asr": ["user_input_audio_format": "pcm_16000"],
            "language_presets": Dictionary(uniqueKeysWithValues: languages.map { ($0, ["overrides": [String: Any]()] as [String: Any]) }),
        ]
        do {
            let id: String
            var kept: String?
            if let old = d.string(forKey: "voiceAgentID") {
                do {
                    _ = try await Self.send("PATCH", "/v1/convai/agents/\(old)", ["conversation_config": config])
                    kept = old
                } catch where error.localizedDescription.contains(" 404 ") {
                    // Deleted on the website: made again below.
                    d.removeObject(forKey: "voiceAgentID")
                }
            }
            if let kept {
                id = kept
            } else {
                let made = try await Self.send("POST", "/v1/convai/agents/create", ["name": "mitroley helper", "conversation_config": config])
                guard let new = made["agent_id"] as? String else { throw ServiceError(message: "ElevenLabs did not return an agent id.") }
                id = new
            }
            d.set(id, forKey: "voiceAgentID")
            d.set(signature, forKey: "voiceAgentSignature")
            d.set("\(model) · \(languages.contains("bn") ? "Bengali on" : "no Bengali")", forKey: "voiceAgentSetup")
            return id
        } catch {
            lastError = error
        }
        }
        throw lastError
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
            // In the background: only needed if the person asks for another voice.
            Task { await store.loadVoices() }
            let id = try await agentID()
            let signed = try await Self.send("GET", "/v1/convai/conversation/get-signed-url?agent_id=\(id)")
            guard let text = signed["signed_url"] as? String, let url = URL(string: text) else { throw ServiceError(message: "ElevenLabs did not return a link to the agent.") }
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            sendJSON(["type": "conversation_initiation_client_data"])
            guard socket === task, state == .connecting else { return }
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
        // Only if the microphone was actually started: asking a half-started engine for its input can wait forever.
        if audioRunning {
            engine.inputNode.removeTap(onBus: 0)
            speaker.stop()
            engine.stop()
        }
        audioRunning = false
        // A fresh engine for next time, so echo cancelling is negotiated from a clean start.
        engine = AVAudioEngine()
        speaker = AVAudioPlayerNode()
        pending = 0
        over = 0; preroll = []; playLevel = 0
        deafUntil = .distantPast; cutBelow = -1
        state = .off
    }

    /// Stops the helper mid-sentence. `mine` = you asked for it with a click, so the rest of that answer is dropped for good.
    func interrupt(mine: Bool = true) {
        guard state == .speaking || pending > 0 else { return }
        speaker.stop(); speaker.play()
        pending = 0
        over = 0
        quietUntil = .distantPast
        // Until the service has heard you and moved on, what it still sends belongs to the answer you cut off.
        deafUntil = mine ? .distantFuture : Date().addingTimeInterval(3)
        state = .listening
        for chunk in preroll { sendJSON(["user_audio_chunk": chunk]) }
        preroll = []
    }

    /// One buffer of microphone. While the helper is quiet it goes straight to the service. While the helper is speaking it is
    /// held back (or the helper would hear itself), and watched for you talking over it.
    private func microphone(_ chunk: String, _ level: Float) {
        guard state == .speaking else {
            guard Date() > quietUntil else { return }
            if noise == 0 || level < noise * 2 { noise = noise == 0 ? level : noise * 0.95 + level * 0.05 }
            sendJSON(["user_audio_chunk": chunk])
            return
        }
        preroll.append(chunk)
        if preroll.count > 14 { preroll.removeFirst() }
        let limit = max(0.012, noise * 4, echoGain * playLevel * 3)
        if learned >= 8, level > limit {
            over += 1
            if over >= 3 { interrupt(mine: false) }
        } else {
            over = 0
            if playLevel > 0.003 {
                let g = level / playLevel
                echoGain = learned == 0 ? g : echoGain * 0.9 + g * 0.1
                learned += 1
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        problem = message
    }

    /// Plain microphone, no system echo canceller: that canceller is what failed to start on this Mac (error -10875),
    /// sometimes after hanging for seconds. The microphone is not sent while the helper is speaking, so it never hears
    /// itself; `microphone` listens for you cutting in instead.
    private func startAudio() throws {
        do { try startAudio(echoCancelling: false) } catch {
            engine = AVAudioEngine()
            speaker = AVAudioPlayerNode()
            throw ServiceError(message: "The microphone could not be started (\(error.localizedDescription)). Check that a microphone is chosen in System Settings › Sound › Input, and that no other app is holding it.")
        }
    }

    private func startAudio(echoCancelling: Bool) throws {
        let input = engine.inputNode
        // Only ever switched on: a new engine starts with it off, and switching it off again is what fails on some set-ups.
        if echoCancelling { try input.setVoiceProcessingEnabled(true) }
        if speaker.engine == nil { engine.attach(speaker) }
        engine.connect(speaker, to: engine.mainMixerNode, format: play)
        // Read after switching echo cancelling: it changes the microphone's format.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let conv = AVAudioConverter(from: format, to: wire) else { throw ServiceError(message: "No microphone was found.") }
        // Only the first channel: the echo canceller can hand over several.
        if format.channelCount > 1 { conv.channelMap = [0] }
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
            let n = Int(out.frameLength)
            var sum: Float = 0
            for i in 0..<n { let v = Float(samples[0][i]) / 32768; sum += v * v }
            let level = (sum / Float(n)).squareRoot()
            let chunk = Data(bytes: samples[0], count: n * 2).base64EncodedString()
            Task { @MainActor in self?.microphone(chunk, level) }
        }
        // How loud the helper is at this moment, to judge what comes back through the microphone.
        speaker.removeTap(onBus: 0)
        speaker.installTap(onBus: 0, bufferSize: 1024, format: play) { [weak self] buffer, _ in
            guard let d = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += d[0][i] * d[0][i] }
            let level = (sum / Float(buffer.frameLength)).squareRoot()
            Task { @MainActor in
                guard let self else { return }
                self.playLevel = max(level, self.playLevel * 0.8)
            }
        }
        engine.prepare()
        try engine.start()
        speaker.play()
        audioRunning = true
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
            let a = e["audio_event"] as? [String: Any]
            let number = (a?["event_id"] as? Int) ?? Int.max
            guard number > cutBelow, Date() > deafUntil else { break }
            if let b64 = a?["audio_base_64"] as? String, let data = Data(base64Encoded: b64) { speak(data) }
        case "interruption":
            // The service heard the person start talking: stop mid-word, and ignore what is left of that answer.
            if let n = (e["interruption_event"] as? [String: Any])?["event_id"] as? Int { cutBelow = max(cutBelow, n) }
            speaker.stop(); speaker.play()
            pending = 0
            preroll = []
            deafUntil = .distantPast
            state = .listening
        case "user_transcript":
            deafUntil = .distantPast
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
                if self.pending == 0, self.state == .speaking {
                    // A short pause before listening again, for the room's own echo to die away.
                    self.quietUntil = Date().addingTimeInterval(0.35)
                    self.state = .listening
                }
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
                state = .working(name.replacingOccurrences(of: "_", with: " "))
                let json: Any
                if let ui = try interface(name, args, store) {
                    json = ui
                } else {
                    guard Commands.tools.contains(where: { ($0["name"] as? String) == name }) else { throw ServiceError(message: "There is no command called \(name). Use look to see what is on screen, or menu to press a menu item.") }
                    json = try await store.commands.call(name, args).json
                }
                let data = try JSONSerialization.data(withJSONObject: json)
                result = String(String(data: data, encoding: .utf8)?.prefix(12000) ?? "")
            case "show_in_app":
                switch (params["place"] as? String) ?? "" {
                case "settings": store.showSettings = true
                case "export": store.showExport = true
                case "claude": store.showClaude = true
                case "session": store.showSession()
                case "room": store.openRoom?()
                case "master_effects": store.showMaster = true
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
            .contentShape(Capsule())
            .onTapGesture { agent.interrupt() }
            .help(agent.state == .speaking ? "Click to stop it talking. You can also just talk over it." : "")
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
