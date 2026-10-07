import Accelerate
import AVFoundation
import CryptoKit
import SwiftUI

/// Waveform of a track for the seek bar: `Waveform.buckets` loudness levels (0…1) over the track (or a cue
/// track's segment). Computed in the background the first time a track plays, then cached in
/// ~/Library/Application Support/MusicAmp/Waveforms (one byte per bucket).
struct Waveform: Equatable {
    static let buckets = 512
    let peaks: [Float]

    /// Peak level at a fraction (0…1) of the track, the loudest bucket in [from, to).
    func level(from a: Double, to b: Double) -> Float {
        let n = peaks.count
        let i0 = max(0, min(n - 1, Int(a * Double(n))))
        let i1 = max(i0 + 1, min(n, Int((b * Double(n)).rounded(.up))))
        var m: Float = 0
        for i in i0..<i1 { m = max(m, peaks[i]) }
        return m
    }
}

final class WaveformStore {
    static let shared = WaveformStore()

    private var memory: [URL: Waveform] = [:]
    private var pending = Set<URL>()
    private let queue = DispatchQueue(label: "musicamp.waveform", qos: .utility)
    /// Called on the main thread when a waveform becomes available.
    var onReady: ((URL) -> Void)?

    static var folder: URL {
        let u = PlayStats.file.deletingLastPathComponent().appendingPathComponent("Waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The waveform of a local track, or nil while it's being computed (it then calls `onReady`).
    /// Streams and remote episodes have none: the seek bar stays classic.
    func waveform(for url: URL) -> Waveform? {
        if let w = memory[url] { return w }
        guard url.isFileURL, !pending.contains(url) else { return nil }
        pending.insert(url)
        queue.async { [weak self] in
            let w = WaveformStore.cached(url) ?? WaveformStore.compute(url).map { w in WaveformStore.store(w, for: url); return w }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(url)
                guard let w else { return }
                if self.memory.count > 64 { self.memory.removeAll() }
                self.memory[url] = w
                self.onReady?(url)
            }
        }
        return nil
    }

    // MARK: Cache

    /// File name: hash of the URL (with any #track=) and the audio file's size and date, so edits recompute.
    private static func cacheFile(_ url: URL) -> URL? {
        let audio = CueSheet.audioURL(url)
        guard let v = try? audio.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let key = "v3|\(url.absoluteString)|\(v.fileSize ?? 0)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".wave")
    }

    static func cached(_ url: URL) -> Waveform? {
        guard let f = cacheFile(url), let d = try? Data(contentsOf: f), d.count == Waveform.buckets else { return nil }
        return Waveform(peaks: d.map { Float($0) / 255 })
    }

    private static func store(_ w: Waveform, for url: URL) {
        guard let f = cacheFile(url) else { return }
        try? Data(w.peaks.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }).write(to: f, options: .atomic)
    }

    // MARK: Computing

    static func compute(_ url: URL) -> Waveform? {
        let file = CueSheet.audioURL(url)
        let seg = CueSheet.segment(url)
        let ext = file.pathExtension.lowercased()
        if !FFmpeg.extensions.contains(ext), let f = try? AVAudioFile(forReading: file) {
            return native(f, start: seg?.start ?? 0, end: seg?.end)
        }
        return FFmpeg.available ? viaFFmpeg(file, start: seg?.start ?? 0, end: seg?.end) : nil
    }

