import AppKit

/// Dynamic Dock icon: while a track is loaded the icon becomes its cover (the app icon when it has none) with the
/// track's waveform along the bottom (green up to the playhead; a plain bar until the waveform is ready); paused it
/// dims and shows a pause sign; radio shows "LIVE". Back to the normal icon when playback stops, except in Dock mode,
/// where the icon is the player and always shows the current track (a play sign when stopped).
final class DockIcon {
    static let shared = DockIcon()
    private weak var ctl: Ctl?
    private let view = DockTileView()
    private var timer: Timer?
    private var coverFor: URL?
    private var showing = false

    func start(ctl: Ctl) {
        self.ctl = ctl
        update()
    }

    /// Transport, track or setting changed: redraw now and keep the progress moving while playing.
    func update() {
        guard let c = ctl else { return }
        let state = c.audio.state
        let dock = DockMode.shared.active
        guard let t = c.playlist.currentTrack, dock || (c.dockIconLive && state != .stopped && c.audio.hasSource) else {
            if dock { showIdle() } else { restore() }
            return
        }
        if coverFor != t.url {
            coverFor = t.url
            view.cover = Artwork.cached(t.url)
            if view.cover == nil {
                let url = t.url
                Task { @MainActor in
                    let img = await Artwork.load(url)
                    guard self.coverFor == url else { return }
                    self.view.cover = img
                    self.redraw()
                }
            }
        }
        view.isStream = t.isStream
        view.paused = state != .playing
        view.stopped = state == .stopped
        view.progress = t.isStream || c.audio.duration <= 0 || state == .stopped ? (state == .stopped && !t.isStream ? 0 : nil)
            : min(1, max(0, c.audio.currentTime / c.audio.duration))
        // The waveform (computed in the background the first time; the bar stands in meanwhile).
        view.waveform = t.isStream ? nil : WaveformStore.shared.waveform(for: t.url)
        if !showing {
            NSApp.dockTile.contentView = view
            showing = true
        }
        redraw()
        // One step per second is plenty for a 128-point icon, and cheap; nothing runs while paused.
        if state == .playing, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
            timer?.tolerance = 0.3
        } else if state != .playing {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Tags were edited: reload the cover if it is the current track's.
    func coverChanged(_ urls: Set<URL>) {
        guard let u = coverFor, urls.contains(u) else { return }
        coverFor = nil
        lastSignature = ""
        update()
    }

    private var lastSignature = ""

    private func redraw() {
        // Redraw only when something visible changed (the bar moves by whole points).
        let sig = "\(coverFor?.absoluteString ?? "")|\(view.cover != nil)|\(view.paused)|\(view.stopped)|\(view.isStream)|\(view.waveform != nil)|\(view.progress.map { Int($0 * 200) } ?? -1)"
        guard sig != lastSignature else { return }
        lastSignature = sig
        view.needsDisplay = true
        NSApp.dockTile.display()
    }

    /// Dock mode with nothing loaded: the app icon with a play sign.
    private func showIdle() {
        timer?.invalidate()
        timer = nil
        coverFor = nil
        view.cover = nil
        view.waveform = nil
        view.progress = nil
        view.isStream = false
        view.paused = true
        view.stopped = true
        if !showing { NSApp.dockTile.contentView = view; showing = true }
        redraw()
    }

    private func restore() {
        timer?.invalidate()
        timer = nil
        guard showing else { return }
        showing = false
        coverFor = nil
        lastSignature = ""
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

/// What the Dock draws: the icon-shaped cover, a progress bar, a pause sign or LIVE badge.
final class DockTileView: NSView {
    var cover: NSImage?
    var progress: Double?
    var paused = false
    var stopped = false
    var isStream = false
    var waveform: Waveform?

    override func draw(_ dirty: NSRect) {
        let b = bounds
        // macOS icon grid: the artwork square is ~80% of the tile, with a continuous-corner radius of ~22.5%.
        let side = b.width * 0.8
        let art = NSRect(x: b.midX - side / 2, y: b.midY - side / 2 + b.height * 0.01, width: side, height: side)
        let shape = NSBezierPath(roundedRect: art, xRadius: side * 0.225, yRadius: side * 0.225)

        if let cover {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = side * 0.03
            shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            // Aspect fill.
            let s = cover.size
            let k = max(art.width / max(1, s.width), art.height / max(1, s.height))
            let w = s.width * k, h = s.height * k
            cover.draw(in: NSRect(x: art.midX - w / 2, y: art.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            // No cover: the app icon (already shaped, with its own shadow), the overlays clipped to its square.
            NSImage(named: NSImage.applicationIconName)?.draw(in: b)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
        }
        if paused {
            NSColor.black.withAlphaComponent(0.45).setFill()
            art.fill()
        }

        // Bottom strip: a soft gradient so the bar reads on any cover.
        let strip = NSRect(x: art.minX, y: art.minY, width: art.width, height: art.height * 0.3)
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.65), NSColor.black.withAlphaComponent(0)])?.draw(in: strip, angle: 90)

        let inset = art.width * 0.1
        let barH = max(3, art.height * 0.055)
        let bar = NSRect(x: art.minX + inset, y: art.minY + art.height * 0.085, width: art.width - inset * 2, height: barH)
        if isStream {
            let text = NSAttributedString(string: "● LIVE", attributes: [
                .font: NSFont.systemFont(ofSize: art.height * 0.11, weight: .heavy),
                .foregroundColor: NSColor(red: 0.2, green: 0.95, blue: 0.2, alpha: 1),
            ])
            let ts = text.size()
            text.draw(at: NSPoint(x: art.midX - ts.width / 2, y: bar.midY - ts.height / 2))
        } else if let p = progress, let w = waveform {
            // The waveform: thin bars, green up to the playhead.
            let area = NSRect(x: art.minX + inset * 0.7, y: art.minY + art.height * 0.06, width: art.width - inset * 1.4, height: art.height * 0.2)
            let bars = 30
            let bw = area.width / CGFloat(bars)
            for i in 0..<bars {
                let a = Double(i) / Double(bars), b = Double(i + 1) / Double(bars)
                let h = max(art.height * 0.012, CGFloat(w.level(from: a, to: b)) * area.height)
                let r = NSRect(x: area.minX + CGFloat(i) * bw + bw * 0.12, y: area.midY - h / 2, width: bw * 0.76, height: h)
                (a < p ? NSColor(red: 0.2, green: 0.95, blue: 0.2, alpha: 1) : NSColor.white.withAlphaComponent(0.55)).setFill()
                NSBezierPath(roundedRect: r, xRadius: bw * 0.3, yRadius: bw * 0.3).fill()
            }
        } else if let p = progress {
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
            var done = bar
            done.size.width = max(barH, bar.width * CGFloat(p))
            // Winamp's display green.
            NSColor(red: 0.2, green: 0.95, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(roundedRect: done, xRadius: barH / 2, yRadius: barH / 2).fill()
        }
        if stopped {
            // Stopped (Dock mode): a play sign, since a click starts playback.
            let h = art.height * 0.3, w = h * 0.86
            let x = art.midX - w * 0.4, y = art.midY - h / 2 + art.height * 0.05
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: x, y: y)); tri.line(to: NSPoint(x: x, y: y + h)); tri.line(to: NSPoint(x: x + w, y: y + h / 2)); tri.close()
            NSColor.white.withAlphaComponent(0.92).setFill()
            tri.fill()
        } else if paused {
            let w = art.width * 0.075, h = art.height * 0.26, gap = w * 0.8
            NSColor.white.withAlphaComponent(0.92).setFill()
            for dx in [-gap / 2 - w, gap / 2] {
                NSBezierPath(roundedRect: NSRect(x: art.midX + dx, y: art.midY - h / 2 + art.height * 0.05, width: w, height: h),
                             xRadius: w * 0.3, yRadius: w * 0.3).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
