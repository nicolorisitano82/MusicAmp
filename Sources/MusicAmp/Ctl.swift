import AppKit
import UniformTypeIdentifiers

/// App controller: playback, settings, window docking and menus.
final class Ctl: NSObject, NSMenuItemValidation, NSMenuDelegate, ObservableObject {
    static let shared = Ctl()

    var skin: Skin = Skin.fallback { didSet { notify() } }
    private(set) var skinPath: String?
    let audio = AudioEngine()
    let playlist = Playlist()

    let mainView = MainView(frame: .zero)
    let eqView = EqView(frame: .zero)
    let plView = PlaylistView(frame: .zero)
    private(set) var mainWindow: SkinWindow!
    private(set) var eqWindow: SkinWindow!
    private(set) var plWindow: SkinWindow!

    // Settings (didSet notify() keeps the SwiftUI preferences panel in sync with clicks on the skin)
    var doubleSize = false { didSet { notify() } }
    var alwaysOnTop = false { didSet { notify() } }
    var shuffle = false { didSet { notify() } }
    var repeatOn = false { didSet { notify() } }
    var timeRemaining = false { didSet { notify() } }
    var visMode = 0 { didSet { notify() } }   // 0 spectrum, 1 oscilloscope, 2 off
    var volume: Double = 75 { didSet { audio.setVolume(volume) } }
    var balance: Double = 0 { didSet { audio.setBalance(balance) } }
    var eqOn = true { didSet { applyEQ() } }
    var eqAuto = false
    var preamp: Double = 0 { didSet { applyEQ() } }
    var bands = [Double](repeating: 0, count: 10) { didSet { applyEQ() } }
    var mainShade = false
    var eqShade = false
    var plShade = false
    var eqVisible = true { didSet { notify() } }
    var plVisible = true { didSet { notify() } }
    var plW = 0
    var plH = 2

    // Preferences panel
    var snapEnabled = true { didSet { notify() } }
    var snapDistance: Double = 10 { didSet { notify() } }
    var marqueeScroll = true { didSet { notify() } }
    var resumeOnLaunch = false { didSet { notify() } }
    var outputDeviceUID: String? { didSet { notify() } }
    var visThinBands = false { didSet { notify() } }
    var visPeaksOn = true { didSet { notify() } }
    var visFalloff = 2 { didSet { notify() } }      // 0 slowest ... 4 fastest
    var peakFalloff = 2 { didSet { notify() } }
    var oscStyle = 1 { didSet { notify() } }        // 0 dots, 1 lines, 2 solid
    var plFontSize = 9 { didSet { notify() } }
    var plShowNumbers = true { didSet { notify() } }
    var plUseSkinFont = true { didSet { notify() } }
    var autoDownloadFonts = true { didSet { FontResolver.shared.autoDownload = autoDownloadFonts; notify() } }

    // Transient UI state
    var marqueeOverride: String?
    var marqueeOffset: CGFloat = 0
    private(set) var tickCount = 0
    private(set) var visBars = [Float](repeating: 0, count: 75)
    private(set) var visPeaks = [Float](repeating: 0, count: 75)
    private var peakFall = [Float](repeating: 0, count: 75)
    private(set) var visWave = [Float](repeating: 0, count: 76)
    private var timer: Timer?
    var prefsWindowRef: NSWindow?

    private func notify() { objectWillChange.send() }

    var scale: CGFloat { doubleSize ? 2 : 1 }
    var windows: [SkinWindow] { [mainWindow, eqWindow, plWindow].compactMap { $0 } }
    var visibleWindows: [SkinWindow] { windows.filter(\.isVisible) }

    /// Custom presets (bands 60 Hz…16 kHz in dB, then preamp). Preamp compensates the largest boost to avoid clipping.
    static let artistPresets: [(String, [Double], Double)] = [
        // Taylor Swift: vocal-forward across country-pop, Antonoff synth-pop (sub-bass) and folklore-style acoustic.
        // Light sub, scoop the 310–600 Hz box, presence at 3 kHz for lyrics, air above 12 kHz for breathy vocals.
        ("TS", [3.2, 1.2, -1.6, -1.2, 0.4, 2.4, 2.0, 2.4, 2.8, 2.0], -3.0),
        // Olivia Rodrigo: pop-punk drums/guitars and belted vocals plus piano ballads.
        // Kick/snare punch, cut guitar mud at 310 Hz, crunch at 1 kHz, restrained 3 kHz (no harsh belts), bright cymbals.
        ("OR", [4.0, 2.4, -2.4, -1.2, 1.2, 1.6, 0.8, 2.4, 3.2, 2.0], -4.0),
    ]

