import Accelerate
import AVFoundation
import CryptoKit

/// Sonic analysis: what a track sounds like, measured on this Mac from 45 seconds of its audio (from a quarter of
/// the way in). Timbre (13 MFCCs), harmony (12-bin chroma and the key it suggests), tempo (BPM from the onset
/// envelope) and energy (loudness, brightness, noisiness, dynamics, punch). Cached per file in
/// ~/Library/Application Support/MusicAmp/sonic.json. Sonic Radio, Sonic Journey and "similar tracks" use it.
struct SonicFeatures: Codable, Equatable {
    static let version = 1
    var mfcc: [Float]        // 13, mean over frames (c0 dropped later: loudness is measured separately)
    var chroma: [Float]      // 12, sums to 1
    var bpm: Float
    var key: Int             // 0 = C … 11 = B
    var minor: Bool
    var keyStrength: Float   // correlation with the best key profile (0…1)
    var loudness: Float      // dBFS RMS
    var centroid: Float      // log2 Hz
    var flatness: Float      // 0 tonal … 1 noisy
    var dynamics: Float      // dB between loud and average frames
    var punch: Float         // mean onset strength
    var zcr: Float

    static let keyNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    var keyName: String { SonicFeatures.keyNames[key] + (minor ? "m" : "") }
    /// Camelot-style position on the circle of fifths (relative minors share the major's spot).
    var fifths: Int { ((minor ? (key + 3) % 12 : key) * 7) % 12 }
}

enum SonicAnalyzer {
    static let rate = 22050.0
    static let fftSize = 2048
    static let hop = 512

    // MARK: Reading audio

    /// Mono samples at ~22 kHz from 45 s starting at a quarter of the track (the whole track when short).
    static func samples(_ url: URL) -> [Float]? {
        let file = CueSheet.audioURL(url)
        let seg = CueSheet.segment(url)
        if !FFmpeg.extensions.contains(file.pathExtension.lowercased()), let f = try? AVAudioFile(forReading: file) {
            return native(f, start: seg?.start ?? 0, end: seg?.end)
        }
        guard FFmpeg.available, let ff = FFmpeg.ffmpegPath else { return nil }
        let total = seg.flatMap { s in s.end.map { $0 - s.start } } ?? FFmpeg.probe(file)?.duration ?? 0
        let from = (seg?.start ?? 0) + (total > 60 ? total * 0.25 : 0)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-v", "quiet", "-nostdin", "-ss", String(from), "-i", file.path, "-t", "45", "-vn", "-ac", "1", "-ar", String(Int(rate)), "-f", "f32le", "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return s.count > fftSize * 4 ? s : nil
    }

