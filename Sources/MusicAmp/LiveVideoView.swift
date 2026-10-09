import AppKit
import Combine
import SwiftUI

// MARK: - Frame

/// What one Live Video frame shows: the scene's picture (and the previous one while they cross-fade), how far
/// into the scene we are, the lyrics and the song.
struct LiveVideoInput {
    var s: TVKaraoke.State
    var picture: CGImage?
    var previous: CGImage?
    var scene = 0
    var progress = 0.0   // 0…1 through the scene
    var fade = 1.0       // 0…1 cross-fade from the previous picture
    var status = ""
    /// The song waits while its video is made: pictures done / total (total 0 while the storyboard is written).
    var preparing: (done: Int, total: Int)?
    var canPlayNow = false
}

extension LiveVideo {
    /// The frame for the song playing now (window and TV).
    func input(_ s: TVKaraoke.State) -> LiveVideoInput {
        var i = LiveVideoInput(s: s, status: status)
        if holding { i.preparing = (images.count, board?.scenes.count ?? 0) }
        let duration = Ctl.shared.audio.duration
        guard let sc = scene(at: s.now, lyrics: s.lyrics, duration: duration), let (k, img) = image(upTo: sc.index) else { return i }
        i.picture = img
        i.scene = k
        let start = k == sc.index ? sc.start : sceneStart(k, lyrics: s.lyrics, duration: duration)
        let end = k == sc.index ? sc.end : sc.start
        i.progress = max(0, min(1, (s.now - start) / max(1, end - start)))
        if k == sc.index, k > 0, let (pk, prev) = image(upTo: k - 1), pk < k {
            i.fade = max(0, min(1, (s.now - sc.start) / 1.2))
            if i.fade < 1 { i.previous = prev }
        }
        return i
    }
}

/// A picture slowly zooming and drifting (the "Ken Burns" move), filling the frame.
private struct KenBurns: View {
    let image: CGImage
    let progress: Double
    let scene: Int

    var body: some View {
        GeometryReader { geo in
            let dir: CGFloat = scene % 2 == 0 ? 1 : -1
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(1.05 + 0.10 * progress)
                .offset(x: dir * geo.size.width * 0.03 * (progress - 0.5), y: -geo.size.height * 0.015 * progress)
                .clipped()
        }
    }
}

struct LiveVideoFrame: View {
    let input: LiveVideoInput

    var body: some View {
        GeometryReader { geo in
            let big = min(geo.size.width / 22, geo.size.height / 11)
            ZStack {
                if input.picture == nil {
                    LyricsBackdrop(cover: input.s.cover.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }, pulse: input.s.pulse)
                }
                if let p = input.previous { KenBurns(image: p, progress: 1, scene: input.scene - 1) }
                if let p = input.picture { KenBurns(image: p, progress: input.progress, scene: input.scene).opacity(input.fade) }
                // Lyrics over a dark band at the bottom.
                VStack(spacing: big * 0.3) {
                    Spacer()
                    lyrics(big: big)
                }
                .padding(.horizontal, geo.size.width * 0.07)
                .padding(.bottom, geo.size.height * 0.07)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.42)
                }
                if let p = input.preparing { preparingPanel(p, big: big) }
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(input.s.title).font(.system(size: big * 0.42, weight: .bold, design: .rounded))
                            if !input.s.artist.isEmpty { Text(input.s.artist).font(.system(size: big * 0.34, weight: .medium, design: .rounded)).opacity(0.75) }
                        }
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                        Spacer()
                        if !input.status.isEmpty {
                            Text(input.status).font(.system(size: big * 0.3, weight: .medium, design: .rounded))
                                .padding(.horizontal, big * 0.35).padding(.vertical, big * 0.15)
                                .background(Capsule().fill(.black.opacity(0.45)))
                        }
                    }
                    Spacer()
                }
                .padding(big * 0.6)
            }
            .foregroundStyle(.white)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    /// "Preparing the video": storyboard, then pictures, with the option to start the song anyway.
    private func preparingPanel(_ p: (done: Int, total: Int), big: CGFloat) -> some View {
        VStack(spacing: big * 0.35) {
            Text("Preparing the video").font(.system(size: big * 0.6, weight: .bold, design: .rounded))
            Text(p.total == 0 ? L("Writing the storyboard…") : String(format: L("Picture %d of %d"), min(p.done + 1, p.total), p.total))
                .font(.system(size: big * 0.4, weight: .medium, design: .rounded)).opacity(0.8)
            ProgressView(value: p.total == 0 ? 0.03 : Double(p.done) / Double(p.total))
                .progressViewStyle(.linear).tint(.white).frame(width: big * 9)
            if input.canPlayNow {
                Button("Play Now") { LiveVideo.shared.playNow() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(big * 0.7)
        .background(RoundedRectangle(cornerRadius: big * 0.4).fill(.black.opacity(0.55)))
    }

    @ViewBuilder
    private func lyrics(big: CGFloat) -> some View {
        let s = input.s
        if let l = s.lyrics, let lines = l.synced, let c = l.lineIndex(at: s.now), !lines[c].text.isEmpty {
            KaraokeLine(words: l.timedWords(c), now: s.now, size: big, center: true, pulse: s.pulse)
                .shadow(color: .black.opacity(0.7), radius: 8)
            if let tr = s.translate(lines[c].text) {
                Text(tr).font(.system(size: big * 0.5, weight: .semibold, design: .rounded)).opacity(0.8)
                    .multilineTextAlignment(.center).shadow(color: .black.opacity(0.7), radius: 6)
            }
        } else if !s.status.isEmpty, s.lyrics == nil {
            Text(s.status).font(.system(size: big * 0.45, weight: .medium, design: .rounded)).opacity(0.6)
        }
    }
}

// MARK: - Window

extension Ctl {
    @MainActor @objc func showLiveVideo() {
        if liveVideoWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LiveVideoWindow()))
            w.title = L("Live Video (Beta)")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.collectionBehavior = [.fullScreenPrimary]
            w.backgroundColor = .black
            w.setContentSize(NSSize(width: 960, height: 540))
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("LiveVideo")
            liveVideoWindowRef = w
        }
        NSApp.activate(ignoringOtherApps: true)
        liveVideoWindowRef?.makeKeyAndOrderFront(nil)
    }
}

