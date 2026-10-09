import AppKit
import SwiftUI

extension Ctl {
    @objc func showLyrics() {
        if lyricsWindowRef == nil {
            let w = LyricsWindow(contentViewController: NSHostingController(rootView: LyricsView(ctl: self, service: .shared)))
            w.ctl = self
            w.title = L("Lyrics")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovable = false   // moved by the docking drag (snap + stick to the player), see LyricsWindow
            w.isReleasedWhenClosed = false
            if !w.setFrameUsingName("MusicAmpLyrics") {
                // First time: docked to the right of the player, top-aligned with the main window.
                let player = visibleWindows.map(\.frame).reduce(mainWindow.frame) { $0.union($1) }
                w.setFrame(CGRect(x: player.maxX, y: mainWindow.frame.maxY - max(player.height, 420),
                                  width: 400, height: max(player.height, 420)), display: false)
            }
            w.setFrameAutosaveName("MusicAmpLyrics")
            let nc = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification, NSWindow.willEnterFullScreenNotification] {
                // A hidden child would come back with its parent: leave the group first.
                nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.detachGroups() }
            }
            for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didExitFullScreenNotification] {
                nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.updateWindowGroups() }
            }
            nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.updateWindowGroups() }
            }
            lyricsWindowRef = w
        }
        refreshLyrics()
        NSApp.activate(ignoringOtherApps: true)
        lyricsWindowRef?.makeKeyAndOrderFront(nil)
        updateWindowGroups()
    }

    /// Full-screen karaoke on the screen of the lyrics window (or the main screen).
    @objc func showKaraoke() {
        if karaokeWindowRef == nil {
            let w = KaraokeWindow(contentViewController: NSHostingController(rootView: KaraokeView(ctl: self, service: .shared)))
            w.title = L("Karaoke")
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.collectionBehavior = [.fullScreenPrimary]
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            karaokeWindowRef = w
        }
        refreshLyrics(force: false, evenIfHidden: true)
        guard let w = karaokeWindowRef else { return }
        let screen = lyricsWindowRef?.screen ?? NSScreen.main
        if let f = screen?.frame { w.setFrame(f.insetBy(dx: f.width * 0.1, dy: f.height * 0.1), display: false) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
    }

    /// Looks lyrics up for what is playing, only while a lyrics view is open (no network otherwise).
    func refreshLyrics(force: Bool = false, evenIfHidden: Bool = false) {
        let tv = MainActor.assumeIsolated { TVKaraoke.shared.active || LiveVideo.shared.active }
        let open = lyricsWindowRef?.isVisible == true || karaokeWindowRef?.isVisible == true || tv
        guard open || force || evenIfHidden else { return }
        var q = playlist.currentTrack.flatMap { LyricsService.query(for: $0, duration: audio.duration) }
        // Music app / Spotify as the source: what that app plays.
        if let e = external { q = e.title.isEmpty ? nil : LyricsService.Query(artist: e.artist, title: e.title, album: e.album, duration: e.duration, file: nil) }
        LyricsService.shared.load(q, force: force)
    }
}

/// Lyrics panel that docks like a Winamp window: dragging its header snaps it to the player and, once
/// touching, it moves with the main window and joins its Mission Control group.
final class LyricsWindow: NSWindow {
    weak var ctl: Ctl?

    override func sendEvent(_ e: NSEvent) {
        guard e.type == .leftMouseDown, let ctl, isDragArea(e.locationInWindow) else { return super.sendEvent(e) }
        if e.clickCount == 2 { return super.sendEvent(e) }
        makeKeyAndOrderFront(nil)
        ctl.beginDrag(self)
        while let n = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), n.type == .leftMouseDragged {
            ctl.continueDrag()
        }
        ctl.endDrag()
    }

    /// The header strip, minus the traffic lights and the resize edges.
    private func isDragArea(_ p: NSPoint) -> Bool {
        let h = frame.height, w = frame.width
        guard !styleMask.contains(.fullScreen), p.y > h - 92, p.y < h - 5, p.x > 5, p.x < w - 5 else { return false }
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let btn = standardWindowButton(b), btn.convert(btn.bounds, to: nil).insetBy(dx: -4, dy: -4).contains(p) { return false }
        }
        return true
    }
}

