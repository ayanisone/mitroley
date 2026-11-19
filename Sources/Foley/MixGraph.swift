import AVFoundation

enum MonitorMode: String, CaseIterable, Identifiable {
    case stereo, spatial
    var id: String { rawValue }
}

/// Which part of the mix a render pass should contain (used to print stems for immersive export).
enum Stem: Equatable {
    case full
    case bedDry            // dry signal of every non-object track
    case reverb            // every space return, nothing dry
    case object(UUID)      // one object track, dry, centred
}

// MARK: - Real-time safe pieces

/// Shared timeline clock. Written from the main thread, read on the audio thread.
final class TransportClock {
    var playing = false
    var generation = 0
    var startFrame: Int64 = 0
    var frame: Int64 = 0
    private var anchorGeneration = -1
    private var anchor = 0.0

    /// Timeline frame for a render call, or nil while stopped. Every node in one render cycle
    /// sees the same sample time, so every track lands on the same frame.
    @inline(__always) func position(sampleTime: Double, frames: UInt32) -> Int64? {
        guard playing else { return nil }
        if anchorGeneration != generation { anchor = sampleTime; anchorGeneration = generation }
        let p = startFrame + Int64(sampleTime - anchor)
        frame = p + Int64(frames)
        return p
    }
}

struct PreparedClip {
    var start: Int64
    var length: Int64
    var offset: Int64
    var sourceLength: Int64
    var loop: Bool
    var gain: Float
    var rate: Float
    var fadeIn: Int64
    var fadeOut: Int64
    var fadeInShape: UInt8      // FadeShape.code
    var fadeOutShape: UInt8
    var left: UnsafePointer<Float>
    var right: UnsafePointer<Float>
}

/// Mixes one track's clips sample-accurately inside the render callback.
final class TrackRenderer {
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var clips: UnsafeMutablePointer<PreparedClip>?
    private var count = 0
    private var retained: [AVAudioPCMBuffer] = []
    var targetGain: Float = 1
    private var gain: Float = 1
    var peak: Float = 0

    init() { lock.initialize(to: os_unfair_lock()) }
    deinit { clips?.deallocate(); lock.deallocate() }

    func set(_ new: [PreparedClip], buffers: [AVAudioPCMBuffer]) {
        let p = UnsafeMutablePointer<PreparedClip>.allocate(capacity: max(1, new.count))
        p.initialize(from: new, count: new.count)
        os_unfair_lock_lock(lock)
        let old = clips
        let oldRetained = retained
        clips = p
        count = new.count
        retained = buffers
        os_unfair_lock_unlock(lock)
        old?.deallocate()
        _ = oldRetained
    }

    func snapGain() { gain = targetGain }

    func render(at pos: Int64, frames: Int, l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        let end = pos + Int64(frames)
        if let clips {
            for c in 0..<count {
                let clip = clips[c]
                let a = max(pos, clip.start), b = min(end, clip.start + clip.length)
                if a >= b { continue }
                var i = a
                if clip.rate != 1 {
                    // Varispeed: read the source at a different rate, interpolating between samples.
                    let n = Double(clip.sourceLength)
                    while i < b {
                        let rel = i - clip.start
                        var p = Double(clip.offset) + Double(rel) * Double(clip.rate)
                        if clip.loop { p = p.truncatingRemainder(dividingBy: n) } else if p >= n - 1 { break }
                        let i0 = Int(p), f = Float(p - Double(i0))
                        let i1 = i0 + 1 < Int(clip.sourceLength) ? i0 + 1 : 0
                        var g = clip.gain
                        if rel < clip.fadeIn { g *= FadeShape(code: clip.fadeInShape).gain(Float(rel) / Float(clip.fadeIn)) }
                        let left = clip.length - rel
                        if left < clip.fadeOut { g *= FadeShape(code: clip.fadeOutShape).gain(Float(left) / Float(clip.fadeOut)) }
                        let o = Int(i - pos)
                        l[o] += (clip.left[i0] + (clip.left[i1] - clip.left[i0]) * f) * g
                        r[o] += (clip.right[i0] + (clip.right[i1] - clip.right[i0]) * f) * g
                        i += 1
                    }
                    continue
                }
                while i < b {
                    let rel = i - clip.start
                    var s = clip.offset + rel
                    if clip.loop { s %= clip.sourceLength } else if s >= clip.sourceLength { break }
                    var g = clip.gain
                    if rel < clip.fadeIn { g *= FadeShape(code: clip.fadeInShape).gain(Float(rel) / Float(clip.fadeIn)) }
                    let left = clip.length - rel
                    if left < clip.fadeOut { g *= FadeShape(code: clip.fadeOutShape).gain(Float(left) / Float(clip.fadeOut)) }
                    let o = Int(i - pos), si = Int(s)
                    l[o] += clip.left[si] * g
                    r[o] += clip.right[si] * g
                    i += 1
                }
            }
        }
        // Track fader, smoothed per sample so automation never zippers.
        var g = gain, pk: Float = 0
        let target = targetGain
        for i in 0..<frames {
            g += (target - g) * 0.0025
            l[i] *= g
            r[i] *= g
            let m = max(abs(l[i]), abs(r[i]))
            if m > pk { pk = m }
        }
        gain = g
        if pk > peak { peak = pk }
    }
}

