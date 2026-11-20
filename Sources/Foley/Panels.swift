import SwiftUI
import AppKit

// MARK: - Claude

struct ClaudePanel: View {
    @AppStorage("claudeEffort") private var effort = "high"
    @AppStorage("claudeModel") private var model = "claude-opus-5-5"
    @State private var dictation = Dictation()
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var input = ""
    @State private var copied = false

    private let starters = [
        "Fit the sound to the picture",
        "Automate the mix in detail, shot by shot",
        "Compose music that follows the film, scene by scene",
        "Make the footsteps match the feet, step by step",
        "Sound only the new shots in this revised cut",
        "Redo the voice-over in the film with fitting voices",
        "Set up scenes and spaces only",
        "Add ambience for every scene",
    ]

    private var bridgeCommand: String {
        "claude mcp add mitroley -- \"\(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/foley-mcp").path)\""
    }

    var body: some View {
        let agent = store.agent
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Claude", systemImage: "sparkle").font(.system(size: 15, weight: .semibold))
                Spacer()
                if !agent.entries.isEmpty {
                    Button("Clear") { agent.reset() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Button { store.showClaude = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22).background(Theme.raised, in: Circle())
                }
                .buttonStyle(PressStyle(scale: 0.88))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if agent.entries.isEmpty {
                            intro
                        }
                        ForEach(agent.entries) { entry in
                            EntryRow(entry: entry).id(entry.id)
                        }
                        if agent.running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: agent.entries.count) {
                    withAnimation(Motion.ui(reduceMotion)) { proxy.scrollTo(agent.entries.last?.id, anchor: .bottom) }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                QuietEditor(placeholder: "Tell Claude what to do with the sound", text: $input, height: 62) {
                    if !agent.running, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send(input) }
                }
                if let problem = dictation.problem {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if agent.running {
                        Button("Stop") { agent.stop() }.buttonStyle(PillButtonStyle())
                    } else {
                        // Return sends, so this spot holds how hard Claude should think instead of a Send button.
                        Menu {
                            Section("Effort") {
                                ForEach([("low", "Low", "Fastest and cheapest. Small, clear jobs"), ("medium", "Medium", "A balance"), ("high", "High", "Thinks longest. Best for fitting a whole film")], id: \.0) { e in
                                    // A toggle, so the system draws the tick in its own column and the two lines stay aligned.
                                    Toggle(isOn: Binding(get: { effort == e.0 }, set: { if $0 { effort = e.0 } })) {
                                        Text(e.1)
                                        Text(e.2)
                                    }
                                }
                            }
                            Section("Model") {
                                ForEach([("claude-opus-5-5", "Claude Opus 5.5"), ("claude-fable-5-2", "Claude Fable 5.2"), ("claude-sonnet-5-5", "Claude Sonnet 5.5")], id: \.0) { m in
                                    Toggle(m.1, isOn: Binding(get: { model == m.0 }, set: { if $0 { model = m.0 } }))
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 11, weight: .semibold))
                                Text(effort.capitalized).font(.system(size: 12, weight: .semibold))
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 11).frame(height: 30)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("How hard Claude thinks before it acts, and which model it uses. Applies from the next message.")
                    }
                    Button { dictation.toggle(typed: input) { input = $0 } } label: {
                        Image(systemName: dictation.listening ? "mic.fill" : "mic")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(dictation.listening ? Color.white : Theme.secondary)
                            .frame(width: 30, height: 30)
                            .background(dictation.listening ? Theme.danger : Color.white.opacity(0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle(scale: 0.92))
                    .help(dictation.listening ? "Stop listening" : "Speak instead of typing")
                    Spacer()
                    Text(dictation.listening ? "Listening" : "Return to send · Shift-Return for a new line").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.2))
        }
    }

    private func send(_ text: String) {
        dictation.stop()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input = ""
        store.agent.send(t, store: store)
    }

    @ViewBuilder private var intro: some View {
        Text("Claude watches the video, reads the storyboard and fits the sound: scenes, spaces, levels, fades, positions.")
            .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        if Secrets.has(.anthropic) {
            ForEach(starters, id: \.self) { s in
                Button { send(s) } label: {
                    HStack {
                        Text(s).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .disabled(store.project.video == nil)
            }
            if store.project.video == nil {
                Text("Add a video first.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
        } else {
            Button("Add an Anthropic API Key…") { store.showSettings = true }.buttonStyle(PillButtonStyle(prominent: true))
        }

        SectionTitle("Or drive it from Claude Code")
        Text("mitroley is also an MCP server. Add it once, then ask Claude Code to work on the open session. It can use your other tools too.")
            .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bridgeCommand, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy Setup Command", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PillButtonStyle())
    }
}

private struct EntryRow: View {
    let entry: AgentEntry
    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .font(.system(size: 13))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Theme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .claude:
            Text(entry.text).font(.system(size: 13)).lineSpacing(2.5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .action:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                Text(entry.text).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.danger)
                Text(entry.text).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var eleven = ""
    @State private var anthropic = ""
    @State private var elevenStatus: (ok: Bool, message: String)?
    @State private var anthropicProblem: String?
    @State private var checking = false
    @AppStorage("claudeModel") private var claudeModel = "claude-opus-5-5"
    @AppStorage("elevenFormat") private var elevenFormat = "mp3_44100_128"
    @AppStorage("elevenModel") private var elevenModel = "eleven_text_to_sound_v3"
    @AppStorage("elevenMusic") private var elevenMusic = "music_v2_5"
    @AppStorage("defaultMixFormat") private var defaultFormat = MixFormat.atmos714.rawValue
    @AppStorage("sessionsFolder") private var sessionsFolder = ""
    @AppStorage("exportsFolder") private var exportsFolder = ""
    @AppStorage("autosaveSeconds") private var autosave = 0.0
    @AppStorage("hoverHelp") private var hoverHelp = true
    @AppStorage("voiceAgentVoice") private var helperVoice = ""
    @AppStorage("voiceAgentVoiceName") private var helperVoiceName = ""
    @AppStorage("voiceAgentStyle") private var helperStyle = ""

    private func folderRow(_ title: String, _ path: String, reset: (() -> Void)?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let reset { Button("Default", action: reset).buttonStyle(PillButtonStyle()) }
            Button("Choose…", action: choose).buttonStyle(PillButtonStyle())
        }
    }

    // Scrolls, so the sheet fits a small window however many settings there are.
    var body: some View {
        ScrollView { content }
            .frame(width: 460, height: min(780, (NSApp.mainWindow?.frame.height ?? 800) - 90))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.system(size: 20, weight: .semibold)).tracking(-0.3)

            SectionTitle("ElevenLabs")
            SecureField(Secrets.has(.elevenLabs) ? "Paste a new key to replace the saved one" : "API key", text: $eleven)
                .textFieldStyle(.roundedBorder)
            if let status = elevenStatus {
                Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(status.ok ? Color(red: 0.3, green: 0.85, blue: 0.5) : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint = Secrets.hint(.elevenLabs) {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("Model", selection: $elevenModel) {
                    Text("Sound effects v2").tag("eleven_text_to_sound_v2")
                    Text("Sound effects v3").tag("eleven_text_to_sound_v3")
                }
                Picker("Music", selection: $elevenMusic) {
                    Text("Music v2.5").tag("music_v2_5")
                    Text("Music v2").tag("music_v2")
                }
                Picker("Quality", selection: $elevenFormat) {
                    Text("MP3 128 kbps").tag("mp3_44100_128")
                    Text("MP3 192 kbps (Creator plan)").tag("mp3_44100_192")
                    Text("WAV 48 kHz").tag("wav_48000")
                }
            }

            SectionTitle("Voice helper")
            HStack {
                Text("Voice").font(.system(size: 12))
                VoicePicker(current: helperVoiceName.isEmpty ? "ElevenLabs default" : helperVoiceName) { v in
                    helperVoice = v.id; helperVoiceName = v.name
                }
                if !helperVoice.isEmpty { Button("Default") { helperVoice = ""; helperVoiceName = "" }.controlSize(.small) }
            }
            TextField("How it should behave (optional). For example: call me Ayan, be brief, joke a little.", text: $helperStyle, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            Text("Start or stop it with ⌘J, or from the Help menu. Changes apply the next time you start it. It follows English, Hindi and Bengali by itself. Talk over it, or click its bar, to stop it mid-sentence; on loud speakers speak up or use headphones. The helper lives on your ElevenLabs account as the agent \"mitroley helper\".")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

            SectionTitle("Mixing")
            Picker("Format for new sessions", selection: $defaultFormat) {
                ForEach(MixFormat.allCases) { f in Text(f.title).tag(f.rawValue) }
            }

            SectionTitle("Sessions and files")
            folderRow("New sessions go in", sessionsFolder.isEmpty ? Places.sessions.path : sessionsFolder, reset: sessionsFolder.isEmpty ? nil : { sessionsFolder = "" }) {
                if let u = Places.chooseFolder("Choose the folder new sessions are made in.", start: Places.sessions) { sessionsFolder = u.path }
            }
            folderRow("Exports go in", exportsFolder.isEmpty ? "Each session's own Exports folder" : exportsFolder, reset: exportsFolder.isEmpty ? nil : { exportsFolder = "" }) {
                if let u = Places.chooseFolder("Choose the folder exports are written to.", start: Places.exports) { exportsFolder = u.path }
            }
            Picker("Save automatically", selection: $autosave) {
                Text("After every change").tag(0.0)
                Text("Every minute").tag(60.0)
                Text("Every 5 minutes").tag(300.0)
                Text("Every 10 minutes").tag(600.0)
            }
            Toggle("Show a hint when the pointer rests on a button", isOn: $hoverHelp)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                .onChange(of: hoverHelp) { _, _ in store.applyHoverHelp() }
            Text("Hints apply the next time mitroley is opened. ⌘S saves at any time, and the session is always saved when you quit.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

            SectionTitle("Claude")
            SecureField(Secrets.has(.anthropic) ? "Paste a new key to replace the saved one" : "Anthropic API key", text: $anthropic)
                .textFieldStyle(.roundedBorder)
            if let anthropicProblem {
                Label(anthropicProblem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint = Secrets.hint(.anthropic) {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Model", selection: $claudeModel) {
                Text("Claude Opus 5.5").tag("claude-opus-5-5")
                Text("Claude Fable 5.2").tag("claude-fable-5-2")
                Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
            }
            Text("Keys are stored on this Mac in a file only your account can read, and are sent only to the service they belong to. When Claude works on a session, frames of the video and the storyboard are sent to Anthropic.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(elevenStatus?.ok == true ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if checking { ProgressView().controlSize(.small) }
                Button("Save") {
                    // Keys are checked before they are stored, so a bad paste is caught here and not at the first request.
                    let e = eleven.trimmingCharacters(in: .whitespacesAndNewlines), a = anthropic.trimmingCharacters(in: .whitespacesAndNewlines)
                    anthropicProblem = a.isEmpty ? nil : Secrets.problem(a)
                    if anthropicProblem != nil { return }
                    checking = true
                    Task {
                        var ok = true
                        if !e.isEmpty {
                            let result = await ElevenLabs.verify(e)
                            elevenStatus = result
                            ok = result.ok
                            if ok { Secrets.set(.elevenLabs, e); eleven = "" }
                        }
                        if !a.isEmpty { Secrets.set(.anthropic, a); anthropic = "" }
                        checking = false
                        if ok && e.isEmpty { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checking)
            }
            .padding(.top, 4)
        }
        .padding(22)
    }
}

// MARK: - Export

struct ExportSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var format = ExportFormat.stereo
    @State private var working = false
    @State private var result: (url: URL, summary: String)?
    @State private var failure: String?
    @State private var destination = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.system(size: 20, weight: .semibold)).tracking(-0.3)
            // Every format on one line; only the chosen one spells itself out, so the sheet fits any window.
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(ExportFormat.allCases) { f in
                        let on = f == format
                        let unavailable = f == .movie && store.project.video == nil
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(on ? Theme.accent : Theme.tertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(f.title).font(.system(size: 12.5, weight: .semibold))
                                    if f == store.project.format.export {
                                        Text("Session format").font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(Theme.accent)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Theme.accent.opacity(0.15), in: Capsule())
                                    }
                                }
                                if on || unavailable {
                                    Text(unavailable ? "Needs a video in the session" : f.detail)
                                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(on ? Theme.accent.opacity(0.12) : Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                        .opacity(unavailable ? 0.45 : 1)
                        .onTapGesture { if !unavailable && !working { format = f; result = nil; failure = nil } }
                    }
                }
            }
            .frame(maxHeight: max(180, (NSApp.mainWindow?.frame.height ?? 800) - 330))
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Text((store.exportsFolder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Button("Change…") {
                    if let u = Places.chooseFolder("Choose the folder exports are written to.", start: store.exportsFolder) {
                        UserDefaults.standard.set(u.path, forKey: "exportsFolder")
                        destination += 1
                    }
                }
                .buttonStyle(PillButtonStyle())
            }
            .id(destination)
            if let result {
                Label("\(result.url.lastPathComponent) · \(result.summary)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                if let result {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                } else {
                    Button("Export") {
                        working = true
                        failure = nil
                        Task {
                            do { result = try await store.export(format) } catch { failure = error.localizedDescription }
                            working = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { format = store.project.format.export }
        .onExitCommand { if !working { dismiss() } }
    }
}