    /// Reads the file in blocks (decoding is the cost: ~0.2–0.5 s for a 4-minute MP3).
    private static func native(_ f: AVAudioFile, start: Double, end: Double?) -> Waveform? {
        let rate = f.processingFormat.sampleRate
        let first = AVAudioFramePosition(start * rate)
        let last = min(f.length, end.map { AVAudioFramePosition($0 * rate) } ?? f.length)
        let total = last - first
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536) else { return nil }
        f.framePosition = first
        var sums = [Double](repeating: 0, count: Waveform.buckets)
        var counts = [Int](repeating: 0, count: Waveform.buckets)
        var done: AVAudioFramePosition = 0
        let channels = Int(f.processingFormat.channelCount)
        while done < total {
            buf.frameLength = 0
            let want = AVAudioFrameCount(min(Int64(buf.frameCapacity), total - done))
            guard (try? f.read(into: buf, frameCount: want)) != nil, buf.frameLength > 0, let d = buf.floatChannelData else { break }
            let n = Int(buf.frameLength)
            var i = 0
            while i < n {
                // One bucket's share of this block at a time.
                let b = Int((done + AVAudioFramePosition(i)) * AVAudioFramePosition(Waveform.buckets) / total)
                let bucketEnd = Int((AVAudioFramePosition(b + 1) * total + AVAudioFramePosition(Waveform.buckets) - 1) / AVAudioFramePosition(Waveform.buckets) - done)
                let j = min(n, max(i + 1, bucketEnd))
                var sq: Float = 0
                for c in 0..<channels {
                    var part: Float = 0
                    vDSP_svesq(d[c] + i, 1, &part, vDSP_Length(j - i))
                    sq += part
                }
                sums[b] += Double(sq)
                counts[b] += (j - i) * channels
                i = j
            }
            done += AVAudioFramePosition(n)
        }
        return done > 0 ? normalized(zip(sums, counts).map { $1 > 0 ? Float(sqrt($0 / Double($1))) : 0 }) : nil
    }

    /// Asks ffmpeg for mono 4 kHz floats: plenty for 512 buckets, and fast.
    static func viaFFmpeg(_ file: URL, start: Double, end: Double?) -> Waveform? {
        guard let ff = FFmpeg.ffmpegPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        var args = ["-v", "quiet", "-nostdin"]
        if start > 0 { args += ["-ss", String(start)] }
        args += ["-i", file.path]
        if let end { args += ["-t", String(end - start)] }
        args += ["-vn", "-ac", "1", "-ar", "4000", "-f", "f32le", "-"]
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !samples.isEmpty else { return nil }
        var sums = [Double](repeating: 0, count: Waveform.buckets)
        var counts = [Int](repeating: 0, count: Waveform.buckets)
        for (i, v) in samples.enumerated() {
            let b = i * Waveform.buckets / samples.count
            sums[b] += Double(v * v)
            counts[b] += 1
        }
        return normalized(zip(sums, counts).map { $1 > 0 ? Float(sqrt($0 / Double($1))) : 0 })
    }

    /// Loudness (RMS) of each bucket, stretched between the track's quiet floor (half its 10th percentile)
    /// and its loudest bucket, so that loud, compressed masters still show verses, choruses and breaks
    /// instead of a solid band. Real silence stays at 0.
    static func normalized(_ rms: [Float]) -> Waveform {
        let top = max(rms.max() ?? 0, 1e-5)
        let sorted = rms.sorted()
        let floor = min(sorted[sorted.count / 10] * 0.5, top * 0.5)
        return Waveform(peaks: rms.map { v in
            guard v > top * 0.003 else { return 0 }
            let x = max(0, min(1, (v - floor) / (top - floor)))
            return 0.08 + 0.92 * pow(x, 1.3)
        })
    }
}

// MARK: - Drawing in the skin's position bar

extension Renderer {
    /// The waveform inside the position bar groove (`rect`, 1x skin coordinates), in the skin's oscilloscope
    /// colour: bright where already played, dimmed ahead. `playX` is the playhead (thumb centre).
    /// Columns are device pixels, so Retina screens get twice the detail while the sprites stay pixel-exact.
    func drawWaveform(_ w: Waveform, in rect: CGRect, playX: CGFloat, played: CGColor, ahead: CGColor) {
        clip(rect) { drawWaveformColumns(w, in: rect, playX: playX, played: played, ahead: ahead) }
    }

    private func drawWaveformColumns(_ w: Waveform, in rect: CGRect, playX: CGFloat, played: CGColor, ahead: CGColor) {
        let px = CGFloat(pixelScale)
        let cols = Int(rect.width * px)
        let mid = rect.midY
        let edge = Renderer.isLight(played) ? CGColor(gray: 0, alpha: 0.45) : CGColor(gray: 1, alpha: 0.55)
        let half = rect.height / 2
        for c in 0..<cols {
            let x0 = rect.minX + CGFloat(c) / px
            let level = CGFloat(w.level(from: Double(c) / Double(cols), to: Double(c + 1) / Double(cols)))
            // At least one device pixel, so silence still reads as a line.
            let h = max(1 / px, (level * half * px).rounded() / px)
            let col = CGRect(x: x0, y: mid - h, width: 1 / px, height: h * 2)
            // A one-device-pixel edge in the opposite tone keeps the shape readable on any bar (light tubes, dark grooves).
            fill(edge, col.insetBy(dx: 0, dy: -1 / px))
            fill(x0 + 0.5 / px < playX ? played : ahead, col)
        }
    }
}

extension Renderer {
    static func isLight(_ c: CGColor) -> Bool {
        let k = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        guard k.count >= 3 else { return (k.first ?? 0) > 0.55 }
        return 0.299 * k[0] + 0.587 * k[1] + 0.114 * k[2] > 0.55
    }
}