// MARK: - Graph

/// The whole signal path for a project:
///
///   track clips → EQ ─┬→ dry (stereo bed) ────────────────→ main
///                     ├→ dry (mono object) → 3D environment → main
///                     └→ send per space → echo → reverb → tone → main
///
/// The same graph runs live and in offline (manual rendering) mode, so exports match what was heard.
final class MixGraph {
    struct TrackNodes {
        var id: UUID
        let source: AVAudioSourceNode
        let renderer: TrackRenderer
        let eq: AVAudioUnitEQ
        let dryStereo: AVAudioMixerNode
        let dryMono: AVAudioMixerNode
        var sends: [UUID: AVAudioMixerNode]
        /// The track's Audio Unit effects, in order.
        var plugins: [(id: UUID, unit: AVAudioUnit)] = []
    }
    final class SpaceNodes {
        var id: UUID
        let input = AVAudioMixerNode()
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        var kind: ReverbKind?
        var size: Double?
        /// Set when the space uses an impulse response instead of the built-in reverb.
        var convolver: AVAudioUnitEffect?
        var engine: Convolver?
        var irKey: String?
        init(id: UUID) { self.id = id }
    }

    let engine = AVAudioEngine()
    let clock = TransportClock()
    let environment = AVAudioEnvironmentNode()
    private(set) var tracks: [TrackNodes] = []
    private(set) var spaces: [SpaceNodes] = []
    private var clockNode: AVAudioSourceNode?
    /// The master compressor and limiter on the live output. Exports run the same code over the rendered mix instead.
    private(set) var bus: BusProcessor?
    /// Where the output meters listen: after the master bus.
    private(set) var meterNode: AVAudioNode!
    private(set) var signature = ""
    let offline: Bool
    private let stereo = AudioCache.format
    private let mono = AVAudioFormat(standardFormatWithSampleRate: AudioCache.sampleRate, channels: 1)!

    init(offline: Bool, headphones: Bool = false) throws {
        self.offline = offline
        if offline {
            try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
        }
        meterNode = engine.mainMixerNode
        if !offline, BusAU.registered {
            let unit = AVAudioUnitEffect(audioComponentDescription: BusAU.desc)
            if let au = unit.auAudioUnit as? BusAU {
                engine.attach(unit)
                engine.connect(engine.mainMixerNode, to: unit, format: stereo)
                engine.connect(unit, to: engine.outputNode, format: stereo)
                bus = au.dsp
                meterNode = unit
            }
        }
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.distanceAttenuationParameters.rolloffFactor = 0
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.outputType = (offline || headphones) ? .headphones : .auto
        environment.reverbParameters.enable = false

        let clock = self.clock
        let node = AVAudioSourceNode(format: stereo) { silence, ts, frames, abl in
            _ = clock.position(sampleTime: ts.pointee.mSampleTime, frames: frames)
            for b in UnsafeMutableAudioBufferListPointer(abl) { memset(b.mData, 0, Int(b.mDataByteSize)) }
            silence.pointee = true
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: stereo)
        clockNode = node
    }

    static func signature(_ p: Project) -> String {
        p.tracks.map { $0.id.uuidString + ($0.plugins ?? []).map { "+" + $0.id.uuidString }.joined() }.joined(separator: ",") + "|" + p.spaces.map { $0.id.uuidString + ($0.ir.map { "/" + $0 } ?? "") }.joined(separator: ",")
    }

