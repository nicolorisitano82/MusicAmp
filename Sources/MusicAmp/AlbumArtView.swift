import AppKit
import SwiftUI

extension Ctl {
    /// Album art view (⌥⌘A): the playing track's cover large, its context and the playback controls,
    /// plus a strip of the playlist's albums to browse. Goes full screen for lean-back listening.
    @objc func showAlbumArt() {
        if albumArtWindowRef == nil {
            let w = KaraokeWindow(contentViewController: NSHostingController(rootView: AlbumArtView(ctl: self)))
            w.title = L("Album Art")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.fullScreenPrimary]
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.setContentSize(NSSize(width: 520, height: 760))
            w.setFrameAutosaveName("MusicAmpAlbumArt")
            albumArtWindowRef = w
        }
        NSApp.activate(ignoringOtherApps: true)
        albumArtWindowRef?.makeKeyAndOrderFront(nil)
    }
}

/// An album of the playlist: its tracks in playlist order and the first one's file (for the cover).
struct PlaylistAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let first: Int
    let count: Int
    let coverURL: URL

    /// Albums in order of first appearance; compilations show "Various Artists".
    static func from(_ tracks: [Track]) -> [PlaylistAlbum] {
        var order: [String] = []
        var info: [String: (title: String, artists: Set<String>, first: Int, count: Int, url: URL)] = [:]
        for (i, t) in tracks.enumerated() {
            guard let al = t.album?.trimmingCharacters(in: .whitespaces), !al.isEmpty else { continue }
            let key = al.lowercased()
            if info[key] == nil {
                order.append(key)
                info[key] = (al, [], i, 0, t.url)
            }
            info[key]!.count += 1
            if let a = t.artist, !a.isEmpty { info[key]!.artists.insert(a) }
        }
        return order.map { k in
            let x = info[k]!
            let artist = x.artists.count > 1 ? PlaylistTree.various : (x.artists.first ?? "")
            return PlaylistAlbum(id: k, title: x.title, artist: artist, first: x.first, count: x.count, coverURL: x.url)
        }
    }
}

/// Cover for any track URL, loaded once per view.
struct CoverThumb: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note").font(.system(size: size * 0.32)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.06))
        .task(id: url) { image = await Artwork.load(url) }
    }
}

struct AlbumArtView: View {
    @ObservedObject var ctl: Ctl
    @StateObject private var cover = CoverModel()
    @State private var hovered: String?
    @State private var seeking: Double?

    private var track: Track? { ctl.playlist.currentTrack }

    var body: some View {
        GeometryReader { geo in
            let side = max(160, min(geo.size.width - 64, geo.size.height - 330))
            VStack(spacing: 18) {
                Spacer(minLength: 34)
                bigCover(side)
                info
                transport(width: min(side, 520))
                Spacer(minLength: 4)
                strip
            }
            .frame(maxWidth: .infinity)
            .background(
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    LyricsBackdrop(cover: cover.image, pulse: { MusicPulse.shared.update(ctl.audio); return MusicPulse.shared.bass * 0.5 }())
                }
            )
        }
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 360, minHeight: 520)
        .onAppear { cover.update(track?.url) }
        // The playlist doesn't publish its changes (restore at launch, track changes): check every second.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in cover.update(ctl.playlist.currentTrack?.url) }
    }

    // MARK: Cover

    private func bigCover(_ side: CGFloat) -> some View {
        ZStack {
            if let img = cover.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
                    .id(track?.url)
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: track == nil ? "music.note.list" : "music.note")
                    .font(.system(size: side * 0.25, weight: .light)).foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.035))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
        // Playing: full size; paused: slightly smaller, like Apple Music.
        .scaleEffect(ctl.audio.state == .playing ? 1 : 0.9)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: ctl.audio.state == .playing)
        .animation(.easeInOut(duration: 0.4), value: cover.image)
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
    }

    // MARK: Info and controls

    private var info: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in infoContent }
    }

    private var infoContent: some View {
        VStack(spacing: 4) {
            Text(track.map { $0.songTitle ?? $0.title } ?? "No track")
                .font(.title2.bold()).foregroundStyle(.white).lineLimit(1)
            Text([track?.artist, track?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                .font(.headline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .padding(.horizontal, 24)
    }

    private func transport(width: CGFloat) -> some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let d = ctl.audio.duration, t = seeking ?? ctl.audio.currentTime
                VStack(spacing: 4) {
                    let wave = ctl.waveSeekBar ? ctl.playlist.currentTrack.flatMap { $0.isStream ? nil : WaveformStore.shared.waveform(for: $0.url) } : nil
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            if let wave {
                                WaveformBar(waveform: wave, progress: d > 0 ? min(1, t / d) : 0)
                            } else {
                                Capsule().fill(.white.opacity(0.2)).frame(height: 6)
                                Capsule().fill(.white.opacity(0.85)).frame(width: d > 0 ? g.size.width * min(1, t / d) : 0, height: 6)
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in if d > 0 { seeking = max(0, min(d, Double(v.location.x / g.size.width) * d)) } }
                            .onEnded { _ in if let s = seeking { ctl.audio.seek(to: s) }; seeking = nil })
                    }
                    .frame(height: wave == nil ? 6 : 30)
                    HStack {
                        Text(Ctl.mmss(t)).monospacedDigit()
                        Spacer()
                        Text(d > 0 ? "−" + Ctl.mmss(max(0, d - t)) : "").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: width)
            HStack(spacing: 44) {
                Button { ctl.previous() } label: { Image(systemName: "backward.fill") }
                Button { ctl.audio.state == .playing ? ctl.pause() : ctl.play() } label: {
                    Image(systemName: ctl.audio.state == .playing ? "pause.fill" : "play.fill").font(.system(size: 34))
                }
                Button { ctl.next() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 24))
            .foregroundStyle(.white)
        }
    }

    // MARK: Album strip

    /// Track tags load in the background and the playlist doesn't publish changes: re-read it every second.
    private var strip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in stripContent(version: ctl.playlist.version) }
    }

    @ViewBuilder
    private func stripContent(version: Int) -> some View {
        let albums = PlaylistAlbum.from(ctl.playlist.tracks)
        if !albums.isEmpty {
            let current = track?.album?.trimmingCharacters(in: .whitespaces).lowercased()
            VStack(alignment: .leading, spacing: 6) {
                Text(hovered.flatMap { h in albums.first { $0.id == h }.map { "\($0.title) — \($0.artist) · \($0.count) tracks" } }
                     ?? "Albums in the playlist")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    .padding(.horizontal, 20)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(albums) { a in
                                CoverThumb(url: a.coverURL, size: 72)
                                    .overlay(RoundedRectangle(cornerRadius: 72 * 0.06)
                                        .stroke(.white, lineWidth: a.id == current ? 2 : 0))
                                    .scaleEffect(hovered == a.id ? 1.08 : 1)
                                    .animation(.easeOut(duration: 0.15), value: hovered)
                                    .onHover { hovered = $0 ? a.id : (hovered == a.id ? nil : hovered) }
                                    .onTapGesture { ctl.playIndex(a.first) }
                                    .help("\(a.title) — \(a.artist)")
                                    .id(a.id)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                    }
                    .onAppear { if let c = current { proxy.scrollTo(c, anchor: .center) } }
                    .onChange(of: current) { _, c in
                        if let c { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(c, anchor: .center) } }
                    }
                }
            }
            .padding(.bottom, 16)
            .background(.ultraThinMaterial.opacity(0.35))
        }
    }
}
