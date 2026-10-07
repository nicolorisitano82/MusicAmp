import AppKit
import SwiftUI

extension Ctl {
    @objc func showLyrics() {
        if lyricsWindowRef == nil {
            let w = LyricsWindow(contentViewController: NSHostingController(rootView: LyricsView(ctl: self, service: .shared)))
            w.ctl = self
            w.title = "Testi"
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
            w.title = "Karaoke"
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
        let open = lyricsWindowRef?.isVisible == true || karaokeWindowRef?.isVisible == true
        guard open || force || evenIfHidden else { return }
        let q = playlist.currentTrack.flatMap { LyricsService.query(for: $0, duration: audio.duration) }
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

/// Blurred cover art (or a gradient) behind the lyrics.
struct LyricsBackdrop: View {
    let cover: NSImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.05, green: 0.18, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let cover {
                // Overlay on a clear view so the filled image never widens the layout.
                Color.clear.overlay(
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 70).saturation(1.4).opacity(0.9)
                ).clipped()
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// One karaoke line: each word lights up while it is sung (real word times when available, else estimated).
struct KaraokeLine: View {
    let words: [Lyrics.TimedWord]
    let now: Double
    let size: CGFloat
    var active = true

    var body: some View {
        words.enumerated().reduce(Text("")) { acc, item in
            let (i, w) = item
            let p = active ? w.progress(now) : 0
            // Sung words full white, the word being sung brightens as it goes, the rest stays dim.
            let opacity = active ? 0.32 + 0.68 * p : 0.32
            return acc + Text(w.text + (i < words.count - 1 ? " " : "")).foregroundColor(.white.opacity(opacity))
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .shadow(color: .white.opacity(active ? 0.25 : 0), radius: 12)
    }
}

/// Three dots that fill up during an instrumental break before the next line.
struct BreakDots: View {
    let progress: Double
    let size: CGFloat
    var body: some View {
        HStack(spacing: size * 0.5) {
            ForEach(0..<3) { i in
                Circle().fill(.white.opacity(0.25 + 0.75 * max(0, min(1, progress * 3 - Double(i)))))
                    .frame(width: size, height: size)
                    .scaleEffect(0.8 + 0.2 * max(0, min(1, progress * 3 - Double(i))))
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
        .onChange(of: service.query) { _ in cover.update(ctl.playlist.currentTrack?.url) }
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
                Text(service.query?.title ?? "Nessun brano").font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(service.query?.artist ?? " ").font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            message("music.note", "Fai partire un brano per vedere il testo.",
                    "Le radio mostrano il testo del brano in onda quando il titolo è \"Artista - Titolo\"; i podcast non hanno testi.")
        case .loading:
            ProgressView().controlSize(.large).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            message("text.magnifyingglass", "Testo non trovato", "Correggi artista e titolo dal menu, o aggiungi un file .lrc accanto al brano.")
        case .error(let e):
            message("wifi.exclamationmark", "Ricerca non riuscita", e)
        case .found(let l):
            if l.instrumental && (l.plain ?? "").isEmpty {
                message("pianokeys", "Brano strumentale", "")
            } else if l.synced != nil, follow, !ctl.audio.isStream {
                synced(l)
            } else {
                ScrollView {
                    Text(l.plain ?? l.synced?.map(\.text).joined(separator: "\n") ?? "")
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
        return TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let now = ctl.audio.currentTime + 0.12
            let current = l.lineIndex(at: now)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: fontSize * 0.7) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            let distance = abs(i - (current ?? -1))
                            Group {
                                if i == current {
                                    if line.text.isEmpty {
                                        BreakDots(progress: (now - line.time) / max(1, l.gap(after: i)), size: fontSize * 0.4)
                                    } else {
                                        KaraokeLine(words: l.timedWords(i), now: now, size: fontSize)
                                    }
                                } else {
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(i < (current ?? 0) ? 0.45 : 0.32))
                                        .blur(radius: current == nil ? 0 : min(2.5, Double(distance) * 0.6))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                .onChange(of: current) { c in
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
                    .help(follow ? "Testo completo" : "Segui la riproduzione")
            }
            Button { fontSize = max(16, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("Testo più piccolo")
            Button { fontSize = min(44, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("Testo più grande")
            Button { ctl.showKaraoke() } label: { Image(systemName: "music.mic") }.help("Karaoke a schermo intero")
            Menu {
                Button("Cerca di nuovo") { ctl.refreshLyrics(force: true) }
                Button("Correggi artista e titolo…") {
                    artist = service.query?.artist ?? ""
                    title = service.query?.title ?? ""
                    editing = true
                }
                if case .found(let l) = service.state {
                    Button("Copia il testo") {
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
            Text("Correggi la ricerca").font(.headline)
            TextField("Artista", text: $artist).textFieldStyle(.roundedBorder)
            TextField("Titolo", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Annulla") { editing = false }.keyboardShortcut(.cancelAction)
                Button("Cerca") {
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
    @StateObject private var cover = CoverModel()

    var body: some View {
        GeometryReader { geo in
            let big = min(geo.size.width / 16, geo.size.height / 7)
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    stage(big: big)
                }
                .padding(.horizontal, geo.size.width * 0.08)
                VStack {
                    Spacer()
                    footer
                }
            }
            .background(LyricsBackdrop(cover: cover.image))
        }
        .environment(\.colorScheme, .dark)
        .onAppear { cover.update(ctl.playlist.currentTrack?.url) }
        .onChange(of: service.query) { _ in cover.update(ctl.playlist.currentTrack?.url) }
    }

    @ViewBuilder
    private func stage(big: CGFloat) -> some View {
        let now = ctl.audio.currentTime + 0.12
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
                        KaraokeLine(words: l.timedWords(c), now: now, size: big)
                    } else if let c = cur {
                        BreakDots(progress: (now - lines[c].time) / max(1, l.gap(after: c)), size: big * 0.35)
                    } else {
                        BreakDots(progress: first > 0 ? now / first : 1, size: big * 0.35)
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
        case .loading: return "Cerco il testo…"
        case .found: return ctl.audio.isStream ? "Karaoke non disponibile per la radio" : "Testo senza tempi: niente karaoke"
        case .notFound: return "Testo non trovato"
        case .error: return "Ricerca non riuscita"
        case .idle: return "Fai partire un brano"
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
            Text("Esc per uscire").font(.caption).foregroundStyle(.white.opacity(0.4))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(.ultraThinMaterial.opacity(0.6))
    }
}