/// Esc leaves full screen and closes the karaoke.
final class KaraokeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
        orderOut(nil)
    }
}

// MARK: Shared pieces

/// Bass and loudness of what is playing, smoothed for animations (karaoke glow, backdrop pulse, dots).
/// Fed by the engine's analysis tap; several views may call `update` in the same frame.
final class MusicPulse {
    static let shared = MusicPulse()
    private(set) var bass = 0.0      // 0…1, fast attack, slow release
    private(set) var level = 0.0     // 0…1, overall
    private(set) var kick = 0.0      // 0…1, jumps on a bass hit, then fades
    private var slowBass = 0.0
    private var last = Date.distantPast

    func update(_ audio: AudioEngine) {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(last))
        guard dt > 0.008 else { return }
        last = now
        var b = 0.0, l = 0.0
        if audio.state == .playing {
            let spec = audio.visData().0
            if spec.count >= 20 {
                b = Double(spec.prefix(12).reduce(0, +)) / 12
                l = Double(spec.reduce(0, +)) / Double(spec.count)
            }
        }
        bass += (b - bass) * (b > bass ? 0.55 : min(1, dt * 5))
        level += (l - level) * min(1, dt * 8)
        slowBass += (b - slowBass) * min(1, dt * 0.8)
        if b > slowBass * 1.25 + 0.06, b - bass > -0.05 { kick = max(kick, min(1, (b - slowBass) * 3)) }
        kick = max(0, kick - dt * 3.2)
    }
}

