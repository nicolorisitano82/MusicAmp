import AVFoundation
import CoreGraphics
import ImageIO

/// `MusicAmp --test-tv [out.png]`: the karaoke drawn for a TV (frame content, drawing time), the live HLS
/// streams (audio for AirPlay, audio + karaoke video for Chromecast): master and media playlists, segments,
/// tracks, and muted system players on the network address. Nothing is sent to a real device.
/// MUSICAMP_TV_DUMP=<folder> saves the TV stream for inspection.
@MainActor
enum TVKaraokeTest {
    private static var fails = 0

    private static func check(_ ok: Bool, _ what: String) {
        print(ok ? "OK  " : "FAIL", what)
        if !ok { fails += 1 }
    }

    private struct Response { var status = 0; var type = ""; var body = Data() }

    private nonisolated static func get(_ url: URL?) -> Response {
        guard let url else { return Response() }
        var res = Response()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { d, r, _ in
            let h = r as? HTTPURLResponse
            res = Response(status: h?.statusCode ?? 0, type: h?.value(forHTTPHeaderField: "Content-Type") ?? "", body: d ?? Data())
            sem.signal()
        }.resume()
        sem.wait()
        return res
    }

    private static func testCover() -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 150, width: 300, height: 150))
        return ctx.makeImage()
    }

    private static let lyrics: Lyrics = {
        let lines: [Lyrics.Line] = [Lyrics.Line(time: 0.5, text: "Hello from the karaoke"), Lyrics.Line(time: 3, text: "Second line here"),
                                    Lyrics.Line(time: 6, text: "Third line"), Lyrics.Line(time: 9, text: "Fourth")]
        return Lyrics(plain: nil, synced: lines, source: "test")
    }()

    private static func state(_ now: Double, lyrics: Lyrics?, cover: CGImage?, backdrop: CGImage?) -> TVKaraoke.State {
        let status: String = lyrics == nil ? "Lyrics not found" : ""
        return TVKaraoke.State(lyrics: lyrics, now: now, title: "Test Song", artist: "Test Artist", cover: cover, backdrop: backdrop,
                               status: status, pulse: 0.3, kick: 0,
                               translate: { (line: String) -> String? in line == "Hello from the karaoke" ? "Ciao dal karaoke" : nil })
    }

    private static func savePNG(_ img: CGImage, _ path: String) {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    /// White pixels in rows y0..<y1 (sampled every other pixel).
    private static func brightPixels(_ img: CGImage, _ y0: Int, _ y1: Int) -> Int {
        guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        var n = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: 100, to: 1180, by: 2) {
                let o = y * img.bytesPerRow + x * 4
                if p[o] > 230, p[o + 1] > 230, p[o + 2] > 230 { n += 1 }
            }
        }
        return n
    }

    private static func tracks(of file: URL) -> ([AVMediaType], Double) {
        let asset = AVURLAsset(url: file)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var types: [AVMediaType] = []
        nonisolated(unsafe) var dur = 0.0
        Task.detached {
            let t = (try? await asset.load(.tracks)) ?? []
            types = t.map(\.mediaType)
            dur = (try? await asset.load(.duration))?.seconds ?? 0
            sem.signal()
        }
        sem.wait()
        return (types, dur)
    }

    /// Video frames per second in a file (decoding timestamps of the samples).
    private nonisolated static func videoFPS(_ file: URL) -> Double {
        let asset = AVURLAsset(url: file)
        guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        Task.detached { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
        sem.wait()
        guard let track else { return 0 }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var times: [Double] = []
        while let sb = out.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        }
        guard let a = times.min(), let b = times.max(), b > a else { return 0 }
        return Double(times.count - 1) / (b - a)
    }

    static func run() -> Int32 {
        let tv = TVKaraoke.shared
        let cover = testCover()
        let backdrop = cover.flatMap(TVKaraoke.blurred)

        // Frame.
        let img = tv.snapshot(state(1.4, lyrics: lyrics, cover: cover, backdrop: backdrop))
        check(img?.width == 1280 && img?.height == 720, "frame 1280×720")
        let args = CommandLine.arguments
        if let img, let i = args.firstIndex(of: "--test-tv"), i + 1 < args.count, args[i + 1].hasSuffix(".png") {
            let out = args[i + 1]
            savePNG(img, out)
            if let c = tv.snapshot(state(0, lyrics: nil, cover: cover, backdrop: backdrop)) {
                savePNG(c, out.replacingOccurrences(of: ".png", with: "-cover.png"))
            }
            print("     frames saved to \(out)")
        }
        if let img {
            let mid = brightPixels(img, 300, 420)
            let top = brightPixels(img, 0, 20)
            check(mid > 300, "the sung line is drawn in the middle (\(mid) bright pixels)")
            check(top < mid / 4, "picture upright (title band at the top, not mirrored)")
        }
        let t0 = Date()
        for i in 0..<20 { _ = tv.snapshot(state(Double(i) * 0.05, lyrics: lyrics, cover: cover, backdrop: backdrop)) }
        let ms = Date().timeIntervalSince(t0) * 1000 / 20
        let budget = 1000 / Double(TVKaraoke.fps)
        check(ms < budget * 0.9, String(format: "drawing a frame: %.1f ms (budget %.0f ms at %d fps)", ms, budget, TVKaraoke.fps))

        // Live HLS: a tone fed in real time, frames at the TV rate.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let live = LiveStream.shared
        do { try live.startDetached(format: fmt) } catch { print("FAIL can't listen: \(error)"); return 1 }
        let video = LiveHLS(name: "tv", videoSize: TVKaraoke.size, fps: TVKaraoke.fps)
        let audio = LiveHLS(name: "audio", metadata: true)
        let coverJPEG: Data? = cover.flatMap { img in
            let d = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, nil)
            return CGImageDestinationFinalize(dest) ? d as Data : nil
        }
        audio.setMetadata(LiveHLS.Metadata(title: "Test Song", artist: "Test Artist", album: "Test Album", cover: coverJPEG))
        live.addHLS(video)
        live.addHLS(audio)
        let feeder = ToneFeeder(live: live, format: fmt)
        feeder.start()
        // Frames on a fixed schedule, like the app's timer.
        var frame = 0
        let clockStart = Date()
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let pb = video.makePixelBuffer() {
                    tv.draw(state(Date().timeIntervalSince(clockStart), lyrics: lyrics, cover: cover, backdrop: backdrop), into: pb)
                    video.appendFrame(pb)
                }
                frame += 1
                RunLoop.main.run(until: clockStart.addingTimeInterval(Double(frame) / Double(TVKaraoke.fps)))
            }
        }
        let pumpStart = Date()
        pump(9)
        print("     frames in 9 s: \(video.frameReport), \(String(format: "%.1f", Double(video.frameStatsOffered) / Date().timeIntervalSince(pumpStart))) offered/s")

        // Paused: the streams stop (no silence), then carry on from the same point.
        let before = (video.clock, audio.clock)
        live.hlsPaused = true
        pump(2)
        let during = (video.clock, audio.clock)
        live.hlsPaused = false
        pump(2)
        let after = (video.clock, audio.clock)
        check(during.0 - before.0 < 0.3 && during.1 - before.1 < 0.3 && after.0 - during.0 > 1.5,
              String(format: "pause: stream clock stops (%.1f → %.1f s) and resumes (%.1f s)", before.0, during.0, after.0))

        for (h, name) in [(video, "tv"), (audio, "audio")] {
            let master = get(live.hlsURL(name, local: true, master: true))
            let masterText = String(decoding: master.body, as: UTF8.self)
            let wantCodecs = h.hasVideo ? "avc1." : "mp4a.40.2"
            check(master.status == 200 && masterText.contains("CODECS=") && masterText.contains(wantCodecs) && masterText.contains("index.m3u8"),
                  "\(name): master playlist declares the codecs: " + (masterText.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF") } ?? "none"))
            let pl = get(live.hlsURL(name, local: true))
            let text = String(decoding: pl.body, as: UTF8.self)
            let segs = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
            check(pl.status == 200 && pl.type.contains("mpegurl") && text.contains("#EXT-X-MAP") && segs.count >= 3,
                  "\(name): live playlist with \(segs.count) segments")
            guard let base = live.hlsURL(name, local: true)?.deletingLastPathComponent() else { continue }
            let mapLine = text.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MAP") }.map(String.init) ?? ""
            let mapName = mapLine.replacingOccurrences(of: "#EXT-X-MAP:URI=", with: "").replacingOccurrences(of: "\"", with: "")
            let initData = get(base.appendingPathComponent(mapName)).body
            var segData = Data()
            if let last = segs.last { segData = get(base.appendingPathComponent(String(last))).body }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-\(name).mp4")
            try? (initData + segData).write(to: file)
            let (types, dur) = tracks(of: file)
            let want: Set<AVMediaType> = h.hasVideo ? [.audio, .video] : [.audio, .metadata]
            let names = types.map(\.rawValue).sorted().joined(separator: "+")
            check(Set(types) == want && dur > 1, "\(name): a segment has \(names), " + String(format: "%.1f s", dur))
            if h.hasVideo {
                let all = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-tv-all.mp4")
                var whole = initData
                for seg in segs { whole += get(base.appendingPathComponent(String(seg))).body }
                try? whole.write(to: all)
                let fps = videoFPS(all)
                check(fps > Double(TVKaraoke.fps) * 0.85, String(format: "tv: video at %.1f fps (target %d), audio in blocks of 93 ms", fps, TVKaraoke.fps))
            }
            // Segments follow each other without holes in the audio.
            let durations = text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
                .compactMap { Double($0.dropFirst(8).replacingOccurrences(of: ",", with: "")) }
            let total = durations.reduce(0, +)
            check(durations.allSatisfy { $0 > 1.5 && $0 < 2.6 }, "\(name): segments of ~2 s (" + durations.map { String(format: "%.2f", $0) }.joined(separator: " ") + ", \(String(format: "%.1f", total)) s)")
        }
        if let dir = ProcessInfo.processInfo.environment["MUSICAMP_TV_DUMP"] {
            video.dump(to: dir)
            print("     TV stream saved to \(dir)")
        }

        // Muted system players on the network address (what a TV or an AirPlay receiver fetches).
        if let u = live.hlsURL("tv", master: true) {
            let player = AVPlayer(url: u)
            player.volume = 0
            player.play()
            let until = Date().addingTimeInterval(12)
            while Date() < until {
                let size = player.currentItem?.presentationSize ?? .zero
                if player.timeControlStatus == .playing, player.currentTime().seconds > 0.3, size.width > 0 { break }
                pump(0.1)
            }
            let size = player.currentItem?.presentationSize ?? .zero
            let err = player.currentItem?.error?.localizedDescription ?? "no error"
            check(player.timeControlStatus == .playing && size == TVKaraoke.size,
                  "system player plays the TV stream from \(u.host ?? "?"): \(Int(size.width))×\(Int(size.height)), \(err)")
            player.pause()
        }
        if let u = live.hlsURL("audio") {
            let item = AVPlayerItem(url: u)
            let collector = MetadataCollector()
            let output = AVPlayerItemMetadataOutput(identifiers: nil)
            output.setDelegate(collector, queue: .main)
            item.add(output)
            let ap = AVPlayer(playerItem: item)
            ap.volume = 0
            ap.play()
            let until = Date().addingTimeInterval(10)
            while Date() < until, !(ap.timeControlStatus == .playing && ap.currentTime().seconds > 0.3) { pump(0.1) }
            check(ap.timeControlStatus == .playing, "system player plays the AirPlay (HLS audio) stream: \(ap.currentItem?.error?.localizedDescription ?? "no error")")
            let until2 = Date().addingTimeInterval(6)
            while Date() < until2, collector.title == nil || collector.cover == nil { pump(0.1) }
            check(collector.title == "Test Song" && collector.artist == "Test Artist" && (collector.cover ?? 0) > 100,
                  "AirPlay stream carries title, artist and cover: \(collector.title ?? "none"), \(collector.artist ?? "none"), cover \(collector.cover ?? 0) bytes")
            ap.pause()
        }
        feeder.stop()
        live.stop()
        print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
        return fails == 0 ? 0 : 1
    }
}