    static let presets: [(String, [Double])] = [
        ("Classical", [0, 0, 0, 0, 0, 0, -7.2, -7.2, -7.2, -9.6]),
        ("Club", [0, 0, 8, 5.6, 5.6, 5.6, 3.2, 0, 0, 0]),
        ("Dance", [9.6, 7.2, 2.4, 0, 0, -5.6, -7.2, -7.2, 0, 0]),
        ("Full Bass", [-8, 9.6, 9.6, 5.6, 1.6, -4, -8, -10.4, -11.2, -11.2]),
        ("Full Bass & Treble", [7.2, 5.6, 0, -7.2, -4.8, 1.6, 8, 11.2, 12, 12]),
        ("Full Treble", [-9.6, -9.6, -9.6, -4, 2.4, 11.2, 12, 12, 12, 12]),
        ("Laptop Speakers/Headphones", [4.8, 11.2, 5.6, -3.2, -2.4, 1.6, 4.8, 9.6, 12, 12]),
        ("Large Hall", [10.4, 10.4, 5.6, 5.6, 0, -4.8, -4.8, -4.8, 0, 0]),
        ("Live", [-4.8, 0, 4, 5.6, 5.6, 5.6, 4, 2.4, 2.4, 2.4]),
        ("Party", [7.2, 7.2, 0, 0, 0, 0, 0, 0, 7.2, 7.2]),
        ("Pop", [-1.6, 4.8, 7.2, 8, 5.6, 0, -2.4, -2.4, -1.6, -1.6]),
        ("Reggae", [0, 0, 0, -5.6, 0, 6.4, 6.4, 0, 0, 0]),
        ("Rock", [8, 4.8, -5.6, -8, -3.2, 4, 8.8, 11.2, 11.2, 11.2]),
        ("Ska", [-2.4, -4.8, -4, 0, 4, 5.6, 8.8, 9.6, 11.2, 9.6]),
        ("Soft", [4.8, 1.6, 0, -2.4, 0, 4, 8, 9.6, 11.2, 12]),
        ("Soft Rock", [4, 4, 2.4, 0, -4, -5.6, -3.2, 0, 2.4, 8.8]),
        ("Techno", [8, 5.6, 0, -5.6, -4.8, 0, 8, 9.6, 9.6, 8.8]),
    ]

    // MARK: Startup

    func start() {
        loadSettings()
        audio.onFinish = { [weak self] in self?.next(auto: true) }
        mainWindow = SkinWindow(view: mainView)
        eqWindow = SkinWindow(view: eqView)
        plWindow = SkinWindow(view: plView)
        if let p = skinPath, let s = try? Skin.load(from: URL(fileURLWithPath: p)) { skin = s } else { skinPath = nil }
        layoutInitial()
        applyLevel()
        applyEQ()
        audio.setVolume(volume)
        audio.setBalance(balance)
        if outputDeviceUID != nil { audio.setOutputDevice(uid: outputDeviceUID) }
        restorePlaylist()

        mainWindow.makeKeyAndOrderFront(nil)
        if eqVisible { eqWindow.orderFront(nil) }
        if plVisible { plWindow.orderFront(nil) }

        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        tickCount += 1
        let playing = audio.state == .playing
        let (spec, wave) = audio.visData()
        let decay: [Float] = [0.012, 0.025, 0.045, 0.07, 0.1]
        let gravity: [Float] = [0.0004, 0.0008, 0.0015, 0.003, 0.006]
        let dec = decay[max(0, min(4, visFalloff))], grav = gravity[max(0, min(4, peakFalloff))]
        for i in 0..<75 {
            visBars[i] = max(playing ? spec[i] : 0, visBars[i] - dec)
            if visBars[i] >= visPeaks[i] {
                visPeaks[i] = visBars[i]
                peakFall[i] = 0
            } else {
                peakFall[i] += grav
                visPeaks[i] = max(0, visPeaks[i] - peakFall[i])
            }
        }
        visWave = playing ? wave : [Float](repeating: 0, count: 76)
        if tickCount % 7 == 0, marqueeOverride == nil, marqueeScroll { marqueeOffset += 5 }
        redraw()
        if tickCount % 900 == 0 { saveSettings() }
    }