    private static func native(_ f: AVAudioFile, start: Double, end: Double?) -> [Float]? {
        let sr = f.processingFormat.sampleRate
        let first = AVAudioFramePosition(start * sr)
        let last = min(f.length, end.map { AVAudioFramePosition($0 * sr) } ?? f.length)
        let length = last - first
        guard length > 0 else { return nil }
        let skip = Double(length) / sr > 60 ? length / 4 : 0
        let want = min(length - skip, AVAudioFramePosition(45 * sr))
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(want)) else { return nil }
        f.framePosition = first + skip
        guard (try? f.read(into: buf, frameCount: AVAudioFrameCount(want))) != nil, let d = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), ch = Int(f.processingFormat.channelCount)
        // Mix to mono, then decimate to ~22 kHz by averaging (a crude anti-alias filter is enough for features).
        let factor = max(1, Int((sr / rate).rounded()))
        var out = [Float](repeating: 0, count: n / factor)
        let scale = 1 / Float(ch * factor)
        for i in 0..<out.count {
            var s: Float = 0
            for c in 0..<ch { for j in 0..<factor { s += d[c][i * factor + j] } }
            out[i] = s * scale
        }
        return out.count > fftSize * 4 ? out : nil
    }

    // MARK: Features

    static func analyze(_ url: URL) -> SonicFeatures? {
        guard let x = samples(url) else { return nil }
        return features(x, sampleRate: rate)
    }

    static func features(_ x: [Float], sampleRate sr: Double) -> SonicFeatures? {
        let n = fftSize, half = n / 2
        let frames = (x.count - n) / hop
        guard frames > 16, let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Mel filterbank (26 bands, 60 Hz – 8 kHz) and the bin → pitch-class map for chroma (55 Hz – 2 kHz).
        let mel = melBank(bands: 26, n: n, sr: sr)
        var pitchClass = [Int](repeating: -1, count: half)
        for b in 1..<half {
            let f = Double(b) * sr / Double(n)
            guard f >= 55, f <= 2000 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            pitchClass[b] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var mfccSum = [Float](repeating: 0, count: 13)
        var chroma = [Float](repeating: 0, count: 12)
        var centroidSum: Float = 0, flatSum: Float = 0
        var frameRMS = [Float]()
        var flux = [Float]()
        var prevLog = [Float](repeating: 0, count: half)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var counted: Float = 0

        for fi in 0..<frames {
            let off = fi * hop
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + off, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            var rms: Float = 0
            x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + off, 1, &rms, vDSP_Length(n)) }
            frameRMS.append(rms)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            // Onset envelope: positive change of log magnitude (spectral flux), every hop.
            var f: Float = 0
            for b in 1..<half {
                let l = log1p(mag[b])
                let d = l - prevLog[b]
                if d > 0 { f += d }
                prevLog[b] = l
            }
            flux.append(f)
            // Timbre, chroma and spectrum shape every 4th hop (2048-sample frames without overlap) is plenty.
            guard fi % 4 == 0, rms > 1e-4 else { continue }
            counted += 1
            var energy = [Float](repeating: 0, count: mel.count)
            for (m, filt) in mel.enumerated() {
                var e: Float = 0
                for (b, w) in filt { e += w * mag[b] * mag[b] }
                energy[m] = log(max(1e-10, e))
            }
            for k in 0..<13 {
                var c: Float = 0
                for m in 0..<energy.count { c += energy[m] * cos(Float.pi * Float(k) * (Float(m) + 0.5) / Float(energy.count)) }
                mfccSum[k] += c
            }
            var total: Float = 0, weighted: Float = 0, logSum: Float = 0
            for b in 1..<half {
                let p = mag[b] * mag[b]
                total += p
                weighted += p * Float(b)
                logSum += log(max(1e-12, p))
                if pitchClass[b] >= 0 { chroma[pitchClass[b]] += mag[b] }
            }
            if total > 0 {
                centroidSum += log2(max(20, weighted / total * Float(sr) / Float(n)))
                flatSum += exp(logSum / Float(half - 1)) / (total / Float(half - 1))
            }
        }
        guard counted > 0 else { return nil }
        let mfcc = mfccSum.map { $0 / counted }
        let cs = chroma.reduce(0, +)
        let chromaN = cs > 0 ? chroma.map { $0 / cs } : chroma
        let (key, minor, strength) = estimateKey(chromaN)
        let meanRMS = frameRMS.reduce(0, +) / Float(frameRMS.count)
        let sortedRMS = frameRMS.sorted()
        let loud = sortedRMS[min(sortedRMS.count - 1, sortedRMS.count * 95 / 100)]
        var zc = 0
        for i in 1..<x.count where (x[i] >= 0) != (x[i - 1] >= 0) { zc += 1 }
        let fluxMean = flux.reduce(0, +) / Float(flux.count)
        return SonicFeatures(mfcc: mfcc, chroma: chromaN, bpm: estimateTempo(flux, frameRate: sr / Double(hop)),
                             key: key, minor: minor, keyStrength: strength,
                             loudness: 20 * log10(max(1e-6, meanRMS)), centroid: centroidSum / counted, flatness: flatSum / counted,
                             dynamics: 20 * log10(max(1e-6, loud) / max(1e-6, meanRMS)), punch: fluxMean,
                             zcr: Float(zc) / Float(x.count) * Float(sr))
    }

    /// Triangular mel filters as (bin, weight) lists.
    static func melBank(bands: Int, n: Int, sr: Double) -> [[(Int, Float)]] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(60), hi = mel(min(8000, sr / 2))
        let edges = (0...(bands + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(bands + 1)) }
        let binHz = sr / Double(n)
        return (0..<bands).map { m in
            var f: [(Int, Float)] = []
            let a = edges[m], c = edges[m + 1], b = edges[m + 2]
            for bin in Int(a / binHz)...min(n / 2 - 1, Int(b / binHz) + 1) where bin > 0 {
                let fr = Double(bin) * binHz
                let w = fr < c ? (fr - a) / (c - a) : (b - fr) / (b - c)
                if w > 0 { f.append((bin, Float(w))) }
            }
            return f
        }
    }

    /// Krumhansl–Kessler key profiles correlated with the chroma vector.
    static func estimateKey(_ chroma: [Float]) -> (Int, Bool, Float) {
        let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minorP: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func corr(_ a: [Float], _ b: [Float]) -> Float {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num: Float = 0, da: Float = 0, db: Float = 0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
        }
        var best = (0, false, -Float.infinity)
        for k in 0..<12 {
            let rot = (0..<12).map { chroma[($0 + k) % 12] }
            let cM = corr(rot, major), cm = corr(rot, minorP)
            if cM > best.2 { best = (k, false, cM) }
            if cm > best.2 { best = (k, true, cm) }
        }
        return (best.0, best.1, max(0, best.2))
    }

    /// Tempo from the autocorrelation of the onset envelope, 60–200 BPM, preferring the 90–150 range
    /// (a log-Gaussian weight around 120 BPM), refined between lags.
    static func estimateTempo(_ flux: [Float], frameRate: Double) -> Float {
        let n = flux.count
        guard n > 64 else { return 0 }
        let mean = flux.reduce(0, +) / Float(n)
        let x = flux.map { $0 - mean }
        let minLag = Int(frameRate * 60 / 200), maxLag = min(n / 2, Int(frameRate * 60 / 60))
        guard maxLag > minLag + 2 else { return 0 }
        var ac = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var s: Float = 0
            x.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(n - lag)) }
            ac[lag] = s / Float(n - lag)
        }
        var bestLag = minLag
        var bestScore = -Float.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            let w = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            let score = ac[lag] * w
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // Parabolic refinement.
        let a = ac[max(minLag, bestLag - 1)], b = ac[bestLag], c = ac[min(maxLag + 1, bestLag + 1)]
        let denom = a - 2 * b + c
        let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
        let lag = Double(bestLag) + Double(max(-0.5, min(0.5, shift)))
        return Float(60 * frameRate / lag)
    }
}

