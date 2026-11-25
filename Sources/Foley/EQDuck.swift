import AVFoundation
import Accelerate

// mitroley. Copyright © 2026 Ayan Mitra.

/// Makes room for a voice inside the music instead of turning the whole of the music down: at each moment, only
/// the frequencies the voice is using are lowered, and only by as much as the voice is there. The bass and the air
/// of the music stay where they were. Worked out once and written as a new take, so it costs nothing while playing.
enum EQDuck {
    static let size = 2048, hop = 512, log2n = vDSP_Length(11)

    /// One spectrum per hop: magnitudes, scaled so a full-level sine reads about 1.
    private static func analyse(_ x: [Float], window: [Float], setup: FFTSetup, keep: Bool) -> (mags: [[Float]], real: [[Float]], imag: [[Float]]) {
        let frames = max(1, (x.count + hop - 1) / hop)
        var mags: [[Float]] = [], reals: [[Float]] = [], imags: [[Float]] = []
        mags.reserveCapacity(frames)
        var frame = [Float](repeating: 0, count: size)
        for f in 0..<frames {
            // Centred on the hop, so the gain found for a frame lines up with the sound it came from.
            let start = f * hop - size / 2
            for i in 0..<size {
                let j = start + i
                frame[i] = (j >= 0 && j < x.count ? x[j] : 0) * window[i]
            }
            var real = [Float](repeating: 0, count: size / 2), imag = [Float](repeating: 0, count: size / 2)
            var m = [Float](repeating: 0, count: size / 2)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &m, 1, vDSP_Length(size / 2))
                }
            }
            // vDSP's forward transform is scaled by 2; a Hann window halves a sine's peak.
            var k = 2 / Float(size)
            vDSP_vsmul(m, 1, &k, &m, 1, vDSP_Length(size / 2))
            mags.append(m)
            if keep { reals.append(real); imags.append(imag) }
        }
        return (mags, reals, imags)
    }

    /// `music`: one array per channel. `voice`: mono, same length and rate. `maxCut`: the most any frequency drops, in dB.
    /// Returns the music with room made for the voice, and how much was taken out at most.
    static func process(music: [[Float]], voice: [Float], rate: Double, maxCut: Double = 9) -> (out: [[Float]], deepest: Double) {
        let n = music.first?.count ?? 0
        guard n > size, voice.count > size, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (music, 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        let bins = size / 2
        let v = analyse(voice, window: window, setup: setup, keep: false).mags
        let frames = v.count

        // How much to take out of each frequency in each frame, 0…1.
        var cut = [[Float]](repeating: [Float](repeating: 0, count: bins), count: frames)
        let binHz = rate / Double(size)
        for f in 0..<frames {
            // Spread across about a third of an octave: room is made around the voice's harmonics, not as a comb of notches.
            var smooth = [Float](repeating: 0, count: bins)
            for k in 1..<bins {
                let w = max(1, Int(Double(k) * 0.12))
                let a = max(1, k - w), b = min(bins - 1, k + w)
                var m: Float = 0
                vDSP_maxv(v[f].withUnsafeBufferPointer { $0.baseAddress! + a }, 1, &m, vDSP_Length(b - a + 1))
                smooth[k] = m
            }
            for k in 1..<bins {
                let hz = Double(k) * binHz
                // Speech lives between about 150 Hz and 8 kHz. Below and above, the music is left alone.
                guard hz > 120, hz < 9000 else { continue }
                let db = 20 * log10(max(1e-7, smooth[k]))
                // Nothing below -52 dB, everything by -24 dB.
                cut[f][k] = min(1, max(0, (db + 52) / 28))
            }
        }
        // In time: the cut arrives a little before the voice (it looks ahead) and lets go slowly, so it never pumps.
        let ahead = max(1, Int(0.06 * rate / Double(hop)))
        let release = Float(exp(-Double(hop) / (0.22 * rate)))
        var shaped = cut
        for k in 1..<bins {
            var held: Float = 0
            for f in 0..<frames {
                var want: Float = 0
                for j in f..<min(frames, f + ahead + 1) { want = max(want, cut[j][k]) }
                held = want > held ? held + (want - held) * 0.5 : max(want, held * release)
                shaped[f][k] = held
            }
        }

        var deepest: Float = 0
        var out: [[Float]] = []
        let norm = 1 / (2 * Float(size) * 1.5)  // undoes the transform's scale (twice the size, there and back) and the overlap of four Hann windows squared
        for channel in music {
            let m = analyse(channel, window: window, setup: setup, keep: true)
            var y = [Float](repeating: 0, count: n + size)
            var frame = [Float](repeating: 0, count: size)
            for f in 0..<min(frames, m.real.count) {
                var real = m.real[f], imag = m.imag[f]
                for k in 1..<bins {
                    let c = shaped[f][k]
                    guard c > 0.001 else { continue }
                    let g = powf(10, -Float(maxCut) * c / 20)
                    real[k] *= g; imag[k] *= g
                    deepest = max(deepest, Float(maxCut) * c)
                }
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                        frame.withUnsafeMutableBufferPointer { p in
                            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2)) }
                        }
                    }
                }
                let start = f * hop - size / 2
                for i in 0..<size {
                    let j = start + i
                    if j >= 0, j < n { y[j] += frame[i] * window[i] * norm }
                }
            }
            out.append(Array(y.prefix(n)))
        }
        return (out, Double(deepest))
    }
}