    func barValue(_ b: Int) -> Float {
        var m: Float = 0
        for i in (b * 4)..<min(75, b * 4 + 4) { m = max(m, visBars[i]) }
        return m
    }

    func barPeak(_ b: Int) -> Float {
        var m: Float = 0
        for i in (b * 4)..<min(75, b * 4 + 4) { m = max(m, visPeaks[i]) }
        return m
    }

    func redraw() {
        for w in visibleWindows { w.contentView?.needsDisplay = true }
    }

    // MARK: Text helpers

    static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t.isFinite ? t : 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func hmmss(_ t: Double) -> String {
        let s = max(0, Int(t.isFinite ? t : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : mmss(t)
    }

    var marqueeText: String {
        guard let i = playlist.current else { return "MusicAmp" }
        let t = playlist.tracks[i]
        var s = "\(i + 1). \(t.title)"
        if let d = t.duration ?? (audio.duration > 0 ? audio.duration : nil) { s += " (\(Ctl.mmss(d)))" }
        return s
    }

    // MARK: Playback

    func playIndex(_ i: Int, start: Bool = true) {
        guard playlist.tracks.indices.contains(i) else { return }
        let t = playlist.tracks[i]
        playlist.currentTrack = t
        marqueeOffset = 0
        do {
            try audio.load(t.url)
            if start { audio.play() }
        } catch {
            audio.unload()
            marqueeOverride = nil
            NSSound.beep()
        }
        plView.ensureVisible(i)
    }

    @objc func play() {
        if audio.file == nil || playlist.current == nil {
            if playlist.tracks.isEmpty { openFiles(); return }
            playIndex(playlist.current ?? playlist.selection.min() ?? 0)
            return
        }
        audio.play()
    }

    @objc func pause() { audio.pause() }
    @objc func stop() { audio.stop() }

    @objc func next() { next(auto: false) }

    func next(auto: Bool) {
        let n = playlist.tracks.count
        guard n > 0 else { return }
        let wasPlaying = auto || audio.state != .stopped
        var i: Int
        if shuffle, n > 1 {
            repeat { i = Int.random(in: 0..<n) } while i == playlist.current
        } else {
            i = (playlist.current ?? -1) + 1
            if i >= n {
                if auto, !repeatOn { audio.stop(); return }
                i = 0
            }
        }
        playIndex(i, start: wasPlaying)
    }

    @objc func previous() {
        let n = playlist.tracks.count
        guard n > 0 else { return }
        let wasPlaying = audio.state != .stopped
        var i = (playlist.current ?? 0) - 1
        if i < 0 { i = n - 1 }
        playIndex(i, start: wasPlaying)
    }

    func seek(by delta: Double) { audio.seek(to: audio.currentTime + delta) }

    func applyEQ() { audio.setEQ(on: eqOn, preamp: preamp, bands: bands) }

    // MARK: Files

    private func chooseAudio(directories: Bool = false, _ done: ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = !directories
        if !directories { p.allowedContentTypes = [.audio, .m3uPlaylist, .folder] }
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { done(p.urls) }
    }

    @objc func openFiles() {
        chooseAudio { replacePlaylist($0, play: true) }
    }

    @objc func addFiles() { chooseAudio { playlist.add($0) } }
    @objc func addFolder() { chooseAudio(directories: true) { playlist.add($0) } }

    @objc func addURL() {
        marqueeOverride = "SOLO FILE LOCALI"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.marqueeOverride = nil }
    }

    func replacePlaylist(_ urls: [URL], play: Bool) {
        audio.unload()
        playlist.clear()
        playlist.add(urls)
        plView.scrollRow = 0
        if play, !playlist.tracks.isEmpty { playIndex(0) }
    }

    @objc func clearPlaylist() {
        playlist.clear()
        plView.scrollRow = 0
    }

    func handleDrop(_ urls: [URL], toPlaylist: Bool) {
        if let s = urls.first(where: { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }) {
            installAndApplySkin(s)
            return
        }
        if toPlaylist { playlist.add(urls) } else { replacePlaylist(urls, play: true) }
    }

    @objc func loadPlaylistFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.m3uPlaylist, UTType(filenameExtension: "m3u8"), UTType(filenameExtension: "pls")].compactMap { $0 }
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { replacePlaylist([u], play: false) }
    }

    @objc func savePlaylistFile() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.m3uPlaylist]
        p.nameFieldStringValue = "Playlist.m3u"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url {
            do { try playlist.writeM3U(to: u) } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc func fileInfo() { showFileInfo(playlist.current) }

    func showFileInfo(_ index: Int?) {
        guard let i = index, playlist.tracks.indices.contains(i) else { NSSound.beep(); return }
        let t = playlist.tracks[i]
        let a = NSAlert()
        a.messageText = t.title
        var lines = [t.url.path]
        if let d = t.duration { lines.append("Durata: \(Ctl.hmmss(d))") }
        if i == playlist.current, audio.file != nil {
            lines.append("\(audio.bitrate) kbps · \(Int(audio.sampleRate)) Hz · \(audio.channels == 1 ? "mono" : "stereo")")
        }
        a.informativeText = lines.joined(separator: "\n")
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Mostra nel Finder")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([t.url]) }
    }

    // MARK: Skins

    var skinsDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @objc func chooseSkin() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "wsz"), .zip].compactMap { $0 }
        p.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { installAndApplySkin(u) }
    }

    /// Copies the skin into ~/Library/Application Support/MusicAmp/Skins (so it shows in the menu) and applies it.
    func installAndApplySkin(_ url: URL) {
        var target = url
        let dir = skinsDir
        if !url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) {
            let dst = dir.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: url, to: dst) }
            if FileManager.default.fileExists(atPath: dst.path) { target = dst }
        }
        applySkin(target)
    }

    func applySkin(_ url: URL?) {
        if let url {
            do {
                skin = try Skin.load(from: url)
                skinPath = url.path
            } catch {
                let a = NSAlert(error: error)
                a.messageText = "Impossibile caricare \(url.lastPathComponent)"
                a.runModal()
                return
            }
        } else {
            skin = Skin.fallback
            skinPath = nil
        }
        for w in windows { w.invalidateCursorRects(for: w.contentView!) }
        redraw()
        saveSettings()
    }

    @objc func selectSkinItem(_ sender: NSMenuItem) { applySkin(sender.representedObject as? URL) }
    @objc func openSkinsFolder() { NSWorkspace.shared.open(skinsDir) }
    @objc func openSkinMuseum() { NSWorkspace.shared.open(URL(string: "https://skins.webamp.org")!) }

    func installedSkins() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: skinsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["wsz", "zip"].contains($0.pathExtension.lowercased()) || $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func populateSkinsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        item(menu, "Carica skin…", #selector(chooseSkin), "k")
        let def = item(menu, "Skin predefinita", #selector(selectSkinItem(_:)))
        def.representedObject = nil
        menu.addItem(.separator())
        let files = installedSkins()
        for f in files {
            let it = item(menu, f.deletingPathExtension().lastPathComponent, #selector(selectSkinItem(_:)))
            it.representedObject = f
        }
        if !files.isEmpty { menu.addItem(.separator()) }
        item(menu, "Apri cartella skin", #selector(openSkinsFolder))
        item(menu, "Scarica skin (Winamp Skin Museum)…", #selector(openSkinMuseum))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Skin" { populateSkinsMenu(menu) }
    }

    // MARK: Windows

    private func size(of v: SkinView) -> CGSize {
        CGSize(width: v.logicalSize.width * scale, height: v.logicalSize.height * scale)
    }

    private func place(_ w: NSWindow, _ v: SkinView, topLeft: CGPoint) {
        let s = size(of: v)
        w.setFrame(CGRect(x: topLeft.x, y: topLeft.y - s.height, width: s.width, height: s.height), display: true)
    }

    private func layoutInitial() {
        let d = UserDefaults.standard
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        func saved(_ k: String) -> CGPoint? {
            guard let a = d.array(forKey: k) as? [Double], a.count == 2 else { return nil }
            let p = CGPoint(x: a[0], y: a[1])
            return NSScreen.screens.contains { $0.frame.insetBy(dx: -10, dy: -10).contains(p) } ? p : nil
        }
        let m = saved("pos.main") ?? CGPoint(x: (screen.midX - size(of: mainView).width / 2).rounded(), y: screen.maxY - 60)
        place(mainWindow, mainView, topLeft: m)
        place(eqWindow, eqView, topLeft: saved("pos.eq") ?? CGPoint(x: m.x, y: mainWindow.frame.minY))
        place(plWindow, plView, topLeft: saved("pos.pl") ?? CGPoint(x: m.x, y: eqWindow.frame.minY))
    }

    /// Resizes a window keeping its top-left; windows docked below it follow when `moveDocked`.
    func refit(_ w: NSWindow, _ v: SkinView, moveDocked: Bool) {
        let old = w.frame
        let s = size(of: v)
        guard old.size != s else { v.needsDisplay = true; return }
        let below = moveDocked ? windowsBelow(w) : []
        let nf = CGRect(x: old.minX, y: old.maxY - s.height, width: s.width, height: s.height)
        w.setFrame(nf, display: true)
        let dy = nf.minY - old.minY
        for b in below { b.setFrameOrigin(NSPoint(x: b.frame.minX, y: b.frame.minY + dy)) }
        w.invalidateCursorRects(for: v)
        v.needsDisplay = true
    }

    private func windowsBelow(_ w: NSWindow) -> [NSWindow] {
        var res: [NSWindow] = []
        var queue: [NSWindow] = [w]
        while let cur = queue.popLast() {
            for o in visibleWindows where o !== w && !res.contains(o) {
                let a = cur.frame, b = o.frame
                if abs(b.maxY - a.minY) <= 1, b.minX < a.maxX, b.maxX > a.minX {
                    res.append(o)
                    queue.append(o)
                }
            }
        }
        return res
    }

    private func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let xo = a.minX < b.maxX && a.maxX > b.minX
        let yo = a.minY < b.maxY && a.maxY > b.minY
        return (xo && (abs(a.minY - b.maxY) <= 1 || abs(a.maxY - b.minY) <= 1))
            || (yo && (abs(a.minX - b.maxX) <= 1 || abs(a.maxX - b.minX) <= 1))
    }

    private func connected(from w: NSWindow) -> [NSWindow] {
        var res: [NSWindow] = [w]
        var queue: [NSWindow] = [w]
        while let c = queue.popLast() {
            for o in visibleWindows where !res.contains(o) && touches(c.frame, o.frame) {
                res.append(o)
                queue.append(o)
            }
        }
        return res
    }

    // Window dragging with docking (main drags its docked group) and 10 px edge snapping.
    private var dragWindow: NSWindow?
    private var dragGroup: [NSWindow] = []
    private var dragOrigins: [NSWindow: NSPoint] = [:]
    private var dragMouse = NSPoint.zero

    func beginDrag(_ w: NSWindow) {
        dragWindow = w
        dragMouse = NSEvent.mouseLocation
        dragGroup = w === mainWindow ? connected(from: w) : [w]
        dragOrigins = Dictionary(uniqueKeysWithValues: dragGroup.map { ($0, $0.frame.origin) })
    }

    func continueDrag() {
        guard dragWindow != nil else { return }
        let m = NSEvent.mouseLocation
        var dx = m.x - dragMouse.x, dy = m.y - dragMouse.y
        let moved = dragGroup.compactMap { g in dragOrigins[g].map { CGRect(origin: CGPoint(x: $0.x + dx, y: $0.y + dy), size: g.frame.size) } }
        guard let first = moved.first else { return }
        let union = moved.dropFirst().reduce(first) { $0.union($1) }
        let others = visibleWindows.filter { !dragGroup.contains($0) }.map(\.frame)
        let screen = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let s = snapEnabled ? snapDelta(union, others, screen) : .zero
        dx += s.x
        dy += s.y
        for g in dragGroup {
            if let o = dragOrigins[g] { g.setFrameOrigin(NSPoint(x: o.x + dx, y: o.y + dy)) }
        }
    }

    func endDrag() {
        dragWindow = nil
        dragGroup = []
        dragOrigins = [:]
    }

    private func snapDelta(_ f: CGRect, _ targets: [CGRect], _ screen: CGRect) -> CGPoint {
        let T = CGFloat(snapDistance)
        var bx: CGFloat?, by: CGFloat?
        func consider(_ d: CGFloat, _ best: inout CGFloat?) {
            if abs(d) <= T, best == nil || abs(d) < abs(best!) { best = d }
        }
        for t in targets {
            if f.minY <= t.maxY + T, f.maxY >= t.minY - T {
                consider(t.maxX - f.minX, &bx); consider(t.minX - f.maxX, &bx)
                consider(t.minX - f.minX, &bx); consider(t.maxX - f.maxX, &bx)
            }
            if f.minX <= t.maxX + T, f.maxX >= t.minX - T {
                consider(t.maxY - f.minY, &by); consider(t.minY - f.maxY, &by)
                consider(t.minY - f.minY, &by); consider(t.maxY - f.maxY, &by)
            }
        }
        if !screen.isEmpty {
            consider(screen.minX - f.minX, &bx); consider(screen.maxX - f.maxX, &bx)
            consider(screen.minY - f.minY, &by); consider(screen.maxY - f.maxY, &by)
        }
        return CGPoint(x: bx ?? 0, y: by ?? 0)
    }

    @objc func toggleEQ() {
        eqVisible.toggle()
        if eqVisible { eqWindow.orderFront(nil) } else { eqWindow.orderOut(nil) }
    }

    @objc func togglePL() {
        plVisible.toggle()
        if plVisible { plWindow.orderFront(nil) } else { plWindow.orderOut(nil) }
    }

    @objc func toggleMainShade() {
        mainShade.toggle()
        refit(mainWindow, mainView, moveDocked: true)
    }

    @objc func togglePLShade() {
        plShade.toggle()
        refit(plWindow, plView, moveDocked: true)
    }

    @objc func toggleEQShade() {
        eqShade.toggle()
        refit(eqWindow, eqView, moveDocked: true)
    }

    @objc func toggleDoubleSize() {
        let old = scale
        doubleSize.toggle()
        let new = scale
        let anchor = CGPoint(x: mainWindow.frame.minX, y: mainWindow.frame.maxY)
        for w in windows {
            guard let v = w.contentView as? SkinView else { continue }
            let tl = CGPoint(x: w.frame.minX, y: w.frame.maxY)
            place(w, v, topLeft: CGPoint(x: anchor.x + (tl.x - anchor.x) * new / old, y: anchor.y + (tl.y - anchor.y) * new / old))
            w.invalidateCursorRects(for: v)
        }
    }

    @objc func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        applyLevel()
    }

    private func applyLevel() {
        for w in windows { w.level = alwaysOnTop ? .floating : .normal }
    }

    func setPlaylistSize(_ w: Int, _ h: Int) {
        plW = w
        plH = h
        refit(plWindow, plView, moveDocked: false)
        plView.clampScroll()
    }

    // MARK: Keyboard (Winamp shortcuts)

    func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) { return false }
        switch e.keyCode {
        case 123: seek(by: -5); return true
        case 124: seek(by: 5); return true
        case 126: volume = min(100, volume + 2); return true
        case 125: volume = max(0, volume - 2); return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "z": previous()
        case "x": play()
        case "c": pause()
        case "v": stop()
        case "b": next()
        case "l": if e.modifierFlags.contains(.shift) { addFolder() } else { openFiles() }
        case "s": shuffle.toggle()
        case "r": repeatOn.toggle()
        case "j": if let i = playlist.current { plView.ensureVisible(i); playlist.selection = [i] }
        default: return false
        }
        return true
    }

    // MARK: Menus

    @discardableResult
    func item(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
              _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        it.tag = tag
        m.addItem(it)
        return it
    }

    func skinsSubmenuItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Skin", action: nil, keyEquivalent: "")
        let m = NSMenu(title: "Skin")
        m.delegate = self
        it.submenu = m
        return it
    }

    func visMenu() -> NSMenu {
        let m = NSMenu(title: "Visualizzazione")
        item(m, "Analizzatore di spettro", #selector(setVisMode(_:)), tag: 0)
        item(m, "Oscilloscopio", #selector(setVisMode(_:)), tag: 1)
        item(m, "Disattivata", #selector(setVisMode(_:)), tag: 2)
        return m
    }

    func optionsMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Apri file…", #selector(openFiles))
        item(m, "Info file…", #selector(fileInfo))
        m.addItem(.separator())
        m.addItem(skinsSubmenuItem())
        let vis = NSMenuItem(title: "Visualizzazione", action: nil, keyEquivalent: "")
        vis.submenu = visMenu()
        m.addItem(vis)
        m.addItem(.separator())
        item(m, "Preferenze…", #selector(showPreferences))
        m.addItem(.separator())
        item(m, "Equalizzatore", #selector(toggleEQ))
        item(m, "Playlist", #selector(togglePL))
        item(m, "Modalità ridotta", #selector(toggleMainShade))
        item(m, "Playlist ridotta", #selector(togglePLShade))
        item(m, "Doppia dimensione", #selector(toggleDoubleSize))
        item(m, "Sempre in primo piano", #selector(toggleAlwaysOnTop))
        item(m, "Tempo rimanente", #selector(toggleTimeRemaining))
        m.addItem(.separator())
        item(m, "Shuffle", #selector(toggleShuffle))
        item(m, "Ripeti", #selector(toggleRepeat))
        m.addItem(.separator())
        let q = NSMenuItem(title: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        m.addItem(q)
        return m
    }

    func presetsMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Flat (reset)", #selector(resetEQ))
        m.addItem(.separator())
        for (i, p) in Ctl.artistPresets.enumerated() { item(m, p.0, #selector(applyArtistPreset(_:)), tag: i) }
        m.addItem(.separator())
        for (i, p) in Ctl.presets.enumerated() { item(m, p.0, #selector(applyPreset(_:)), tag: i) }
        return m
    }

    func sortMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Ordina per titolo", #selector(sortByTitle))
        item(m, "Ordina per nome file", #selector(sortByFilename))
        item(m, "Ordina per percorso", #selector(sortByPath))
        m.addItem(.separator())
        item(m, "Inverti ordine", #selector(reverseList))
        item(m, "Ordine casuale", #selector(randomizeList))
        return m
    }

    func removeMiscMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Rimuovi file mancanti", #selector(removeMissing))
        item(m, "Rimuovi duplicati", #selector(removeDuplicates))
        return m
    }

    func miscOptionsMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Mostra nel Finder", #selector(revealSelected))
        item(m, "Vai al brano in riproduzione (J)", #selector(jumpToCurrent))
        return m
    }

    @objc func setVisMode(_ s: NSMenuItem) { visMode = s.tag }
    @objc func toggleTimeRemaining() { timeRemaining.toggle() }
    @objc func toggleShuffle() { shuffle.toggle() }
    @objc func toggleRepeat() { repeatOn.toggle() }
    @objc func resetEQ() { bands = Array(repeating: 0, count: 10); preamp = 0 }
    @objc func applyPreset(_ s: NSMenuItem) { bands = Ctl.presets[s.tag].1 }

    @objc func applyArtistPreset(_ s: NSMenuItem) {
        let p = Ctl.artistPresets[s.tag]
        bands = p.1
        preamp = p.2
        eqOn = true
    }
    @objc func sortByTitle() { playlist.sort { $0.title } }
    @objc func sortByFilename() { playlist.sort { $0.url.lastPathComponent } }
    @objc func sortByPath() { playlist.sort { $0.url.path } }
    @objc func reverseList() { playlist.reverse() }
    @objc func randomizeList() { playlist.shuffle() }
    @objc func jumpToCurrent() { if let i = playlist.current { plView.ensureVisible(i); playlist.selection = [i] } }

    @objc func removeMissing() {
        let missing = Set(playlist.tracks.indices.filter { !FileManager.default.fileExists(atPath: playlist.tracks[$0].url.path) })
        playlist.remove(missing)
        plView.clampScroll()
    }

    @objc func removeDuplicates() {
        var seen = Set<String>()
        let dup = Set(playlist.tracks.indices.filter { !seen.insert(playlist.tracks[$0].url.path).inserted })
        playlist.remove(dup)
        plView.clampScroll()
    }

    @objc func revealSelected() {
        let urls = playlist.selection.sorted().map { playlist.tracks[$0].url }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func validateMenuItem(_ it: NSMenuItem) -> Bool {
        func on(_ b: Bool) { it.state = b ? .on : .off }
        switch it.action {
        case #selector(toggleEQ): on(eqVisible)
        case #selector(togglePL): on(plVisible)
        case #selector(toggleMainShade): on(mainShade)
        case #selector(togglePLShade): on(plShade)
        case #selector(toggleEQShade): on(eqShade)
        case #selector(toggleDoubleSize): on(doubleSize)
        case #selector(toggleAlwaysOnTop): on(alwaysOnTop)
        case #selector(toggleTimeRemaining): on(timeRemaining)
        case #selector(toggleShuffle): on(shuffle)
        case #selector(toggleRepeat): on(repeatOn)
        case #selector(setVisMode(_:)): on(it.tag == visMode)
        case #selector(selectSkinItem(_:)): on((it.representedObject as? URL)?.path == skinPath)
        case #selector(savePlaylistFile): return !playlist.tracks.isEmpty
        case #selector(fileInfo): return playlist.current != nil
        default: break
        }
        return true
    }

    // MARK: Persistence

    private func loadSettings() {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
        volume = dbl("volume", 75)
        balance = dbl("balance", 0)
        eqOn = bool("eqOn", true)
        eqAuto = bool("eqAuto", false)
        preamp = dbl("preamp", 0)
        if let b = d.array(forKey: "bands") as? [Double], b.count == 10 { bands = b }
        doubleSize = bool("doubleSize", false)
        alwaysOnTop = bool("alwaysOnTop", false)
        shuffle = bool("shuffle", false)
        repeatOn = bool("repeat", false)
        timeRemaining = bool("timeRemaining", false)
        visMode = int("visMode", 0)
        mainShade = bool("mainShade", false)
        eqShade = bool("eqShade", false)
        plShade = bool("plShade", false)
        eqVisible = bool("eqVisible", true)
        plVisible = bool("plVisible", true)
        plW = int("plW", 0)
        plH = int("plH", 2)
        skinPath = d.string(forKey: "skinPath")
        snapEnabled = bool("snapEnabled", true)
        snapDistance = dbl("snapDistance", 10)
        marqueeScroll = bool("marqueeScroll", true)
        resumeOnLaunch = bool("resumeOnLaunch", false)
        outputDeviceUID = d.string(forKey: "outputDeviceUID")
        visThinBands = bool("visThinBands", false)
        visPeaksOn = bool("visPeaksOn", true)
        visFalloff = int("visFalloff", 2)
        peakFalloff = int("peakFalloff", 2)
        oscStyle = int("oscStyle", 1)
        plFontSize = int("plFontSize", 9)
        plShowNumbers = bool("plShowNumbers", true)
        plUseSkinFont = bool("plUseSkinFont", true)
        autoDownloadFonts = bool("autoDownloadFonts", true)
    }

    func saveSettings() {
        let d = UserDefaults.standard
        let values: [String: Any] = [
            "volume": volume, "balance": balance, "eqOn": eqOn, "eqAuto": eqAuto, "preamp": preamp, "bands": bands,
            "doubleSize": doubleSize, "alwaysOnTop": alwaysOnTop, "shuffle": shuffle, "repeat": repeatOn,
            "timeRemaining": timeRemaining, "visMode": visMode, "mainShade": mainShade, "eqShade": eqShade,
            "plShade": plShade, "eqVisible": eqVisible, "plVisible": plVisible, "plW": plW, "plH": plH,
            "snapEnabled": snapEnabled, "snapDistance": snapDistance, "marqueeScroll": marqueeScroll,
            "resumeOnLaunch": resumeOnLaunch, "visThinBands": visThinBands, "visPeaksOn": visPeaksOn,
            "visFalloff": visFalloff, "peakFalloff": peakFalloff, "oscStyle": oscStyle, "plFontSize": plFontSize,
            "plShowNumbers": plShowNumbers, "plUseSkinFont": plUseSkinFont, "autoDownloadFonts": autoDownloadFonts,
            "playlist": playlist.tracks.map(\.url.path), "current": playlist.current ?? -1,
            "resumeTime": audio.currentTime, "resumePlaying": audio.state == .playing,
        ]
        for (k, v) in values { d.set(v, forKey: k) }
        for (k, v) in [("skinPath", skinPath), ("outputDeviceUID", outputDeviceUID)] {
            if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        for (k, w) in [("pos.main", mainWindow), ("pos.eq", eqWindow), ("pos.pl", plWindow)] {
            if let w { d.set([Double(w.frame.minX), Double(w.frame.maxY)], forKey: k) }
        }
    }

    private func restorePlaylist() {
        let d = UserDefaults.standard
        guard let paths = d.stringArray(forKey: "playlist") else { return }
        playlist.add(paths.map { URL(fileURLWithPath: $0) })
        let c = d.integer(forKey: "current")
        guard playlist.tracks.indices.contains(c) else { return }
        playIndex(c, start: false)
        if resumeOnLaunch, d.bool(forKey: "resumePlaying") {
            audio.play()
            audio.seek(to: d.double(forKey: "resumeTime"))
        }
    }
}