    /// Rebuilds nodes when tracks or spaces were added or removed. Returns true if it rebuilt.
    @discardableResult
    func rebuildIfNeeded(_ p: Project) -> Bool {
        let sig = Self.signature(p)
        guard sig != signature else { return false }
        // Another session with the same shape (the same number of tracks and spaces, the same plug-ins in the same
        // places), as when switching between cuts of one film: keep every node and hand them their new owners.
        // Tearing the engine down and building it again is what made switching cuts slow.
        if rebind(p) {
            signature = sig
            return false
        }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        for t in tracks {
            for n in [t.source, t.eq, t.dryStereo, t.dryMono] as [AVAudioNode] { engine.detach(n) }
            for s in t.sends.values { engine.detach(s) }
            for p in t.plugins { engine.detach(p.unit) }
        }
        for s in spaces {
            for n in [s.input, s.delay, s.reverb, s.eq] as [AVAudioNode] { engine.detach(n) }
            if let c = s.convolver { engine.detach(c) }
        }
        // Never built smaller than it was: spare track and space nodes sit silent, so going back to a session with more
        // tracks (the other cut of a film) can reuse them instead of rebuilding.
        let spareTracks = max(0, tracks.count - p.tracks.count), spareSpaces = max(0, spaces.count - p.spaces.count)
        let spaceList = p.spaces + (0..<spareSpaces).map { _ in Space(name: "", hue: 0) }
        let trackList = p.tracks + (0..<spareTracks).map { _ in Track(name: "", kind: .fx) }
        tracks = []
        spaces = []

        for sp in spaceList {
            let n = SpaceNodes(id: sp.id)
            for node in [n.input, n.delay, n.reverb, n.eq] as [AVAudioNode] { engine.attach(node) }
            engine.connect(n.input, to: n.delay, format: stereo)
            if sp.ir != nil, ConvolverAU.registered, case let unit = AVAudioUnitEffect(audioComponentDescription: ConvolverAU.desc),
               let au = unit.auAudioUnit as? ConvolverAU {
                // This space's reverb is an impulse response: the convolver takes the built-in reverb's place.
                engine.attach(unit)
                engine.connect(n.delay, to: unit, format: stereo)
                engine.connect(unit, to: n.eq, format: stereo)
                n.convolver = unit
                n.engine = au.dsp
            } else {
                engine.connect(n.delay, to: n.reverb, format: stereo)
                engine.connect(n.reverb, to: n.eq, format: stereo)
            }
            engine.connect(n.eq, to: engine.mainMixerNode, format: stereo)
            n.reverb.wetDryMix = 100
            n.eq.bands[0].filterType = .lowPass
            spaces.append(n)
        }

        for tr in trackList {
            let renderer = TrackRenderer()
            let clock = self.clock
            let source = AVAudioSourceNode(format: stereo) { silence, ts, frames, abl in
                let bufs = UnsafeMutableAudioBufferListPointer(abl)
                guard bufs.count >= 2, let lp = bufs[0].mData, let rp = bufs[1].mData else { return noErr }
                let n = Int(frames)
                memset(lp, 0, n * 4)
                memset(rp, 0, n * 4)
                guard let pos = clock.position(sampleTime: ts.pointee.mSampleTime, frames: frames) else {
                    silence.pointee = true
                    return noErr
                }
                renderer.render(at: pos, frames: n, l: lp.assumingMemoryBound(to: Float.self), r: rp.assumingMemoryBound(to: Float.self))
                return noErr
            }
            let eq = AVAudioUnitEQ(numberOfBands: 2)
            eq.bands[0].filterType = .highPass
            eq.bands[1].filterType = .lowPass
            let dryStereo = AVAudioMixerNode(), dryMono = AVAudioMixerNode()
            for node in [source, eq, dryStereo, dryMono] as [AVAudioNode] { engine.attach(node) }
            var sends: [UUID: AVAudioMixerNode] = [:]
            var points = [AVAudioConnectionPoint(node: dryStereo, bus: 0), AVAudioConnectionPoint(node: dryMono, bus: 0)]
            for sp in spaces {
                let send = AVAudioMixerNode()
                engine.attach(send)
                sends[sp.id] = send
                points.append(AVAudioConnectionPoint(node: send, bus: 0))
            }
            engine.connect(source, to: eq, format: stereo)
            // The track's plug-ins sit after its filters and before everything it feeds (dry, object, spaces).
            var last: AVAudioNode = eq
            var plugins: [(id: UUID, unit: AVAudioUnit)] = []
            for slot in tr.plugins ?? [] {
                guard let unit = Plugins.make(slot) else { continue }
                engine.attach(unit)
                engine.connect(last, to: unit, format: stereo)
                last = unit
                plugins.append((slot.id, unit))
            }
            engine.connect(last, to: points, fromBus: 0, format: stereo)
            engine.connect(dryStereo, to: engine.mainMixerNode, format: stereo)
            engine.connect(dryMono, to: environment, format: mono)
            dryMono.renderingAlgorithm = offline ? .HRTFHQ : .auto
            dryMono.outputVolume = 0
            for sp in spaces {
                guard let send = sends[sp.id] else { continue }
                engine.connect(send, to: sp.input, format: stereo)
                send.outputVolume = 0
            }
            tracks.append(TrackNodes(id: tr.id, source: source, renderer: renderer, eq: eq, dryStereo: dryStereo, dryMono: dryMono, sends: sends, plugins: plugins))
        }
        signature = sig
        if wasRunning { try? engine.start() }
        return true
    }

