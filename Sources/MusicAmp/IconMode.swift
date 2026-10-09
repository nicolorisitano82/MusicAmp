import AppKit
import SwiftUI

/// Icon mode: the player shrinks to a floating tile with the cover, the waveform and the progress.
/// Click = play/pause; click on the waveform = seek; drag = move; hover = title, previous/next and a button back
/// to the full player; right click = menu (size, keep on top). Radio shows a live spectrum instead of the waveform.
extension Ctl {
    var iconModeActive: Bool { IconMode.shared.active }

    @objc func toggleIconMode() {
        if IconMode.shared.active { IconMode.shared.exit() } else { IconMode.shared.enter() }
    }
}

final class IconMode: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = IconMode()
    @Published private(set) var active = false
    @Published var size: CGFloat = UserDefaults.standard.object(forKey: "iconMode.size") as? CGFloat ?? 140 {
        didSet { UserDefaults.standard.set(size, forKey: "iconMode.size"); resize() }
    }
    @Published var keepOnTop: Bool = UserDefaults.standard.object(forKey: "iconMode.onTop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepOnTop, forKey: "iconMode.onTop"); panel?.level = keepOnTop ? .floating : .normal }
    }
    static let sizes: [(String, CGFloat)] = [("Small", 104), ("Medium", 140), ("Large", 196)]

    private var panel: NSPanel?
    /// Windows that were visible when entering, shown again when leaving.
    private var hidden: [NSWindow] = []

    func enter() {
        guard !active else { return }
        if DockMode.shared.active { DockMode.shared.exit() }
        let c = Ctl.shared
        hidden = NSApp.windows.filter { $0.isVisible && $0 !== panel && !($0 is NSPanel && $0.className.contains("Status")) && $0.level.rawValue < NSWindow.Level.statusBar.rawValue }
        let p = panel ?? makePanel()
        // Where the main window was, unless the tile has a saved place.
        if let saved = UserDefaults.standard.array(forKey: "iconMode.origin") as? [Double], saved.count == 2 {
            p.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else if let m = c.mainWindow {
            p.setFrameOrigin(NSPoint(x: m.frame.minX, y: m.frame.maxY - size))
        }
        resize()
        keepInScreen(p)
        hidden.forEach { $0.orderOut(nil) }
        p.orderFrontRegardless()
        active = true
        UserDefaults.standard.set(true, forKey: "iconMode")
        c.wake()
    }

    func exit() {
        guard active else { return }
        panel?.orderOut(nil)
        active = false
        UserDefaults.standard.set(false, forKey: "iconMode")
        let c = Ctl.shared
        let show = hidden.isEmpty ? [c.mainWindow].compactMap { $0 } as [NSWindow] : hidden
        show.forEach { $0.orderFront(nil) }
        c.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.updateWindowGroups()
        hidden = []
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = keepOnTop ? .floating : .normal
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovable = false   // moved by our drag, so a click stays a click
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.title = L("MusicAmp")
        p.setAccessibilityLabel("MusicAmp icon player")
        p.contentView = NSHostingView(rootView: IconTileView(ctl: .shared, mode: self))
        p.delegate = self
        panel = p
        return p
    }

    private func resize() {
        guard let p = panel else { return }
        var f = p.frame
        f.origin.y += f.height - size   // keep the top-left corner
        f.size = NSSize(width: size, height: size)
        p.setFrame(f, display: true)
        keepInScreen(p)
    }

    private func keepInScreen(_ p: NSWindow) {
        guard let s = (p.screen ?? NSScreen.main)?.visibleFrame else { return }
        var o = p.frame.origin
        o.x = min(max(o.x, s.minX), s.maxX - p.frame.width)
        o.y = min(max(o.y, s.minY), s.maxY - p.frame.height)
        p.setFrameOrigin(o)
    }

    // MARK: Dragging (from the SwiftUI view)

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func drag(ended: Bool) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (m, p.frame.origin) }
        if let s = dragStart { p.setFrameOrigin(NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y)) }
        if ended {
            dragStart = nil
            keepInScreen(p)
            UserDefaults.standard.set([Double(p.frame.minX), Double(p.frame.minY)], forKey: "iconMode.origin")
        }
    }

    /// Relaunch in icon mode when it was on at quit.
    func restoreAtLaunch() {
        if UserDefaults.standard.bool(forKey: "iconMode") { DispatchQueue.main.async { self.enter() } }
    }
}

// MARK: - The tile

