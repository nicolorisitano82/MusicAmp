import AVFoundation
import AudioToolbox

enum StreamError: LocalizedError {
    case http(Int), unsupported(String), ended, noEntry
    var errorDescription: String? {
        switch self {
        case .http(let c): return "Il server ha risposto \(c)"
        case .unsupported(let f): return "Formato \(f) non supportato"
        case .ended: return "Lo stream si è interrotto"
        case .noEntry: return "La playlist della radio non contiene stream"
        }
    }
}

/// One HTTP radio connection (SHOUTcast/Icecast): strips ICY metadata, parses MP3/AAC/HE-AAC with
/// AudioFileStream and decodes to PCM with AVAudioConverter, so the stream runs through our own engine
/// (EQ, visualizer, balance) like a file. Remote .pls/.m3u playlists and HLS are reported back via `onRedirect`.
/// All callbacks except `onFormat` may arrive on the stream's private queue.
final class RadioStream: NSObject, URLSessionDataDelegate {
    struct Headers {
        var name: String?
        var genre: String?
        var bitrate: Int?
    }

    static let userAgent = "MusicAmp/0.1"

    var onHeaders: ((Headers) -> Void)?
    /// Decoded PCM format; called synchronously on the stream queue so the engine is reconnected before buffers arrive.
    var onFormat: ((AVAudioFormat) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onTitle: ((String) -> Void)?
    /// A playlist pointed to `url`; `hls` when it is an HLS (.m3u8) stream.
    var onRedirect: ((URL, Bool) -> Void)?
    var onEnd: ((Error?) -> Void)?

    let url: URL
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "musicamp.radio"
        return q
    }()
    private var cancelled = false

    private var playlistBody: Data?
    private var metaInt = 0
    private var untilMeta = 0
    private var metaLeft = 0
    private var metaBuf = Data()

    private var fileStream: AudioFileStreamID?
    private var inFormat: AVAudioFormat?
    private var outFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var maxPacketSize = 0

    init(url: URL) {
        self.url = url
        super.init()
    }