/// Blurred cover art (or a gradient) behind the lyrics; it breathes with the bass when `pulse` > 0.
struct LyricsBackdrop: View {
    let cover: NSImage?
    var pulse: Double = 0
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.05, green: 0.18, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let cover {
                // Overlay on a clear view so the filled image never widens the layout.
                Color.clear.overlay(
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 70).saturation(1.4).opacity(0.9)
                        .scaleEffect(1 + 0.05 * pulse)
                        .brightness(0.12 * pulse)
                ).clipped()
            }
            LinearGradient(colors: [.black.opacity(0.35 - 0.1 * pulse), .black.opacity(0.6 - 0.1 * pulse)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// Wraps words onto lines like text, keeping each word a separate view (so it can animate on its own).
struct WordFlow: Layout {
    var center = false
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if x > 0, x + s.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(i)
            x += s.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? .infinity
        var h: CGFloat = 0, w: CGFloat = 0
        let rs = rows(sizes, width: width)
        for r in rs {
            var rowW: CGFloat = 0, rowH: CGFloat = 0
            for i in r { rowW += sizes[i].width; rowH = max(rowH, sizes[i].height) }
            rowW += spacing * CGFloat(max(0, r.count - 1))
            w = max(w, rowW)
            h += rowH
        }
        h += lineSpacing * CGFloat(max(0, rs.count - 1))
        // Wrapped onto several rows: take the whole width offered, so placing the words (which wraps again, in
        // the width it's given) finds the same rows. Reporting only the widest row made it wrap once more and
        // the last row fell below the frame.
        if let pw = proposal.width, pw.isFinite { w = rs.count > 1 ? pw : min(pw, w) }
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        // Same width as sizeThatFits (a hair of slack against rounding).
        for r in rows(sizes, width: max(bounds.width, proposal.width ?? 0) + 0.5) {
            let rowW = r.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(0, r.count - 1))
            let rowH = r.map { sizes[$0].height }.max() ?? 0
            var x = center ? bounds.minX + (bounds.width - rowW) / 2 : bounds.minX
            for i in r {
                subviews[i].place(at: CGPoint(x: x, y: y + (rowH - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += rowH + lineSpacing
        }
    }
}

/// One karaoke line, Apple Music style: each word fills from left to right while it is sung; held notes
/// swell and glow, their letters rising one after another; the line's glow follows the bass.
struct KaraokeLine: View {
    let words: [Lyrics.TimedWord]
    let now: Double
    let size: CGFloat
    var active = true
    var center = false
    var pulse = 0.0

    var body: some View {
        WordFlow(center: center, spacing: size * 0.26, lineSpacing: size * 0.08) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                KaraokeWord(word: w, now: now, size: size, active: active, pulse: pulse)
            }
        }
        .shadow(color: .white.opacity(active ? 0.18 + 0.35 * pulse : 0), radius: size * (0.25 + 0.3 * pulse))
    }
}

struct KaraokeWord: View {
    let word: Lyrics.TimedWord
    let now: Double
    let size: CGFloat
    let active: Bool
    let pulse: Double

    private var font: Font { .system(size: size, weight: .bold, design: .rounded) }

    // The view keeps the same structure for the whole song (a held word is always drawn letter by letter,
    // with its room for the swell always reserved): switching structure or reflowing the line mid-word
    // made the text flicker.
    var body: some View {
        let p = active ? word.progress(now) : 0
        if word.held { held(p) } else { filled(p) }
    }

    /// Dim word with a bright copy revealed by a soft-edged sweep.
    private func filled(_ p: Double) -> some View {
        let edge = min(1, p * 1.15)
        return Text(word.text).font(font).foregroundColor(.white.opacity(0.32))
            .overlay(alignment: .leading) {
                Text(word.text).font(font).foregroundColor(.white)
                    .mask(LinearGradient(stops: [.init(color: .black, location: min(edge, max(0, edge - 0.15))),
                                                 .init(color: .clear, location: edge)],
                                         startPoint: .leading, endPoint: .trailing))
            }
    }

    /// Held note: letters light and lift in sequence across the hold; the word swells and glows, then settles.
    private func held(_ p: Double) -> some View {
        let letters = Array(word.text)
        let n = Double(max(1, letters.count))
        // Swell up quickly, stay while held, ease back once the note ends.
        let after = max(0, now - word.end)
        let env: Double = !active || p <= 0 ? 0 : (after > 0 ? max(0, 1 - after / 0.6) : min(1, p * 4))
        return HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { k, ch in
                let lp = max(0, min(1, p * n - Double(k)))
                let wave = sin(.pi * lp)
                Text(String(ch)).font(font)
                    .foregroundColor(.white.opacity(0.32 + 0.68 * lp))
                    .offset(y: -size * 0.09 * wave * env)
                    .scaleEffect(1 + 0.12 * wave * env, anchor: .bottom)
            }
        }
        .scaleEffect(1 + (0.07 + 0.03 * pulse) * env)
        .shadow(color: .white.opacity((0.55 + 0.3 * pulse) * env), radius: max(0.01, size * 0.35 * env))
        .padding(.horizontal, size * 0.12)   // fixed room for the swell: the line never reflows
    }
}

/// Playback time for lyrics animations: advances smoothly with the wall clock between the engine's
/// position updates (which come in steps and can wobble back a few ms), drifting gently toward the real
/// position and jumping only on a seek.
final class LyricsClock {
    static let shared = LyricsClock()
    private var base = 0.0
    private var baseWall = Date()
    private var last = 0.0

    func time(_ audio: AudioEngine) -> Double {
        let actual = audio.currentTime
        let wall = Date()
        guard audio.state == .playing else {
            base = actual; baseWall = wall; last = actual
            return actual
        }
        var t = base + wall.timeIntervalSince(baseWall) * max(0.25, audio.rate)
        let error = actual - t
        if abs(error) > 0.25 {
            base = actual; baseWall = wall; t = actual          // seek, track change, stall
        } else {
            base += error * 0.06; t += error * 0.06             // ease toward the real position
        }
        if t < last, last - t < 0.25 { t = last }               // never wobble backwards
        last = t
        return t
    }
}

/// Three dots that fill up during an instrumental break before the next line, beating with the bass.
struct BreakDots: View {
    let progress: Double
    let size: CGFloat
    var kick = 0.0
    var body: some View {
        HStack(spacing: size * 0.5) {
            ForEach(0..<3) { i in
                let f = max(0, min(1, progress * 3 - Double(i)))
                Circle().fill(.white.opacity(0.25 + 0.75 * f))
                    .frame(width: size, height: size)
                    .scaleEffect(0.8 + 0.2 * f + 0.25 * kick)
                    .shadow(color: .white.opacity(0.5 * kick * f), radius: size * 0.6)
            }
        }
    }
}

/// Cover of the current track, reloaded when it changes.
final class CoverModel: ObservableObject {
    @Published var image: NSImage?
    private var url: URL?
    func update(_ u: URL?) {
        guard u != url else { return }
        url = u
        image = nil
        guard let u else { return }
        Task { @MainActor in
            let img = await Artwork.load(u)
            if self.url == u { self.image = img }
        }
    }
}

// MARK: Lyrics panel

struct LyricsView: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var service: LyricsService
    @ObservedObject private var translator = LyricsTranslator.shared
    @StateObject private var cover = CoverModel()
    @AppStorage("lyricsFontSize") private var fontSize = 26.0
    @AppStorage("lyricsFollow") private var follow = true
    @State private var editing = false
    @State private var artist = ""
    @State private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .background(LyricsBackdrop(cover: cover.image))
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 340, minHeight: 360)
        .sheet(isPresented: $editing) { editSheet }
        .onAppear { cover.update(ctl.playlist.currentTrack?.url) }
        .onChange(of: service.query) { cover.update(ctl.playlist.currentTrack?.url) }
        .onChange(of: service.state) { service.autoSyncIfUseful(); translator.request(service.lyrics) }
        .onAppear { service.autoSyncIfUseful(); translator.request(service.lyrics) }
        .translationTask(translator.configuration) { session in await translator.run(session) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let img = cover.image { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else {
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.1))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.query?.title ?? "No track").font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(service.query?.artist ?? " ").font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 8)
    }

    /// Plain lyrics with each line's translation under it (dimmed), when translation is on.
    private func translatedPlain(_ text: String) -> AttributedString {
        var out = AttributedString()
        for line in text.components(separatedBy: .newlines) {
            out += AttributedString(line + "\n")
            if let tr = translator.translation(line) {
                var t = AttributedString(tr + "\n")
                t.foregroundColor = .white.opacity(0.45)
                t.font = .system(size: fontSize * 0.55, weight: .medium, design: .rounded)
                out += t
            }
        }
        return out
    }

    /// Times plain lyrics (or writes missing ones) from the audio, on this Mac.
    @ViewBuilder private func syncControl(label: String) -> some View {
        if let p = service.syncing {
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 160).tint(.white)
                Text("Listening to the track…").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        } else if service.canSync {
            VStack(spacing: 4) {
                Button { service.syncFromAudio() } label: { Label(label, systemImage: "waveform.badge.mic") }
                    .buttonStyle(.bordered).tint(.white)
                Text(service.syncError ?? "Speech recognition on this Mac times every line and word for the karaoke.")
                    .font(.caption).foregroundStyle(service.syncError == nil ? .white.opacity(0.55) : .orange)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            message("music.note", "Play a track to see its lyrics.",
                    "Radio stations show lyrics for the current song when its title is \"Artist - Title\". Podcasts have no lyrics.")
        case .loading:
            ProgressView().controlSize(.large).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            VStack(spacing: 14) {
                message("text.magnifyingglass", "Lyrics Not Found", "Correct the artist and title from the menu, or add an .lrc file next to the track.")
                    .frame(maxHeight: 220)
                syncControl(label: "Write Them from the Audio")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let e):
            message("wifi.exclamationmark", "Search Failed", e)
        case .found(let l):
            if l.instrumental && (l.plain ?? "").isEmpty {
                message("pianokeys", "Instrumental", "")
            } else if l.synced != nil, follow, !ctl.audio.isStream {
                synced(l)
            } else {
                ScrollView {
                    if l.synced == nil { syncControl(label: "Sync with the Audio").padding(.top, 16) }
                    Text(translatedPlain(l.plain ?? l.synced?.map(\.text).joined(separator: "\n") ?? ""))
                        .font(.system(size: fontSize * 0.75, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }
        }
    }

    /// Apple Music–style: current line bright with per-word highlight, the others dimmed and softly blurred.
    private func synced(_ l: Lyrics) -> some View {
        let lines = l.synced ?? []
        return TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let now = LyricsClock.shared.time(ctl.audio) + 0.12
            let current = l.lineIndex(at: now)
            let music = { MusicPulse.shared.update(ctl.audio); return MusicPulse.shared }()
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: fontSize * 0.7) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            let distance = abs(i - (current ?? -1))
                            Group {
                                if i == current {
                                    if line.text.isEmpty {
                                        BreakDots(progress: (now - line.time) / max(1, l.gap(after: i)), size: fontSize * 0.4, kick: music.kick)
                                    } else {
                                        KaraokeLine(words: l.timedWords(i), now: now, size: fontSize, pulse: music.bass)
                                    }
                                } else {
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(i < (current ?? 0) ? 0.45 : 0.32))
                                        .blur(radius: current == nil ? 0 : min(2.5, Double(distance) * 0.6))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottomLeading) {
                                if let tr = translator.translation(line.text) {
                                    Text(tr)
                                        .font(.system(size: fontSize * 0.52, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(i == current ? 0.75 : 0.35))
                                        .offset(y: fontSize * 0.62)
                                }
                            }
                            .padding(.bottom, translator.translation(line.text) == nil ? 0 : fontSize * 0.55)
                            .scaleEffect(i == current ? 1.0 : 0.96, anchor: .leading)
                            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: current)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { ctl.audio.seek(to: line.time) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 160)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: current) { _, c in
                    guard let c else { return }
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { proxy.scrollTo(c, anchor: UnitPoint(x: 0, y: 0.38)) }
                }
            }
        }
    }

    private func message(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(.white.opacity(0.7))
            Text(title).font(.title3.bold()).foregroundStyle(.white)
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if case .found(let l) = service.state {
                if let link = l.link, let u = URL(string: link) {
                    Link(l.source, destination: u).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(l.source).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if case .found(let l) = service.state, l.synced != nil {
                Button { follow.toggle() } label: { Image(systemName: follow ? "text.line.first.and.arrowtriangle.forward" : "text.alignleft") }
                    .help(follow ? "Show Full Lyrics" : "Follow Playback")
            }
            Button { fontSize = max(16, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller Text")
            Button { fontSize = min(44, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("Larger Text")
            Button { ctl.showKaraoke() } label: { Image(systemName: "music.mic") }.help("Full-Screen Karaoke")
            TranslateMenu()
            Menu {
                Button("Search Again") { ctl.refreshLyrics(force: true) }
                Button("Correct Artist and Title…") {
                    artist = service.query?.artist ?? ""
                    title = service.query?.title ?? ""
                    editing = true
                }
                Toggle("Sync Plain Lyrics Automatically", isOn: $service.autoSync)
                if service.canSync { Button("Sync with the Audio") { service.syncFromAudio() } }
                if case .found(let l) = service.state {
                    Button("Copy Lyrics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(l.plain ?? l.synced?.map(\.text).joined(separator: "\n") ?? "", forType: .string)
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white.opacity(0.85))
        .font(.system(size: 15))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Correct Search").font(.headline)
            TextField("Artist", text: $artist).textFieldStyle(.roundedBorder)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                Button("Search") {
                    editing = false
                    var q = service.query ?? LyricsService.Query(artist: "", title: "")
                    q.artist = artist
                    q.title = title
                    q.file = nil
                    service.load(q, force: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(artist.isEmpty || title.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: Karaoke

/// Full-screen karaoke: previous line above, the sung line huge with word-by-word highlight, next lines below.
struct KaraokeView: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var service: LyricsService
    @ObservedObject private var translator = LyricsTranslator.shared
    @StateObject private var cover = CoverModel()

    var body: some View {
        GeometryReader { geo in
            let big = min(geo.size.width / 16, geo.size.height / 7)
            ZStack {
                TimelineView(.animation) { _ in
                    stage(big: big)
                }
                .padding(.horizontal, geo.size.width * 0.08)
                VStack {
                    Spacer()
                    footer
                }
            }
            .background(
                // Full screen: the blurred cover breathes with the bass.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    LyricsBackdrop(cover: cover.image, pulse: { MusicPulse.shared.update(ctl.audio); return MusicPulse.shared.bass }())
                }
            )
        }
        .environment(\.colorScheme, .dark)
        .onAppear { cover.update(ctl.playlist.currentTrack?.url) }
        .onChange(of: service.query) { cover.update(ctl.playlist.currentTrack?.url) }
        .onChange(of: service.state) { service.autoSyncIfUseful(); translator.request(service.lyrics) }
        .onAppear { service.autoSyncIfUseful(); translator.request(service.lyrics) }
        .translationTask(translator.configuration) { session in await translator.run(session) }
    }

    @ViewBuilder
    private func stage(big: CGFloat) -> some View {
        let now = LyricsClock.shared.time(ctl.audio) + 0.12
        let music = { MusicPulse.shared.update(ctl.audio); return MusicPulse.shared }()
        if case .found(let l) = service.state, let lines = l.synced, !ctl.audio.isStream {
            let cur = l.lineIndex(at: now)
            let first = lines.first?.time ?? 0
            VStack(spacing: big * 0.55) {
                // previous
                Text(cur.flatMap { $0 > 0 ? lines[$0 - 1].text : nil } ?? " ")
                    .font(.system(size: big * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35)).lineLimit(2)
                // current (or the intro / a break)
                Group {
                    if let c = cur, !lines[c].text.isEmpty {
                        KaraokeLine(words: l.timedWords(c), now: now, size: big, center: true, pulse: music.bass)
                        if let tr = translator.translation(lines[c].text) {
                            Text(tr)
                                .font(.system(size: big * 0.42, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    } else if let c = cur {
                        BreakDots(progress: (now - lines[c].time) / max(1, l.gap(after: c)), size: big * 0.35, kick: music.kick)
                    } else {
                        BreakDots(progress: first > 0 ? now / first : 1, size: big * 0.35, kick: music.kick)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(minHeight: big * 2.6)
                .id(cur ?? -1)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                // next two
                VStack(spacing: big * 0.25) {
                    ForEach(1...2, id: \.self) { k in
                        let i = (cur ?? -1) + k
                        Text(lines.indices.contains(i) ? lines[i].text : " ")
                            .font(.system(size: big * (k == 1 ? 0.5 : 0.4), weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(k == 1 ? 0.5 : 0.28)).lineLimit(2)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: cur)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "music.mic").font(.system(size: big * 0.8, weight: .light))
                Text(status).font(.system(size: big * 0.4, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var status: String {
        switch service.state {
        case .loading: return "Searching for lyrics…"
        case .found: return ctl.audio.isStream ? "Karaoke isn’t available for radio" : "Lyrics aren’t time-synced: no karaoke"
        case .notFound: return "Lyrics not found"
        case .error: return "Search failed"
        case .idle: return "Play a track"
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let img = cover.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(service.query?.title ?? "").font(.headline)
                Text(service.query?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let d = max(1, ctl.audio.duration), t = ctl.audio.currentTime
                HStack(spacing: 10) {
                    Text(Ctl.mmss(t)).monospacedDigit()
                    ProgressView(value: min(1, t / d)).tint(.white).frame(width: 220)
                    Text(Ctl.mmss(d)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Button { ctl.audio.state == .playing ? ctl.pause() : ctl.play() } label: {
                Image(systemName: ctl.audio.state == .playing ? "pause.fill" : "play.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            Button { ctl.toggleVocalRemover() } label: {
                Label(ctl.vocalRemoval > 0 ? "Restore Vocals" : "Remove Vocals", systemImage: ctl.vocalRemoval > 0 ? "mic.fill" : "mic.slash.fill")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderless)
            .help("Remove the lead vocals (⌥⌘V)")
            TranslateMenu()
            Text("Press Esc to exit").font(.caption).foregroundStyle(.white.opacity(0.4))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(.ultraThinMaterial.opacity(0.6))
    }
}
