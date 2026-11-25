import AVFoundation

/// `Foley --selftest <dir>` renders a small synthetic project offline and checks the engine's behaviour.
/// <dir> must contain click.wav and noise.wav; results are printed and exports are written into it.
enum SelfTest {
    static func rms(_ a: [Float], _ from: Double, _ to: Double) -> Double {
        let s = Int(from * 48000), e = min(a.count, Int(to * 48000))
        guard e > s else { return 0 }
        var sum = 0.0
        for i in s..<e { sum += Double(a[i] * a[i]) }
        return (sum / Double(e - s)).squareRoot()
    }

    static func run(_ dir: String) -> Int32 {
        let base = URL(fileURLWithPath: dir)
        let click = base.appendingPathComponent("click.wav"), noise = base.appendingPathComponent("noise.wav")
        let resolve: (Take) -> URL? = { URL(fileURLWithPath: $0.file) }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print((ok ? "PASS  " : "FAIL  ") + name + " — " + detail)
            if !ok { failures += 1 }
        }
        let clickDur = AudioCache.shared.duration(click), noiseDur = AudioCache.shared.duration(noise)
        check("decode", clickDur > 0 && noiseDur > 0, String(format: "click %.2fs noise %.2fs", clickDur, noiseDur))

        // Every sound preset builds: each link is an effect this Mac has, and it took its settings.
        let broken = SoundPreset.all.filter { p in let s = p.slots(); return s.count != p.chain.count || s.contains { $0.state == nil } }
        check("sound presets build", broken.isEmpty, broken.isEmpty ? "\(SoundPreset.all.count) presets" : "broken: " + broken.map(\.name).joined(separator: ", "))

