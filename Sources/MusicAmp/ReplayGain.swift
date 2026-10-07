import AVFoundation
import Foundation

/// ReplayGain: tag values when present (ID3 TXXX, Vorbis/FLAC comments, iTunes "----" atoms), otherwise an
/// EBU R128 / BS.1770 integrated-loudness scan of the file, cached on disk. Reference level -18 LUFS (RG 2.0).
final class ReplayGain {
    static let shared = ReplayGain()

    enum Mode: Int { case off = 0, track = 1, album = 2 }

    struct Info: Codable {
        var trackGain: Double?
        var trackPeak: Double?
        var albumGain: Double?
        var albumPeak: Double?
        var analyzed = false
        var stamp: String   // size + modification date: re-scan when the file changes
    }

    var mode: Mode = .track
    /// Extra dB on top of the computed gain.
    var preamp: Double = 0
    var analyzeUntagged = true
    var preventClipping = true
    /// Called on the main thread when a file's values become known.
    var onUpdate: ((URL) -> Void)?

    private var cache: [String: Info] = [:]
    private var pending = Set<String>()
    private let work = DispatchQueue(label: "musicamp.replaygain", qos: .utility)
    private var saveScheduled = false

    private var cacheURL: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("replaygain.json")
    }

    private init() {
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode([String: Info].self, from: d) { cache = c }
    }

    static func stamp(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(v?.fileSize ?? 0)-\(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
    }

    func info(_ url: URL) -> Info? {
        guard let i = cache[url.path], i.stamp == Self.stamp(url) else { return nil }
        return i
    }

    /// dB to apply now (0 when off). Unknown files are looked up in the background; `onUpdate` fires when ready.
    func gain(for url: URL) -> Float {
        guard mode != .off, url.isFileURL else { return 0 }
        guard let i = info(url) else { lookup(url); return Float(preamp) }
        let g = (mode == .album ? i.albumGain ?? i.trackGain : i.trackGain) ?? 0
        let peak = (mode == .album ? i.albumPeak ?? i.trackPeak : i.trackPeak) ?? 0
        var db = g + preamp
        if preventClipping, peak > 0 { db = min(db, -20 * log10(peak)) }
        return Float(max(-24, min(24, db)))
    }

    /// Reads tags, falling back to a loudness scan. Background; results land in the cache.
    func lookup(_ url: URL) {
        let key = url.path
        guard url.isFileURL, !pending.contains(key) else { return }
        pending.insert(key)
        let analyze = analyzeUntagged
        work.async { [weak self] in
            var i = Self.readTags(url) ?? Info(stamp: Self.stamp(url))
            i.stamp = Self.stamp(url)
            if i.trackGain == nil, analyze, let (lufs, peak) = Self.measure(url) {
                i.trackGain = -18 - lufs
                i.trackPeak = peak
                i.analyzed = true
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(key)
                self.cache[key] = i
                self.scheduleSave()
                self.onUpdate?(url)
            }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(self.cache) { try? d.write(to: self.cacheURL, options: .atomic) }
        }
    }

    // MARK: Tags

    /// Scans the first and last 512 KB for "replaygain_*" keys; the value is the first number after the key.
    /// Covers ID3v2 TXXX (MP3), Vorbis comments (FLAC/Ogg) and iTunes freeform atoms (M4A, often at the end).
    static func readTags(_ url: URL) -> Info? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        var blob = (try? h.read(upToCount: 512 * 1024)) ?? Data()
        if size > 1024 * 1024 {
            try? h.seek(toOffset: size - 512 * 1024)
            blob += (try? h.read(upToCount: 512 * 1024)) ?? Data()
        }
        let text = String(decoding: blob.filter { $0 != 0 }, as: UTF8.self).lowercased()   // drop NULs: also reads UTF-16 ID3 frames
        func value(_ key: String) -> Double? {
            guard let r = text.range(of: key) else { return nil }
            let tail = text[r.upperBound...].prefix(64)
            guard let n = tail.range(of: #"[-+]?\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
            return Double(tail[n].replacingOccurrences(of: "+", with: ""))
        }
        var i = Info(trackGain: value("replaygain_track_gain"), trackPeak: value("replaygain_track_peak"),
                     albumGain: value("replaygain_album_gain"), albumPeak: value("replaygain_album_peak"),
                     stamp: stamp(url))
        // Opus (RFC 7845): R128_TRACK_GAIN is Q7.8 dB relative to -23 LUFS; ReplayGain's reference is -18 LUFS.
        if i.trackGain == nil, let r = value("r128_track_gain") { i.trackGain = r / 256 + 5 }
        if i.albumGain == nil, let r = value("r128_album_gain") { i.albumGain = r / 256 + 5 }
        return i.trackGain == nil && i.albumGain == nil ? nil : i
    }

    // MARK: EBU R128 integrated loudness (ITU-R BS.1770-4)

    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// K-weighting for sample rate `fs`: a high-shelf (+4 dB above ~1.7 kHz) and a ~38 Hz high-pass.
    static func kWeighting(_ fs: Double) -> [Biquad] {
        var k = tan(.pi * 1681.974450955533 / fs)
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416), q1 = 0.7071752369554196
        var a0 = 1 + k / q1 + k * k
        let shelf = Biquad(b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
        k = tan(.pi * 38.13547087602444 / fs)
        let q2 = 0.5003270373238773
        a0 = 1 + k / q2 + k * k
        let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
        return [shelf, hp]
    }

    /// Integrated loudness (LUFS) and sample peak of a file. 400 ms blocks with 75% overlap,
    /// absolute gate -70 LUFS, relative gate -10 LU.
    static func measure(_ url: URL) -> (Double, Double)? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.processingFormat
        let fs = fmt.sampleRate, chans = min(Int(fmt.channelCount), 5)
        guard chans > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fs)) else { return nil }
        var filters = (0..<chans).map { _ in kWeighting(fs) }
        let step = Int(fs / 10)   // 100 ms
        var stepEnergy: [Double] = []
        var acc = 0.0, n = 0
        var peak = 0.0
        while f.framePosition < f.length {
            do { try f.read(into: buf) } catch { break }
            guard buf.frameLength > 0, let data = buf.floatChannelData else { break }
            for i in 0..<Int(buf.frameLength) {
                var e = 0.0
                for c in 0..<chans {
                    let x = Double(data[c][i])
                    peak = max(peak, abs(x))
                    var y = x
                    for k in 0..<2 { y = filters[c][k].run(y) }
                    e += y * y   // channel weight 1.0 (L, R, C)
                }
                acc += e
                n += 1
                if n == step {
                    stepEnergy.append(acc / Double(step))
                    acc = 0
                    n = 0
                }
            }
        }
        guard stepEnergy.count >= 4 else { return nil }
        let blocks = (0...(stepEnergy.count - 4)).map { stepEnergy[$0..<($0 + 4)].reduce(0, +) / 4 }
        func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(max(e, 1e-12)) }
        let abs = blocks.filter { lufs($0) > -70 }
        guard !abs.isEmpty else { return (-70, peak) }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        guard !gated.isEmpty else { return (-70, peak) }
        return (lufs(gated.reduce(0, +) / Double(gated.count)), peak)
    }
}