// MARK: - Store

/// Features of every analysed track, analysed in the background on demand.
final class SonicStore: ObservableObject {
    static let shared = SonicStore()

    @Published private(set) var features: [String: SonicFeatures] = [:]
    @Published private(set) var analyzing = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    private var fingerprints: [String: String] = [:]
    private var cancelled = false
    private var saveScheduled = false

    struct Entry: Codable { var fp: String; var f: SonicFeatures }

    static var file: URL { PlayStats.file.deletingLastPathComponent().appendingPathComponent("sonic.json") }

    init(load: Bool = true) {
        guard load, let d = try? Data(contentsOf: SonicStore.file),
              let all = try? JSONDecoder().decode([String: Entry].self, from: d) else { return }
        for (k, e) in all { features[k] = e.f; fingerprints[k] = e.fp }
    }

    /// Changes when the file does (size, date) or the analysis does.
    static func fingerprint(_ url: URL) -> String {
        let v = try? CueSheet.audioURL(url).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(SonicFeatures.version)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func feature(for url: URL) -> SonicFeatures? {
        guard let k = PlayStats.key(url) else { return nil }
        return features[k]
    }

    func needsAnalysis(_ url: URL) -> Bool {
        guard let k = PlayStats.key(url) else { return false }
        return features[k] == nil || fingerprints[k] != SonicStore.fingerprint(url)
    }

    /// Analyses the tracks not done yet, three at a time; `done` runs on the main thread at the end.
    func analyze(_ urls: [URL], done: (() -> Void)? = nil) {
        let todo = urls.filter(needsAnalysis)
        guard !todo.isEmpty else { done?(); return }
        guard !analyzing else { return }
        analyzing = true
        cancelled = false
        progress = (0, todo.count)
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 3)
        let q = DispatchQueue(label: "musicamp.sonic", qos: .utility, attributes: .concurrent)
        for url in todo {
            group.enter()
            q.async { [weak self] in
                sem.wait()
                defer { sem.signal(); group.leave() }
                guard let self, !self.cancelled else { return }
                let f = SonicAnalyzer.analyze(url)
                let fp = SonicStore.fingerprint(url)
                DispatchQueue.main.async {
                    if let f, let k = PlayStats.key(url) {
                        self.features[k] = f
                        self.fingerprints[k] = fp
                    }
                    self.progress.done += 1
                    self.scheduleSave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.analyzing = false
            self?.save()
            done?()
        }
    }

    func cancel() { cancelled = true }

    /// Tests: features computed elsewhere.
    func remember(_ f: SonicFeatures, key: String) { features[key] = f; fingerprints[key] = "test" }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        var all: [String: Entry] = [:]
        for (k, f) in features { all[k] = Entry(fp: fingerprints[k] ?? "", f: f) }
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: SonicStore.file, options: .atomic) }
    }
}

