import AudioToolbox
import CommonCrypto
import Foundation

/// Native HLS client for audio radio, so HLS stations play through our own engine (EQ, ReplayGain-free
/// gain, visualizer, Milkdrop) instead of AVPlayer. It follows the media playlist, downloads segments in
/// order and turns them into a raw AAC (ADTS) or MP3 elementary stream for RadioStream's decoder:
/// MPEG-TS segments are demultiplexed (PAT → PMT → PES), "packed audio" segments (.aac/.mp3 with an ID3
/// timestamp tag) are passed through. Titles come from ID3 frames (TIT2/TPE1), in the TS or packed.
/// AES-128 encrypted segments are decrypted here (key from EXT-X-KEY, IV given or from the sequence number).
/// SAMPLE-AES, fMP4 (EXT-X-MAP) and LATM audio are reported as `HLSError.unsupported` so the caller can
/// fall back to AVPlayer.
final class HLSFetcher {
    enum HLSError: LocalizedError {
        case unsupported(String), badPlaylist
        var errorDescription: String? {
            switch self {
            case .unsupported(let s): return "HLS: unsupported \(s)"
            case .badPlaylist: return "HLS: invalid playlist"
            }
        }
    }

    let url: URL
    /// Elementary audio bytes and their format (kAudioFileAAC_ADTSType or kAudioFileMP3Type).
    var onAudio: ((Data, AudioFileTypeID) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBandwidth: ((Int) -> Void)?
    var onEnd: ((Error?) -> Void)?
    private var task: Task<Void, Never>?
    private var lastTitle = ""
    private var keys: [URL: Data] = [:]

    init(url: URL) { self.url = url }

    func start() {
        task = Task.detached(priority: .userInitiated) { [weak self] in await self?.run() }
    }

    func cancel() { task?.cancel() }

    // MARK: Playlists

    struct Segment {
        var url: URL
        var duration: Double
        var key: URL? = nil          // AES-128 key
        var iv: [UInt8]? = nil       // explicit IV, else the media sequence number
    }
    struct MediaPlaylist {
        var firstSeq = 0
        var target = 6.0
        var endList = false
        var segments: [Segment] = []
    }

    private func fetch(_ u: URL) async throws -> Data {
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue(RadioStream.userAgent, forHTTPHeaderField: "User-Agent")
        var lastError: Error = StreamError.ended
        for attempt in 0..<3 {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw StreamError.http(h.statusCode) }
                return data
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(attempt + 1) * 1e9))
            }
        }
        throw lastError
    }

    private func text(_ d: Data) -> String { String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? "" }

    /// Master playlist → the audio variant to play: the best one up to 320 kb/s (radio variants are small).
    static func pickVariant(_ text: String, base: URL) -> (URL, Int)? {
        var best: (URL, Int)?
        var pending: Int?
        for raw in Skin.lines(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let bw = attribute(line, "BANDWIDTH").flatMap { Int($0) } ?? 0
                pending = bw
            } else if let bw = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let u = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                if let b = best {
                    let better = bw <= 320_000 ? (b.1 > 320_000 || bw > b.1) : (b.1 > 320_000 && bw < b.1)
                    if better { best = (u, bw) }
                } else {
                    best = (u, bw)
                }
            }
        }
        return best
    }

    static func attribute(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: key + "=") else { return nil }
        var v = line[r.upperBound...]
        if v.hasPrefix("\"") { v = v.dropFirst(); return String(v.prefix { $0 != "\"" }) }
        return String(v.prefix { $0 != "," })
    }

    static func parseMedia(_ text: String, base: URL) throws -> MediaPlaylist {
        var p = MediaPlaylist()
        var dur: Double?
        var key: URL?, iv: [UInt8]?
        for raw in Skin.lines(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { p.firstSeq = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("#EXT-X-TARGETDURATION:") { p.target = Double(line.dropFirst(22)) ?? 6 }
            else if line.hasPrefix("#EXT-X-ENDLIST") { p.endList = true }
            else if line.hasPrefix("#EXT-X-KEY:") {
                let m = attribute(line, "METHOD") ?? "NONE"
                if m == "NONE" { key = nil; iv = nil; continue }
                guard m == "AES-128", let k = attribute(line, "URI").flatMap({ URL(string: $0, relativeTo: base)?.absoluteURL }) else {
                    throw HLSError.unsupported("\(m) encryption")
                }
                key = k
                iv = attribute(line, "IV").flatMap(HLSFetcher.hexBytes)
            }
            else if line.hasPrefix("#EXT-X-MAP:") { throw HLSError.unsupported("fMP4") }
            else if line.hasPrefix("#EXTINF:") { dur = Double(line.dropFirst(8).prefix { $0 != "," }) ?? p.target }
            else if !line.isEmpty, !line.hasPrefix("#"), let u = URL(string: line, relativeTo: base)?.absoluteURL {
                p.segments.append(Segment(url: u, duration: dur ?? p.target, key: key, iv: iv))
                dur = nil
            }
        }
        guard text.contains("#EXTM3U") || !p.segments.isEmpty else { throw HLSError.badPlaylist }
        return p
    }

    // MARK: Loop

    private func run() async {
        do {
            var mediaURL = url
            var body = text(try await fetch(url))
            if body.contains("#EXT-X-STREAM-INF") {
                guard let (u, bw) = HLSFetcher.pickVariant(body, base: url) else { throw HLSError.badPlaylist }
                mediaURL = u
                if bw > 0 { onBandwidth?(bw) }
                body = text(try await fetch(u))
            }
            var next: Int?
            while !Task.isCancelled {
                let pl = try HLSFetcher.parseMedia(body, base: mediaURL)
                // Live: start three segments from the end, like Apple's player; VOD: from the start.
                if next == nil { next = pl.endList ? pl.firstSeq : max(pl.firstSeq, pl.firstSeq + pl.segments.count - 3) }
                if next! < pl.firstSeq { next = pl.firstSeq }   // fell behind the live window
                var fetched = 0
                for (idx, seg) in pl.segments.enumerated() where pl.firstSeq + idx >= next! {
                    if Task.isCancelled { return }
                    var data = try await fetch(seg.url)
                    if let k = seg.key {
                        let keyData: Data
                        if let cached = keys[k] { keyData = cached } else { keyData = try await fetch(k); keys[k] = keyData }
                        data = try HLSFetcher.decrypt(data, key: keyData, iv: seg.iv ?? HLSFetcher.sequenceIV(pl.firstSeq + idx))
                    }
                    let (audio, type) = try demux(data)
                    if !audio.isEmpty, let type { onAudio?(audio, type) }
                    next = pl.firstSeq + idx + 1
                    fetched += 1
                }
                if pl.endList, fetched == 0 { onEnd?(nil); return }
                if fetched == 0 { try await Task.sleep(nanoseconds: UInt64(max(1, pl.target / 2) * 1e9)) }
                body = text(try await fetch(mediaURL))
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { onEnd?(error) }
        }
    }

    // MARK: AES-128

    static func hexBytes(_ s: String) -> [UInt8]? {
        var h = s.lowercased()
        if h.hasPrefix("0x") { h.removeFirst(2) }
        guard h.count == 32 else { return nil }
        var out: [UInt8] = []
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Default IV: the segment's media sequence number as a 128-bit big-endian integer.
    static func sequenceIV(_ seq: Int) -> [UInt8] {
        (0..<16).map { i in i < 8 ? 0 : UInt8((UInt64(seq) >> (8 * UInt64(15 - i))) & 0xFF) }
    }

    static func decrypt(_ data: Data, key: Data, iv: [UInt8]) throws -> Data {
        guard key.count == 16 else { throw HLSError.unsupported("\(key.count)-byte AES key") }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, iv, d.baseAddress, data.count, o.baseAddress, outCount, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw HLSError.unsupported("decryption (\(status))") }
        out.count = moved
        return out
    }

    // MARK: Segments

    /// Segment bytes → elementary audio stream (+ titles from ID3 along the way).
    func demux(_ d: Data) throws -> (Data, AudioFileTypeID?) {
        let b = [UInt8](d)
        if b.count >= 188, b[0] == 0x47, b.count < 376 || b[188] == 0x47 { return try demuxTS(b) }
        // Packed audio: optional ID3 tag (timestamp, titles), then ADTS or MP3 frames.
        var i = 0
        while i + 10 <= b.count, b[i] == 0x49, b[i + 1] == 0x44, b[i + 2] == 0x33 {   // "ID3"
            let size = (Int(b[i + 6]) << 21) | (Int(b[i + 7]) << 14) | (Int(b[i + 8]) << 7) | Int(b[i + 9])
            let end = min(b.count, i + 10 + size + ((b[i + 5] & 0x10) != 0 ? 10 : 0))
            title(fromID3: Array(b[i..<end]))
            i = end
        }
        guard i + 2 <= b.count else { return (Data(), nil) }
        let isADTS = b[i] == 0xFF && (b[i + 1] & 0xF6) == 0xF0
        return (Data(b[i...]), isADTS ? kAudioFileAAC_ADTSType : kAudioFileMP3Type)
    }

    private func demuxTS(_ b: [UInt8]) throws -> (Data, AudioFileTypeID?) {
        var pmtPID: Int?
        var audioPID: Int?, audioType: AudioFileTypeID?, id3PID: Int?
        var audio = [UInt8]()
        var id3 = [UInt8]()
        audio.reserveCapacity(b.count)
        var p = 0
        while p + 188 <= b.count {
            defer { p += 188 }
            guard b[p] == 0x47 else { continue }
            let start = (b[p + 1] & 0x40) != 0
            let pid = (Int(b[p + 1] & 0x1F) << 8) | Int(b[p + 2])
            let afc = (b[p + 3] >> 4) & 3
            var off = p + 4
            if afc == 2 { continue }                       // adaptation field only
            if afc == 3 { off += 1 + Int(b[p + 4]) }
            guard off < p + 188 else { continue }
            let payload = b[off..<(p + 188)]
            if pid == 0, start {
                // PAT: first program with a non-zero number → its PMT PID.
                let t = payload.startIndex + 1 + Int(payload.first ?? 0)
                guard t + 8 <= payload.endIndex else { continue }
                let secLen = (Int(b[t + 1] & 0x0F) << 8) | Int(b[t + 2])
                var e = t + 8
                while e + 4 <= min(payload.endIndex, t + 3 + secLen - 4) {
                    let prog = (Int(b[e]) << 8) | Int(b[e + 1])
                    if prog != 0 { pmtPID = (Int(b[e + 2] & 0x1F) << 8) | Int(b[e + 3]); break }
                    e += 4
                }
            } else if pid == pmtPID, start, audioPID == nil {
                let t = payload.startIndex + 1 + Int(payload.first ?? 0)
                guard t + 12 <= payload.endIndex else { continue }
                let secLen = (Int(b[t + 1] & 0x0F) << 8) | Int(b[t + 2])
                let progInfo = (Int(b[t + 10] & 0x0F) << 8) | Int(b[t + 11])
                var e = t + 12 + progInfo
                let end = min(payload.endIndex, t + 3 + secLen - 4)
                while e + 5 <= end {
                    let st = b[e], epid = (Int(b[e + 1] & 0x1F) << 8) | Int(b[e + 2])
                    let esInfo = (Int(b[e + 3] & 0x0F) << 8) | Int(b[e + 4])
                    switch st {
                    case 0x0F where audioPID == nil: audioPID = epid; audioType = kAudioFileAAC_ADTSType
                    case 0x03, 0x04: if audioPID == nil { audioPID = epid; audioType = kAudioFileMP3Type }
                    case 0x11 where audioPID == nil: throw HLSError.unsupported("AAC LATM")
                    case 0x15: id3PID = epid
                    case 0xDB, 0xCF: throw HLSError.unsupported("encrypted audio")
                    default: break
                    }
                    e += 5 + esInfo
                }
            } else if pid == audioPID {
                audio += pesPayload(payload, start: start)
            } else if pid == id3PID {
                if start, !id3.isEmpty { title(fromID3: id3); id3.removeAll() }
                id3 += pesPayload(payload, start: start)
            }
        }
        if !id3.isEmpty { title(fromID3: id3) }
        return (Data(audio), audioType)
    }

    /// Payload of a TS packet, without the PES header when the packet starts one.
    private func pesPayload(_ p: ArraySlice<UInt8>, start: Bool) -> ArraySlice<UInt8> {
        guard start else { return p }
        let s = p.startIndex
        guard p.count >= 9, p[s] == 0, p[s + 1] == 0, p[s + 2] == 1 else { return p }
        let skip = 9 + Int(p[s + 8])
        return skip < p.count ? p[(s + skip)...] : []
    }

    // MARK: ID3 titles

    /// "Artist - Title" from TPE1/TIT2 (ID3 v2.3/2.4) when it changes.
    private func title(fromID3 b: [UInt8]) {
        guard let t = HLSFetcher.id3Title(b), !t.isEmpty, t != lastTitle else { return }
        lastTitle = t
        onTitle?(t)
    }

    static func id3Title(_ b: [UInt8]) -> String? {
        guard b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let version = b[3]
        let size = (Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])
        let end = min(b.count, 10 + size)
        var i = 10
        var artist: String?, title: String?
        while i + 10 <= end {
            let id = String(bytes: b[i..<(i + 4)], encoding: .ascii) ?? ""
            guard id.first?.isLetter == true || id.first?.isNumber == true else { break }
            let fs = version >= 4
                ? (Int(b[i + 4]) << 21) | (Int(b[i + 5]) << 14) | (Int(b[i + 6]) << 7) | Int(b[i + 7])
                : (Int(b[i + 4]) << 24) | (Int(b[i + 5]) << 16) | (Int(b[i + 6]) << 8) | Int(b[i + 7])
            let ds = i + 10, de = min(end, ds + fs)
            guard fs > 0, ds < de else { break }
            if id == "TIT2" || id == "TPE1" {
                let enc = b[ds]
                let raw = Data(b[(ds + 1)..<de])
                let s: String?
                switch enc {
                case 1: s = String(data: raw, encoding: .utf16)
                case 2: s = String(data: raw, encoding: .utf16BigEndian)
                case 3: s = String(data: raw, encoding: .utf8)
                default: s = String(data: raw, encoding: .isoLatin1)
                }
                let v = s?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}")))
                if id == "TIT2" { title = v } else { artist = v }
            }
            i = de
        }
        if let a = artist, !a.isEmpty, let t = title, !t.isEmpty { return "\(a) - \(t)" }
        return title ?? artist
    }
}
