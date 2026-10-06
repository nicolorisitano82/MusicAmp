import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var started = false
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        Ctl.shared.start()
        started = true
        if !pending.isEmpty { Ctl.shared.handleDrop(pending, toPlaylist: false) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        if started { Ctl.shared.handleDrop(urls, toPlaylist: false) } else { pending += urls }
    }

    func applicationWillTerminate(_ n: Notification) { Ctl.shared.saveSettings() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Ctl.shared.mainWindow.makeKeyAndOrderFront(nil) }
        return true
    }

    private func buildMenu() -> NSMenu {
        let c = Ctl.shared
        let bar = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            it.submenu = m
            bar.addItem(it)
            return m
        }

        let app = sub("MusicAmp")
        app.addItem(withTitle: "Informazioni su MusicAmp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        c.item(app, "Preferenze…", #selector(Ctl.showPreferences), ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Nascondi MusicAmp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Esci da MusicAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub("File")
        c.item(file, "Apri file…", #selector(Ctl.openFiles), "o")
        c.item(file, "Aggiungi file…", #selector(Ctl.addFiles), "o", [.command, .shift])
        c.item(file, "Aggiungi cartella…", #selector(Ctl.addFolder))
        file.addItem(.separator())
        c.item(file, "Carica playlist…", #selector(Ctl.loadPlaylistFile))
        c.item(file, "Salva playlist…", #selector(Ctl.savePlaylistFile), "s")
        file.addItem(.separator())
        c.item(file, "Info file…", #selector(Ctl.fileInfo), "i")

        let play = sub("Riproduzione")
        c.item(play, "Precedente", #selector(Ctl.previous), "z", [])
        c.item(play, "Play", #selector(Ctl.play), "x", [])
        c.item(play, "Pausa", #selector(Ctl.pause), "c", [])
        c.item(play, "Stop", #selector(Ctl.stop), "v", [])
        c.item(play, "Successivo", #selector(Ctl.next as (Ctl) -> () -> Void), "b", [])
        play.addItem(.separator())
        c.item(play, "Shuffle", #selector(Ctl.toggleShuffle), "s", [])
        c.item(play, "Ripeti", #selector(Ctl.toggleRepeat), "r", [])
        c.item(play, "Tempo rimanente", #selector(Ctl.toggleTimeRemaining))

        let skins = sub("Skin")
        skins.delegate = c

        let view = sub("Vista")
        c.item(view, "Equalizzatore", #selector(Ctl.toggleEQ), "g", [.option])
        c.item(view, "Playlist", #selector(Ctl.togglePL), "e", [.option])
        c.item(view, "Libreria", #selector(Ctl.showLibrary), "l", [.option])
        view.addItem(.separator())
        c.item(view, "Modalità ridotta", #selector(Ctl.toggleMainShade), "w", [.option])
        c.item(view, "Equalizzatore ridotto", #selector(Ctl.toggleEQShade), "w", [.option, .shift])
        c.item(view, "Playlist ridotta", #selector(Ctl.togglePLShade), "w", [.control, .option])
        c.item(view, "Doppia dimensione", #selector(Ctl.toggleDoubleSize), "d")
        c.item(view, "Sempre in primo piano", #selector(Ctl.toggleAlwaysOnTop), "a", [.option])
        let vis = NSMenuItem(title: "Visualizzazione", action: nil, keyEquivalent: "")
        vis.submenu = c.visMenu()
        view.addItem(vis)

        return bar
    }
}

/// Debug: `MusicAmp --snapshot <skin.wsz|-> <out.png>` renders main/EQ/playlist stacked, then exits.
func snapshot(_ args: [String]) -> Never {
    let c = Ctl.shared
    if args[0] != "-" {
        do { c.skin = try Skin.load(from: URL(fileURLWithPath: args[0])) } catch { print("skin error: \(error)"); exit(1) }
    }
    c.bands = [-12, -6, 0, 6, 12, 6, 0, -6, -12, 3]
    c.preamp = 4
    c.playlist.tracks = ["Artist - First Song", "Another Artist - Second Song With A Long Title"].map {
        let t = Track(url: URL(fileURLWithPath: "/tmp/\($0).mp3"))
        t.duration = 215
        return t
    }
    c.playlist.selection = [1]
    let views: [SkinView] = [c.mainView, c.eqView, c.plView]
    func renderAll() -> [CGImage] {
        views.compactMap { v -> CGImage? in
            let s = v.logicalSize
            guard let r = Renderer(width: Int(s.width), height: Int(s.height), skin: c.skin) else { return nil }
            v.render(r)
            return r.image()
        }
    }
    c.snapshotMode = true
    c.debugFillVis()
    var images = renderAll()
    (c.mainShade, c.eqShade, c.plW) = (true, true, 3)
    images += renderAll()
    c.plShade = true
    images += [c.plView].compactMap { v -> CGImage? in
        guard let r = Renderer(width: Int(v.logicalSize.width), height: 14, skin: c.skin) else { return nil }
        v.render(r)
        return r.image()
    }
    let info = c.makeInfoView(1)
    if let r = Renderer(width: Int(info.size.width), height: Int(info.size.height), skin: c.skin) {
        info.render(r)
        if let img = r.image() { images.append(img) }
    }
    let w = images.map(\.width).max() ?? 1, h = images.reduce(0) { $0 + $1.height }
    let ctx = CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    var y = h
    for img in images {
        y -= img.height
        ctx.draw(img, in: CGRect(x: 0, y: y * 2, width: img.width * 2, height: img.height * 2))
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
    exit(0)
}

/// Debug: `MusicAmp --resolve-fonts "Name" ...` runs the font lookup and prints where each font came from.
if let i = CommandLine.arguments.firstIndex(of: "--resolve-fonts") {
    let names = Array(CommandLine.arguments[(i + 1)...])
    let fr = FontResolver.shared
    names.forEach { _ = fr.family(for: $0) }
    let deadline = Date().addingTimeInterval(40)
    while names.contains(where: { fr.status(for: $0) == .searching }), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    for n in names { print("\(n) -> \(fr.family(for: n) ?? "Arial (fallback)")  [\(fr.status(for: n).map { "\($0)" } ?? "?")]") }
    exit(0)
}

/// Debug: `MusicAmp --parse-cursor file.ani|file.cur` prints frame count, delays and hotspots.
if let i = CommandLine.arguments.firstIndex(of: "--parse-cursor"), CommandLine.arguments.count > i + 1 {
    guard let c = SkinCursor.load(URL(fileURLWithPath: CommandLine.arguments[i + 1])) else { print("parse failed"); exit(1) }
    print("frames: \(c.frames.count)  delays: \(c.delays.map { String(format: "%.3f", $0) })")
    print("hotspots: \(c.frames.map { "\(Int($0.hotSpot.x)),\(Int($0.hotSpot.y))" })")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 2 {
    snapshot(Array(CommandLine.arguments[(i + 1)...]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