        // Room for the voice: a 1 kHz "voice" over noise "music" takes out the middle and leaves the rest.
        do {
            let rate = 48000.0, n = Int(rate * 4)
            var seed: UInt64 = 7
            func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2000) / 2000 * 0.6 - 0.3 }
            let music = (0..<n).map { _ in rnd() }
            let voice = (0..<n).map { i -> Float in i > Int(rate) && i < Int(rate * 3) ? 0.25 * sin(2 * .pi * 1000 * Float(i) / Float(rate)) : 0 }
            let made = EQDuck.process(music: [music], voice: voice, rate: rate, maxCut: 9).out[0]
            // Level in a narrow band, measured directly at a spread of frequencies inside it.
            func band(_ x: [Float], _ lo: Double, _ hi: Double, _ from: Double, _ to: Double) -> Double {
                let a = Int(from * rate), b = Int(to * rate)
                var power = 0.0
                for step in 0..<12 {
                    let hz = lo + (hi - lo) * (Double(step) + 0.5) / 12
                    var re = 0.0, im = 0.0
                    for i in a..<b {
                        let ph = 2 * Double.pi * hz * Double(i) / rate
                        re += Double(x[i]) * cos(ph); im += Double(x[i]) * sin(ph)
                    }
                    power += re * re + im * im
                }
                return 10 * log10(max(1e-12, power))
            }
            let mid = band(made, 960, 1040, 1.5, 2.5) - band(music, 960, 1040, 1.5, 2.5)
            let high = band(made, 5000, 6000, 1.5, 2.5) - band(music, 5000, 6000, 1.5, 2.5)
            let quiet = 20 * log10(max(1e-9, rms(made, 0.1, 0.7))) - 20 * log10(max(1e-9, rms(music, 0.1, 0.7)))
            check("EQ ducking lowers only where the voice is", mid < -5 && abs(high) < 1 && abs(quiet) < 0.5,
                  String(format: "at the voice %.1f dB, above it %.1f dB, before it speaks %.1f dB", mid, high, quiet))
        }
        // The library tells shapes and pitch apart.
        do {
            let rate = 48000.0
            func item(_ x: [Float]) -> SoundItem { Library.measure(x, rate: rate, duration: Double(x.count) / rate, url: URL(fileURLWithPath: "/tmp/x.wav")) }
            var seed: UInt64 = 3
            func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1 }
            let n = Int(rate * 2)
            let hit = item((0..<n).map { i in rnd() * exp(-Float(i) / Float(rate) * 9) })
            let rise = item((0..<n).map { i in rnd() * powf(Float(i) / Float(n), 3) })
            let steady = item((0..<n).map { _ in rnd() * 0.3 })
            let pulse = item((0..<n).map { i in rnd() * (i % 12000 < 2400 ? 1 : 0.02) })
            let tone = item((0..<n).map { i in 0.4 * sin(2 * .pi * 440 * Float(i) / Float(rate)) })
            let click = item((0..<Int(rate * 0.05)).map { i in rnd() * exp(-Float(i) / 300) })
            // A low thump with hiss on it must not be given a high note, and a pure low tone must not read as bright.
            let thump = item((0..<n).map { i in (sin(2 * .pi * 55 * Float(i) / Float(rate)) + 0.3 * rnd()) * exp(-Float(i) / Float(rate) * 5) })
            let low = item((0..<n).map { i in 0.4 * sin(2 * .pi * 110 * Float(i) / Float(rate)) })
            let got = [hit.shape, rise.shape, steady.shape, pulse.shape, click.shape]
            check("library tells shapes apart", got == [.hit, .rise, .steady, .pulsing, .click] && tone.note == "A4" && hit.note == nil && (thump.note == nil || thump.note!.hasSuffix("1")) && low.tone == .low && low.note == "A2" && steady.tone == .bright,
                  "hit=\(hit.shape.rawValue) rise=\(rise.shape.rawValue) steady=\(steady.shape.rawValue) pulse=\(pulse.shape.rawValue) click=\(click.shape.rawValue) tone=\(tone.note ?? "none") noise=\(hit.note ?? "none") thump=\(thump.note ?? "none") low=\(low.note ?? "none")/\(low.tone.rawValue)")
        }

        var p = Project()
        p.duration = 8
        let room = SpaceTemplate.named("Living Room")!.space
        let cave = SpaceTemplate.named("Cave")!.space
        p.spaces = [room, cave]
        p.scenes = [SceneRegion(start: 0, end: 4, name: "Living room", spaceID: room.id),
                    SceneRegion(start: 4, end: 8, name: "Cave", spaceID: cave.id, transition: 0.2)]
        var steps = Track(name: "Steps", kind: .foley, spatial: true)
        for i in 0..<14 {
            steps.clips.append(Clip(name: "step", start: 0.5 + Double(i) * 0.5, duration: min(0.4, clickDur),
                                    takes: [Take(file: click.path, duration: clickDur)]))
        }
        p.tracks = [steps]

        do {
            // 1. Scene-following reverb: the gaps between steps should ring far more in the cave.
            let mix = try Exporter.render(p, mode: .stereo, resolve: resolve)
            let roomTail = rms(mix.l, 2.30, 2.48) + rms(mix.l, 2.80, 2.98)
            let caveTail = rms(mix.l, 6.30, 6.48) + rms(mix.l, 6.80, 6.98)
            check("scene follows space", caveTail > roomTail * 2.5 && roomTail > 0,
                  String(format: "tail level room %.5f → cave %.5f (×%.1f)", roomTail, caveTail, caveTail / max(roomTail, 1e-9)))
            let lr = rms(mix.l, 0, 8) / max(1e-9, rms(mix.r, 0, 8))
            check("centred object is centred in stereo", abs(lr - 1) < 0.05, String(format: "L/R %.3f", lr))

            // 2. Dry mode ignores spaces.
            var dry = p
            dry.tracks[0].spaceMode = .dry
            let dmix = try Exporter.render(dry, mode: .stereo, resolve: resolve)
            let dryTail = rms(dmix.l, 6.30, 6.48)
            check("dry track stays dry", dryTail < caveTail * 0.05, String(format: "tail %.6f", dryTail))

            // 3. Two tracks with the same clip must be sample-locked (sum = +6 dB of one).
            var two = dry
            two.tracks.append(two.tracks[0])
            two.tracks[1].id = UUID()
            let tmix = try Exporter.render(two, mode: .stereo, resolve: resolve)
            var maxDiff: Float = 0
            for i in 0..<min(tmix.l.count, dmix.l.count) { maxDiff = max(maxDiff, abs(tmix.l[i] - 2 * dmix.l[i])) }
            check("tracks are sample-locked", maxDiff < 0.001, "max deviation \(maxDiff)")

            // 4. Spatial: an object on the right is louder in the right ear.
            var right = dry
            right.tracks[0].position = Vec3(x: 1, y: 0, z: 0)
            let bmix = try Exporter.render(right, mode: .spatial, resolve: resolve)
            let l = rms(bmix.l, 0, 8), r = rms(bmix.r, 0, 8)
            check("binaural object pans right", r > l * 1.5, String(format: "L %.4f R %.4f", l, r))

            // 5. Position automation moves an object left → right.
            var sweep = dry
            sweep.tracks[0].automation[AutoParam.x.rawValue] = [Keyframe(time: 0, value: -1), Keyframe(time: 8, value: 1)]
            let smix = try Exporter.render(sweep, mode: .stereo, resolve: resolve)
            let early = rms(smix.l, 0, 2) / max(1e-9, rms(smix.r, 0, 2)), late = rms(smix.l, 6, 8) / max(1e-9, rms(smix.r, 6, 8))
            check("automation pans left → right", early > 2 && late < 0.5, String(format: "L/R early %.2f late %.2f", early, late))

            // 6. Muffle (next room) removes highs: noise through a 1.1 kHz low-pass is much quieter.
            var amb = Project()
            amb.duration = 4
            let next = SpaceTemplate.named("Next Room")!.space
            amb.spaces = [next]
            amb.scenes = [SceneRegion(start: 2, end: 4, name: "Next room", spaceID: next.id)]
            var bed = Track(name: "Amb", kind: .ambience)
            bed.clips = [Clip(name: "noise", start: 0, duration: 4, loop: true, takes: [Take(file: noise.path, duration: noiseDur)])]
            amb.tracks = [bed]
            let amix = try Exporter.render(amb, mode: .stereo, resolve: resolve)
            let open = rms(amix.l, 0.5, 1.5), shut = rms(amix.l, 2.8, 3.8)
            check("space muffles and trims the dry sound", shut < open * 0.5, String(format: "open %.4f → next room %.4f", open, shut))

            // 7. Fades and looping: a 4 s looped clip from a shorter source keeps sounding to the end.
            check("looping fills the clip", rms(amix.l, 1.5, 2.0) > 0.001, String(format: "source %.2fs, level at 1.5–2s %.4f", noiseDur, rms(amix.l, 1.5, 2.0)))

            // 8. Panner keeps constant power.
            var worst = 0.0
            for x in stride(from: -1.0, through: 1.0, by: 0.25) { for y in stride(from: -1.0, through: 1.0, by: 0.25) { for z in [0.0, 0.5, 1.0] {
                let g = Exporter.pan714(Vec3(x: x, y: y, z: z))
                let pw = g.reduce(0.0) { $0 + Double($1 * $1) }
                worst = max(worst, abs(pw - 1))
            } } }
            check("7.1.4 panner is constant-power", worst < 0.001, "worst deviation \(worst)")

            // IR reverb inside the engine: a space whose room is an impulse response returns a tail, a different one from the built-in reverb.
            var irp = p
            irp.spaces[0].wet = 0.6; irp.spaces[1].wet = 0.6
            let builtIn = try Exporter.render(irp, mode: .stereo, stem: .reverb, resolve: resolve)
            irp.spaces[0].ir = noise.path; irp.spaces[1].ir = noise.path
            let withIR = try Exporter.render(irp, mode: .stereo, stem: .reverb, resolve: resolve)
            var diff = 0.0
            for i in 0..<min(builtIn.l.count, withIR.l.count) { diff += Double(abs(builtIn.l[i] - withIR.l[i])) }
            check("IR reverb runs in the engine", rms(withIR.l, 1, 6) > 0.0005 && diff > 1,
                  String(format: "reverb return %.5f with the response, %.5f built-in", rms(withIR.l, 1, 6), rms(builtIn.l, 1, 6)))

            // Audio Unit on a track: Apple's low-pass in the chain takes the top off white noise in an offline render.
            var plug = Project()
            plug.duration = 3
            var hiss = Track(name: "Hiss", kind: .fx)
            hiss.spaceMode = .dry
            hiss.clips = [Clip(name: "noise", start: 0, duration: 2.5, takes: [Take(file: noise.path, duration: noiseDur)])]
            plug.tracks = [hiss]
            let plain = try Exporter.render(plug, mode: .stereo, tail: 0, resolve: resolve)
            plug.tracks[0].plugins = [PluginSlot(name: "AULowpass", maker: "Apple", type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_LowPassFilter, manufacturer: kAudioUnitManufacturer_Apple)]
            let filtered = try Exporter.render(plug, mode: .stereo, tail: 0, resolve: resolve)
            plug.tracks[0].plugins?[0].bypass = true
            let bypassed = try Exporter.render(plug, mode: .stereo, tail: 0, resolve: resolve)
            let r0 = rms(plain.l, 0.5, 2), r1 = rms(filtered.l, 0.5, 2), r2 = rms(bypassed.l, 0.5, 2)
            check("Audio Unit runs on a track", r0 > 0.01 && r1 < r0 * 0.9 && abs(r2 - r0) < r0 * 0.02,
                  String(format: "noise level %.4f plain, %.4f through Apple's low-pass, %.4f bypassed", r0, r1, r2))

            // Effects before the fader: with no effects, a track 12 dB down sounds the same either way round.
            var order = plug
            order.tracks[0].plugins = nil
            order.tracks[0].volume = -12
            let post = try Exporter.render(order, mode: .stereo, tail: 0, resolve: resolve)
            order.tracks[0].fxBeforeFader = true
            let pre = try Exporter.render(order, mode: .stereo, tail: 0, resolve: resolve)
            let o0 = rms(post.l, 0.5, 2), o1 = rms(pre.l, 0.5, 2)
            check("fader after effects keeps the level", o0 > 0.001 && abs(o1 / o0 - 1) < 0.03 && abs(o0 / r0 - 0.251) < 0.02,
                  String(format: "%.4f fader first, %.4f effects first, %.4f at 0 dB", o0, o1, r0))

            // A bus with an effect: the low-pass on the group reaches the track sent to it, and not one that is not.
            var bus = plug
            bus.tracks[0].plugins = nil
            var g = TrackGroup(name: "Bus")
            g.plugins = [PluginSlot(name: "AULowpass", maker: "Apple", type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_LowPassFilter, manufacturer: kAudioUnitManufacturer_Apple)]
            bus.groups = [g]
            let outside = try Exporter.render(bus, mode: .stereo, tail: 0, resolve: resolve)
            bus.tracks[0].groupID = g.id
            let inside = try Exporter.render(bus, mode: .stereo, tail: 0, resolve: resolve)
            let b0 = rms(outside.l, 0.5, 2), b1 = rms(inside.l, 0.5, 2)
            check("bus effect reaches only its tracks", abs(b0 - r0) < r0 * 0.02 && b1 < r0 * 0.9 && b1 > 0.0005,
                  String(format: "%.4f outside the bus, %.4f through it", b0, b1))

            // A "music effect" kind of Audio Unit, if this Mac has one, loads and passes sound in the same chain.
            if let music = Plugins.installed().first(where: { $0.audioComponentDescription.componentType == kAudioUnitType_MusicEffect }) {
                let d = music.audioComponentDescription
                plug.tracks[0].plugins = [PluginSlot(name: music.name, maker: music.manufacturerName, type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer)]
                let through = try Exporter.render(plug, mode: .stereo, tail: 0, resolve: resolve)
                check("music-effect Audio Unit loads", rms(through.l, 0.5, 2) > 0.001,
                      String(format: "%@ %@: noise level %.4f through it at its default settings", music.manufacturerName, music.name, rms(through.l, 0.5, 2)))
            }

            // 9. Fold-downs of the 7.1.4 mix, on synthetic channels.
            downmixChecks(check)
            busChecks(check)
            cutChecks(check)
            // A serial made for "Test Person" with the author's key checks out; one changed letter does not.
            let serial = "MIT-VGVzdCBQZXJzb24-1houk_jxDmKLp1IoRhOCCe32E7HqEbOru7kzSIa_J8GswJf4eiX0AW6mzAic5CemSjuYgdESMmGZEBE2Gy9EAw"
            if !serial.hasSuffix("__SIG__") {
                var bad = Array(serial); bad[6] = bad[6] == "A" ? "B" : "A"
                check("serial codes", License.owner(of: serial) == "Test Person" && License.owner(of: String(bad)) == nil && License.owner(of: "MIT-abc") == nil,
                      "a real serial names its owner, a changed one is refused")
            }

            // 10. Exports.
            let sem = DispatchSemaphore(value: 0)
            var notes: [String] = []
            Task.detached {
                for f in [ExportFormat.stereo, .binaural, .bed714, .surround51, .stereoFold, .speakers, .mixdowns, .adm] {
                    let out = base.appendingPathComponent(f.isFolder ? "selftest " + f.suffix : "selftest." + f.suffix + ".wav")
                    do {
                        let s = try await Exporter.export(sweep, format: f, to: out, videoURL: nil, resolve: resolve)
                        notes.append("PASS  export \(f.rawValue) — \(out.lastPathComponent): \(s)")
                    } catch {
                        notes.append("FAIL  export \(f.rawValue) — \(error.localizedDescription)")
                    }
                }
                sem.signal()
            }
            sem.wait()
            for n in notes { print(n); if n.hasPrefix("FAIL") { failures += 1 } }
        } catch {
            check("render", false, error.localizedDescription)
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// The master bus and the loudness meter.
    static func busChecks(_ check: (String, Bool, String) -> Void) {
        let sr = 48000.0, n = 48000
        func sine(_ hz: Double, _ amp: Double, phase: Double = 0) -> [Float] {
            (0..<n).map { Float(amp * sin(2 * .pi * hz * Double($0) / sr + phase)) }
        }
        // 1. Linked: a loud burst in one of twelve channels turns every channel down by the same amount.
        var ch = [[Float]](repeating: sine(440, 0.1), count: 12)
        for i in 20000..<24000 { ch[5][i] = Float(1.6 * sin(2 * .pi * 300 * Double(i) / sr)) }
        let before = ch
        var lim = BusDynamics()
        lim.limiter = true
        let red = BusProcessor.run(&ch, lim)
        let at = 22000
        var ratios: [Double] = []
        for c in 0..<12 where c != 5 { ratios.append(Double(ch[c][at]) / Double(before[c][at])) }
        let spread = (ratios.max() ?? 1) - (ratios.min() ?? 1)
        check("bus is linked across channels", spread < 1e-4 && (ratios.first ?? 1) < 0.7 && abs(Double(ch[0][1000]) / Double(before[0][1000]) - 1) < 1e-4,
              String(format: "gain on the other 11 channels during the hit %.3f (spread %.5f), limiter %.1f dB", ratios.first ?? 1, spread, red.limiter))

        // 2. Ceiling in true peak, on a signal whose peaks fall between samples (fs/4 at 45°) and on a hard burst.
        var hot = [sine(12000, 1.3, phase: .pi / 4), sine(3000, 1.2)]
        for i in 30000..<30200 { hot[1][i] = i % 2 == 0 ? 1.8 : -1.8 }
        BusProcessor.run(&hot, lim)
        let tp = Downmix.truePeak(hot)
        check("limiter holds the true-peak ceiling", tp <= -1.0 + 0.05 && tp > -3, String(format: "%.2f dBTP against a -1.0 ceiling", tp))

        // 3. Compressor curve: steady sines settle at threshold + (level - threshold) / ratio.
        var comp = BusDynamics()
        comp.limiter = false; comp.compressor = true; comp.threshold = -20; comp.ratio = 4; comp.attack = 1; comp.release = 50
        var worst = 0.0, detail: [String] = []
        for level in [-30.0, -10.0, 0.0] {
            var s = [sine(1000, pow(10, level / 20)), sine(1000, pow(10, level / 20))]
            BusProcessor.run(&s, comp)
            var pk: Float = 0
            for i in 40000..<47000 { pk = max(pk, abs(s[0][i])) }
            let out = 20 * log10(Double(pk))
            let want = level <= -23 ? level : -20 + (level + 20) / 4
            worst = max(worst, abs(out - want))
            detail.append(String(format: "%.0f→%.1f", level, out))
        }
        check("compressor follows its curve", worst < 0.6, detail.joined(separator: "  ") + " dB (threshold -20, 4:1)")

        // 4. Sample-aligned: an impulse comes out on the sample it went in on.
        var imp = [[Float]](repeating: [Float](repeating: 0, count: 4000), count: 2)
        imp[0][1234] = 0.5; imp[1][1234] = 0.5
        BusProcessor.run(&imp, lim)
        let where_ = imp[0].firstIndex { abs($0) > 0.25 } ?? -1
        check("bus keeps exports aligned", where_ == 1234, "impulse at 1234 comes out at \(where_)")

        // 6. Surround reverb copies: same level, no longer lined up with the original.
        var seed: UInt64 = 88172645463325252
        let noise = (0..<n).map { _ -> Float in
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Float(Double(seed % 20001) / 10000 - 1) * 0.3
        }
        let a = Exporter.decorrelate(noise, seed: 11), b = Exporter.decorrelate(noise, seed: 21)
        let level = 20 * log10(rms(a, 0.1, 0.9) / rms(noise, 0.1, 0.9))
        check("surround reverb is decorrelated", abs(level) < 0.5 && abs(Downmix.correlation(noise, a)) < 0.35 && abs(Downmix.correlation(a, b)) < 0.35,
              String(format: "level %+.2f dB, correlation with the front %.2f, between pairs %.2f", level, Downmix.correlation(noise, a), Downmix.correlation(a, b)))

        // 7. IR reverb: the block convolver gives the same answer as convolving sample by sample, 512 samples later.
        var s2: UInt64 = 0x2545F4914F6CDD1D
        func rnd() -> Float { s2 ^= s2 << 13; s2 ^= s2 >> 7; s2 ^= s2 << 17; return Float(Double(s2 % 20001) / 10000 - 1) }
        let hl = (0..<1500).map { Float(exp(-Double($0) / 300)) * rnd() }, hr = (0..<1500).map { Float(exp(-Double($0) / 250)) * rnd() }
        if let ir = IRData(left: hl, right: hr) {
            let m = 6000
            let x = (0..<m).map { _ in rnd() * 0.5 }
            var energy = 0.0
            for i in 0..<1500 { energy += Double(hl[i] * hl[i]) + Double(hr[i] * hr[i]) }
            let k = Float(1 / (energy / 2).squareRoot())
            var want = [Float](repeating: 0, count: m)
            for i in 0..<m { var acc: Float = 0; for j in 0...min(i, 1499) { acc += x[i - j] * hl[j] }; want[i] = acc * k }
            let conv = Convolver()
            conv.set(ir)
            var l = x + [Float](repeating: 0, count: 512), r = l
            var at = 0
            // Odd-sized buffers, the way a real audio device asks for them.
            while at < l.count {
                let len = min(300, l.count - at)
                l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in
                        var ptrs = [lp.baseAddress! + at, rp.baseAddress! + at]
                        ptrs.withUnsafeMutableBufferPointer { conv.process(UnsafePointer($0.baseAddress!), frames: len) }
                    }
                }
                at += len
            }
            var worst: Float = 0
            for i in 0..<m { worst = max(worst, abs(l[i + 512] - want[i])) }
            check("IR reverb matches a direct convolution", worst < 1e-3, String(format: "largest difference %.6f over %d samples, %d blocks of response", worst, m, ir.parts))
        } else {
            check("IR reverb matches a direct convolution", false, "could not prepare the response")
        }

        // 8. Ducking: two spoken stretches in a recording are found, and the music's volume lane dips under each.
        var talk = [Float](repeating: 0, count: Int(sr * 10))
        for (a, b) in [(2.0, 4.0), (6.5, 8.0)] {
            for i in Int(a * sr)..<Int(b * sr) { talk[i] = Float(0.2 * sin(2 * .pi * 800 * Double(i) / sr) * (0.6 + 0.4 * sin(2 * .pi * 4 * Double(i) / sr))) }
        }
        // Rumble all the way through must not count as voice.
        for i in talk.indices { talk[i] += Float(0.2 * sin(2 * .pi * 50 * Double(i) / sr)) }
        let spoken = VoiceActivity.regions(left: talk, right: talk)
        let dips = VoiceActivity.keys(for: spoken, depth: 9, duration: 10)
        let ok = spoken.count == 2 && abs(spoken[0].lowerBound - 2) < 0.1 && abs(spoken[0].upperBound - 4) < 0.1 && abs(spoken[1].lowerBound - 6.5) < 0.1
        let at3 = interpolate(dips, at: 3, log: false) ?? 0, at5 = interpolate(dips, at: 5.2, log: false) ?? 0, at9 = interpolate(dips, at: 9.5, log: false) ?? 0
        check("music ducks under voice", ok && abs(at3 + 9) < 0.01 && abs(at5) < 0.01 && abs(at9) < 0.01,
              "voice at " + spoken.map { String(format: "%.2f–%.2f s", $0.lowerBound, $0.upperBound) }.joined(separator: ", ")
              + String(format: "; music %.1f dB under it, %.1f dB between, %.1f dB after", at3, at5, at9))

        // 9. Marquee delete: taking 2…3 s out of a 0…5 s clip leaves 0…2 and 3…5, the second starting 3 s into the sound.
        var lane = Track(name: "t", kind: .fx)
        lane.clips = [Clip(name: "long", start: 0, duration: 5, takes: [Take(file: "x", duration: 5)]),
                      Clip(name: "inside", start: 2.2, duration: 0.5, takes: [Take(file: "y", duration: 1)]),
                      Clip(name: "later", start: 6, duration: 1, takes: [Take(file: "z", duration: 1)])]
        lane.remove(from: 2, to: 3)
        let parts = lane.clips.sorted { $0.start < $1.start }
        let good = parts.count == 3 && parts[0].name == "long" && abs(parts[0].duration - 2) < 1e-9
            && abs(parts[1].start - 3) < 1e-9 && abs(parts[1].duration - 2) < 1e-9 && abs(parts[1].offset - 3) < 1e-9
            && parts[2].name == "later" && parts[1].id != parts[0].id
        check("marquee delete cuts a stretch out", good,
              parts.map { String(format: "%@ %.1f–%.1f (from %.1f s)", $0.name, $0.start, $0.end, $0.offset) }.joined(separator: ", "))

        // 5. Loudness: 997 Hz at -23 dBFS in both channels reads -23 LUFS, and silence afterwards does not pull it down.
        let meter = LoudnessAnalyzer()
        var last = LoudnessAnalyzer.Reading()
        meter.publish = { last = $0 }
        let tone = (0..<Int(sr * 5)).map { Float(pow(10, -23.0 / 20) * sin(2 * .pi * 997 * Double($0) / sr)) }
        let quiet = [Float](repeating: 0, count: Int(sr * 5))
        for block in [tone, quiet] {
            var i = 0
            while i < block.count {
                let len = min(1024, block.count - i)
                block.withUnsafeBufferPointer { p in meter.feed(p.baseAddress! + i, p.baseAddress! + i, frames: len) }
                i += len
            }
        }
        let integrated = last.integrated ?? -99
        check("loudness meter reads -23 LUFS", abs(integrated + 23) < 0.2 && abs((last.truePeak ?? 0) + 23) < 0.3,
              String(format: "integrated %.2f LUFS after 5 s of silence, true peak %.2f dBTP", integrated, last.truePeak ?? 0))
    }

    /// The 5.1, Lo/Ro and laptop-and-phone fold-downs, checked on 12 channels with known content.
    static func cutChecks(_ check: (String, Bool, String) -> Void) {
        let sr = 48000.0
        var seed: UInt64 = 7
        func noise(_ seconds: Double, _ level: Float) -> [Float] {
            (0..<Int(seconds * sr)).map { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * level
            }
        }
        // 0–3 s quiet room, 3–6 s a room 20 dB louder (a jump at the cut at 3), 6–7 s nothing (dead air), 7–10 s the quiet
        // room again with one sample at full scale, and it is still sounding at the end.
        var x = noise(3, 0.003) + noise(3, 0.03) + [Float](repeating: 0, count: Int(sr)) + noise(3, 0.02)
        x[Int(8.2 * sr)] = 1
        let found = CutCheck.run(l: x, r: x, rate: sr, cuts: [3, 8.6], duration: 10, fps: 25)
        let kinds = found.map(\.kind)
        let jump = found.first { $0.kind == .jump }
        check("cut check finds the four faults", kinds.filter { $0 == .jump }.count == 1 && abs((jump?.time ?? 0) - 3) < 0.01 && kinds.contains(.silence) && kinds.filter { $0 == .peak }.count == 1 && kinds.contains(.chopped),
              found.map { "\($0.kind.rawValue) at \(String(format: "%.1f", $0.time))" }.joined(separator: ", "))
        let even = noise(10, 0.01).enumerated().map { i, v in Float(min(1, Double(10 * 48000 - i) / 48000)) * v }
        let clean = CutCheck.run(l: even, r: even, rate: sr, cuts: [3, 6], duration: 10, fps: 25)
        check("cut check passes an even mix", clean.isEmpty, clean.isEmpty ? "nothing found" : clean.map(\.title).joined(separator: "; "))
    }

    static func downmixChecks(_ check: (String, Bool, String) -> Void) {
        let sr = 48000.0
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func pink(_ seconds: Double, rms target: Double) -> [Float] {
            var b0 = 0.0, b1 = 0.0, b2 = 0.0
            var x = (0..<Int(seconds * sr)).map { _ -> Float in
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let w = Double(seed >> 11) / Double(1 << 53) * 2 - 1
                b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913
                return Float(b0 + b1 + b2 + w * 0.1848)
            }
            let k = Float(target / max(1e-9, rms(x, 0, seconds)))
            for i in x.indices { x[i] *= k }
            return x
        }
        /// `src` placed from `from` to `to` seconds with 10 ms fades.
        func place(_ src: [Float], into dst: inout [Float], from: Double, to: Double) {
            let s = Int(from * sr), e = min(dst.count, Int(to * sr), s + src.count), fade = 480.0
            for i in s..<e {
                let a = min(1, Double(i - s) / fade, Double(e - 1 - i) / fade)
                dst[i] += src[i - s] * Float(0.5 - 0.5 * cos(.pi * a))
            }
        }
        func band(_ x: [Float], hp: Double?, lp: Double?) -> [Float] {
            var y = x
            if let hp { Downmix.highpass(&y, hz: hp); Downmix.highpass(&y, hz: hp) }
            if let lp { Downmix.lowpass(&y, hz: lp); Downmix.lowpass(&y, hz: lp) }
            return y
        }
        func db(_ a: Double, _ b: Double) -> Double { 20 * log10(max(a, 1e-12) / max(b, 1e-12)) }

        // Fold coefficients: one channel at a time, every output measured against the brief's matrix.
        // Inputs: L R C LFE Lrs Rrs Lss Rss Ltf Rtf Ltr Rtr.
        let e51: [[Double]] = [[1, 0, 0, 0, 0, 0, 0, 0, 0.707, 0, 0, 0], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0.707, 0, 0],
                               [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0],
                               [0, 0, 0, 0, 0.707, 0, 1, 0, 0, 0, 0.707, 0], [0, 0, 0, 0, 0, 0.707, 0, 1, 0, 0, 0, 0.707]]
        let eLoRo: [[Double]] = [[1, 0, 0.707, 0, 0.5, 0, 0.707, 0, 0.707, 0, 0.5, 0],
                                 [0, 1, 0.707, 0, 0, 0.5, 0, 0.707, 0, 0.707, 0, 0.5]]
        let src = pink(1, rms: 0.1)
        var worst51 = 0.0, worstLoRo = 0.0
        func off(_ out: [Float], _ g: Double) -> Double {
            let level = rms(out, 0, 1) / rms(src, 0, 1)
            return g == 0 ? (level < 1e-6 ? 0 : 99) : abs(db(level, g))
        }
        for c in 0..<12 {
            var ch = [[Float]](repeating: [Float](repeating: 0, count: src.count), count: 12)
            ch[c] = src
            let f = Downmix.fold51(ch), lr = Downmix.loRo(f)
            for o in 0..<6 { worst51 = max(worst51, off(f[o], e51[o][c])) }
            for o in 0..<2 { worstLoRo = max(worstLoRo, off(lr[o], eLoRo[o][c])) }
        }
        check("5.1 fold coefficients", worst51 <= 0.2, String(format: "worst of 72 paths %.3f dB from the matrix", worst51))
        check("Lo/Ro coefficients", worstLoRo <= 0.2, String(format: "worst of 24 paths %.3f dB from the matrix", worstLoRo))

        // Meters: a full-scale 997 Hz sine in one channel reads -3.01 LUFS; a quarter-rate sine sampled
        // off its peaks reads its true peak, not its sample peak.
        let sine = (0..<Int(5 * sr)).map { Float(sin(2 * .pi * 997 * Double($0) / sr)) }
        let lufs = Downmix.loudness([sine, [Float](repeating: 0, count: sine.count)]) ?? 0
        check("loudness meter", abs(lufs + 3.01) < 0.05, String(format: "%.2f LUFS (expected -3.01)", lufs))
        let quarter = (0..<48000).map { i -> Float in
            let fade = min(1, Double(min(i, 47999 - i)) / 480)   // faded in and out: a hard edge really does overshoot
            return Float(0.5 * sin(.pi * Double(i) / 2 + .pi / 4) * (0.5 - 0.5 * cos(.pi * fade)))
        }
        let tp = Downmix.truePeak([quarter])
        check("true-peak meter", abs(tp + 6.02) < 0.1, String(format: "%.2f dBTP, sample peak %.2f dBFS (expected -6.02 / -9.03)",
                                                             tp, 20 * log10(Double(quarter.map(abs).max()!))))

        // The laptop and phone stereo on a 12 s scene: front 0-3 s and 9-12 s, a side-surround-only source 3-5 s,
        // a height-only source 5-7 s, a 50 Hz burst in the LFE only 7-9 s.
        let n = Int(12 * sr)
        var ch = [[Float]](repeating: [Float](repeating: 0, count: n), count: 12)
        for (a, b) in [(0.0, 3.0), (9.0, 12.0)] {
            place(pink(3, rms: 0.1), into: &ch[2], from: a, to: b)
            place(pink(3, rms: 0.05), into: &ch[0], from: a, to: b)
            place(pink(3, rms: 0.05), into: &ch[1], from: a, to: b)
        }
        place(pink(2, rms: 0.1), into: &ch[6], from: 3, to: 5)
        place(pink(2, rms: 0.1), into: &ch[8], from: 5, to: 7)
        place((0..<Int(2 * sr)).map { Float(0.1 * sin(2 * .pi * 50 * Double($0) / sr)) }, into: &ch[3], from: 7, to: 9)

        let t0 = Date()
        let sp = Downmix.speakers(ch)
        let lr = Downmix.loRo(Downmix.fold51(ch))
        print("      laptop and phone: \(sp.summary) Widening \(Int(sp.widening * 100))%, limiting \(String(format: "%.1f", sp.limiting)) dB, \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let got = sp.lufs ?? -99
        check("speakers: loudness", abs(got + 14) <= 0.5, String(format: "%.2f LUFS (target -14)", got))
        check("speakers: true peak", sp.truePeak <= -1.0, String(format: "%.2f dBTP (ceiling -1)", sp.truePeak))
        check("speakers: mono", sp.monoLoss <= 3.0, String(format: "mono loses %.2f dB, correlation %.2f", sp.monoLoss, sp.correlation))

        // Width, while only the left side surround plays: side (L-R) against mid (L+R) in the band the widening
        // works in (300 Hz-6 kHz), and the level difference at the ears in a simple model of two close speakers
        // (each ear also hears the far speaker 2 dB down: 0.125 ms late for a laptop, 0.083 ms for a phone).
        func sideOverMid(_ l: [Float], _ r: [Float], _ a: Double, _ b: Double) -> Double {
            var m = l, s = l
            for i in m.indices { m[i] = (l[i] + r[i]) / 2; s[i] = (l[i] - r[i]) / 2 }
            return db(rms(band(s, hp: 300, lp: 6000), a, b), rms(band(m, hp: 300, lp: 6000), a, b))
        }
        func ears(_ l: [Float], _ r: [Float], late d: Int, _ a: Double, _ b: Double) -> Double {
            var el = l, er = r
            for i in d..<l.count { el[i] += 0.8 * r[i - d]; er[i] += 0.8 * l[i - d] }
            return db(rms(band(el, hp: 300, lp: 6000), a, b), rms(band(er, hp: 300, lp: 6000), a, b))
        }
        let wideSp = sideOverMid(sp.left, sp.right, 3.3, 4.7), wideLr = sideOverMid(lr[0], lr[1], 3.3, 4.7)
        let earSp = ears(sp.left, sp.right, late: 6, 3.3, 4.7), earLr = ears(lr[0], lr[1], late: 6, 3.3, 4.7)
        check("speakers: surround is wider than Lo/Ro", wideSp >= wideLr + 1 && earSp >= earLr + 2,
              String(format: "side/mid %+.1f dB vs Lo/Ro %+.1f dB; ears %.1f dB apart vs %.1f (laptop), %.1f vs %.1f (phone)",
                     wideSp, wideLr, earSp, earLr, ears(sp.left, sp.right, late: 4, 3.3, 4.7), ears(lr[0], lr[1], late: 4, 3.3, 4.7)))
        func monoDrop(_ l: [Float], _ r: [Float], _ a: Double, _ b: Double) -> Double {
            var m = l
            for i in m.indices { m[i] = (l[i] + r[i]) / 2 }
            return db(rms(m, a, b), ((rms(l, a, b) * rms(l, a, b) + rms(r, a, b) * rms(r, a, b)) / 2).squareRoot())
        }
        print(String(format: "      surround source in mono: %.1f dB against its stereo (Lo/Ro %.1f dB)",
                     monoDrop(sp.left, sp.right, 3.3, 4.7), monoDrop(lr[0], lr[1], 3.3, 4.7)))

        // Height: top end (above 8 kHz) against 1-4 kHz, the height source against the front source of the same noise.
        func tilt(_ x: [Float], _ a: Double, _ b: Double) -> Double {
            db(rms(band(x, hp: 8000, lp: nil), a, b), rms(band(x, hp: 1000, lp: 4000), a, b))
        }
        let lift = tilt(sp.left, 5.3, 6.7) - tilt(sp.left, 0.3, 2.7), liftLr = tilt(lr[0], 5.3, 6.7) - tilt(lr[0], 0.3, 2.7)
        check("speakers: height shelf", lift >= 2.5 && lift <= 5,
              String(format: "+%.1f dB above 8 kHz against the front (Lo/Ro %+.1f dB)", lift, liftLr))

        // Bass: the 50 Hz burst in the LFE alone must show up between 150 and 400 Hz.
        let harm = rms(band(sp.left, hp: 150, lp: 400), 7.3, 8.7), fund = rms(band(sp.left, hp: nil, lp: 100), 7.3, 8.7)
        let harmLr = rms(band(lr[0], hp: 150, lp: 400), 7.3, 8.7)
        check("speakers: LFE heard as harmonics", fund > 0 && db(harm, fund) > -20 && db(harm, fund) < -10,
              String(format: "150-400 Hz at %.1f dB under the 50 Hz tone (Lo/Ro: %.1f dBFS there, no LFE)", -db(harm, fund), 20 * log10(max(harmLr, 1e-9))))

        // Mono safety on a mix of nothing but uncorrelated side surrounds (3 dB mono loss before any widening):
        // the widening has to back off.
        var wide = [[Float]](repeating: [Float](repeating: 0, count: Int(6 * sr)), count: 12)
        place(pink(6, rms: 0.1), into: &wide[6], from: 0, to: 6)
        place(pink(6, rms: 0.1), into: &wide[7], from: 0, to: 6)
        let sw = Downmix.speakers(wide)
        check("speakers: widening backs off for mono", sw.widening < 1 && (sw.monoLoss < 3.05 || sw.widening == 0),
              String(format: "surround-only mix: widening %.0f%%, mono loses %.2f dB, correlation %.2f: \"%@\"",
                     sw.widening * 100, sw.monoLoss, sw.correlation, sw.summary))

        // A quiet mix with sharp peaks: no more than 12 dB of limiting, and the summary says it stopped short.
        var quiet = [[Float]](repeating: [Float](repeating: 0, count: Int(6 * sr)), count: 12)
        place(pink(6, rms: 0.003), into: &quiet[2], from: 0, to: 6)
        for k in 1..<12 { quiet[2][k * 24000] = 0.5 }
        let sq = Downmix.speakers(quiet)
        check("speakers: limiting is capped", sq.limiting <= 12.05 && sq.short > 0.3 && sq.truePeak <= -1.0,
              String(format: "%.1f LUFS, %.1f dB limiting, %.2f dBTP: \"%@\"", sq.lufs ?? -99, sq.limiting, sq.truePeak, sq.summary))
    }
}
