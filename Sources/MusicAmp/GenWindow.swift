import AppKit

/// genex.bmp system colours (row 0, every 2 px from x 48), as used by Winamp's generic windows.
struct GenColors {
    var itemBackground, itemForeground, windowBackground, buttonText, windowText, divider,
        selection, headerBackground, headerText: CGColor

    init(_ skin: Skin) {
        let px = skin.image("genex").map { img in (0..<18).map { Skin.pixels(img, R(48 + CGFloat($0 * 2), 0, 1, 1)).first } } ?? []
        func c(_ i: Int, _ def: CGColor) -> CGColor { (i < px.count ? px[i] : nil) ?? def }
        itemBackground = c(0, rgb(0, 0, 0))
        itemForeground = c(1, rgb(0, 255, 0))
        windowBackground = c(2, rgb(56, 55, 87))
        buttonText = c(3, rgb(0, 0, 0))
        windowText = c(4, rgb(255, 255, 255))
        divider = c(5, rgb(117, 116, 139))
        selection = c(6, rgb(0, 0, 198))
        headerBackground = c(7, rgb(72, 72, 120))
        headerText = c(8, rgb(255, 255, 255))
    }
}

extension Skin {
    /// Variable-width title letters from gen.bmp (row 88 active, 96 inactive), split on the background colour
    /// found at x = 0 of each row, the same way Winamp reads them.
    func genLetters(active: Bool) -> [Character: CGRect] {
        guard let img = image("gen"), img.height >= 103 else { return [:] }
        let y = active ? 88 : 96
        let row = Skin.pixels(img, R(0, CGFloat(y), CGFloat(img.width), 1))
        guard let bg = row.first else { return [:] }
        var out: [Character: CGRect] = [:]
        var x = 1
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            var end = x
            while end < row.count, row[end] != bg { end += 1 }
            guard end > x else { break }
            out[ch] = R(CGFloat(x), CGFloat(y), CGFloat(end - x), 6)
            x = end + 1
        }
        return out
    }
}

/// Winamp "general purpose" window frame (gen.bmp) with genex.bmp colours and buttons.
final class GenView: SkinView {
    var title: String
    var size: CGSize
    var buttons: [(String, () -> Void)] = []
    var drawContent: (Renderer, CGRect, GenColors) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}

    private var pressed: String?
    private var pressInside = false

    init(title: String, size: CGSize) {
        self.title = title
        self.size = size
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var logicalSize: CGSize { size }

    override var renderSignature: Int {
        var h = Hasher()
        h.combine(isActive); h.combine(ObjectIdentifier(skin)); h.combine(pressed); h.combine(pressInside); h.combine(title)
        return h.finalize()
    }

    private var W: CGFloat { size.width }
    private var H: CGFloat { size.height }
    private var closeRect: CGRect { R(W - 11, 3, 9, 9) }

    private func buttonRects() -> [(String, CGRect)] {
        var x = W - 8 - 6
        return buttons.reversed().map { b in
            let w = max(47, CGFloat(b.0.count) * 6 + 16)
            x -= w
            defer { x -= 4 }
            return (b.0, R(x, H - 14 - 6 - 15, w, 15))
        }
    }

    override func render(_ r: Renderer) {
        let y0: CGFloat = isActive ? 0 : 21
        let letters = skin.genLetters(active: isActive)
        let text = title.uppercased()
        let tw = text.reduce(CGFloat(0)) { $0 + (letters[$1]?.width ?? 5) + 1 }
        let cw = max(25, ((tw + 10) / 25).rounded(.up) * 25)
        let tx = ((W - cw) / 2).rounded(.down)

        // Title bar: corner, bar fill, bar end, title centre, bar start, bar fill, corner with close
        r.tileX("gen", R(104, y0, 25, 20), 25, 0, width: tx - 50)
        r.tileX("gen", R(104, y0, 25, 20), tx + cw + 25, 0, width: W - 25 - (tx + cw + 25))
        r.blit("gen", R(0, y0, 25, 20), 0, 0)
        r.blit("gen", R(26, y0, 25, 20), tx - 25, 0)
        r.tileX("gen", R(52, y0, 25, 20), tx, 0, width: cw)
        r.blit("gen", R(78, y0, 25, 20), tx + cw, 0)
        r.blit("gen", R(130, y0, 25, 20), W - 25, 0)
        var x = tx + ((cw - tw) / 2).rounded(.down)
        for ch in text {
            if let src = letters[ch] { r.blit("gen", src, x, 4); x += src.width + 1 } else { x += 5 }
        }
        if pressed == "close", pressInside { r.blit("gen", R(148, 42, 9, 9), W - 11, 3) }

        // Sides and bottom
        let sideH = H - 20 - 14 - 24
        r.tileY("gen", R(127, 42, 11, 29), 0, 20, height: sideH)
        r.tileY("gen", R(139, 42, 8, 29), W - 8, 20, height: sideH)
        r.blit("gen", R(158, 42, 11, 24), 0, H - 14 - 24)
        r.blit("gen", R(170, 42, 8, 24), W - 8, H - 14 - 24)
        // The fill art is 13 rows (row 85 is sheet background in the base skin): repeat the last row.
        r.tileX("gen", R(127, 72, 25, 13), 125, H - 14, width: W - 250)
        r.tileX("gen", R(127, 84, 25, 1), 125, H - 1, width: W - 250)
        r.blit("gen", R(0, 42, 125, 14), 0, H - 14)
        r.blit("gen", R(0, 57, 125, 14), W - 125, H - 14)

        // Content
        let colors = GenColors(skin)
        let content = R(11, 20, W - 19, H - 34)
        r.fill(colors.windowBackground, content)
        drawContent(r, content, colors)

        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        for (id, rect) in buttonRects() {
            let down = pressed == id && pressInside
            let y: CGFloat = down ? 16 : 0
            r.blit("genex", R(0, y, 4, 15), rect.minX, rect.minY)
            r.blit("genex", R(4, y, 39, 15), rect.minX + 4, rect.minY, w: rect.width - 8)
            r.blit("genex", R(43, y, 4, 15), rect.maxX - 4, rect.minY)
            let tw = r.measure(id, font: font)
            r.ttf(id, font: font, color: colors.buttonText, x: rect.midX - tw / 2 + (down ? 1 : 0), baseline: rect.minY + 11, maxWidth: rect.width - 6)
        }
    }

    override func hitDown(_ p: CGPoint, _ e: NSEvent) -> Bool {
        if closeRect.contains(p) { pressed = "close"; pressInside = true; return true }
        for (id, rect) in buttonRects() where rect.contains(p) { pressed = id; pressInside = true; return true }
        return false
    }

    override func hitDrag(_ p: CGPoint, _ e: NSEvent) {
        guard let id = pressed else { return }
        pressInside = id == "close" ? closeRect.contains(p) : (buttonRects().first { $0.0 == id }?.1.contains(p) ?? false)
    }

    override func hitUp(_ p: CGPoint, _ e: NSEvent) {
        defer { pressed = nil }
        guard let id = pressed, pressInside else { return }
        if id == "close" { onClose(); return }
        buttons.first { $0.0 == id }?.1()
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 || e.keyCode == 36 { onClose(); return }   // Esc / Return
        super.keyDown(with: e)
    }

    override func cursorAreas() -> [(String, CGRect)] { [] }
}

