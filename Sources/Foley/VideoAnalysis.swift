import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum VideoAnalysis {
    static func info(_ url: URL) async throws -> VideoRef {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError(message: "That file has no video track.")
        }
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        return VideoRef(path: url.path, duration: duration, fps: fps > 1 ? (fps * 1000).rounded() / 1000 : 30, width: Int(size.width), height: Int(size.height))
    }

    /// Hard-cut detection: decodes at thumbnail size and looks for frames that differ sharply from the one before.
    static func detectCuts(_ url: URL) async -> [Double] {
        cuts(from: await frameDifferences(url))
    }

    /// Mean absolute colour difference between each frame and the one before it, 0…1.
    static func frameDifferences(_ url: URL) async -> [(t: Double, d: Double)] {
        await Task.detached(priority: .userInitiated) { () -> [(t: Double, d: Double)] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let w = 64, h = 36, n = w * h * 3
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return [] }
            var prev = [UInt8](repeating: 0, count: n), cur = [UInt8](repeating: 0, count: n)
            var hasPrev = false
            var samples: [(t: Double, d: Double)] = []
            while let sb = output.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                if let basePtr = CVPixelBufferGetBaseAddress(pb) {
                    let rowBytes = CVPixelBufferGetBytesPerRow(pb)
                    let pw = min(w, CVPixelBufferGetWidth(pb)), ph = min(h, CVPixelBufferGetHeight(pb))
                    let p = basePtr.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<ph {
                        for x in 0..<pw {
                            let o = y * rowBytes + x * 4, q = (y * w + x) * 3
                            cur[q] = p[o]; cur[q + 1] = p[o + 1]; cur[q + 2] = p[o + 2]
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                if hasPrev {
                    var sum = 0
                    for i in 0..<n { sum += abs(Int(cur[i]) - Int(prev[i])) }
                    samples.append((CMSampleBufferGetPresentationTimeStamp(sb).seconds, Double(sum) / Double(n) / 255))
                }
                swap(&prev, &cur)
                hasPrev = true
            }
            return samples.sorted { $0.t < $1.t }
        }.value
    }

    /// A cut is either a big jump against recent motion, or a smaller jump that stands alone:
    /// one frame very different from its neighbours on both sides. The second rule catches cuts
    /// between similar-looking shots (green field to green field) that the first one misses.
    static func cuts(from samples: [(t: Double, d: Double)]) -> [Double] {
        var cuts: [Double] = []
        for i in samples.indices {
            let recent = samples[max(0, i - 8)..<i].map(\.d).sorted()
            let median = recent.isEmpty ? 0 : recent[recent.count / 2]
            let d = samples[i].d
            let before = i > 0 ? samples[i - 1].d : 0
            let after = i + 1 < samples.count ? samples[i + 1].d : 0
            let big = d > 0.09 && d > (median + 0.012) * 3
            let isolated = d > 0.035 && d > 3.5 * max(before, after) + 0.01
            if big || isolated, samples[i].t - (cuts.last ?? 0) > 0.3, samples[i].t > 0.2 {
                cuts.append(samples[i].t)
            }
        }
        return cuts
    }

    static func frame(_ url: URL, at t: Double, maxSize: CGFloat, exact: Bool = true) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        if exact {
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
        }
        return try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func filmstrip(_ url: URL, duration: Double, count: Int) async -> [NSImage] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 120)
        var out: [NSImage] = []
        for i in 0..<count {
            let t = (Double(i) + 0.5) / Double(count) * duration
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                out.append(NSImage(cgImage: img, size: .zero))
            }
        }
        return out
    }
}
