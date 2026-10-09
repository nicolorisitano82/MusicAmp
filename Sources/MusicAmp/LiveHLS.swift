import AVFoundation
import CoreMedia

/// A live HLS stream (fMP4 segments of ~2 s) made with AVAssetWriter, served by LiveStream under /<name>/.
/// Audio only for AirPlay (AVPlayer plays HLS reliably over AirPlay, URL hand-off included); audio plus a
/// rendered video (the karaoke for the TV) for Chromecast. Audio and video share one clock, so the lyrics on
/// the TV stay in sync with the sound however much the receiver buffers.
final class LiveHLS: NSObject, AVAssetWriterDelegate {
    struct Segment { let seq: Int; let duration: Double; let data: Data; let discontinuity: Bool }

    let name: String
    let videoSize: CGSize?
    let fps: Int
    private let queue = DispatchQueue(label: "musicamp.hls")
    private var writer: AVAssetWriter?
    private var audioIn: AVAssetWriterInput?
    private var videoIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var rate: Double = 0
    private var samples: Int64 = 0
    private var started = false
    private var lastVideoPTS = CMTime.negativeInfinity
    /// When the last audio block arrived: frames between two blocks get times in between (audio comes in
    /// blocks of ~90 ms, frames every ~67 ms).
    private var lastAudioWall = Date()
    /// Frames offered, written, and dropped (encoder busy / out of order), for tests.
    private(set) var frameStats = (offered: 0, written: 0, busy: 0, late: 0)
    private var initData: Data?
    private var segments: [Segment] = []
    private var nextSeq = 0
    private var discontinuityPending = false
    /// Audio waiting for the encoder (never dropped: a hole in the audio is a stutter on the receiver).
    private var pendingAudio: [CMSampleBuffer] = []
    private var generation = 0
    static let keep = 10
    /// Last time a player asked for the playlist; unused streams stop being encoded.
    private(set) var lastRequest = Date()

    /// Title, artist, album and cover carried in the stream (AirPlay screens show them).
    struct Metadata: Equatable { var title = ""; var artist = ""; var album = ""; var cover: Data? }
    let carriesMetadata: Bool
    private var metaIn: AVAssetWriterInput?
    private var metaAdaptor: AVAssetWriterInputMetadataAdaptor?
    private var metadata = Metadata()
    /// The stream time up to which metadata has been written (it is repeated in 2-second groups).
    private var metaUntil = CMTime.zero

    func setMetadata(_ m: Metadata) {
        queue.async { [self] in
            guard m != metadata else { return }
            metadata = m
            // Start a new group now.
            if rate > 0 { metaUntil = min(metaUntil, CMTime(value: samples, timescale: CMTimeScale(rate))) }
        }
    }