extension Store {
    /// The voice across the whole timeline as one mono signal: the Voice-over tracks, and the film's own sound when it is turned up.
    nonisolated static func voiceSignal(_ p: Project, folder: URL, video: URL?, source: UUID? = nil) -> [Float] {
        var q = p
        let anySolo = p.anySolo
        q.tracks = p.tracks.filter { source == nil ? $0.kind == .dialogue && !$0.mute && (!anySolo || $0.solo) : $0.id == source }
        q.groups = nil
        for i in q.tracks.indices { q.tracks[i].solo = false; q.tracks[i].mute = false; q.tracks[i].groupID = nil; q.tracks[i].spaceMode = .dry; q.tracks[i].plugins = nil }
        q.rack = []
        var mono = [Float](repeating: 0, count: Int(p.extent * AudioCache.sampleRate) + 1)
        if !q.tracks.isEmpty, let mix = try? Exporter.render(q, mode: .stereo, tail: 0, resolve: { Store.url(for: $0, in: folder) }) {
            for i in 0..<min(mono.count, mix.l.count) { mono[i] = (mix.l[i] + mix.r[i]) * 0.5 }
        }
        if source == nil, p.videoVolume > 0.001, let video, let buf = AudioCache.shared.buffer(video), let ch = buf.floatChannelData {
            let g = Float(p.videoVolume)
            for i in 0..<min(mono.count, Int(buf.frameLength)) { mono[i] += (ch[0][i] + ch[1][i]) * 0.5 * g }
        }
        return mono
    }

    /// Carves room for the voice in every clip on a music track. Each clip gets a new take; the original stays as the take before it.
    func carveForVoice(_ id: UUID, maxCut: Double, source: UUID? = nil) async {
        guard let track = project.tracks.first(where: { $0.id == id }) else { return }
        let p = project, folder = self.folder, video = videoURL
        let audio = subfolder("Audio")
        busy = "Making room for the voice"
        defer { busy = nil }
        struct Done { let clip: UUID; let take: Take; let deepest: Double }
        let result = await Task.detached(priority: .userInitiated) { () -> (done: [Done], silent: Bool, skipped: Int) in
            let voice = Store.voiceSignal(p, folder: folder, video: video, source: source)
            var top: Float = 0
            vDSP_maxmgv(voice, 1, &top, vDSP_Length(voice.count))
            guard top > 0.003 else { return ([], true, 0) }
            var done: [Done] = [], skipped = 0
            let rate = AudioCache.sampleRate
            for c in track.clips {
                // A clip that is sped up or looped does not line up one-to-one with the voice.
                guard let take = c.take, abs(c.speed - 1) < 0.001, !c.loop,
                      let buf = AudioCache.shared.buffer(Store.url(for: take, in: folder)), let ch = buf.floatChannelData else { skipped += 1; continue }
                let n = Int(buf.frameLength)
                let left = Array(UnsafeBufferPointer(start: ch[0], count: n)), right = Array(UnsafeBufferPointer(start: ch[1], count: n))
                // The voice as this file hears it: sample i of the file plays at clip.start + (i/rate - offset).
                var along = [Float](repeating: 0, count: n)
                let shift = Int(((c.start - c.offset) * rate).rounded())
                for i in 0..<n {
                    let j = i + shift
                    if j >= 0, j < voice.count { along[i] = voice[j] }
                }
                let made = EQDuck.process(music: [left, right], voice: along, rate: rate, maxCut: maxCut)
                guard made.deepest > 0.5 else { skipped += 1; continue }
                let file = audio.appendingPathComponent("carved-" + UUID().uuidString.prefix(8) + ".wav")
                guard (try? WAV.write(file, channels: made.out)) != nil else { skipped += 1; continue }
                done.append(Done(clip: c.id, take: Take(file: "Audio/" + file.lastPathComponent, duration: Double(n) / rate), deepest: made.deepest))
            }
            return (done, false, skipped)
        }.value
        if result.silent {
            say("No voice found to make room for. It looks on Voice-over tracks, and in the film's own sound when that is turned up.", error: true)
            return
        }
        guard !result.done.isEmpty else {
            say("Nothing was changed: the voice and the music do not overlap, or the clips are looped or sped up.", error: true)
            return
        }
        mutate { p in
            for d in result.done {
                guard let l = p.locate(clip: d.clip) else { continue }
                p.tracks[l.track].clips[l.clip].takes.append(d.take)
                p.tracks[l.track].clips[l.clip].activeTake = p.tracks[l.track].clips[l.clip].takes.count - 1
            }
        }
        let deepest = result.done.map(\.deepest).max() ?? 0
        say(String(format: "Made room for the voice in %d clip%@, up to %.0f dB where it speaks. It is a new take: switch takes to compare.", result.done.count, result.done.count == 1 ? "" : "s", deepest))
    }
}
