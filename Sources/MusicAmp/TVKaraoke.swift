import AppKit
import CoreImage
import SwiftUI

/// The karaoke drawn for a TV (Chromecast): 1280×720 frames rendered off screen 15 times a second and
/// written, with the audio, into a live HLS stream (LiveHLS "tv"). Lines and words light up like the
/// full-screen karaoke; without synced lyrics the TV shows the cover, title and artist.
@MainActor
final class TVKaraoke {
    static let shared = TVKaraoke()
    static let size = CGSize(width: 1280, height: 720)
    static let name = "tv"
    /// Frames per second: smooth enough for the word sweep, light on the main thread (a frame takes ~25 ms).
    static let fps = 15

    private var timer: Timer?
    private(set) var hls: LiveHLS?
    private var coverKey = ""
    private var cover: CGImage?
    private var backdrop: CGImage?
    /// Average time to draw one frame (ms), for tests.
    private(set) var renderMS = 0.0
    private var frames = 0

    var active: Bool { timer != nil }

    func start(stream: LiveStream) {
        guard timer == nil else { return }
        let h = LiveHLS(name: TVKaraoke.name, videoSize: TVKaraoke.size, fps: TVKaraoke.fps)
        stream.addHLS(h)
        hls = h
        Ctl.shared.refreshLyrics(evenIfHidden: true)
        let t = Timer(timeInterval: 1.0 / Double(TVKaraoke.fps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop(stream: LiveStream) {
        timer?.invalidate()
        timer = nil
        stream.removeHLS(TVKaraoke.name)
        hls = nil
    }

    private func tick() {
        guard let h = hls, let pb = h.makePixelBuffer() else { return }
        let t0 = Date()
        draw(state(), into: pb)
        renderMS = (renderMS * Double(frames) + Date().timeIntervalSince(t0) * 1000) / Double(frames + 1)
        frames = min(frames + 1, 200)
        h.appendFrame(pb)
    }

    // MARK: State

    struct State {
        var lyrics: Lyrics?
        var now: Double
        var title: String
        var artist: String
        var cover: CGImage?
        var backdrop: CGImage?
        var status: String
        var pulse: Double
        var kick: Double
        var translate: (String) -> String?
    }

    /// What is playing, where in the song, and its lyrics.
    func state() -> State {
        let c = Ctl.shared
        let service = LyricsService.shared
        var title = "MusicAmp", artist = "", now = 0.0
        var image: NSImage?
        var key = ""
        if let e = c.external {
            title = e.title.isEmpty ? e.app.name : e.title; artist = e.artist; now = e.currentTime
            image = e.artwork; key = "ext|\(e.artist)|\(e.title)|\(e.artwork != nil)"
        } else if let t = c.playlist.currentTrack {
            title = t.songTitle ?? t.title; artist = t.artist ?? ""
            now = LyricsClock.shared.time(c.audio) + 0.12
            image = Artwork.cached(t.url); key = "\(t.url.absoluteString)|\(image != nil)"
            if image == nil { Task { _ = await Artwork.load(t.url) } }
        }
        if key != coverKey {
            coverKey = key
            cover = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            backdrop = cover.flatMap(TVKaraoke.blurred)
        }
        MusicPulse.shared.update(c.audio)
        var status = ""
        var lyrics: Lyrics?
        switch service.state {
        case .found(let l):
            if l.synced?.isEmpty == false {
                lyrics = l
            } else {
                // Plain lyrics: time them from the audio on this Mac, as the karaoke does.
                service.autoSyncIfUseful()
                status = service.syncing != nil ? L("Syncing the lyrics with the music…") : L("Lyrics aren’t time-synced")
            }
        case .loading: status = L("Searching for lyrics…")
        case .notFound: status = L("Lyrics not found")
        default: break
        }
        if c.external == nil, c.playlist.currentTrack?.isStream == true { lyrics = nil; status = "" }
        let tr = LyricsTranslator.shared
        return State(lyrics: lyrics, now: now, title: title, artist: artist, cover: cover, backdrop: backdrop, status: status,
                     pulse: MusicPulse.shared.bass, kick: MusicPulse.shared.kick, translate: { tr.translation($0) })
    }

    nonisolated static func blurred(_ img: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: img)
        let scale = 240 / max(1, ci.extent.width)
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blur = small.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4, kCIInputBrightnessKey: -0.05])
        return CIContext().createCGImage(blur, from: small.extent)
    }

