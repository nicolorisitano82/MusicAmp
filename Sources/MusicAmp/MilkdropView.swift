import AppKit
import MetalKit

extension Ctl {
    /// Milkdrop window (⌥⌘M): full-screen visualizer driven by the playing audio.
    @objc func showMilkdrop() {
        if milkdropWindowRef == nil {
            guard let c = MilkdropController(ctl: self) else {
                let a = NSAlert()
                a.messageText = "Milkdrop Unavailable"
                a.informativeText = "This Mac doesn’t have a usable Metal GPU."
                a.runModal()
                return
            }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = L("Milkdrop")
            w.contentView = c.view
            w.collectionBehavior = [.fullScreenPrimary]
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.setFrameAutosaveName("MusicAmpMilkdrop")
            w.delegate = c
            milkdropWindowRef = w
            milkdropController = c
        }
        milkdropController?.setActive(true)
        NSApp.activate(ignoringOtherApps: true)
        milkdropWindowRef?.makeKeyAndOrderFront(nil)
        milkdropWindowRef?.makeFirstResponder(milkdropController?.view)
    }
}

/// Folder for user presets, created on first use.
enum MilkdropLibrary {
    static var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Milkdrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Built-in presets plus every .milk under the folder (subfolders too), sorted by name.
    static func entries() -> [Entry] {
        var out = MilkdropBuiltins.all.map { Entry(name: $0.0, url: nil) }
        if let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            var files: [Entry] = []
            for case let f as URL in en where f.pathExtension.lowercased() == "milk" {
                files.append(Entry(name: f.deletingPathExtension().lastPathComponent, url: f))
            }
            out += files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return out
    }

    struct Entry: Equatable {
        let name: String
        let url: URL?
        func load() -> MilkPreset? {
            if let url { return MilkPreset.load(url) }
            return MilkdropBuiltins.all.first { $0.0 == name }.map { MilkPreset.parse($0.1, name: name) }
        }
    }
}

final class MilkdropMTKView: MTKView {
    weak var controller: MilkdropController?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if controller?.handleKey(e) != true { super.keyDown(with: e) } }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.toggleFullScreen(nil) } else { super.mouseDown(with: e) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu() }
}

