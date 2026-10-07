import AppKit
import AVKit
import SwiftUI

/// Menu bar mini player: status item + popover with cover, title, seek, transport, volume and AirPlay.
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let ctl: Ctl

    init(ctl: Ctl) {
        self.ctl = ctl
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MiniPlayerView(ctl: ctl))
    }

    func setEnabled(_ on: Bool) {
        if on, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            it.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "MusicAmp")
            it.button?.target = self
            it.button?.action = #selector(toggle)
            item = it
            update()
        } else if !on, let it = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    /// Tooltip and icon follow the transport state.
    func update() {
        guard let button = item?.button else { return }
        let playing = ctl.audio.state == .playing
        button.image = NSImage(systemSymbolName: playing ? "music.note" : "music.note.list", accessibilityDescription: "MusicAmp")
        button.toolTip = ctl.playlist.currentTrack.map { $0.title } ?? "MusicAmp"
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// System route picker (AirPlay). Without a player it changes the system output; the engine follows the default.
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

struct MiniPlayerView: View {
    @ObservedObject var ctl: Ctl
    @State private var cover: NSImage?
    @State private var scrub: Double?

    private var track: Track? { ctl.playlist.currentTrack }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let a = ctl.audio
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Group {
                        if let cover {
                            Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                        }
                    }
                    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.map { $0.songTitle ?? $0.title } ?? "Nessun brano").font(.headline).lineLimit(2)
                        Text([track?.artist, track?.album].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { scrub ?? a.currentTime },
                                          set: { scrub = $0 }),
                           in: 0...max(1, a.duration)) { editing in
                        if !editing, let s = scrub { a.seek(to: s); scrub = nil }
                    }
                    .disabled(a.file == nil || a.state == .stopped || a.isStream)
                    HStack {
                        Text(Ctl.mmss(scrub ?? a.currentTime))
                        Spacer()
                        Text(Ctl.mmss(a.duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    Spacer()
                    Button { ctl.previous() } label: { Image(systemName: "backward.fill") }
                    Button { a.state == .playing ? ctl.pause() : ctl.play() } label: {
                        Image(systemName: a.state == .playing ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button { ctl.stop() } label: { Image(systemName: "stop.fill") }
                    Button { ctl.next() } label: { Image(systemName: "forward.fill") }
                    Spacer()
                }
                .buttonStyle(.borderless).font(.title3)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { ctl.volume }, set: { ctl.volume = $0 }), in: 0...100)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    RoutePicker().frame(width: 24, height: 20).help("AirPlay e uscite audio")
                }
                Divider()
                HStack {
                    Button("Mostra MusicAmp") {
                        NSApp.activate(ignoringOtherApps: true)
                        ctl.mainWindow?.makeKeyAndOrderFront(nil)
                    }
                    Spacer()
                    Button("Libreria") { ctl.showLibrary() }
                }
                .buttonStyle(.link).font(.callout)
            }
            .padding(14)
            .frame(width: 300)
        }
        .task(id: track?.url) {
            cover = nil
            if let u = track?.url { cover = await Artwork.load(u) }
        }
    }
}