extension Renderer {
    func measure(_ s: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font])), nil, nil, nil))
    }
}

extension Ctl {
    /// "File info" as a skinned gen.bmp window, like Winamp's general purpose windows.
    func showInfoWindow(_ i: Int) {
        let view = makeInfoView(i)
        let window = SkinWindow(view: view)
        view.onClose = { [weak window] in window?.orderOut(nil) }
        view.buttons = [("Finder", { [url = playlist.tracks[i].url] in NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                        ("OK", { [weak window] in window?.orderOut(nil) })]
        let s = CGSize(width: view.size.width * scale, height: view.size.height * scale)
        let anchor = mainWindow.frame
        window.setFrame(CGRect(x: anchor.midX - s.width / 2, y: anchor.minY - s.height - 20, width: s.width, height: s.height), display: false)
        window.level = alwaysOnTop ? .floating : .normal
        infoWindows.removeAll { !$0.isVisible }
        infoWindows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func makeInfoView(_ i: Int) -> GenView {
        let t = playlist.tracks[i]
        let isCurrent = i == playlist.current && audio.file != nil
        let view = GenView(title: "File info", size: CGSize(width: 325, height: 174))
        view.buttons = [("Finder", {}), ("OK", {})]
        view.drawContent = { [weak self] r, rect, c in
            guard let self else { return }
            var rows: [(String, String)] = [
                ("Titolo", t.songTitle ?? t.title),
                ("Artista", t.artist ?? "—"),
                ("Album", t.album ?? "—"),
                ("Durata", t.duration.map(Ctl.hmmss) ?? "—"),
            ]
            if isCurrent {
                let ch = self.audio.channels == 1 ? "mono" : "stereo"
                rows.append(("Formato", "\(self.audio.bitrate) kbps · \(Int(self.audio.sampleRate)) Hz · \(ch)"))
            } else {
                rows.append(("Formato", t.url.pathExtension.uppercased()))
            }
            let label = NSFont.systemFont(ofSize: 9, weight: .semibold), value = NSFont.systemFont(ofSize: 9)
            var y = rect.minY + 8
            for (k, v) in rows {
                r.ttf(k, font: label, color: c.windowText, x: rect.minX + 8, baseline: y + 9, maxWidth: 52)
                r.ttf(v, font: value, color: c.windowText, x: rect.minX + 62, baseline: y + 9, maxWidth: rect.width - 70)
                y += 13
            }
            let box = R(rect.minX + 6, y + 3, rect.width - 12, 14)
            r.fill(c.divider, box.insetBy(dx: -1, dy: -1))
            r.fill(c.itemBackground, box)
            r.ttf(t.url.path, font: value, color: c.itemForeground, x: box.minX + 4, baseline: box.minY + 10, maxWidth: box.width - 8)
        }
        return view
    }
}