// MARK: - Mixing

/// Distances between analysed tracks, with every feature scaled by its spread across the library.
struct SonicSpace {
    struct Track { let item: SmartItem; let f: SonicFeatures; let v: [Float] }
    let tracks: [Track]

    init(items: [SmartItem], store: SonicStore = SonicStore.shared) {
        let known = items.compactMap { it in store.features[it.key].map { (it, $0) } }
        // Raw vector: timbre (MFCC 1–12), energy group; tempo and key are compared separately.
        func raw(_ f: SonicFeatures) -> [Float] {
            Array(f.mfcc.dropFirst().prefix(12)) + [f.loudness, f.centroid, f.flatness, f.dynamics, f.punch, f.zcr / 1000]
        }
        let raws = known.map { raw($0.1) }
        let dims = raws.first?.count ?? 0
        var mean = [Float](repeating: 0, count: dims), sd = [Float](repeating: 1, count: dims)
        if raws.count > 1 {
            for d in 0..<dims {
                let col = raws.map { $0[d] }
                let m = col.reduce(0, +) / Float(col.count)
                let v = col.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(col.count)
                mean[d] = m
                sd[d] = max(1e-3, v.squareRoot())
            }
        }
        // Timbre counts as much as the energy group, whatever the number of dimensions in each.
        let weights: [Float] = Array(repeating: 1 / 12.0.squareRoot(), count: 12).map(Float.init)
            + Array(repeating: Float(1 / 6.0.squareRoot()), count: 6)
        tracks = zip(known, raws).map { k, r in
            Track(item: k.0, f: k.1, v: (0..<dims).map { (r[$0] - mean[$0]) / sd[$0] * weights[$0] })
        }
    }

    /// 0 = identical. Timbre/energy, tempo (half and double time count as close) and key (circle of fifths).
    static func distance(_ a: Track, _ b: Track) -> Float {
        var d: Float = 0
        for i in 0..<min(a.v.count, b.v.count) { let x = a.v[i] - b.v[i]; d += x * x }
        d = d.squareRoot()
        return d + tempoDistance(a.f.bpm, b.f.bpm) * 1.2 + keyDistance(a.f, b.f) * 0.5
    }

    static func tempoDistance(_ a: Float, _ b: Float) -> Float {
        guard a > 0, b > 0 else { return 0.5 }
        var r = abs(log2(a / b))
        r = min(r, abs(r - 1) + 0.15)   // double/half time: close, but not identical
        return min(1, r * 4)            // 10% apart ≈ 0.55
    }

    static func keyDistance(_ a: SonicFeatures, _ b: SonicFeatures) -> Float {
        let diff = abs(a.fifths - b.fifths), steps = min(diff, 12 - diff)
        let confidence = min(1, (a.keyStrength + b.keyStrength) * 1.2)
        return Float(steps) / 6 * confidence
    }

