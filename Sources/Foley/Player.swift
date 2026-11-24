import AVFoundation
import Observation

/// Peaks written by the audio tap, read by the UI timer.
final class MeterTap {
    var left: Float = 0
    var right: Float = 0
}

/// Live playback: owns the real-time graph, the video player and the 60 Hz automation tick.
@MainActor @Observable
final class Player {
    var isPlaying = false
    var time = 0.0
    var monitor: MonitorMode = .stereo { didSet { applyNow() } }
    var loop = false
    var masterL: Float = 0
    var masterR: Float = 0
    var trackLevels: [UUID: Float] = [:]
    var engineError: String?
    /// Loudness and gain reduction of the output. Separate, so only the views that show it redraw with it.
    @ObservationIgnored let loudness = LoudnessMeter()

    @ObservationIgnored let graph: MixGraph
    @ObservationIgnored let video = AVPlayer()
    @ObservationIgnored private var project = Project()
    private var loopRange: ClosedRange<Double>? { loop ? project.loopRange : nil }
    @ObservationIgnored private var resolve: (Take) -> URL? = { _ in nil }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let tap = MeterTap()
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var videoDuration = 0.0
    @ObservationIgnored private var items: [String: AVPlayerItem] = [:]
    /// Called whenever the transport starts, so the store can stop a take that is auditioning.
    @ObservationIgnored var onPlay: (() -> Void)?

    init() {
        graph = try! MixGraph(offline: false)
        video.automaticallyWaitsToMinimizeStalling = false
        video.actionAtItemEnd = .pause
        let tap = self.tap
        let analyzer = loudness.analyzer
        graph.meterNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var l: Float = 0, r: Float = 0
            let right = buf.format.channelCount > 1 ? ch[1] : ch[0]
            analyzer.feed(ch[0], right, frames: n)
            var i = 0
            while i < n {
                l = max(l, abs(ch[0][i])); r = max(r, abs(right[i]))
                i += 2
            }
            if l > tap.left { tap.left = l }
            if r > tap.right { tap.right = r }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph.engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startEngine() }
        }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startEngine() {
        guard !graph.engine.isRunning else { return }
        do {
            graph.engine.prepare()
            try graph.engine.start()
            engineError = nil
        } catch {
            engineError = error.localizedDescription
        }
    }

    /// Called after every project change.
    func sync(_ p: Project, resolve: @escaping (Take) -> URL?) {
        project = p
        self.resolve = resolve
        graph.rebuildIfNeeded(p)
        graph.configureSpaces(p)
        graph.configurePlugins(p)
        graph.loadClips(p, resolve: resolve)
        graph.bus?.set(p.bus)
        startEngine()
        video.volume = Float(p.videoVolume)
        video.isMuted = p.videoVolume <= 0.001
        applyNow()
    }

    private func applyNow() {
        graph.apply(project, at: time, mode: monitor)
    }

    // MARK: Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        onPlay?()
        loudness.reset()
        if let r = loopRange, time < r.lowerBound || time >= r.upperBound - 0.02 { time = r.lowerBound }
        if time >= project.extent - 0.02 { time = 0 }
        startEngine()
        graph.apply(project, at: time, mode: monitor, snap: true)
        graph.seek(to: time, playing: true)
        isPlaying = true
        startVideo(at: time)
    }

    func pause() {
        guard isPlaying else { return }
        time = min(project.extent, graph.time)
        graph.seek(to: time, playing: false)
        isPlaying = false
        video.pause()
        seekVideo(time)
    }

    func seek(_ t: Double) {
        time = min(max(0, t), project.extent)
        graph.seek(to: time, playing: isPlaying)
        if isPlaying { startVideo(at: time) } else { seekVideo(time) }
        applyNow()
    }

    private func step() {
        if isPlaying {
            let t = graph.time
            if let r = loopRange, t >= r.upperBound {
                seek(r.lowerBound)
            } else if t >= project.extent {
                if loop { seek(0) } else { pause(); time = project.extent }
            } else {
                time = t
            }
            tick += 1
            if tick % 30 == 0 { correctVideoDrift() }
        }
        applyNow()

        if let bus = graph.bus {
            // Gain reduction: deepest since the last tick, easing back to zero.
            let c = min(Double(bus.compressorReduction), loudness.compressor * 0.85)
            let l = min(Double(bus.limiterReduction), loudness.limiter * 0.85)
            bus.compressorReduction = 0; bus.limiterReduction = 0
            let nc = c > -0.05 ? 0 : c, nl = l > -0.05 ? 0 : l
            if nc != loudness.compressor { loudness.compressor = nc }
            if nl != loudness.limiter { loudness.limiter = nl }
        }
        // Meters: fast attack from the tap, smooth release.
        let l = max(tap.left, masterL * 0.86), r = max(tap.right, masterR * 0.86)
        tap.left = 0; tap.right = 0
        let nl: Float = l < 0.0005 ? 0 : l, nr: Float = r < 0.0005 ? 0 : r
        if nl != masterL { masterL = nl }
        if nr != masterR { masterR = nr }
        var changed = false
        var levels = trackLevels
        for n in graph.tracks {
            let pk = n.renderer.peak
            n.renderer.peak = 0
            let old = levels[n.id] ?? 0
            var v = max(pk, old * 0.86)
            if v < 0.0005 { v = 0 }
            if v != old { levels[n.id] = v; changed = true }
        }
        if changed { trackLevels = levels }
    }

    // MARK: Video

    func loadVideo(_ url: URL?) {
        if let url {
            // Kept per file: going back to a cut that was open a moment ago does not open its video again.
            let item = items[url.path] ?? AVPlayerItem(url: url)
            items[url.path] = item
            if items.count > 6, let extra = items.keys.first(where: { $0 != url.path }) { items[extra] = nil }
            video.replaceCurrentItem(with: item)
            videoDuration = 0
            Task {
                let d = (try? await item.asset.load(.duration).seconds) ?? 0
                self.videoDuration = d
                self.seekVideo(self.time)
            }
        } else {
            video.replaceCurrentItem(with: nil)
        }
    }

    /// Starts the picture so that frame `t` is on screen when sample `t` reaches the speakers.
    private func startVideo(at t: Double) {
        guard video.currentItem != nil, videoDuration == 0 || t < videoDuration else { video.pause(); return }
        let latency = graph.engine.outputNode.presentationLatency
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: latency, preferredTimescale: 48000))
        video.setRate(1, time: CMTime(seconds: t, preferredTimescale: 48000), atHostTime: host)
    }

    private func correctVideoDrift() {
        guard video.currentItem != nil, video.rate != 0 else { return }
        let heard = time - graph.engine.outputNode.presentationLatency
        if abs(video.currentTime().seconds - heard) > 0.08 { startVideo(at: time) }
    }

    /// Frame-accurate scrubbing that never queues more than one seek.
    private func seekVideo(_ t: Double) {
        guard video.currentItem != nil else { return }
        if seeking { pendingSeek = t; return }
        seeking = true
        video.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    if !self.isPlaying { self.seekVideo(next) }
                }
            }
        }
    }
}