struct LiveVideoWindow: View {
    @ObservedObject private var live = LiveVideo.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            LiveVideoFrame(input: { var i = live.input(TVKaraoke.shared.state()); i.canPlayNow = true; return i }())
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottomTrailing) {
            if live.model == nil {
                Button("Settings…") { Ctl.shared.openPreferences(tab: .vis) }.padding()
            }
        }
        .onAppear { live.windowOpen = true; live.refresh() }
        .onDisappear { live.windowOpen = false; live.refresh() }
    }
}

// MARK: - Settings

struct LiveVideoSettings: View {
    @ObservedObject private var live = LiveVideo.shared
    @State private var cache: Int64 = 0

    var body: some View {
        Section {
            HStack {
                BetaBadge()
                Text("Pictures made on this Mac from what the lyrics are about, with the lyrics underneath. Needs Apple Intelligence and an image model (downloaded once, kept on this Mac).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Image model", selection: $live.modelPath) {
                if live.models.isEmpty { Text("None installed").tag("") }
                ForEach(live.models) { Text($0.label).tag($0.id) }
            }
            .disabled(live.models.isEmpty)
            ForEach(LiveVideoModel.downloads) { d in
                if !live.models.contains(where: { $0.isXL == (d.id == "sdxl") }) {
                    HStack {
                        Text(LocalizedStringKey(d.title))
                        Spacer()
                        if let dl = live.download, dl.id == d.id {
                            ProgressView(value: dl.progress).frame(width: 120)
                            Button("Cancel") { live.cancelDownload() }
                        } else {
                            Button(String(format: L("Download (%@)"), ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file))) { live.startDownload(d) }
                                .disabled(live.download != nil)
                        }
                    }
                }
            }
            Button("Choose Model…") { live.chooseModel() }
            Picker("Style", selection: $live.style) {
                ForEach(LiveVideoStyle.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            Toggle("Make the whole video before the song starts", isOn: $live.waitBeforePlaying)
            Toggle("Prepare the next track while this one plays", isOn: $live.prefetch)
            Toggle("Show on the TV (Chromecast with lyrics)", isOn: $live.onTV)
            HStack {
                Button("Open Live Video") { Ctl.shared.showLiveVideo() }
                Spacer()
                Button(String(format: L("Clear Pictures (%@)"), ByteCountFormatter.string(fromByteCount: cache, countStyle: .file))) { live.clearCache(); cache = live.cacheSize }
            }
            if let e = live.error { Text(e).font(.caption).foregroundStyle(.red) }
            Text("Models: Apple's Core ML conversions of Stable Diffusion (CreativeML Open RAIL++-M licence). A model folder or .zip can also be added by hand with Choose Model…; they're kept in Application Support/MusicAmp/Models.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Live Video") }
        .onAppear { cache = live.cacheSize }
    }
}