/// A 440 Hz tone pushed into the live stream at real-time pace, on its own thread.
private final class ToneFeeder: @unchecked Sendable {
    let live: LiveStream
    let format: AVAudioFormat
    private var running = false
    private let lock = NSLock()

    init(live: LiveStream, format: AVAudioFormat) { self.live = live; self.format = format }

    func start() {
        running = true
        Thread.detachNewThread { [self] in
            var k = 0
            let start = Date()
            while isRunning {
                guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return }
                b.frameLength = 4096
                let l = b.floatChannelData![0], r = b.floatChannelData![1]
                for i in 0..<4096 {
                    let v = 0.3 * sin(2 * Float.pi * 440 * Float(k * 4096 + i) / 44100)
                    l[i] = v
                    r[i] = v
                }
                live.feed(b)
                k += 1
                let due = start.addingTimeInterval(Double(k * 4096) / 44100)
                Thread.sleep(forTimeInterval: max(0, due.timeIntervalSinceNow))
            }
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func stop() { lock.lock(); running = false; lock.unlock() }
}

/// Timed metadata seen by a player (what AirPlay forwards to a receiver's screen).
private final class MetadataCollector: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var title: String?
    var artist: String?
    var cover: Int?

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        for g in groups {
            for item in g.items {
                if item.identifier == .commonIdentifierTitle { title = item.stringValue }
                if item.identifier == .commonIdentifierArtist { artist = item.stringValue }
                if item.identifier == .commonIdentifierArtwork { cover = item.dataValue?.count }
            }
        }
    }
}