    /// Re-labels the existing nodes for a project of the same shape. false if the shape differs.
    private func rebind(_ p: Project) -> Bool {
        guard !tracks.isEmpty, p.tracks.count <= tracks.count, p.spaces.count <= spaces.count else { return false }
        // Spare nodes beyond this project's own must be plain: no plug-ins, no impulse response.
        for i in p.tracks.count..<tracks.count where !tracks[i].plugins.isEmpty { return false }
        for j in p.spaces.count..<spaces.count where spaces[j].convolver != nil { return false }
        for (j, sp) in p.spaces.enumerated() where (sp.ir != nil) != (spaces[j].convolver != nil) { return false }
        for (i, tr) in p.tracks.enumerated() {
            let slots = (tr.plugins ?? []).filter { Plugins.isInstalled($0) }
            guard slots.count == tracks[i].plugins.count else { return false }
            for (k, slot) in slots.enumerated() {
                let d = tracks[i].plugins[k].unit.audioComponentDescription
                guard d.componentType == slot.type, d.componentSubType == slot.subtype, d.componentManufacturer == slot.manufacturer else { return false }
            }
        }
        let oldSpaces = spaces.map(\.id)
        // Spares get new names nobody uses, and go silent.
        for j in p.spaces.count..<spaces.count { spaces[j].id = UUID() }
        for i in p.tracks.count..<tracks.count {
            tracks[i].id = UUID()
            tracks[i].renderer.set([], buffers: [])
            tracks[i].dryStereo.outputVolume = 0
            tracks[i].dryMono.outputVolume = 0
            for node in tracks[i].sends.values { node.outputVolume = 0 }
        }
        for (j, sp) in p.spaces.enumerated() {
            spaces[j].id = sp.id
            // Forget what was loaded, so the space's own reverb and response are set again.
            spaces[j].kind = nil; spaces[j].size = nil; spaces[j].irKey = nil
        }
        for (i, tr) in p.tracks.enumerated() {
            tracks[i].id = tr.id
            var sends: [UUID: AVAudioMixerNode] = [:]
            for (j, old) in oldSpaces.enumerated() { if let node = tracks[i].sends[old] { sends[spaces[j].id] = node } }
            tracks[i].sends = sends
            let slots = (tr.plugins ?? []).filter { Plugins.isInstalled($0) }
            for (k, slot) in slots.enumerated() {
                tracks[i].plugins[k].id = slot.id
                Plugins.restore(slot, into: tracks[i].plugins[k].unit)
            }
        }
        return true
    }

    /// Hands every track its clips. `resolve` maps a take to a file on disk.
    func loadClips(_ p: Project, resolve: (Take) -> URL?) {
        let sr = AudioCache.sampleRate
        for n in spaces {
            guard let conv = n.engine, let file = p.space(n.id)?.ir, n.irKey != file else { continue }
            conv.set(resolve(Take(file: file, duration: 0)).flatMap { IRData(url: $0) })
            n.irKey = file
        }
        for (i, tr) in p.tracks.enumerated() where i < tracks.count {
            var prepared: [PreparedClip] = []
            var keep: [AVAudioPCMBuffer] = []
            for c in tr.clips where c.muted != true {
                guard let take = c.take, let url = resolve(take), let buf = AudioCache.shared.buffer(url),
                      let ch = buf.floatChannelData, buf.frameLength > 0, c.duration > 0 else { continue }
                let length = Int64(c.duration * sr)
                let srcLen = Int64(buf.frameLength)
                let offset = min(max(0, Int64(c.offset * sr)), srcLen - 1)
                let fadeIn = min(length, max(48, Int64(c.fadeIn * sr)))
                let fadeOut = min(length, max(48, Int64(c.fadeOut * sr)))
                prepared.append(PreparedClip(start: Int64(c.start * sr), length: length, offset: offset, sourceLength: srcLen,
                                             loop: c.loop, gain: Float(dbToLinear(c.gain)), rate: Float(c.speed), fadeIn: fadeIn, fadeOut: fadeOut,
                                             fadeInShape: c.inShape.code, fadeOutShape: c.outShape.code,
                                             left: UnsafePointer(ch[0]), right: UnsafePointer(ch[1])))
                keep.append(buf)
            }
            tracks[i].renderer.set(prepared, buffers: keep)
        }
    }

