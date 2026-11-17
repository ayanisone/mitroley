import Foundation

// mitroley. Copyright © 2026 Ayan Mitra. All rights reserved.

/// The master effects a session can pull in. Nothing is applied unless it is in the rack and switched on.
enum EffectKind: String, Codable, CaseIterable, Identifiable {
    case compressor, limiter, surroundReverb, trims, loudness
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compressor: "Compressor"
        case .limiter: "Limiter"
        case .surroundReverb: "Surround reverb"
        case .trims: "Fold-down trims"
        case .loudness: "Loudness meter"
        }
    }

    var detail: String {
        switch self {
        case .compressor: "Evens out levels. Linked across every channel: it listens to the loudest one and turns all of them down together, so the image never moves."
        case .limiter: "Stops peaks at a true-peak ceiling on every channel, linked the same way. Also holds the 5.1 and stereo fold-downs under the ceiling."
        case .surroundReverb: "In surround exports, gives the side, rear and height speakers their own decorrelated copy of each space's reverb, so the room wraps around the listener. Without it, they play the same reverb as the front."
        case .trims: "How loud the surrounds and heights are when the 7.1.4 mix is folded to 5.1, stereo or laptop and phone. The 7.1.4 itself is not changed."
        case .loudness: "Momentary, short-term and integrated loudness and true peak of what is playing, and a measurement of the full mix in every format. Changes nothing in the sound."
        }
    }

    struct Param: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let range: ClosedRange<Double>
        let fallback: Double
        var log = false
        let format: String
        var scale = 1.0     // shown value = stored value × scale
    }

    var params: [Param] {
        switch self {
        case .compressor:
            [Param(key: "threshold", title: "Threshold", range: -48...0, fallback: -18, format: "%.1f dB"),
             Param(key: "ratio", title: "Ratio", range: 1...12, fallback: 3, format: "%.1f : 1"),
             Param(key: "attack", title: "Attack", range: 0.5...120, fallback: 10, log: true, format: "%.0f ms"),
             Param(key: "release", title: "Release", range: 20...1200, fallback: 150, log: true, format: "%.0f ms"),
             Param(key: "makeup", title: "Make-up", range: 0...18, fallback: 0, format: "%+.1f dB")]
        case .limiter:
            [Param(key: "ceiling", title: "Ceiling", range: -6...0, fallback: -1, format: "%.1f dBTP"),
             Param(key: "release", title: "Release", range: 20...800, fallback: 120, log: true, format: "%.0f ms")]
        case .surroundReverb:
            [Param(key: "spread", title: "Spread", range: 0...1, fallback: 1, format: "%.0f%%", scale: 100)]
        case .trims:
            [Param(key: "surround", title: "Surrounds", range: -12...6, fallback: 0, format: "%+.1f dB"),
             Param(key: "height", title: "Heights", range: -12...6, fallback: 0, format: "%+.1f dB")]
        case .loudness:
            [Param(key: "target", title: "Target", range: -30...(-8), fallback: -14, format: "%.0f LUFS")]
        }
    }
}

struct Effect: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: EffectKind
    var on = true
    var values: [String: Double] = [:]

    func value(_ key: String) -> Double {
        values[key] ?? kind.params.first { $0.key == key }?.fallback ?? 0
    }
}

extension Project {
    /// The rack, in signal order. Sessions saved before the rack existed carry their old master settings over.
    var effects: [Effect] {
        if let rack { return rack }
        var out: [Effect] = []
        if let d = dynamics {
            if d.compressor {
                out.append(Effect(kind: .compressor, values: ["threshold": d.threshold, "ratio": d.ratio, "attack": d.attack, "release": d.release, "makeup": d.makeup]))
            }
            if d.limiter { out.append(Effect(kind: .limiter, values: ["ceiling": d.ceiling, "release": d.limiterRelease])) }
        }
        if surroundTrim != nil || heightTrim != nil {
            out.append(Effect(kind: .trims, values: ["surround": surroundTrim ?? 0, "height": heightTrim ?? 0]))
        }
        return out
    }

    /// The effect of a kind if it is in the rack and switched on.
    func active(_ kind: EffectKind) -> Effect? { effects.first { $0.kind == kind && $0.on } }

    /// Compressor and limiter settings for the bus processor; both off when neither is in the rack.
    var bus: BusDynamics {
        var d = BusDynamics()
        d.compressor = false
        d.limiter = false
        if let c = active(.compressor) {
            d.compressor = true
            d.threshold = c.value("threshold"); d.ratio = c.value("ratio"); d.attack = c.value("attack")
            d.release = c.value("release"); d.makeup = c.value("makeup")
        }
        if let l = active(.limiter) {
            d.limiter = true
            d.ceiling = l.value("ceiling"); d.limiterRelease = l.value("release")
        }
        return d
    }

    /// 0 = the surrounds play the front's reverb; 1 = each pair has its own.
    var surroundSpread: Double { active(.surroundReverb)?.value("spread") ?? 0 }

    var foldTrims: (surround: Double, height: Double) {
        guard let t = active(.trims) else { return (0, 0) }
        return (t.value("surround"), t.value("height"))
    }

    mutating func setRack(_ r: [Effect]) {
        let order = EffectKind.allCases
        rack = r.sorted { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
        dynamics = nil; surroundTrim = nil; heightTrim = nil
    }

    /// Changes the effect of a kind, adding it first if the rack does not have one.
    mutating func withEffect(_ kind: EffectKind, _ change: (inout Effect) -> Void) {
        var r = effects
        if let i = r.firstIndex(where: { $0.kind == kind }) { change(&r[i]) } else {
            var e = Effect(kind: kind)
            change(&e)
            r.append(e)
        }
        setRack(r)
    }

    mutating func removeEffect(_ kind: EffectKind) {
        setRack(effects.filter { $0.kind != kind })
    }
}