extension Skin {
    /// Waveform colours from viscolor.txt: of the analyzer and oscilloscope colours, the one standing out most
    /// from the bar's groove (a spectrum green on the classic skin; each skin its own), and the same at 35% for
    /// the part still to play (60%).
    var waveformColors: (played: CGColor, ahead: CGColor) {
        if let c = Skin.colorCache[ObjectIdentifier(self)] { return (c, c.copy(alpha: 0.6) ?? c) }
        let rows = Skin.grooveLumas(image("posbar"), waveformRect)
        let candidates = visColors.count > 22 ? [12, 11, 13, 10, 14, 9, 8, 7, 2, 18, 19, 20, 21, 22].map { visColors[$0] } : visColors
        func luma(_ c: CGColor) -> Double {
            let k = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
            return 0.299 * Double(k[0]) + 0.587 * Double(k[min(1, k.count - 1)]) + 0.114 * Double(k[min(2, k.count - 1)])
        }
        // The preferred order wins unless a later colour is clearly more visible.
        var best = candidates.first ?? CGColor(srgbRed: 0.16, green: 0.81, blue: 0.06, alpha: 1)
        var bestScore = -1.0
        for (i, c) in candidates.enumerated() {
            // Contrast with the least contrasting row of the groove (bars often mix dark lines and light bevels).
            let score = (rows.map { abs(luma(c) - $0) }.min() ?? 1) - Double(i) * 0.01
            if score > bestScore { bestScore = score; best = c }
            if i == 0, score > 0.3 { break }
        }
        Skin.colorCache[ObjectIdentifier(self)] = best
        return (best, best.copy(alpha: 0.6) ?? best)
    }

    private static var colorCache: [ObjectIdentifier: CGColor] = [:]

    /// Average luminance (0…1) of each row of posbar.bmp inside the waveform's rectangle (transparent = black).
    static func grooveLumas(_ img: CGImage?, _ r: CGRect) -> [Double] {
        guard let img, img.width >= 248, img.height >= 10,
              let bar = img.cropping(to: CGRect(x: 0, y: 0, width: 248, height: 10)),
              let ctx = CGContext(data: nil, width: 248, height: 10, bitsPerComponent: 8, bytesPerRow: 248 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [0] }
        ctx.draw(bar, in: CGRect(x: 0, y: 0, width: 248, height: 10))
        let px = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 248 * 10 * 4)
        var out: [Double] = []
        for row in Int(r.minY - 72)..<Int(r.maxY - 72) {
            var sum = 0.0, n = 0
            for x in Int(r.minX - 16)..<Int(r.maxX - 16) where x < 248 {
                let i = (row * 248 + x) * 4
                sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
                n += 1
            }
            if n > 0 { out.append(sum / Double(n) / 255) }
        }
        return out.isEmpty ? [0] : out
    }

    private static var grooves: [ObjectIdentifier: CGRect] = [:]

    /// Where the waveform goes inside the position bar (1x main-window coordinates): the bar's dark groove,
    /// found from posbar.bmp's rows, one pixel taller on each side; the whole bar when it has no clear groove.
    var waveformRect: CGRect {
        if let r = Skin.grooves[ObjectIdentifier(self)] { return r }
        let r = Skin.findGroove(image("posbar"))
        Skin.grooves[ObjectIdentifier(self)] = r
        return r
    }

    static func findGroove(_ img: CGImage?) -> CGRect {
        let full = CGRect(x: 30, y: 73, width: 219, height: 8)
        guard let img, img.width >= 248, img.height >= 10,
              let ctx = CGContext(data: nil, width: 248, height: 10, bitsPerComponent: 8, bytesPerRow: 248 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bar = img.cropping(to: CGRect(x: 0, y: 0, width: 248, height: 10)) else { return full }
        ctx.draw(bar, in: CGRect(x: 0, y: 0, width: 248, height: 10))
        let px = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 248 * 10 * 4)
        // Average luminance of each row (top to bottom) over the thumb's travel.
        var lum = [Double](repeating: 0, count: 10)
        for row in 0..<10 {
            var sum = 0.0
            for x in 14..<233 {
                let i = (row * 248 + x) * 4
                sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
            }
            lum[row] = sum / 219
        }
        guard let lo = lum.min(), let hi = lum.max(), hi - lo > 20, let darkest = lum.firstIndex(of: lo) else { return full }
        let limit = lo + 0.35 * (hi - lo)
        var top = darkest, bottom = darkest
        while top > 0, lum[top - 1] <= limit { top -= 1 }
        while bottom < 9, lum[bottom + 1] <= limit { bottom += 1 }
        top = max(0, top - 1)
        bottom = min(9, bottom + 1)
        let h = bottom - top + 1
        guard h >= 4 else { return full }
        return CGRect(x: 30, y: 72 + CGFloat(top), width: 219, height: CGFloat(h))
    }
}

// MARK: - SwiftUI version (album art view)

/// The same waveform as a seek bar for the album art view.
struct WaveformBar: View {
    let waveform: Waveform
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            let bars = max(1, Int(size.width / 3))
            let bw = size.width / CGFloat(bars)
            for i in 0..<bars {
                let a = Double(i) / Double(bars), b = Double(i + 1) / Double(bars)
                let h = max(2, CGFloat(waveform.level(from: a, to: b)) * size.height)
                let r = CGRect(x: CGFloat(i) * bw + 0.5, y: (size.height - h) / 2, width: bw - 1, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(.white.opacity(a < progress ? 0.9 : 0.28)))
            }
        }
    }
}