    func start() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        session = s
        task = s.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        queue.addOperation { [self] in
            cancelled = true
            closeParser()
        }
        task?.cancel()
        session?.invalidateAndCancel()
    }

    deinit { closeParser() }

    private func closeParser() {
        if let fs = fileStream { AudioFileStreamClose(fs) }
        fileStream = nil
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !cancelled else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); openParser(hint: 0); return }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            onEnd?(StreamError.http(http.statusCode))
            return
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let ext = url.pathExtension.lowercased()
        metaInt = Int(http.value(forHTTPHeaderField: "icy-metaint") ?? "") ?? 0
        untilMeta = metaInt
        onHeaders?(Headers(name: http.value(forHTTPHeaderField: "icy-name"),
                           genre: http.value(forHTTPHeaderField: "icy-genre"),
                           bitrate: Int(http.value(forHTTPHeaderField: "icy-br")?.split(separator: ",").first ?? "")))

        if type.contains("mpegurl") || type.contains("scpls") || ["m3u", "m3u8", "pls"].contains(ext) {
            playlistBody = Data()   // resolve when complete
        } else if type.contains("ogg") || type.contains("opus") || type.contains("flac") {
            completionHandler(.cancel)
            onEnd?(StreamError.unsupported(type.contains("flac") ? "FLAC" : "Ogg/Opus"))
            return
        } else if type.contains("aac") || type.contains("mp4a") {
            openParser(hint: kAudioFileAAC_ADTSType)
        } else if type.contains("mpeg") || type.contains("mp3") {
            openParser(hint: kAudioFileMP3Type)
        } else {
            openParser(hint: 0)   // let AudioFileStream sniff (e.g. application/octet-stream)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled else { return }
        if playlistBody != nil {
            if (playlistBody?.count ?? 0) < 256_000 { playlistBody?.append(data) }
            return
        }
        stripICY(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled else { return }
        session.finishTasksAndInvalidate()
        if let body = playlistBody {
            let text = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? ""
            if text.contains("#EXT-X-") { onRedirect?(url, true); return }
            guard let entry = Self.firstEntry(text) else { onEnd?(StreamError.noEntry); return }
            onRedirect?(entry, entry.pathExtension.lowercased() == "m3u8")
            return
        }
        onEnd?(error ?? StreamError.ended)
    }

    /// First http(s) URL in a PLS ("File1=…") or M3U body.
    static func firstEntry(_ text: String) -> URL? {
        for raw in Skin.lines(text) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("file"), let eq = line.firstIndex(of: "=") { line = String(line[line.index(after: eq)...]) }
            if line.hasPrefix("http://") || line.hasPrefix("https://"), let u = URL(string: line) { return u }
        }
        return nil
    }

    // MARK: ICY metadata: every `metaInt` audio bytes, one length byte (×16) and "StreamTitle='…';"

    private func stripICY(_ data: Data) {
        guard metaInt > 0 else { feed(data); return }
        var i = data.startIndex
        while i < data.endIndex {
            if metaLeft > 0 {
                let n = min(metaLeft, data.endIndex - i)
                metaBuf.append(data[i..<(i + n)])
                metaLeft -= n
                i += n
                if metaLeft == 0 {
                    parseMetadata(metaBuf)
                    untilMeta = metaInt
                }
            } else if untilMeta == 0 {
                let len = Int(data[i]) * 16
                i += 1
                if len == 0 { untilMeta = metaInt } else { metaLeft = len; metaBuf = Data() }
            } else {
                let n = min(untilMeta, data.endIndex - i)
                feed(data[i..<(i + n)])
                untilMeta -= n
                i += n
            }
        }
    }

    private func parseMetadata(_ d: Data) {
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        guard let r = s.range(of: "StreamTitle='") else { return }
        let rest = s[r.upperBound...]
        let end = rest.range(of: "';")?.lowerBound ?? rest.endIndex
        let title = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if !title.isEmpty { onTitle?(title) }
    }

    // MARK: AudioFileStream → AVAudioConverter

    private func openParser(hint: AudioFileTypeID) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(me, { client, fs, prop, _ in
            Unmanaged<RadioStream>.fromOpaque(client).takeUnretainedValue().property(fs, prop)
        }, { client, bytes, packets, data, descs in
            let d: UnsafeMutablePointer<AudioStreamPacketDescription>? = descs
            Unmanaged<RadioStream>.fromOpaque(client).takeUnretainedValue().packets(bytes, packets, data, d)
        }, hint, &fileStream)
    }

    private func feed<D: DataProtocol>(_ bytes: D) {
        guard let fs = fileStream else { return }
        let chunk = Data(bytes)
        chunk.withUnsafeBytes { p in
            guard let base = p.baseAddress else { return }
            _ = AudioFileStreamParseBytes(fs, UInt32(chunk.count), base, [])
        }
    }

    private func property(_ fs: AudioFileStreamID, _ prop: AudioFileStreamPropertyID) {
        guard prop == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_DataFormat, &size, &asbd)
        // The format list puts HE-AAC (SBR) ahead of its AAC-LC core: decode the richer one.
        var listSize: UInt32 = 0
        var writable: DarwinBoolean = false
        if AudioFileStreamGetPropertyInfo(fs, kAudioFileStreamProperty_FormatList, &listSize, &writable) == noErr, listSize > 0 {
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: Int(listSize) / MemoryLayout<AudioFormatListItem>.size)
            if AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_FormatList, &listSize, &items) == noErr, let first = items.first {
                asbd = first.mASBD
            }
        }
        var cookie: Data?
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(fs, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable) == noErr, cookieSize > 0 {
            var bytes = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &bytes) == noErr { cookie = Data(bytes) }
        }
        var maxPkt: UInt32 = 0
        size = 4
        if AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_PacketSizeUpperBound, &size, &maxPkt) != noErr || maxPkt == 0 {
            size = 4
            AudioFileStreamGetProperty(fs, kAudioFileStreamProperty_MaximumPacketSize, &size, &maxPkt)
        }
        maxPacketSize = Int(maxPkt)

        guard let inF = AVAudioFormat(streamDescription: &asbd),
              let outF = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                       channels: AVAudioChannelCount(max(1, min(2, asbd.mChannelsPerFrame)))),
              let conv = AVAudioConverter(from: inF, to: outF) else {
            onEnd?(StreamError.unsupported("audio"))
            return
        }
        if let cookie { conv.magicCookie = cookie }
        inFormat = inF
        outFormat = outF
        converter = conv
        onFormat?(outF)
    }

    private func packets(_ bytes: UInt32, _ count: UInt32, _ data: UnsafeRawPointer,
                         _ descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard !cancelled, count > 0, let inF = inFormat, let outF = outFormat, let conv = converter else { return }
        var maxPkt = max(maxPacketSize, (Int(bytes) + Int(count) - 1) / Int(count))
        if let d = descs { for i in 0..<Int(count) { maxPkt = max(maxPkt, Int(d[i].mDataByteSize)) } }
        let cb = AVAudioCompressedBuffer(format: inF, packetCapacity: AVAudioPacketCount(count), maximumPacketSize: maxPkt)
        guard Int(bytes) <= Int(count) * maxPkt else { return }
        memcpy(cb.data, data, Int(bytes))
        if let pd = cb.packetDescriptions {
            if let d = descs {
                for i in 0..<Int(count) { pd[i] = d[i] }
            } else {
                let per = Int64(bytes) / Int64(count)
                for i in 0..<Int(count) {
                    pd[i] = AudioStreamPacketDescription(mStartOffset: Int64(i) * per, mVariableFramesInPacket: 0, mDataByteSize: UInt32(per))
                }
            }
        }
        cb.packetCount = count
        cb.byteLength = bytes

        let fpp = max(1, inF.streamDescription.pointee.mFramesPerPacket)
        let ratio = outF.sampleRate / max(1, inF.sampleRate)
        let cap = AVAudioFrameCount(Double(count * max(fpp, 1152)) * max(1, ratio) * 2)
        guard let out = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return cb
        }
        if out.frameLength > 0 { onBuffer?(out) }
    }
}
