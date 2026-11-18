import AVFoundation
import Speech
import Observation
import AppKit

// mitroley. Copyright © 2026 Ayan Mitra.

/// Speech to text for the Claude panel, using the Mac's own speech recogniser. Words appear as they are spoken.
@MainActor @Observable
final class Dictation {
    var listening = false
    var problem: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognizer = SFSpeechRecognizer()

    /// Starts or stops listening. `update` gets the whole text so far: what was already typed, then what was heard.
    func toggle(typed: String, update: @escaping (String) -> Void) {
        if listening { stop(); return }
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                Task { @MainActor in
                    guard status == .authorized else {
                        self.problem = "Speech recognition is off for mitroley. Turn it on in System Settings › Privacy & Security › Speech Recognition."
                        return
                    }
                    guard mic else {
                        self.problem = "The microphone is off for mitroley. Turn it on in System Settings › Privacy & Security › Microphone."
                        return
                    }
                    self.start(typed: typed, update: update)
                }
            }
        }
    }

    private func start(typed: String, update: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition is not available for this Mac's language right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On this Mac when it can be, so what is said does not leave it.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone was found."
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Could not start the microphone: \(error.localizedDescription)"
            return
        }
        let lead = typed.isEmpty || typed.hasSuffix(" ") || typed.hasSuffix("\n") ? typed : typed + " "
        self.request = request
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let text, !text.isEmpty { update(lead + text) }
                if done { self.stop() }
            }
        }
    }

    func stop() {
        guard listening || request != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        listening = false
    }
}

/// Double-clicking the bar at the top of a window does what the Mac is set to do there (zoom by default), as in other apps.
enum TitleBarDoubleClick {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let w = event.window, w.styleMask.contains(.titled), !(w is NSPanel),
                  w.attachedSheet == nil else { return event }
            // Only the strip above the content, and not on a button in it.
            guard event.locationInWindow.y > w.contentLayoutRect.maxY else { return event }
            if let frame = w.contentView?.superview, let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) {
                var v: NSView? = hit
                while let view = v {
                    if view is NSControl { return event }
                    v = view.superview
                }
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": w.miniaturize(nil)
            case "None": break
            default: w.zoom(nil)
            }
            return nil
        }
    }
}