    private func writeMetadata(upTo now: CMTime) {
        guard let input = metaIn, let ad = metaAdaptor, now >= metaUntil else { return }
        var items: [AVMetadataItem] = []
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, _ type: CFString) {
            let m = AVMutableMetadataItem()
            m.identifier = id; m.value = value; m.dataType = type as String
            items.append(m)
        }
        if !metadata.title.isEmpty { item(.commonIdentifierTitle, metadata.title as NSString, kCMMetadataBaseDataType_UTF8) }
        if !metadata.artist.isEmpty { item(.commonIdentifierArtist, metadata.artist as NSString, kCMMetadataBaseDataType_UTF8) }
        if !metadata.album.isEmpty { item(.commonIdentifierAlbumName, metadata.album as NSString, kCMMetadataBaseDataType_UTF8) }
        if let c = metadata.cover { item(.commonIdentifierArtwork, c as NSData, kCMMetadataBaseDataType_JPEG) }
        let range = CMTimeRange(start: metaUntil, duration: CMTime(seconds: 2, preferredTimescale: 600))
        guard !items.isEmpty, input.isReadyForMoreMediaData else { return }
        if ad.append(AVTimedMetadataGroup(items: items, timeRange: range)) { metaUntil = range.end }
    }

    static func metadataFormat() -> CMFormatDescription? {
        let specs: [[String: Any]] = [
            (AVMetadataIdentifier.commonIdentifierTitle, kCMMetadataBaseDataType_UTF8),
            (.commonIdentifierArtist, kCMMetadataBaseDataType_UTF8),
            (.commonIdentifierAlbumName, kCMMetadataBaseDataType_UTF8),
            (.commonIdentifierArtwork, kCMMetadataBaseDataType_JPEG),
        ].map { [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: $0.0.rawValue,
                 kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: $0.1 as String] }
        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
                                                                    metadataSpecifications: specs as CFArray, formatDescriptionOut: &desc)
        return desc
    }

    /// Frames are drawn on the main thread: their buffers come from a pool of our own, no wait on the encoder.
    private let pool: CVPixelBufferPool?

    init(name: String, videoSize: CGSize? = nil, fps: Int = 20, metadata: Bool = false) {
        self.name = name; self.videoSize = videoSize; self.fps = fps; carriesMetadata = metadata
        var p: CVPixelBufferPool?
        if let size = videoSize {
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: Int(size.width),
                kCVPixelBufferHeightKey: Int(size.height), kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary, &p)
        }
        pool = p
    }

    var hasVideo: Bool { videoSize != nil }
    /// Seconds of audio written so far (the stream's clock).
    var clock: Double { queue.sync { rate > 0 ? Double(samples) / rate : 0 } }
    var segmentCount: Int { queue.sync { segments.count } }
    /// The writer accepted a metadata track (tests).
    var hasMetadataTrack: Bool { queue.sync { metaIn != nil } }
    var frameStatsOffered: Int { queue.sync { frameStats.offered } }
    var frameReport: String { queue.sync { "offered \(frameStats.offered), written \(frameStats.written), encoder busy \(frameStats.busy), late \(frameStats.late)" } }

    // MARK: Writer

    private func makeWriter(rate: Double) -> Bool {
        let w = AVAssetWriter(contentType: .mpeg4Movie)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
        w.initialSegmentStartTime = .zero
        w.delegate = self
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: StreamEncoder.aacBitRate,
        ])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(a) else { return false }
        w.add(a)
        if let size = videoSize {
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_500_000, AVVideoMaxKeyFrameIntervalKey: fps, AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoAllowFrameReorderingKey: false,
                ],
            ])
            v.expectsMediaDataInRealTime = true
            guard w.canAdd(v) else { return false }
            w.add(v)
            videoIn = v
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        }
        metaIn = nil; metaAdaptor = nil
        if carriesMetadata, let fmt = LiveHLS.metadataFormat() {
            let m = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: fmt)
            m.expectsMediaDataInRealTime = true
            if w.canAdd(m) {
                w.add(m)
                metaIn = m
                metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: m)
            }
        }
        metaUntil = .zero
        guard w.startWriting() else { return false }
        writer = w
        audioIn = a
        if generation > 0 { segments = []; initData = nil }
        self.rate = rate
        samples = 0
        lastAudioWall = Date()
        started = false
        lastVideoPTS = .negativeInfinity
        generation += 1
        return true
    }

    func stop() {
        queue.sync {
            // With a live metadata track, cancelWriting can spin forever: finish without waiting and let it go.
            if let w = writer, w.status == .writing {
                metaIn?.markAsFinished(); audioIn?.markAsFinished(); videoIn?.markAsFinished()
                w.finishWriting {}
            }
            writer = nil; audioIn = nil; videoIn = nil; adaptor = nil; metaIn = nil; metaAdaptor = nil
            segments = []; initData = nil; pendingAudio = []
        }
    }

    // MARK: Input

    /// Audio from the engine (Float32), at real-time pace; silence when nothing plays.
    func append(_ buf: AVAudioPCMBuffer) {
        queue.async { [self] in
            if writer == nil || abs(buf.format.sampleRate - rate) > 0.5 || writer?.status == .failed {
                if let old = writer { discontinuityPending = true; LiveHLS.retire(old); writer = nil }
                guard makeWriter(rate: buf.format.sampleRate) else { return }
            }
            guard let w = writer, let a = audioIn else { return }
            if !started { w.startSession(atSourceTime: .zero); started = true }
            let pts = CMTime(value: samples, timescale: CMTimeScale(rate))
            guard let sb = LiveHLS.sampleBuffer(buf, pts: pts) else { return }
            samples += Int64(buf.frameLength)
            lastAudioWall = Date()
            pendingAudio.append(sb)
            while let first = pendingAudio.first, a.isReadyForMoreMediaData {
                guard a.append(first) else { break }
                pendingAudio.removeFirst()
            }
            writeMetadata(upTo: pts)
            // Way behind (encoder stuck): restart rather than grow without end.
            if pendingAudio.count > 200, let old = writer { pendingAudio = []; discontinuityPending = true; LiveHLS.retire(old); writer = nil }
        }
    }

    /// A video frame for the audio being written now.
    func appendFrame(_ pixels: CVPixelBuffer) {
        queue.async { [self] in
            guard started, let v = videoIn, let ad = adaptor, rate > 0 else { return }
            // The stream's clock now: the audio written so far plus the time since its last block (at most one block).
            let since = min(Date().timeIntervalSince(lastAudioWall), 0.2)
            var pts = CMTime(seconds: Double(samples) / rate + since, preferredTimescale: 90_000)
            if lastVideoPTS == .negativeInfinity { pts = .zero }   // video starts with the audio
            frameStats.offered += 1
            guard pts > lastVideoPTS else { frameStats.late += 1; return }
            guard v.isReadyForMoreMediaData else { frameStats.busy += 1; return }
            frameStats.written += 1
            if ad.append(pixels, withPresentationTime: pts) { lastVideoPTS = pts }
        }
    }

    /// An empty frame from the adaptor's pool (falls back to a fresh buffer before the writer starts).
    func makePixelBuffer() -> CVPixelBuffer? {
        guard let size = videoSize else { return nil }
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        if pb == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        }
        return pb
    }

    /// Ends a writer that is being replaced, without blocking.
    static func retire(_ w: AVAssetWriter) {
        guard w.status == .writing else { return }
        w.inputs.forEach { $0.markAsFinished() }
        w.finishWriting {}
    }

    static func sampleBuffer(_ buf: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buf.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: buf.format.formatDescription, sampleCount: CMItemCount(buf.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sb) == noErr, let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: buf.audioBufferList) == noErr else { return nil }
        return sb
    }

    // MARK: Segments

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        // Called on the writer's queue: hop to ours.
        let report = segmentReport?.trackReports.map(\.duration.seconds).max() ?? 2
        queue.async { [self] in
            guard writer === self.writer else { return }
            switch segmentType {
            case .initialization:
                initData = segmentData
            case .separable:
                segments.append(Segment(seq: nextSeq, duration: report.isFinite && report > 0 ? report : 2, data: segmentData, discontinuity: discontinuityPending))
                discontinuityPending = false
                nextSeq += 1
                if segments.count > LiveHLS.keep { segments.removeFirst(segments.count - LiveHLS.keep) }
            @unknown default: break
            }
        }
    }

    // MARK: HTTP

    /// (content type, body) for a path inside /<name>/, or nil.
    func serve(_ file: String) -> (String, Data)? {
        queue.sync {
            if file == "master.m3u8" {
                lastRequest = Date()
                guard let i = initData else { return nil }
                var codecs = ["mp4a.40.2"]
                var extra = ""
                if let v = LiveHLS.avcCodec(i), let size = videoSize {
                    codecs.insert(v, at: 0)
                    let w = Int(size.width), h = Int(size.height)
                    extra = ",RESOLUTION=\(w)x\(h),FRAME-RATE=\(fps).000"
                }
                let bw: Int = hasVideo ? 2_800_000 : 220_000
                let list: String = codecs.joined(separator: ",")
                var m = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
                m += "#EXT-X-STREAM-INF:BANDWIDTH=\(bw),AVERAGE-BANDWIDTH=\(bw),CODECS=\"\(list)\"\(extra)\n"
                m += "index.m3u8\n"
                return ("application/vnd.apple.mpegurl", Data(m.utf8))
            }
            if file == "index.m3u8" {
                lastRequest = Date()
                guard initData != nil, let first = segments.first else { return nil }
                let target = Int((segments.map(\.duration).max() ?? 2).rounded(.up))
                var m = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first.seq)\n"
                // Start a few segments behind the newest: a receiver at the very edge stalls waiting for the next one.
                m += "#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-START:TIME-OFFSET=-6.0\n#EXT-X-MAP:URI=\"init\(generation).mp4\"\n"
                for s in segments {
                    if s.discontinuity { m += "#EXT-X-DISCONTINUITY\n" }
                    m += String(format: "#EXTINF:%.3f,\n", s.duration) + "seg\(s.seq).m4s\n"
                }
                return ("application/vnd.apple.mpegurl", Data(m.utf8))
            }
            let type = hasVideo ? "video/mp4" : "audio/mp4"
            if file.hasPrefix("init"), file.hasSuffix(".mp4"), let d = initData { return (type, d) }
            if file.hasPrefix("seg"), file.hasSuffix(".m4s"), let n = Int(file.dropFirst(3).dropLast(4)),
               let s = segments.first(where: { $0.seq == n }) { return (type, s.data) }
            return nil
        }
    }

    /// Writes the playlist, the init segment and the segments to `dir` (debugging).
    func dump(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let (_, pl) = serve("index.m3u8") else { return }
        try? pl.write(to: URL(fileURLWithPath: dir + "/index.m3u8"))
        let text = String(decoding: pl, as: UTF8.self)
        for line in text.split(separator: "\n") {
            var name = String(line)
            if name.hasPrefix("#EXT-X-MAP") {
                name = name.replacingOccurrences(of: "#EXT-X-MAP:URI=", with: "").replacingOccurrences(of: "\"", with: "")
            } else if name.hasPrefix("#") { continue }
            if let (_, d) = serve(name) { try? d.write(to: URL(fileURLWithPath: dir + "/" + name)) }
        }
    }

    /// "avc1.PPCCLL" from the avcC box of an init segment.
    static func avcCodec(_ d: Data) -> String? {
        guard let r = d.range(of: Data("avcC".utf8)), r.upperBound + 4 <= d.endIndex else { return nil }
        let b = d[r.upperBound...]
        let p = b[b.startIndex + 1], c = b[b.startIndex + 2], l = b[b.startIndex + 3]
        return String(format: "avc1.%02x%02x%02x", p, c, l)
    }
}
