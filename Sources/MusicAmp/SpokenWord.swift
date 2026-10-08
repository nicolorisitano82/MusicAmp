import Accelerate
import AVFoundation
import CryptoKit

/// Podcasts and audiobooks, like Overcast's Voice Boost and Smart Speed:
/// - Voice Boost: a speech EQ (rumble cut below 80 Hz, a little less boom at 250 Hz, presence at 3 kHz) and Apple's
///   dynamics processor (gentle compression + make-up gain), so quiet hosts, loud guests and noisy rooms even out.
/// - Shorten silences: a map of the pauses, computed in the background from the file; during a pause the engine
///   plays 4× faster, keeping a quarter of a second of natural pause at each end. Local files only (downloaded
///   episodes, audiobooks): a streamed episode has no file to map yet.
enum SpokenWord {
    /// Episodes and audiobooks get the spoken-word treatment; music never does.
    static func isSpoken(_ t: Track) -> Bool {
        t.isEpisode || ["m4b", "aa", "aax"].contains(t.url.pathExtension.lowercased())
    }

    // MARK: Voice Boost chain

    static func makeVoiceEQ() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let b = eq.bands
        b[0].filterType = .highPass; b[0].frequency = 80; b[0].bypass = false
        b[1].filterType = .parametric; b[1].frequency = 250; b[1].bandwidth = 1.2; b[1].gain = -2; b[1].bypass = false
        b[2].filterType = .parametric; b[2].frequency = 3000; b[2].bandwidth = 1.5; b[2].gain = 4; b[2].bypass = false
        eq.bypass = true
        return eq
    }

    static func makeCompressor() -> AVAudioUnitEffect {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let c = AVAudioUnitEffect(audioComponentDescription: desc)
        let tree = c.auAudioUnit.parameterTree
        func set(_ p: AudioUnitParameterID, _ v: Float) { tree?.parameter(withAddress: AUParameterAddress(p))?.value = v }
        set(kDynamicsProcessorParam_Threshold, -30)     // dB: compress everything above conversational level
        set(kDynamicsProcessorParam_HeadRoom, 8)        // dB: soft knee up to the limit
        set(kDynamicsProcessorParam_AttackTime, 0.004)
        set(kDynamicsProcessorParam_ReleaseTime, 0.12)
        set(kDynamicsProcessorParam_OverallGain, 9)     // dB of make-up gain
        c.bypass = true
        return c
    }

    // MARK: Silence map

    struct Pause: Codable, Equatable { var start: Double; var end: Double }

    private static var memory: [URL: [Pause]] = [:]
    private static var pending = Set<URL>()
    private static let queue = DispatchQueue(label: "musicamp.silence", qos: .utility)

    static var folder: URL {
        let u = PlayStats.file.deletingLastPathComponent().appendingPathComponent("Silences", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The pauses of a local file, or nil while they're being found (`ready` is called on the main thread then).
    static func pauses(_ url: URL, ready: @escaping ([Pause]) -> Void) -> [Pause]? {
        if let p = memory[url] { return p }
        guard url.isFileURL, !pending.contains(url) else { return nil }
        pending.insert(url)
        queue.async {
            let cache = cacheFile(url)
            var p = cache.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Pause].self, from: $0) }
            if p == nil {
                p = find(url)
                if let p, let cache, let d = try? JSONEncoder().encode(p) { try? d.write(to: cache, options: .atomic) }
            }
            DispatchQueue.main.async {
                pending.remove(url)
                guard let p else { return }
                memory[url] = p
                ready(p)
            }
        }
        return nil
    }

    private static func cacheFile(_ url: URL) -> URL? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let key = "v1|\(url.path)|\(v.fileSize ?? 0)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return folder.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    /// Loudness every 50 ms; a pause is ≥ 0.6 s below a threshold set between the file's noise floor and its
    /// typical speech level, so it works for quiet and loud recordings alike.
    static func find(_ url: URL) -> [Pause]? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate
        let win = Int(sr * 0.05)
        guard win > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(win * 40)) else { return nil }
        var levels: [Float] = []
        levels.reserveCapacity(Int(Double(f.length) / sr * 20) + 1)
        while true {
            buf.frameLength = 0
            guard (try? f.read(into: buf, frameCount: buf.frameCapacity)) != nil, buf.frameLength > 0, let d = buf.floatChannelData else { break }
            let n = Int(buf.frameLength)
            var i = 0
            while i + win <= n {
                var rms: Float = 0
                vDSP_rmsqv(d[0] + i, 1, &rms, vDSP_Length(win))
                if f.processingFormat.channelCount > 1 {
                    var r2: Float = 0
                    vDSP_rmsqv(d[1] + i, 1, &r2, vDSP_Length(win))
                    rms = max(rms, r2)
                }
                levels.append(20 * log10(max(1e-7, rms)))
                i += win
            }
        }
        return pauses(levels: levels, window: 0.05)
    }

    static func pauses(levels: [Float], window: Double, minimum: Double = 0.6) -> [Pause] {
        guard levels.count > 20 else { return [] }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10], speech = sorted[sorted.count * 6 / 10]
        let threshold = floor + max(6, (speech - floor) * 0.3)
        var out: [Pause] = []
        var start: Int?
        for (i, l) in levels.enumerated() {
            if l < threshold {
                if start == nil { start = i }
            } else if let s = start {
                if Double(i - s) * window >= minimum { out.append(Pause(start: Double(s) * window, end: Double(i) * window)) }
                start = nil
            }
        }
        if let s = start, Double(levels.count - s) * window >= minimum { out.append(Pause(start: Double(s) * window, end: Double(levels.count) * window)) }
        return out
    }
}