    /// The same song in another file (another edition, a copy): main artist + title, ignoring case, accents,
    /// typographic apostrophes, spacing and a copy number at the end. A mix never holds a song twice.
    static func songKey(_ t: Track) -> String {
        func fold(_ s: String) -> String {
            s.replacingOccurrences(of: "’", with: "'").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // A Finder copy suffix ("Song (2)") is the same song.
        let title = t.item.title.replacingOccurrences(of: #"\s*\(\d{1,2}\)$"#, with: "", options: .regularExpression)
        return fold(artist(t)) + "|" + fold(title)
    }

    /// Main artist ("Taylor Swift" for "Taylor Swift, Chris Stapleton").
    static func artist(_ t: Track) -> String {
        PlaylistTree.mainArtist(t.item.stats.artist ?? "").lowercased()
    }

    func track(_ url: URL) -> Track? {
        guard let k = PlayStats.key(url) else { return nil }
        return tracks.first { $0.item.key == k }
    }

    func similar(to seed: Track, count: Int) -> [(Track, Float)] {
        var songs = Set([SonicSpace.songKey(seed)])
        return tracks.filter { $0.item.key != seed.item.key }
            .map { ($0, SonicSpace.distance(seed, $0)) }
            .sorted { $0.1 < $1.1 }
            .filter { songs.insert(SonicSpace.songKey($0.0)).inserted }
            .prefix(count).map { $0 }
    }

    /// Sonic Radio: each next track close to the previous one and still close to the seed, avoiding the same
    /// artist twice in a row; a little randomness among the closest picks so it isn't the same every time.
    func radio(from seed: Track, count: Int, randomness: Float = 0.25) -> [Track] {
        var out = [seed]
        var used = Set([seed.item.key])
        var songs = Set([SonicSpace.songKey(seed)])
        var current = seed
        while out.count < count + 1 {
            // The same main artist within the last three tracks costs as much as a clearly different sound.
            let lastArtists = Set(out.suffix(3).map(SonicSpace.artist).filter { !$0.isEmpty })
            let scored = tracks.filter { !used.contains($0.item.key) && !songs.contains(SonicSpace.songKey($0)) }.map { t -> (Track, Float) in
                var s = SonicSpace.distance(current, t) * 0.65 + SonicSpace.distance(seed, t) * 0.35
                if lastArtists.contains(SonicSpace.artist(t)) { s += 2.0 }
                return (t, s)
            }.sorted { $0.1 < $1.1 }
            guard !scored.isEmpty else { break }
            let pick = scored.prefix(3).count > 1 && Float.random(in: 0..<1) < randomness ? scored[Int.random(in: 0..<min(3, scored.count))].0 : scored[0].0
            out.append(pick)
            used.insert(pick.item.key)
            songs.insert(SonicSpace.songKey(pick))
            current = pick
        }
        return out
    }

    /// Sonic Journey: from `a` to `b` through `steps` tracks spread evenly in between (in feature space, tempo on a
    /// log scale), each the closest unused track to its waypoint.
    func journey(from a: Track, to b: Track, steps: Int) -> [Track] {
        var out = [a]
        var used = Set([a.item.key, b.item.key])
        var songs = Set([SonicSpace.songKey(a), SonicSpace.songKey(b)])
        for i in 1...max(1, steps) {
            let t = Float(i) / Float(steps + 1)
            let wv = zip(a.v, b.v).map { $0 + ($1 - $0) * t }
            let wbpm = a.f.bpm > 0 && b.f.bpm > 0 ? a.f.bpm * pow(b.f.bpm / a.f.bpm, t) : max(a.f.bpm, b.f.bpm)
            var best: (Track, Float)?
            for c in tracks where !used.contains(c.item.key) && !songs.contains(SonicSpace.songKey(c)) {
                var d: Float = 0
                for j in 0..<min(wv.count, c.v.count) { let x = wv[j] - c.v[j]; d += x * x }
                d = d.squareRoot() + SonicSpace.tempoDistance(wbpm, c.f.bpm) * 1.2
                if let prev = out.last { d += SonicSpace.distance(prev, c) * 0.25 }   // smooth steps
                if best == nil || d < best!.1 { best = (c, d) }
            }
            guard let pick = best?.0 else { break }
            out.append(pick)
            used.insert(pick.item.key)
            songs.insert(SonicSpace.songKey(pick))
        }
        out.append(b)
        return SonicSpace.smooth(out)
    }

    /// 2-opt with fixed ends: reverses stretches of the path while that shortens it, so the journey doesn't
    /// zig-zag between tracks that each sat closest to their own waypoint.
    static func smooth(_ path: [Track]) -> [Track] {
        guard path.count > 3 else { return path }
        var p = path
        let n = p.count
        var d = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in (i + 1)..<n { d[i][j] = distance(p[i], p[j]); d[j][i] = d[i][j] } }
        var idx = Array(0..<n)
        var improved = true, rounds = 0
        while improved, rounds < 50 {
            improved = false
            rounds += 1
            for i in 1..<(n - 2) {
                for k in (i + 1)..<(n - 1) {
                    let before = d[idx[i - 1]][idx[i]] + d[idx[k]][idx[k + 1]]
                    let after = d[idx[i - 1]][idx[k]] + d[idx[i]][idx[k + 1]]
                    if after + 1e-4 < before { idx[i...k].reverse(); improved = true }
                }
            }
        }
        p = idx.map { path[$0] }
        return p
    }

    /// 0…100% for display.
    static func similarity(_ d: Float) -> Int { max(0, min(100, Int((100 * exp(-d / 2.2)).rounded()))) }
}