    // MARK: Drawing

    func draw(_ s: State, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let r = ImageRenderer(content: TVKaraokeFrame(s: s).frame(width: TVKaraoke.size.width, height: TVKaraoke.size.height))
        r.proposedSize = ProposedViewSize(TVKaraoke.size)
        r.render { _, paint in paint(ctx) }
    }

    /// One frame as an image (tests, previews).
    func snapshot(_ s: State) -> CGImage? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(TVKaraoke.size.width), Int(TVKaraoke.size.height), kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { return nil }
        draw(s, into: pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return ctx?.makeImage()
    }
}

/// The TV picture: blurred cover, title in a corner, previous / current / next lines.
struct TVKaraokeFrame: View {
    let s: TVKaraoke.State
    private let big: CGFloat = 62

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.05, green: 0.18, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let b = s.backdrop {
                Image(decorative: b, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .scaleEffect(1.05 + 0.04 * s.pulse)
                    .frame(width: TVKaraoke.size.width, height: TVKaraoke.size.height).clipped()
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
            if let l = s.lyrics, let lines = l.synced {
                lyricsStage(l, lines).padding(.horizontal, 90).padding(.top, 40)
            } else {
                coverStage
            }
            VStack {
                HStack(spacing: 14) {
                    if let c = s.cover, s.lyrics != nil {
                        Image(decorative: c, scale: 1).resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 22, weight: .bold, design: .rounded))
                        if !s.artist.isEmpty { Text(s.artist).font(.system(size: 18, weight: .medium, design: .rounded)).opacity(0.7) }
                    }
                    .lineLimit(1)
                    Spacer()
                    Text("MusicAmp").font(.system(size: 16, weight: .semibold, design: .rounded)).opacity(0.45)
                }
                .opacity(s.lyrics != nil ? 1 : 0)
                Spacer()
            }
            .padding(36)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func lyricsStage(_ l: Lyrics, _ lines: [Lyrics.Line]) -> some View {
        let cur = l.lineIndex(at: s.now)
        let first = lines.first?.time ?? 0
        return VStack(spacing: big * 0.5) {
            Text(cur.flatMap { $0 > 0 ? lines[$0 - 1].text : nil } ?? " ")
                .font(.system(size: big * 0.45, weight: .semibold, design: .rounded)).opacity(0.35).lineLimit(1)
            VStack(spacing: big * 0.3) {
                if let c = cur, !lines[c].text.isEmpty {
                    KaraokeLine(words: l.timedWords(c), now: s.now, size: big, center: true, pulse: s.pulse)
                    if let tr = s.translate(lines[c].text) {
                        Text(tr).font(.system(size: big * 0.42, weight: .semibold, design: .rounded)).opacity(0.72)
                    }
                } else if let c = cur {
                    BreakDots(progress: (s.now - lines[c].time) / max(1, l.gap(after: c)), size: big * 0.35, kick: s.kick)
                } else {
                    BreakDots(progress: first > 0 ? s.now / first : 1, size: big * 0.35, kick: s.kick)
                }
            }
            .frame(minHeight: big * 2.6)
            VStack(spacing: big * 0.22) {
                ForEach(1...2, id: \.self) { k in
                    let i = (cur ?? -1) + k
                    Text(lines.indices.contains(i) ? lines[i].text : " ")
                        .font(.system(size: big * (k == 1 ? 0.5 : 0.4), weight: .semibold, design: .rounded))
                        .opacity(k == 1 ? 0.5 : 0.28).lineLimit(1)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var coverStage: some View {
        HStack(spacing: 56) {
            Group {
                if let c = s.cover {
                    Image(decorative: c, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").font(.system(size: 120, weight: .light)).opacity(0.5) }
                }
            }
            .frame(width: 400, height: 400).clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .scaleEffect(1 + 0.02 * s.pulse)
            VStack(alignment: .leading, spacing: 14) {
                Text(s.title).font(.system(size: 52, weight: .bold, design: .rounded)).lineLimit(3)
                if !s.artist.isEmpty { Text(s.artist).font(.system(size: 34, weight: .medium, design: .rounded)).opacity(0.75).lineLimit(2) }
                if !s.status.isEmpty { Text(s.status).font(.system(size: 22, weight: .medium, design: .rounded)).opacity(0.45).padding(.top, 18) }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