final class MilkdropController: NSObject, MTKViewDelegate, NSWindowDelegate {
    weak var ctl: Ctl?
    let renderer: MilkdropRenderer
    let view: MilkdropMTKView
    private let label = NSTextField(labelWithString: "")
    private var entries: [MilkdropLibrary.Entry] = []
    private var history: [Int] = []
    private var historyPos = -1
    private var lastChange = Date()
    private var lastFrame = Date()
    private(set) var locked = false
    /// Seconds between automatic changes (0 = never).
    var interval: Double {
        get { UserDefaults.standard.object(forKey: "milkdropInterval") as? Double ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "milkdropInterval") }
    }

    init?(ctl: Ctl) {
        guard let r = MilkdropRenderer() else { return nil }
        self.ctl = ctl
        renderer = r
        view = MilkdropMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), device: r.device)
        super.init()
        view.controller = self
        view.colorPixelFormat = MilkdropRenderer.format
        view.preferredFramesPerSecond = 60
        view.delegate = self
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.shadow = { let s = NSShadow(); s.shadowBlurRadius = 4; s.shadowColor = .black; return s }()
        label.alphaValue = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                                     label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)])
        reloadPresets()
        let last = UserDefaults.standard.string(forKey: "milkdropPreset")
        select(entries.firstIndex { $0.name == last } ?? Int.random(in: 0..<entries.count), blend: false)
    }

    func setActive(_ on: Bool) {
        ctl?.audio.milkdropEnabled = on
        view.isPaused = !on
    }

    func windowWillClose(_ notification: Notification) {
        setActive(false)
        if let w = notification.object as? NSWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
    }

    func windowDidMiniaturize(_ notification: Notification) { setActive(false) }
    func windowDidDeminiaturize(_ notification: Notification) { setActive(true) }

    // MARK: Presets

    func reloadPresets() {
        entries = MilkdropLibrary.entries()
    }

    private let compileQueue = DispatchQueue(label: "milkdrop.compile", qos: .userInitiated)
    private var pending = 0

    /// Shaders compile in the background; the current preset keeps playing until the new one is ready.
    private func select(_ i: Int, blend: Bool = true, record: Bool = true) {
        guard entries.indices.contains(i) else { return }
        let entry = entries[i]
        lastChange = Date()
        if record {
            history = Array(history.prefix(historyPos + 1)) + [i]
            historyPos = history.count - 1
        }
        pending += 1
        let ticket = pending
        compileQueue.async { [weak self] in
            guard let self, let p = entry.load() else { return }
            let prepared = self.renderer.prepare(p)
            DispatchQueue.main.async {
                guard ticket == self.pending else { return }   // a newer choice won
                self.renderer.install(prepared, blend: blend)
                self.lastChange = Date()
                UserDefaults.standard.set(p.name, forKey: "milkdropPreset")
                var text = p.name
                if !prepared.notes.isEmpty {
                    text += "  ·  shader not translated, using the classic pipeline"
                    NSLog("Milkdrop %@: %@", p.name, prepared.notes.joined(separator: " | "))
                }
                self.show(text)
            }
        }
    }

    func next() {
        guard entries.count > 1 else { return }
        if historyPos < history.count - 1 {
            historyPos += 1
            select(history[historyPos], record: false)
            return
        }
        var i = Int.random(in: 0..<entries.count)
        if i == history.last { i = (i + 1) % entries.count }
        select(i)
    }

    func previous() {
        guard historyPos > 0 else { return }
        historyPos -= 1
        select(history[historyPos], record: false)
    }

    private func show(_ text: String) {
        label.stringValue = text
        label.alphaValue = 1
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.4
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.label.stringValue == text else { return }
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.8
                self.label.animator().alphaValue = 0
            }
        }
    }

    // MARK: Input

    func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 49, 124: next(); return true                                   // space, →
        case 123: previous(); return true                                   // ←
        case 37: locked.toggle(); show(locked ? "Preset locked" : "Auto-advance"); return true   // L
        case 3, 36: view.window?.toggleFullScreen(nil); return true         // F, Return
        case 53:                                                            // Esc
            if view.window?.styleMask.contains(.fullScreen) == true { view.window?.toggleFullScreen(nil) } else { view.window?.performClose(nil) }
            return true
        case 4: show("Space/→ next preset · ← previous · L lock · F full screen · Esc exit"); return true   // H
        default: return ctl?.handleKey(e) ?? false   // Winamp keys (Z X C V B…) still work here
        }
    }

    func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: L("Next Preset"), action: #selector(menuNext), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Previous Preset"), action: #selector(menuPrev), keyEquivalent: "").target = self
        let lock = m.addItem(withTitle: L("Lock Preset"), action: #selector(menuLock), keyEquivalent: "")
        lock.target = self
        lock.state = locked ? .on : .off
        let auto = NSMenu()
        for s in [0.0, 10, 20, 40, 90] {
            let it = auto.addItem(withTitle: s == 0 ? "Never" : "Every \(Int(s)) s", action: #selector(menuInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s
            it.state = interval == s ? .on : .off
        }
        m.addItem(withTitle: L("Auto-Advance"), action: nil, keyEquivalent: "").submenu = auto
        let list = NSMenu()
        for (i, e) in entries.enumerated() {
            let it = list.addItem(withTitle: e.name, action: #selector(menuPick(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = history.indices.contains(historyPos) && history[historyPos] == i ? .on : .off
        }
        m.addItem(withTitle: L("Presets"), action: nil, keyEquivalent: "").submenu = list
        m.addItem(.separator())
        m.addItem(withTitle: L("Open Presets Folder"), action: #selector(menuFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Reload Presets"), action: #selector(menuReload), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Full Screen"), action: #selector(menuFull), keyEquivalent: "").target = self
        return m
    }

    @objc private func menuNext() { next() }
    @objc private func menuPrev() { previous() }
    @objc private func menuLock() { locked.toggle() }
    @objc private func menuInterval(_ s: NSMenuItem) { interval = s.representedObject as? Double ?? 20 }
    @objc private func menuPick(_ s: NSMenuItem) { select(s.tag) }
    @objc private func menuFolder() { NSWorkspace.shared.open(MilkdropLibrary.folder) }
    @objc private func menuReload() { reloadPresets(); show("\(entries.count) \(entries.count == 1 ? "preset" : "presets")") }
    @objc private func menuFull() { view.window?.toggleFullScreen(nil) }

    // MARK: Frame loop

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = Date()
        let dt = now.timeIntervalSince(lastFrame)
        lastFrame = now
        if let a = ctl?.audio {
            let d = a.state == .playing ? a.milkdropData() : (Array(repeating: 0, count: 576), Array(repeating: 0, count: 576), Array(repeating: 0, count: 512), (0, 0, 0))
            renderer.updateAudio(left: d.0, right: d.1, spectrum: d.2, bands: d.3, dt: dt)
        }
        if !locked, interval > 0, now.timeIntervalSince(lastChange) > interval { next() }
        guard let drawable = view.currentDrawable, let cb = renderer.render(into: drawable.texture) else { return }
        cb.present(drawable)
        cb.commit()
    }
}