struct IconTileView: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var mode: IconMode
    @StateObject private var cover = CoverModel()
    /// MUSICAMP_ICON_HOVER: debug screenshots with the hover controls shown.
    @State private var hover = ProcessInfo.processInfo.environment["MUSICAMP_ICON_HOVER"] != nil

    private var track: Track? { ctl.playlist.currentTrack }
    private var playing: Bool { ctl.audio.state == .playing }

    var body: some View {
        let side = mode.size
        ZStack {
            artwork
            // Bottom: waveform / spectrum and progress, over a gradient so it reads on any cover.
            VStack(spacing: 0) {
                Spacer()
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: side * 0.42)
                    TimelineView(.periodic(from: .now, by: playing ? 0.1 : 1)) { _ in bottomStrip(side) }
                        .padding(.horizontal, side * 0.07)
                        .padding(.bottom, side * 0.07)
                }
            }
            if !playing { pausedOverlay(side) }
            if hover { hoverControls(side) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in mode.drag(ended: false) }
            .onEnded { _ in mode.drag(ended: true) })
        .onTapGesture { playPause() }
        .contextMenu { menu }
        .onAppear { cover.update(track?.url) }
        .onChange(of: track?.url) { cover.update($1) }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { playPause() }
    }

    private var helpText: String {
        guard let t = track else { return "MusicAmp — nothing playing" }
        return [t.artist, t.songTitle ?? t.title].compactMap { $0 }.joined(separator: " — ") + (playing ? "" : " (paused)")
    }

    @ViewBuilder private var artwork: some View {
        if let img = cover.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.08)], startPoint: .top, endPoint: .bottom)
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().padding(mode.size * 0.16).opacity(0.85)
            }
        }
    }

    @ViewBuilder private func bottomStrip(_ side: CGFloat) -> some View {
        let a = ctl.audio
        let progress = a.duration > 0 ? min(1, a.currentTime / a.duration) : 0
        let h = side * 0.2
        if track?.isStream == true {
            HStack(alignment: .bottom, spacing: 2) {
                Text("LIVE").font(.system(size: max(8, side * 0.075), weight: .heavy)).foregroundStyle(IconTileView.green)
                SpectrumBars(values: playing ? a.visData().0 : []).frame(height: h)
            }
        } else if let t = track, let w = WaveformStore.shared.waveform(for: t.url) {
            GeometryReader { g in
                WaveformTile(waveform: w, progress: progress)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        // Seek where clicked.
                        if a.duration > 0 { a.seek(to: Double(location.x / g.size.width) * a.duration) }
                    }
            }
            .frame(height: h)
        } else {
            // Waveform not computed yet: a simple progress bar.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(IconTileView.green).frame(width: g.size.width * progress)
                }
            }
            .frame(height: max(3, side * 0.03))
        }
    }

    private func pausedOverlay(_ side: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            Image(systemName: track == nil ? "music.note" : "play.fill")
                .font(.system(size: side * 0.26, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 4)
                .offset(y: -side * 0.08)
        }
        .allowsHitTesting(false)
    }

    private func hoverControls(_ side: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(track.map { $0.songTitle ?? $0.title } ?? "MusicAmp")
                    .font(.system(size: max(9, side * 0.075), weight: .semibold))
                    .foregroundStyle(.white).lineLimit(2).shadow(radius: 3)
                Spacer(minLength: 2)
                tileButton("arrow.up.left.and.arrow.down.right", side * 0.1, help: "Show the Full Player") { IconMode.shared.exit() }
            }
            .padding(side * 0.07)
            .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            HStack(spacing: side * 0.12) {
                tileButton("backward.fill", side * 0.12, help: "Previous") { ctl.previous() }
                tileButton(playing ? "pause.fill" : "play.fill", side * 0.16, help: playing ? "Pause" : "Play") { playPause() }
                tileButton("forward.fill", side * 0.12, help: "Next") { ctl.next() }
            }
            .padding(.bottom, side * 0.33)
        }
    }

    private func tileButton(_ icon: String, _ size: CGFloat, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .bold)).foregroundStyle(.white).shadow(radius: 3)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private var menu: some View {
        Button(playing ? "Pause" : "Play") { playPause() }
        Button("Next") { ctl.next() }
        Button("Previous") { ctl.previous() }
        Divider()
        Picker("Size", selection: $mode.size) {
            ForEach(IconMode.sizes, id: \.1) { Text($0.0).tag($0.1) }
        }
        Toggle("Keep on Top", isOn: $mode.keepOnTop)
        Divider()
        Button("Show the Full Player") { IconMode.shared.exit() }
        Button("Quit MusicAmp") { NSApp.terminate(nil) }
    }

    private func playPause() {
        if ctl.audio.state == .playing { ctl.pause() } else { ctl.play() }
    }

    static let green = Color(red: 0.2, green: 0.95, blue: 0.2)
}

/// The waveform as thin bars: played part bright green, the rest translucent white.
struct WaveformTile: View {
    let waveform: Waveform
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            let bars = max(8, Int(size.width / 2.5))
            let bw = size.width / CGFloat(bars)
            for i in 0..<bars {
                let a = Double(i) / Double(bars), b = Double(i + 1) / Double(bars)
                let h = max(1.5, CGFloat(waveform.level(from: a, to: b)) * size.height)
                let r = CGRect(x: CGFloat(i) * bw, y: (size.height - h) / 2, width: max(1, bw - 0.8), height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 0.6),
                         with: .color(a < progress ? IconTileView.green : .white.opacity(0.45)))
            }
            // Playhead.
            let x = size.width * progress
            ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
        }
    }
}

