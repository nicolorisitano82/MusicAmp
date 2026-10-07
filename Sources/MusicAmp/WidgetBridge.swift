import AppKit
import MusicAmpShared
import WidgetKit

/// Feeds the "Now Playing" widget: writes the state (and a small cover) into the folder the widget may read,
/// asks WidgetKit to reload when something visible changes, and runs the commands the widget's buttons post.
/// The same commands arrive as `musicamp://play`, `…/next` etc. (Shortcuts "Open URL", scripts, links).
final class WidgetBridge {
    static let shared = WidgetBridge()
    private weak var ctl: Ctl?
    private var scheduled = false
    private var last: WidgetState?
    private var artworkFor: URL?
    private var artworkName: String?

    func start(ctl: Ctl) {
        self.ctl = ctl
        try? FileManager.default.createDirectory(at: WidgetShared.folder, withIntermediateDirectories: true)
        let dnc = DistributedNotificationCenter.default()
        for cmd in MusicAmpCommand.allCases {
            dnc.addObserver(forName: cmd.notificationName, object: nil, queue: .main) { [weak self] _ in self?.perform(cmd) }
        }
        setNeedsUpdate()
    }

    // MARK: Commands

    func perform(_ cmd: MusicAmpCommand) {
        guard let c = ctl else { return }
        switch cmd {
        case .play: if c.audio.state != .playing { c.play() }
        case .pause: if c.audio.state == .playing { c.pause() }
        case .playPause: if c.audio.state == .playing { c.pause() } else { c.play() }
        case .next: c.next()
        case .previous: c.previous()
        case .stop: c.stop()
        case .open:
            NSApp.activate(ignoringOtherApps: true)
            c.mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// `musicamp://<command>`, plus `musicamp://volume?level=40`, `musicamp://sleep?minutes=30` (0 = off),
    /// `musicamp://sleep?end=track`.
    func handle(_ url: URL) {
        guard let c = ctl else { return }
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let q = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap { i in i.value.map { (i.name, $0) } } ?? [],
                           uniquingKeysWith: { a, _ in a })
        if let cmd = MusicAmpCommand(rawValue: name) { perform(cmd); return }
        switch name {
        case "volume":
            if let v = Double(q["level"] ?? "") { c.volume = max(0, min(100, v)); c.mainView.needsDisplay = true }
        case "sleep":
            if q["end"] == "track" { Scheduler.shared.sleepAtEndOfTrack() }
            else if let m = Double(q["minutes"] ?? ""), m > 0 { Scheduler.shared.startSleep(minutes: m) }
            else { Scheduler.shared.cancelSleep() }
        default: NSSound.beep()
        }
    }

    // MARK: State

    func setNeedsUpdate() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.scheduled = false
            self?.write()
        }
    }

    /// MusicAmp is quitting: the widget shows it stopped.
    func terminated() {
        var s = state()
        s.running = false
        s.playing = false
        save(s)
    }

    private func state() -> WidgetState {
        var s = WidgetState()
        s.running = true
        s.updated = Date()
        let sch = Scheduler.shared
        s.sleepAt = sch.sleep == .endOfTrack ? nil : sch.sleepDate
        s.sleepEndOfTrack = sch.sleep == .endOfTrack
        s.alarm = sch.nextAlarm
        s.ringing = sch.ringing
        guard let c = ctl, let t = c.playlist.currentTrack else { return s }
        s.hasTrack = true
        s.isStream = t.isStream
        s.playing = c.audio.state == .playing
        s.paused = c.audio.state == .paused
        s.elapsed = c.audio.hasSource ? c.audio.currentTime : 0
        s.duration = t.isStream ? 0 : (c.audio.hasSource ? c.audio.duration : (t.duration ?? 0))
        if t.isStream {
            // "Artist - Title" from the station's live metadata.
            let parts = (t.streamTitle ?? "").components(separatedBy: " - ")
            s.title = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : (t.streamTitle ?? t.title)
            s.artist = parts.count > 1 ? parts[0] : nil
            s.album = t.title
        } else {
            s.title = t.songTitle ?? t.title
            s.artist = t.artist
            s.album = t.album
        }
        if artworkFor == t.url { s.artwork = artworkName } else { loadArtwork(t.url) }
        return s
    }

    private func write() {
        let s = state()
        if let l = last, l.sameContent(as: s) { return }
        save(s)
    }

    private func save(_ s: WidgetState) {
        guard let data = WidgetShared.encode(s) else { return }
        try? data.write(to: WidgetShared.stateFile, options: .atomic)
        last = s
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.kind)
    }

    /// A 300 px PNG of the cover, under a name unique to the track; older covers are removed.
    private func loadArtwork(_ url: URL) {
        artworkFor = url
        artworkName = nil
        Task { @MainActor in
            let img = await Artwork.load(url)
            guard self.artworkFor == url else { return }
            let folder = WidgetShared.folder
            for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasPrefix("art-") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(f))
            }
            if let img, let png = WidgetBridge.png(img, side: 300) {
                let name = "art-\(UInt(bitPattern: url.absoluteString.hashValue)).png"
                try? png.write(to: folder.appendingPathComponent(name), options: .atomic)
                self.artworkName = name
            }
            self.write()
        }
    }

    static func png(_ img: NSImage, side: Int) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Aspect fill into a square.
        let w = Double(cg.width), h = Double(cg.height), k = Double(side) / min(w, h)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: (Double(side) - w * k) / 2, y: (Double(side) - h * k) / 2, width: w * k, height: h * k))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}
