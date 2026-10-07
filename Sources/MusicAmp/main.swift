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

        // Standard Edit menu: text fields (library search, preferences, Jump to file) get ⌘A ⌘C ⌘V ⌘X ⌘Z from it.
        let edit = sub("Composizione")
        edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let file = sub("File")
        c.item(file, "Apri file…", #selector(Ctl.openFiles), "o")
        c.item(file, "Aggiungi file…", #selector(Ctl.addFiles), "o", [.command, .shift])
        c.item(file, "Aggiungi cartella…", #selector(Ctl.addFolder))
        c.item(file, "Apri URL…", #selector(Ctl.openURL), "u")
        file.addItem(.separator())
        c.item(file, "Carica playlist…", #selector(Ctl.loadPlaylistFile))
        c.item(file, "Salva playlist…", #selector(Ctl.savePlaylistFile), "s")
        file.addItem(.separator())
        c.item(file, "Info file…", #selector(Ctl.fileInfo), "i")

        let play = sub("Riproduzione")
        // Winamp letter keys (Z X C V B, J, Q…) are handled by the skin windows, not as menu key equivalents:
        // as menu shortcuts they would fire while typing in the library or preferences search fields.
        c.item(play, "Precedente (Z)", #selector(Ctl.previous))
        c.item(play, "Play (X)", #selector(Ctl.play))
        c.item(play, "Pausa (C)", #selector(Ctl.pause))
        c.item(play, "Stop (V)", #selector(Ctl.stop))
        c.item(play, "Successivo (B)", #selector(Ctl.next as (Ctl) -> () -> Void))
        play.addItem(.separator())
        c.item(play, "Vai al file… (J)", #selector(Ctl.showJumpToFile))
        c.item(play, "Accoda / togli dalla coda (Q)", #selector(Ctl.queueSelected))
        c.item(play, "Svuota coda", #selector(Ctl.clearQueue))
        play.addItem(.separator())
        c.item(play, "Shuffle (S)", #selector(Ctl.toggleShuffle))
        c.item(play, "Ripeti (R)", #selector(Ctl.toggleRepeat))
        c.item(play, "Tempo rimanente", #selector(Ctl.toggleTimeRemaining))

        let skins = sub("Skin")
        skins.delegate = c

        let view = sub("Vista")
        c.item(view, "Equalizzatore", #selector(Ctl.toggleEQ), "g", [.option])
        c.item(view, "Playlist", #selector(Ctl.togglePL), "e", [.option])
        c.item(view, "Libreria", #selector(Ctl.showLibrary), "l", [.option])
        c.item(view, "Radio", #selector(Ctl.showRadio), "r", [.option])
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

/// Debug: `MusicAmp --self-test [file.eqf ...]` checks EQ preset files, the play queue and drop insertion.
if let i = CommandLine.arguments.firstIndex(of: "--self-test") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }
    // EQF: hand-built bytes as Winamp writes them
    var raw = EQF.header
    var name = Array("Test".utf8); name += [UInt8](repeating: 0, count: 257 - name.count)
    raw.append(contentsOf: name)
    raw.append(contentsOf: [0, 63, 31, 32, 16, 47, 0, 63, 31, 32, 20] as [UInt8])
    let parsed = EQF.parse(raw)
    check(parsed?.count == 1 && parsed?[0].name == "Test", "eqf: one preset named Test")
    check(parsed?[0].bands.first == 12 && parsed?[0].bands[1] == -12, "eqf: 0 = +12 dB, 63 = -12 dB")
    check(parsed?[0].bands[2] == 0, "eqf: 0x1F (31) = 0 dB")
    check(parsed.map { EQF.write($0) } == raw, "eqf: write(parse(x)) == x")
    let lib = [EQPreset(name: "A", bands: Array(repeating: 3, count: 10), preamp: -2),
               EQPreset(name: "B", bands: Array(repeating: -6, count: 10), preamp: 1)]
    let back = EQF.parse(EQF.write(lib))
    check(back?.map(\.name) == ["A", "B"] && back.map { zip($0, lib).allSatisfy { abs($0.bands[0] - $1.bands[0]) < 0.4 && abs($0.preamp - $1.preamp) < 0.4 } } == true,
          "q1: two presets round-trip within 0.4 dB")
    for path in CommandLine.arguments[(i + 1)...] {
        let ps = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(EQF.parse) ?? []
        print("file \(path): \(ps.count) preset" + ps.prefix(3).map { "\n  \($0.name): \($0.bands.map { String(format: "%+.1f", $0) }.joined(separator: " ")) pre \(String(format: "%+.1f", $0.preamp))" }.joined())
    }
    // Queue
    let pl = Playlist()
    pl.tracks = (0..<6).map { Track(url: URL(fileURLWithPath: "/tmp/t\($0).mp3")) }
    pl.toggleQueue([4]); pl.toggleQueue([1]); pl.toggleQueue([2])
    check(pl.queue.map { pl.tracks.firstIndex(of: $0) } == [4, 1, 2], "queue: order kept as queued")
    pl.toggleQueue([1])
    check(pl.queue.count == 2 && pl.queuePosition(pl.tracks[2]) == 2, "queue: Q again removes, positions shift")
    pl.remove([4])
    check(pl.popQueue() == 2 && pl.queue.isEmpty, "queue: removed tracks skipped, pop returns playlist index")
    // Insert at a drop position
    pl.insert([], at: 1)
    let before = pl.tracks.count
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-selftest.mp3")
    FileManager.default.createFile(atPath: tmp.path, contents: Data())
    pl.insert([tmp], at: 2)
    check(pl.tracks.count == before + 1 && pl.tracks[2].url == tmp && pl.selection == [2], "insert: lands at index 2 and is selected")
    try? FileManager.default.removeItem(at: tmp)
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-radio URL [seconds]` plays a stream muted and prints what the engine sees.
if let i = CommandLine.arguments.firstIndex(of: "--test-radio"), CommandLine.arguments.count > i + 1,
   let url = URL(string: CommandLine.arguments[i + 1]) {
    let secs = Double(CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "8") ?? 8
    let a = AudioEngine()
    a.setVolume(0)
    a.bufferSeconds = 2
    var lastTitle: String?
    a.onStreamInfo = {
        if a.stream.title != lastTitle { lastTitle = a.stream.title; print("  title: \(a.stream.title ?? "-")") }
        if let e = a.stream.error { print("  status: \(e)") }
    }
    var rms: Float = 0
    a.eq.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
        guard let ch = buf.floatChannelData else { return }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[0][i] * ch[0][i] }
        rms = max(rms, (sum / Float(max(1, buf.frameLength))).squareRoot())
    }
    a.playStream(url)
    let start = Date()
    var peak: Float = 0
    while Date().timeIntervalSince(start) < secs {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        peak = max(peak, a.visData().0.max() ?? 0)
    }
    print("  name=\(a.stream.name ?? "-") hls=\(a.stream.isHLS) rate=\(Int(a.sampleRate)) ch=\(a.channels) kbps=\(a.bitrate)")
    print("  state=\(a.state) buffering=\(a.stream.buffering) played=\(String(format: "%.1f", a.currentTime))s vis-peak=\(String(format: "%.2f", peak)) eq-rms=\(String(format: "%.3f", rms)) error=\(a.stream.error ?? "none")")
    exit(a.currentTime > 1 || a.stream.isHLS ? 0 : 1)
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