/// Live spectrum (radio): the analyser's columns, averaged into a few bars.
struct SpectrumBars: View {
    let values: [Float]

    var body: some View {
        Canvas { ctx, size in
            let n = 16
            let bw = size.width / CGFloat(n)
            for i in 0..<n {
                let lo = i * max(1, values.count) / n, hi = max(lo + 1, (i + 1) * max(1, values.count) / n)
                let v = values.isEmpty ? 0.04 : values[lo..<min(values.count, hi)].max() ?? 0
                let h = max(1.5, CGFloat(min(1, v)) * size.height)
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * bw, y: size.height - h, width: bw - 1.5, height: h), cornerRadius: 1),
                         with: .color(IconTileView.green.opacity(0.9)))
            }
        }
    }
}

// MARK: - Dock mode

/// Dock mode: every window hidden, MusicAmp lives in its Dock icon (cover + waveform). A click on the icon plays or
/// pauses; its menu has the track, the controls and "Show Player". The main window's close button leads here
/// (Settings → General), so closing the player doesn't stop the music.
final class DockMode: ObservableObject {
    static let shared = DockMode()
    @Published private(set) var active = false
    private var hidden: [NSWindow] = []

    func enter() {
        guard !active else { return }
        if IconMode.shared.active { IconMode.shared.exit() }
        hidden = NSApp.windows.filter { $0.isVisible && $0.level.rawValue < NSWindow.Level.statusBar.rawValue && $0.className != "NSStatusBarWindow" }
        hidden.forEach { $0.orderOut(nil) }
        active = true
        DockIcon.shared.update()
        Ctl.shared.flashMarquee("MUSICAMP IS IN THE DOCK")
    }

    func exit() {
        guard active else { return }
        active = false
        let c = Ctl.shared
        // Nothing was hidden (launched straight into the Dock): the player as the settings have it.
        let show = hidden.isEmpty ? ([c.mainWindow] + (c.eqVisible ? [c.eqWindow] : []) + (c.plVisible ? [c.plWindow] : [])).compactMap { $0 } as [NSWindow] : hidden
        show.forEach { $0.orderFront(nil) }
        c.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.updateWindowGroups()
        hidden = []
        DockIcon.shared.update()
    }

    /// A click on the Dock icon while in Dock mode.
    func iconClicked() {
        let c = Ctl.shared
        if c.playlist.tracks.isEmpty { exit(); return }   // nothing to play: show the player instead
        if c.audio.state == .playing { c.pause() } else { c.play() }
    }

    /// The Dock icon's menu (right click or long press), in every mode.
    func menu() -> NSMenu {
        let c = Ctl.shared
        let m = NSMenu()
        if let t = c.playlist.currentTrack {
            let title = [t.artist, t.songTitle ?? t.title].compactMap { $0 }.joined(separator: " — ")
            let it = m.addItem(withTitle: title, action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(.separator())
        }
        c.item(m, c.audio.state == .playing ? "Pause" : "Play", #selector(Ctl.dockPlayPause))
        c.item(m, "Next", #selector(Ctl.next as (Ctl) -> () -> Void))
        c.item(m, "Previous", #selector(Ctl.previous))
        let rate = NSMenuItem(title: L("Rate Current Track"), action: nil, keyEquivalent: "")
        rate.submenu = c.ratingMenu(#selector(Ctl.rateCurrent(_:)), current: c.playlist.currentTrack.map { PlayStats.shared.rating($0.url) }, keys: false)
        m.addItem(rate)
        let sleep = NSMenuItem(title: L("Sleep Timer"), action: nil, keyEquivalent: "")
        sleep.submenu = Scheduler.shared.sleepMenu()
        m.addItem(sleep)
        m.addItem(.separator())
        if active {
            c.item(m, "Show Player", #selector(Ctl.showPlayer))
        } else {
            c.item(m, "Dock Mode (Hide the Player)", #selector(Ctl.toggleDockMode))
        }
        c.item(m, IconMode.shared.active ? "Hide Mini Tile" : "Mini Tile", #selector(Ctl.toggleIconMode))
        return m
    }
}

extension Ctl {
    @objc func toggleDockMode() { if DockMode.shared.active { DockMode.shared.exit() } else { DockMode.shared.enter() } }
    @objc func showPlayer() {
        if DockMode.shared.active { DockMode.shared.exit() }
        if IconMode.shared.active { IconMode.shared.exit() }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func dockPlayPause() { if audio.state == .playing { pause() } else { play() } }
}