    func configurePlugins(_ p: Project) {
        for nodes in tracks {
            guard let slots = p.tracks.first(where: { $0.id == nodes.id })?.plugins else { continue }
            for (id, unit) in nodes.plugins {
                if let s = slots.first(where: { $0.id == id }), unit.auAudioUnit.shouldBypassEffect != s.bypass { unit.auAudioUnit.shouldBypassEffect = s.bypass }
            }
        }
    }

    func configureSpaces(_ p: Project) {
        for n in spaces {
            guard let sp = p.space(n.id) else { continue }
            if n.kind != sp.reverb || n.size != sp.size {
                n.reverb.loadFactoryPreset(sp.reverb.preset)
                n.reverb.wetDryMix = 100
                // Parameter 1 of the system reverb blends its small and large rooms.
                if let size = sp.size, let p = n.reverb.auAudioUnit.parameterTree?.parameter(withAddress: 1) {
                    p.value = AUValue(min(1, max(0, size)) * 100)
                }
                n.kind = sp.reverb
                n.size = sp.size
            }
            n.delay.delayTime = min(2, max(0.01, sp.echoTime))
            n.delay.feedback = Float(min(90, max(0, sp.echoFeedback * 100)))
            n.delay.lowPassCutoff = 5500
            n.delay.wetDryMix = Float(min(1, max(0, sp.echo)) * 60)
            n.eq.bands[0].frequency = Float(min(20000, max(300, sp.tone)))
            n.eq.bands[0].bypass = sp.tone >= 19000
        }
    }

    /// Pushes the mix for time `t` into the nodes. Called ~60×/s live and once per block offline.
    func apply(_ p: Project, at t: Double, mode: MonitorMode, stem: Stem = .full, snap: Bool = false) {
        let anySolo = p.anySolo
        for (i, tr) in p.tracks.enumerated() where i < tracks.count {
            let n = tracks[i]
            let m = p.mix(for: tr, at: t, anySolo: anySolo)
            n.renderer.targetGain = Float(m.gain)
            if snap { n.renderer.snapGain() }

            n.eq.bands[0].frequency = Float(m.lowCut)
            n.eq.bands[0].bypass = m.lowCut <= 25
            n.eq.bands[1].frequency = Float(m.highCut)
            n.eq.bands[1].bypass = m.highCut >= 19500

            var stereoOn = false, monoOn = false, sendsOn = true
            var pan = tr.spatial ? m.position.x : m.pan
            switch stem {
            case .full:
                if tr.spatial && mode == .spatial { monoOn = true } else { stereoOn = true }
            case .bedDry:
                stereoOn = !tr.spatial
                sendsOn = false
            case .reverb:
                break
            case .object(let id):
                stereoOn = tr.id == id
                pan = 0
                sendsOn = false
            }
            n.dryStereo.outputVolume = stereoOn ? 1 : 0
            n.dryStereo.pan = Float(min(1, max(-1, pan)))
            n.dryMono.outputVolume = monoOn ? 1 : 0
            if monoOn {
                // Room coordinates → listener space (x right, y up, -z ahead), on a 2 m sphere-ish room.
                n.dryMono.position = AVAudio3DPoint(x: Float(m.position.x * 2), y: Float(m.position.z * 2), z: Float(-m.position.y * 2))
            }
            for (sid, node) in n.sends {
                node.outputVolume = sendsOn ? Float(m.sends[sid] ?? 0) : 0
            }
        }
    }

    func seek(to time: Double, playing: Bool) {
        clock.startFrame = Int64(max(0, time) * AudioCache.sampleRate)
        clock.frame = clock.startFrame
        clock.playing = playing
        clock.generation += 1
    }

    var time: Double { Double(clock.frame) / AudioCache.sampleRate }
}

extension ReverbKind {
    var preset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        case .mediumChamber: .mediumChamber
        case .largeChamber: .largeChamber
        case .mediumHall: .mediumHall
        case .largeHall: .largeHall
        case .plate: .plate
        case .cathedral: .cathedral
        }
    }
}
